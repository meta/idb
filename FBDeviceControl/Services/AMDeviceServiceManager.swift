/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

enum AMDeviceServiceError: Error {
  case houseArrestStartFailed(bundleID: String, status: Int32, message: String)
  case houseArrestConnectionMissing(bundleID: String)
  case notAnAFCConnection(context: String)
  case secureStartServiceFailed(service: String, status: Int32, message: String)
  case deviceNotConnected(service: String)
  case notAMDeviceBacked(service: String)
}

extension AMDeviceServiceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case let .houseArrestStartFailed(bundleID, status, message):
      return "Failed to start house_arrest service for '\(bundleID)' with error 0x\(String(status, radix: 16)) (\(message))"
    case let .houseArrestConnectionMissing(bundleID):
      return "No house_arrest connection was returned for '\(bundleID)'"
    case let .notAnAFCConnection(context):
      return "\(context) is not a FileConduit"
    case let .secureStartServiceFailed(service, status, message):
      return "SecureStartService of \(service) Failed with 0x\(String(status, radix: 16)) \(message)"
    case let .deviceNotConnected(service):
      return "Cannot start service \(service): device is not connected"
    case let .notAMDeviceBacked(service):
      return "Cannot start service \(service): the device is not AMDevice backed"
    }
  }
}

/// The house arrest service for a single bundle id, and the AFC connection it vends.
///
/// One consumer uses the connection at a time and the rest wait for it. When the last consumer
/// releases it the connection is not closed but pooled for `reuseTimeout`, so a following
/// operation on the same bundle re-uses it instead of paying for another
/// `AMDeviceCreateHouseArrestService`. With no timeout it is closed as soon as it is released.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class HouseArrestService: @unchecked Sendable {

  // MARK: - Properties

  private weak var device: MobileDevice?
  private let bundleID: String
  private let afcCalls: AFCCalls
  private let reuseTimeout: TimeInterval?
  private let logger: any ControlCoreLogger

  private let lock = NSLock()
  private var connection: FileConduit?
  private var inUse = false
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
  private var idleTeardown: Task<Void, Never>?

  init(device: MobileDevice, bundleID: String, afcCalls: AFCCalls, reuseTimeout: TimeInterval?) {
    self.device = device
    self.bundleID = bundleID
    self.afcCalls = afcCalls
    self.reuseTimeout = reuseTimeout
    self.logger = device.logger.withName("house_arrest_\(bundleID)")
  }

  deinit {
    idleTeardown?.cancel()
    close(connection)
  }

  // MARK: - Public Methods

  /// Waits for exclusive use of the connection, opening it if it is not already established.
  ///
  /// Every call that returns a connection must be paired with a `release()`.
  func acquire() async throws -> FileConduit {
    try await takeExclusiveUse()
    if let established = establishedConnection() {
      logger.log("Re-using the existing house arrest connection for '\(bundleID)'")
      return established
    }
    do {
      let opened = try openConnection()
      store(opened)
      return opened
    } catch {
      // Use was taken before the connection could be opened, so it has to be handed on from here.
      release()
      throw error
    }
  }

  /// Gives up use of the connection, passing it to the next waiter or pooling it for reuse.
  func release() {
    lock.lock()
    // Waiters are served back to front. `inUse` stays set: use passes straight on to the consumer
    // resumed here.
    if let next = waiters.popLast() {
      lock.unlock()
      next.continuation.resume()
      return
    }
    inUse = false
    idleTeardown?.cancel()
    idleTeardown = nil
    guard let reuseTimeout else {
      let closing = connection
      connection = nil
      lock.unlock()
      close(closing)
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
    logger.log("No more consumers of house arrest for '\(bundleID)', pooling it for \(reuseTimeout) seconds of inactivity")
  }

  // MARK: - Private

  /// Suspends until the connection is free, or the calling task is cancelled.
  private func takeExclusiveUse() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        park(id, continuation)
      }
    } onCancel: {
      cancelWaiter(id)
    }
  }

  /// The cancellation check closes the window against `cancelWaiter`, which runs as soon as the
  /// task is cancelled and so can find nothing to remove because this has yet to park.
  private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    guard !Task.isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    idleTeardown?.cancel()
    idleTeardown = nil
    if inUse {
      waiters.append((id: id, continuation: continuation))
      lock.unlock()
      return
    }
    inUse = true
    lock.unlock()
    continuation.resume()
  }

  private func cancelWaiter(_ id: UUID) {
    lock.lock()
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    let (_, continuation) = waiters.remove(at: index)
    lock.unlock()
    continuation.resume(throwing: CancellationError())
  }

  private func establishedConnection() -> FileConduit? {
    lock.lock()
    defer { lock.unlock() }
    return connection
  }

  private func store(_ connection: FileConduit) {
    lock.lock()
    self.connection = connection
    lock.unlock()
  }

  private func openConnection() throws -> FileConduit {
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    logger.log("Starting house arrest for '\(bundleID)'")
    var afcConnection: Unmanaged<AnyObject>?
    let status =
      unsafe device.calls.CreateHouseArrestService?(
        device.amDeviceRef,
        bundleID as CFString,
        nil,
        &afcConnection
      ) ?? -1
    guard status == 0 else {
      let message = unsafe device.calls.CopyErrorText?(status)?.takeRetainedValue() as String? ?? "unknown"
      throw AMDeviceServiceError.houseArrestStartFailed(bundleID: bundleID, status: status, message: message)
    }
    guard let afcConnection = unsafe afcConnection else {
      throw AMDeviceServiceError.houseArrestConnectionMissing(bundleID: bundleID)
    }
    return unsafe FileConduit(connection: afcConnection.takeUnretainedValue(), calls: afcCalls, logger: logger)
  }

  /// The idle window is best-effort cancelled rather than reliably so, hence the second check for
  /// a consumer that took the connection while it was running out.
  private func closeIfUnused() {
    lock.lock()
    if inUse {
      lock.unlock()
      logger.log("Not tearing down house arrest for '\(bundleID)' as it has a consumer again")
      return
    }
    let closing = connection
    connection = nil
    lock.unlock()
    close(closing)
  }

  private func close(_ connection: FileConduit?) {
    guard let connection else {
      return
    }
    logger.log("Closing the connection to house arrest for '\(bundleID)'")
    do {
      try connection.close()
      logger.log("Closed house arrest for '\(bundleID)'")
    } catch {
      logger.log("Failed to close house arrest for '\(bundleID)' with error \(error)")
    }
  }
}

/// The house arrest services a device has opened, one per bundle id.
///
/// `@unchecked Sendable`: the service map is guarded by `lock`.
final class AMDeviceServiceManager: @unchecked Sendable {

  private weak var device: MobileDevice?
  private let serviceTimeout: TimeInterval?
  private let lock = NSLock()
  private var houseArrestServices: [String: HouseArrestService] = [:]

  init(device: MobileDevice, serviceTimeout: TimeInterval?) {
    self.device = device
    self.serviceTimeout = serviceTimeout
  }

  // MARK: - Public Services

  /// The house arrest service for `bundleID`, created on first use and kept for the device's life.
  func houseArrestService(forBundleID bundleID: String, afcCalls: AFCCalls) -> HouseArrestService {
    lock.lock()
    defer { lock.unlock() }
    if let existing = houseArrestServices[bundleID] {
      return existing
    }
    guard let device else {
      preconditionFailure("Device is nil when creating house arrest connection for '\(bundleID)'")
    }
    let service = HouseArrestService(device: device, bundleID: bundleID, afcCalls: afcCalls, reuseTimeout: serviceTimeout)
    houseArrestServices[bundleID] = service
    return service
  }
}
