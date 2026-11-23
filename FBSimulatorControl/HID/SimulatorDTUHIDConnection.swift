/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import XPC
import os

/// The waits `SimulatorDTUHIDConnection` performs around the events it sends.
enum DTUHIDTiming {

  /// Time allowed for a warm connection to dispatch events before disconnecting.
  static let drain = Duration.milliseconds(80)

  /// Time allowed for device-open and dispatch after the barrier reply signals peer activation.
  static let replyTail = Duration.milliseconds(200)

  /// Deadline for the connect-time liveness reply. Generous because this is the send that
  /// demand-launches `dtuhidd`, so it pays for the daemon's cold start.
  static let livenessTimeout = DispatchTimeInterval.seconds(4)

  /// Wait between liveness attempts. `dtuhidd` declares a 10s `minimum runtime`, so launchd
  /// throttles the respawn of one that aborted before reaching it; retrying sooner only re-reads
  /// the same throttled job.
  static let livenessRetryBackoff = Duration.seconds(4)

  /// Liveness attempts before the transport is reported unreachable.
  ///
  /// Sized from a measured recovery: a daemon that aborted repeatedly through a slow boot answered
  /// roughly 19s after the boot finished, launchd's exponential respawn throttle being what that
  /// wait is made of rather than the daemon's own start-up. At `livenessTimeout + livenessRetryBackoff`
  /// per attempt that took three, so three is the floor, not the budget.
  static let livenessAttempts = 5
}

/// Injectable waits for the DTUHID transport.
protocol DTUHIDSleeper: Sendable {
  func sleep(for duration: Duration) async throws
}

struct TaskSleeper: DTUHIDSleeper {
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/**
 One host XPC connection to a `dtuhidd` HID service, and the drain that lets events sent on it reach the
 guest before it is torn down. Knows nothing of what the events mean: each transport encodes its own
 payloads and writes them here.

 A class rather than an actor so `write` is synchronous: a transport assigning order-dependent state
 (a contact's start/position/end) writes before it next suspends, which a hop onto another actor
 would not guarantee. The XPC connection is thread-safe, and the send counters are behind a lock.
 */
final class SimulatorDTUHIDConnection: Sendable {

  private let channel: SimulatorXPCChannel
  let serviceName: String
  private let sleeper: any DTUHIDSleeper
  // A drain claims a snapshot of the send count; later sends remain outstanding.
  private let generations = OSAllocatedUnfairLock(initialState: (sent: 0, drained: 0))
  private let interruptionCount = OSAllocatedUnfairLock(initialState: 0)

  /// Connects to the simulator's DTUHID service, confirming a live `dtuhidd` answers before the
  /// connection is handed out.
  ///
  /// Retried, because the daemon's startup races the guest's. `dtuhidd` is demand-launched early in
  /// boot and asks CoreAnimation for the display list, which aborts the process outright when no
  /// display is up yet — reliably so on a boot slow enough to still be `WaitingOnBackboard`. What is
  /// left behind is a job launchd will respawn but has throttled, for which the service lookup below
  /// still yields a port and every send is then silently discarded. The window is seconds wide and
  /// closes once the boot settles, so a backed-off retry recovers the full transport, keyboard
  /// included, where giving up would cost the keyboard for the lifetime of the boot.
  static func connect(
    using connector: SimulatorXPCConnector, serviceName: String, sleeper: any DTUHIDSleeper = TaskSleeper()
  ) async throws -> SimulatorDTUHIDConnection {
    let logger = ControlCoreGlobalConfiguration.defaultLogger
    var lastFailure: (any Error)?
    for attempt in 1...DTUHIDTiming.livenessAttempts {
      do {
        return try await connected(using: connector, serviceName: serviceName, sleeper: sleeper)
      } catch let error as SimulatorHIDError where error.isPermanentDTUHIDFailure {
        throw error
      } catch {
        lastFailure = error
        logger.log(
          "dtuhidd did not answer the liveness probe (attempt \(attempt) of \(DTUHIDTiming.livenessAttempts)): \(error)")
        guard attempt < DTUHIDTiming.livenessAttempts else {
          break
        }
        try await sleeper.sleep(for: DTUHIDTiming.livenessRetryBackoff)
      }
    }
    throw SimulatorHIDError.dtuhidUnresponsive(
      attempts: DTUHIDTiming.livenessAttempts, underlying: lastFailure)
  }

  /// One attempt: look the service up, connect, and prove a daemon is behind it.
  ///
  /// The lookup belongs to the attempt rather than preceding the loop: a failed attempt cancels its
  /// connection, and a cancelled XPC connection cannot be resumed.
  private static func connected(
    using connector: SimulatorXPCConnector, serviceName: String, sleeper: any DTUHIDSleeper
  ) async throws -> SimulatorDTUHIDConnection {
    let connection = SimulatorDTUHIDConnection(
      channel: try await channel(using: connector, serviceName: serviceName),
      serviceName: serviceName,
      sleeper: sleeper)
    do {
      try await connection.confirmLiveness()
    } catch {
      connection.disconnect()
      throw error
    }
    return connection
  }

