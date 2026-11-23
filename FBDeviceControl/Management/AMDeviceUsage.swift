/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import MobileDeviceAPI

private let mobileBackupDomain = "com.apple.mobile.backup"

/// Taking a single device into and out of use: connecting, pairing, and opening a session.
///
/// Separate from `AMDeviceManager`, which discovers the *set* of devices. These operate on one
/// device and are what `MobileDevice` wraps around every operation it performs.
public enum AMDeviceUsage {

  /// Connects to the device and opens a session on it, pairing first if required.
  public static func start(using device: AMDevice, calls: AMDCalls, logger: any ControlCoreLogger) throws {
    try startConnection(to: device, calls: calls, logger: logger)
    try startSessionByPairing(with: device, calls: calls, logger: logger)
    logger.log("\(device) ready for use")
  }

  /// Ends the session and then the connection.
  public static func stop(using device: AMDevice, calls: AMDCalls, logger: any ControlCoreLogger) {
    stopSession(with: device, calls: calls, logger: logger)
    stopConnection(to: device, calls: calls, logger: logger)
  }

  // MARK: - Steps

  internal static func startConnection(
    to device: AMDevice,
    calls: AMDCalls,
    logger: any ControlCoreLogger
  ) throws {
    logger.log("Connecting to \(device)")
    let status = calls.Connect(device)
    guard status == 0 else {
      throw AMDeviceManagerError.connectFailed(device: "\(device)", message: errorText(status, calls: calls))
    }
  }

  internal static func startSessionByPairing(
    with device: AMDevice,
    calls: AMDCalls,
    logger: any ControlCoreLogger
  ) throws {
    logger.log("Checking whether \(device) is paired")
    if calls.IsPaired(device) == 0 {
      logger.log("\(device) is not paired, attempting to pair")
      let status = calls.Pair(device)
      guard status == 0 else {
        throw AMDeviceManagerError.notPaired(device: "\(device)", message: errorText(status, calls: calls))
      }
      logger.log("\(device) succeeded pairing request")
    }

    logger.log("Validating Pairing to \(device)")
    let validateStatus = calls.ValidatePairing(device)
    guard validateStatus == 0 else {
      throw AMDeviceManagerError.pairingValidationFailed(
        device: "\(device)", message: errorText(validateStatus, calls: calls))
    }

    logger.log("Starting Session on \(device)")
    let sessionStatus = calls.StartSession(device)
    guard sessionStatus == 0 else {
      _ = calls.Disconnect(device)
      throw AMDeviceManagerError.sessionFailed(message: errorText(sessionStatus, calls: calls))
    }
  }

  internal static func stopSession(
    with device: AMDevice,
    calls: AMDCalls,
    logger: any ControlCoreLogger
  ) {
    logger.log("Stopping Session on \(device)")
    _ = calls.StopSession(device)
  }

  internal static func stopConnection(
    to device: AMDevice,
    calls: AMDCalls,
    logger: any ControlCoreLogger
  ) {
    logger.log("Disconnecting from \(device)")
    _ = calls.Disconnect(device)
    logger.log("Disconnected from \(device)")
  }

  internal static func obtainDeviceValues(_ device: AMDevice, calls: AMDCalls) -> [String: Any]? {
    // The default domain is readable even when unpaired.
    guard var info = calls.CopyValue(device, nil, nil)?.takeRetainedValue() as? [String: Any] else {
      return nil
    }

    info[DeviceKey.isPaired.rawValue] = calls.IsPaired(device) != 0

    // Only meaningful when paired.
    let backupInfo =
      calls.CopyValue(device, mobileBackupDomain as CFString, nil)?.takeRetainedValue() as? [String: Any] ?? [:]
    info[mobileBackupDomain] = backupInfo

    return info
  }

  private static func errorText(_ status: Int32, calls: AMDCalls) -> String {
    calls.CopyErrorText(status)?.takeRetainedValue() as String? ?? "Unknown error"
  }

}

