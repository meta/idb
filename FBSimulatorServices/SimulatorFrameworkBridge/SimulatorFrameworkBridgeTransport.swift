/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation

package enum BridgeServiceScope: Sendable, Hashable {
  case shared
  case exclusive
}

protocol BridgeConnection: Sendable {
  var mayBeHeldBetweenRoundTrips: Bool { get }
  /// One request and its response. `receiveTimeout` replaces the connection's usual silence deadline for this
  /// round trip; nil keeps it.
  func roundTrip(_ requestData: Data, receiveTimeout: TimeInterval?) async throws -> Data
}

extension BridgeConnection {
  func roundTrip(_ requestData: Data) async throws -> Data {
    try await roundTrip(requestData, receiveTimeout: nil)
  }
}

/// Where a persistent transport's connections to a guest come from.
protocol BridgeConnector: Sendable {
  func connection() async throws -> any BridgeConnection
  /// A connection held for the whole of one stream.
  func streamConnection() async throws -> SimulatorFrameworkBridgeConnection
}

extension BridgeConnector {
  func streamConnection() async throws -> SimulatorFrameworkBridgeConnection {
    throw AXBridgeError.bridgeUnavailable
  }
}

/// Owns the lifecycle of a shared or exclusive SimulatorFrameworkBridge guest.
package actor SimulatorFrameworkBridgePersistentTransport: AXBridgeStreamingTransport {
  private let connector: any BridgeConnector
  private var connectionTask: Task<any BridgeConnection, any Error>?
  private var connectionGeneration = UUID()

  init(simulator: Simulator, scope: BridgeServiceScope) {
    self.init(connector: SimulatorBridgeConnector(simulator: simulator, scope: scope))
  }

  init(connector: any BridgeConnector) {
    self.connector = connector
  }

  package func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply {
    try await reply(to: request, receiveTimeout: nil)
  }

  /// Bounds the guest's silence on the socket itself, so a timed-out round trip drops its connection rather
  /// than leaving a late reply for the next request.
  package func send(_ request: AXBridgeRequest, receiveTimeout: TimeInterval) async throws -> AXBridgeReply {
    try await reply(to: request, receiveTimeout: receiveTimeout)
  }

  private func reply(to request: AXBridgeRequest, receiveTimeout: TimeInterval?) async throws -> AXBridgeReply {
    do {
      let response = try await exchange(BridgeRequest(command: request.command), receiveTimeout: receiveTimeout)
      return AXBridgeReply(answer: try response.result.accessibilityAnswer(), frameBytes: response.frameBytes)
    } catch let error as DecodingError {
      throw AXBridgeReply.unparseable(error, answering: request)
    }
  }

  func send(_ request: BridgeRequest, receiveTimeout: TimeInterval? = nil) async throws -> BridgeResult {
    try await exchange(request, receiveTimeout: receiveTimeout).result
  }

  private func exchange(_ request: BridgeRequest, receiveTimeout: TimeInterval?) async throws -> (result: BridgeResult, frameBytes: Int) {
    do {
      return try await roundTrip(request, receiveTimeout: receiveTimeout)
    } catch AXBridgeError.guestNotAnswering(let after) {
      // The caller's time is spent; a retry would take as long again.
      throw AXBridgeError.guestNotAnswering(after: after)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard request.command.mayRetry else { throw error }
      return try await roundTrip(request, receiveTimeout: receiveTimeout)
    }
  }

  package func stream(_ request: AXBridgeRequest) async throws -> AsyncThrowingStream<BridgeAXAnswer, any Error> {
    let results = try await connector.streamConnection().stream(BridgeRequest(command: request.command))
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          do {
            for try await result in results {
              continuation.yield(try result.accessibilityAnswer())
            }
          } catch let error as DecodingError {
            throw AXBridgeReply.unparseable(error, answering: request)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func roundTrip(_ request: BridgeRequest, receiveTimeout: TimeInterval?) async throws -> (result: BridgeResult, frameBytes: Int) {
    let lease = try await connection()
    do {
      let frame = try await lease.connection.roundTrip(request.encoded(), receiveTimeout: receiveTimeout)
      let response = try BridgeResponse.decode(frame, for: request)
      if request.command == .shutdown || !lease.connection.mayBeHeldBetweenRoundTrips { invalidate(lease.generation) }
      return (response.result, frame.count)
    } catch {
      invalidate(lease.generation)
      throw error
    }
  }

  private func invalidate(_ generation: UUID) {
    if connectionGeneration == generation { connectionTask = nil }
  }

  private func connection() async throws -> (generation: UUID, connection: any BridgeConnection) {
    if let connectionTask {
      let generation = connectionGeneration
      return (generation, try await connectionTask.value)
    }
    let generation = UUID()
    connectionGeneration = generation
    let connector = connector
    let task = Task { try await connector.connection() }
    connectionTask = task
    do {
      return (generation, try await task.value)
    } catch {
      invalidate(generation)
      throw error
    }
  }

  static let idleTimeoutSeconds = 300

  static func serveArguments(
    socketPath: String,
    scope: BridgeServiceScope,
    idleTimeoutSeconds: Int = idleTimeoutSeconds
  ) -> [String] {
    var arguments = ["serve", socketPath, "--idle-timeout", "\(idleTimeoutSeconds)"]
    if scope == .exclusive {
      arguments += ["--exit-on-disconnect", "1"]
    }
    return arguments
  }

  static let adoptionTimeout: TimeInterval = 0.25

  private enum RunningBridge {
    case adopted(Int32)
    case absent
    case busy
  }

  fileprivate static func establish(
    simulator: Simulator?,
    scope: BridgeServiceScope
  ) async throws -> SimulatorFrameworkBridgeConnection {
    guard let simulator else {
      throw WeakTargetError.simulator
    }
    guard let helperPath = simulator.frameworkBridgePath else {
      throw AXBridgeError.bridgeUnavailable
    }
    try SimulatorFrameworkBridgeSocket.prepareDirectory()

    if scope == .exclusive {
      let privatePath = SimulatorFrameworkBridgeSocket.path(forConnection: UUID().uuidString)
      return try await spawn(
        simulator: simulator,
        helperPath: helperPath,
        socketPath: privatePath,
        scope: .exclusive,
        ownership: { .privateToThisHost($0) }
      )
    }

    let sharedPath = SimulatorFrameworkBridgeSocket.path(forSimulator: simulator.udid)
    switch await runningBridge(at: sharedPath) {
    case let .adopted(fileDescriptor):
      simulator.logger.log("Adopted the SimulatorFrameworkBridge guest already serving on \(sharedPath)")
      return SimulatorFrameworkBridgeConnection(fileDescriptor: fileDescriptor, ownership: .shared(nil))
    case .absent:
      return try await spawn(
        simulator: simulator,
        helperPath: helperPath,
        socketPath: sharedPath,
        scope: .shared,
        ownership: { .shared($0) }
      )
    case .busy:
      let privatePath = SimulatorFrameworkBridgeSocket.path(forConnection: UUID().uuidString)
      simulator.logger.log(
        "The SimulatorFrameworkBridge guest on \(sharedPath) is serving another client; starting a private one on \(privatePath)"
      )
      return try await spawn(
        simulator: simulator,
        helperPath: helperPath,
        socketPath: privatePath,
        scope: .exclusive,
        ownership: { .privateToThisHost($0) }
      )
    }
  }

  private static func runningBridge(at path: String) async -> RunningBridge {
    guard FileManager.default.fileExists(atPath: path) else {
      return .absent
    }
    let fileDescriptor: Int32
    do {
      fileDescriptor = try await SimulatorFrameworkBridgeConnection.connect(path: path, timeout: adoptionTimeout)
    } catch {
      return .absent
    }
    return await DispatchQueue.global().perform {
      probe(fileDescriptor: fileDescriptor)
    }
  }

  /// Converts a deadline without rounding a positive sub-second value down to an all-zero `timeval`,
  /// which the kernel interprets as no deadline.
  static func receiveWindow(_ timeout: TimeInterval) -> timeval {
    let whole = timeout.rounded(.down)
    return timeval(tv_sec: Int(whole), tv_usec: Int32((timeout - whole) * 1_000_000))
  }

  private static func probe(fileDescriptor: Int32) -> RunningBridge {
    // A successful connect only means the listen backlog accepted us. The guest serves one connection
    // at a time, so a round trip is the only way to distinguish an adoptable guest from a busy one.
    var window = receiveWindow(adoptionTimeout)
    unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
    do {
      let request = BridgeRequest(command: .ping)
      try SimulatorFrameworkBridgeConnection.writeFrame(fileDescriptor, request.encoded())
      let response = try BridgeResponse.decode(SimulatorFrameworkBridgeConnection.readFrame(fileDescriptor, guest: nil), for: request)
      guard response.result.exitCode == 0 else { throw AXBridgeError.guestFailure("bridge handshake failed") }
    } catch {
      close(fileDescriptor)
      return .busy
    }
    var readTimeout = timeval(tv_sec: SimulatorFrameworkBridgeConnection.receiveTimeoutSeconds, tv_usec: 0)
    unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
    return .adopted(fileDescriptor)
  }

  private static func spawn(
    simulator: Simulator,
    helperPath: String,
    socketPath: String,
    scope: BridgeServiceScope,
    ownership: (RunningSubprocess) -> BridgeGuestOwnership
  ) async throws -> SimulatorFrameworkBridgeConnection {
    let process = try await Subprocess(
      executable: helperPath,
      arguments: serveArguments(socketPath: socketPath, scope: scope),
      environment: .exact([:])
    )
    .launch(on: SimulatorSubprocessLauncher(simulator: simulator), output: .nullDevice, error: .nullDevice)
    do {
      let fileDescriptor = try await SimulatorFrameworkBridgeConnection.connect(path: socketPath, timeout: 10, guest: process, scope: scope)
      return SimulatorFrameworkBridgeConnection(fileDescriptor: fileDescriptor, ownership: ownership(process))
    } catch {
      simulator.logger.log("Could not reach the SimulatorFrameworkBridge guest just spawned on \(socketPath): \(error)")
      throw error
    }
  }
}

/// Holds the `Simulator` weakly, as the command cache that owns this transport is the simulator's.
private struct SimulatorBridgeConnector: BridgeConnector {
  weak var simulator: Simulator?
  let scope: BridgeServiceScope

  func connection() async throws -> any BridgeConnection {
    try await SimulatorFrameworkBridgePersistentTransport.establish(simulator: simulator, scope: scope)
  }

  // Each stream gets a guest of its own, whatever this transport's scope: a guest serves one connection
  // at a time, and a stream holds its connection until the consumer stops.
  func streamConnection() async throws -> SimulatorFrameworkBridgeConnection {
    try await SimulatorFrameworkBridgePersistentTransport.establish(simulator: simulator, scope: .exclusive)
  }
}