  /// A channel to the requested guest HID service. Says nothing about whether `dtuhidd` is able to
  /// run — launchd vends the port for a demand-launched job either way.
  ///
  /// A simulator that is still booting is waited on rather than retried: nothing is vended until the
  /// boot completes, however long that takes.
  private static func channel(using connector: SimulatorXPCConnector, serviceName: String) async throws -> SimulatorXPCChannel {
    do {
      return try channel(connecting: connector, serviceName: serviceName)
    } catch SimulatorHIDError.dtuhidSimulatorNotBooted(_, .booting) {
      try await connector.bootFinished()
      return try channel(connecting: connector, serviceName: serviceName)
    }
  }

  private static func channel(connecting connector: SimulatorXPCConnector, serviceName: String) throws -> SimulatorXPCChannel {
    do {
      return SimulatorXPCChannel(
        connection: try connector.connect(serviceName),
        queue: DispatchQueue(label: "com.facebook.FBSimulatorControl.dtuhid"))
    } catch let error as SimulatorXPCConnectionError {
      throw SimulatorHIDError(dtuhidConnection: error)
    }
  }

  init(channel: SimulatorXPCChannel, serviceName: String, sleeper: any DTUHIDSleeper = TaskSleeper()) {
    self.channel = channel
    self.serviceName = serviceName
    self.sleeper = sleeper
    channel.activate { [weak self] event in
      self?.observe(event)
    }
  }

  /// How many times `dtuhidd` has dropped this connection. XPC reconnects on the next send, but
  /// anything the daemon held for the connection, such as a gesture in progress, is gone.
  var interruptions: Int {
    interruptionCount.withLock { $0 }
  }

  func observe(_ event: SimulatorXPCEvent) {
    guard case .interrupted = event else { return }
    interruptionCount.withLock { $0 += 1 }
    ControlCoreGlobalConfiguration.defaultLogger.log("dtuhidd connection (\(serviceName)) was interrupted")
  }

  /// Round-trips a barrier to establish that a `dtuhidd` is behind the connection and has activated.
  ///
  /// The only observation available: every step of building the connection succeeds against a
  /// daemon that cannot run, and a send to one reports no error, so an unanswered probe is what
  /// separates a working transport from a black hole.
  ///
  /// A reply also means the peer activated. Paying the device-open tail here, before the connection
  /// is handed out, is what lets every later drain be the short warm one.
  ///
  /// An XPC error reply fails rather than resolving: the probe asks whether there is a peer at all,
  /// so XPC's own answer is the negative result.
  func confirmLiveness() async throws {
    _ = try await channel.request(barrierMessage(), timeout: DTUHIDTiming.livenessTimeout)
    try await sleeper.sleep(for: DTUHIDTiming.replyTail)
  }

  func disconnect() {
    channel.cancel()
  }

  // MARK: - Sending

  /// Wraps `payload` in a `DTUHIDMessage` and serializes it to the `xpc_object_t` `dtuhidd` decodes.
  func encode(messageType: String, payload: some Encodable, isBarrier: Bool = false) throws -> xpc_object_t {
    let message = DTUHIDMessage(
      messageType: messageType,
      featureIdentifier: serviceName,
      isBarrier: isBarrier,
      payload: payload)
    return try XPCEncoder().encode(message)
  }

  /// Encodes `payload` and hands it to XPC before returning, marking it outstanding for `flush()`.
  /// Throws once the connection has been invalidated.
  func write(messageType: String, payload: some Encodable) throws {
    let object = try encode(messageType: messageType, payload: payload)
    do {
      try channel.send(object)
    } catch SimulatorXPCError.invalidated {
      throw SimulatorHIDError.dtuhidConnectionInvalidated(name: serviceName)
    }
    generations.withLock { $0.sent += 1 }
  }

  /// Resolves once XPC has sent everything written before this call. Does not wait for the daemon to
  /// consume it — that is `flush()`'s job, run once per gesture rather than per primitive.
  func awaitSendBarrier() async {
    await channel.sendBarrier()
  }

  /// `write` then `awaitSendBarrier`, for a sender with no order-dependent state to guard.
  func send(messageType: String, payload: some Encodable) async throws {
    try write(messageType: messageType, payload: payload)
    await awaitSendBarrier()
  }

  /// Allows time for events sent before this call to reach the guest before disconnecting.
  /// Returns immediately when no sends are outstanding.
  func flush() async throws {
    let generation = generations.withLock { $0.sent }
    guard generation > generations.withLock({ $0.drained }) else {
      return
    }
    try await sleeper.sleep(for: DTUHIDTiming.drain)
    generations.withLock { $0.drained = max($0.drained, generation) }
  }

  /// A barrier carrying usage `0` — "no event indicated" — so the daemon answers without the guest
  /// seeing a keypress.
  private func barrierMessage() throws -> xpc_object_t {
    try encode(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: 0, state: .up),
      isBarrier: true)
  }
}