/// The AMDevice session everything a device does runs inside.
///
/// Sessions nest and overlap: every device command opens one, and house arrest opens one around
/// work that opens more. So users are counted rather than serialised — the first opens the
/// session, the last closes it, and everyone in between shares it. With a `reuseTimeout` the
/// session outlives its last user by that long, so a following operation re-uses it instead of
/// connecting again; without one it is closed as soon as it is released.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class AMDeviceSession: @unchecked Sendable {

  /// Whether the session is open, and whether someone is part way through changing that.
  ///
  /// `opening` and `closing` are what a caller arriving mid-transition waits on. Without them it
  /// would see `closed` while a disconnect was still in flight and start a connect on top of it.
  private enum State {
    case closed
    case opening
    case open
    case closing
  }

  // MARK: - Properties

  private weak var device: MobileDevice?
  private let reuseTimeout: TimeInterval?
  private let logger: any ControlCoreLogger

  private let lock = NSLock()
  private var state: State = .closed
  private var users = 0
  // Keyed rather than a list: a waiter whose task is cancelled has to be taken out of the set
  // individually, and its id is the only handle the cancellation handler has on it.
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var idleTeardown: Task<Void, Never>?

  init(device: MobileDevice, reuseTimeout: TimeInterval?, logger: any ControlCoreLogger) {
    self.device = device
    self.reuseTimeout = reuseTimeout
    self.logger = logger
  }

  // MARK: - Public Methods

  /// Takes a share of the session, opening it if no one holds it yet. Every call that returns
  /// without throwing must be paired with a `release()`.
  ///
  /// The lock is never held across the MobileDevice calls, which block until the device answers;
  /// a caller arriving mid-transition suspends on a continuation and re-reads the state when woken.
  ///
  /// Waiting is cancellable; connecting is not (the MobileDevice calls are synchronous). A
  /// cancelled caller therefore never holds a share it cannot `release()`.
  func acquire() async throws {
    while true {
      try Task.checkCancellation()
      switch arrive() {
      case .tookAShare:
        return
      case .mustOpen:
        try openSession()
        return
      case .transitionInProgress:
        try await waitForSettle()
      }
    }
  }

  /// Gives up a share of the session, closing it once the last user is done with it.
  ///
  /// Synchronous, so that it can be the `defer` half of the pattern its callers are written in.
  func release() {
    lock.lock()
    users -= 1
    guard users == 0, state == .open else {
      lock.unlock()
      return
    }
    idleTeardown?.cancel()
    idleTeardown = nil
    guard let reuseTimeout else {
      state = .closing
      lock.unlock()
      closeSession()
      return
    }
    idleTeardown = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(reuseTimeout * Double(NSEC_PER_SEC)))
      guard !Task.isCancelled else {
        return
      }
      self?.closeIfUnused()
    }
    lock.unlock()
    logger.log("No more users of the device session, pooling it for \(reuseTimeout) seconds of inactivity")
  }

  // MARK: - Private

  /// What a caller found when it got to the session, and so what it has to do about it.
  private enum Arrival {
    case tookAShare
    case mustOpen
    case transitionInProgress
  }

  private func arrive() -> Arrival {
    lock.lock()
    defer { lock.unlock() }
    idleTeardown?.cancel()
    idleTeardown = nil
    switch state {
    case .open:
      users += 1
      return .tookAShare
    case .opening, .closing:
      return .transitionInProgress
    case .closed:
      state = .opening
      return .mustOpen
    }
  }

  /// Suspends until the transition in flight has settled, or the calling task is cancelled.
  private func waitForSettle() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        park(id, continuation)
      }
    } onCancel: {
      cancelWaiter(id)
    }
  }

  /// The transition can settle between `arrive` reporting it and this parking against it, so the
  /// state is re-read here. Without that the continuation would join an already-drained set of
  /// waiters and never be resumed.
  ///
  /// The cancellation check closes the same window against `cancelWaiter`, which runs as soon as
  /// the task is cancelled and so can find nothing to remove because this has yet to park.
  private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    guard !Task.isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    switch state {
    case .opening, .closing:
      waiters[id] = continuation
      lock.unlock()
    case .open, .closed:
      lock.unlock()
      continuation.resume()
    }
  }

  private func cancelWaiter(_ id: UUID) {
    lock.lock()
    let continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }

  /// Connects outside the lock, then publishes the outcome. A failure leaves the session closed
  /// rather than half-open, so the next caller starts from scratch.
  private func openSession() throws {
    do {
      guard let device, let amDevice = device.amDevice else {
        throw AMDeviceServiceError.deviceNotConnected(service: "connect")
      }
      try AMDeviceUsage.start(using: amDevice, calls: device.calls, logger: logger)
    } catch {
      settle(.closed)
      throw error
    }
    settle(.open, takingAShare: true)
  }

  private func closeSession() {
    if let device, let amDevice = device.amDevice {
      AMDeviceUsage.stop(using: amDevice, calls: device.calls, logger: logger)
    }
    settle(.closed)
  }

  /// Publishes the end of a transition and wakes everyone who arrived during it. They re-read the
  /// state rather than being handed a result, since it decides whether they share this session or
  /// open the next one.
  private func settle(_ newState: State, takingAShare: Bool = false) {
    lock.lock()
    state = newState
    if takingAShare {
      users += 1
    }
    let resuming = Array(waiters.values)
    waiters.removeAll()
    lock.unlock()
    for continuation in resuming {
      continuation.resume()
    }
  }

  /// The idle window is best-effort cancelled rather than reliably so, hence the second check for
  /// a user that took the session while it was running out.
  private func closeIfUnused() {
    lock.lock()
    guard users == 0, state == .open else {
      lock.unlock()
      return
    }
    state = .closing
    lock.unlock()
    closeSession()
  }
}
