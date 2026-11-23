/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/// A simulator's CoreDevice features, reached one request at a time.
///
/// Owns what every request shares: the device identifier, the installed CoreDevice version (read
/// once), the queue the sessions run on, and how a service is connected to. Features supply only
/// what is theirs: the action, the service, the request and how to read the reply.
/// Memoized per `Simulator` through its command cache.
///
// SAFETY: The version and capability caches are guarded by the lock; everything else is immutable.
// patternlint-disable-next-line unchecked-sendable
final class SimulatorCoreDeviceClient: @unchecked Sendable {
  typealias VersionSource = @Sendable () throws -> CoreDeviceVersion

  private let deviceID: String
  private let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.coredevice")
  private let connector: SimulatorXPCConnector
  private let readVersion: VersionSource
  private let lock = NSLock()
  private var cachedVersion: CoreDeviceVersion?
  private var cachedMotionCapabilities: MotionCapabilities?

  init(deviceID: String, connector: SimulatorXPCConnector, version: @escaping VersionSource = CoreDeviceVersion.installed) {
    self.deviceID = deviceID
    self.connector = connector
    self.readVersion = version
  }

  /// The installed CoreDevice version, read once. Only a successful read is kept, so a failure is
  /// reported again on the next request rather than remembered.
  func version() throws -> CoreDeviceVersion {
    lock.lock()
    defer { lock.unlock() }
    if let cachedVersion { return cachedVersion }
    let version = try readVersion()
    cachedVersion = version
    return version
  }

  /// The motion capabilities the simulator advertises, queried once: they are a property of the
  /// runtime and device type, fixed for the simulator's lifetime. Only an answered query is kept.
  /// A runtime that cannot answer is asked again, since a simulator that is not yet booted cannot
  /// answer either.
  func motionCapabilities() async throws -> MotionCapabilities {
    if let cached = rememberedMotionCapabilities() { return cached }
    let capabilities = try await perform(
      action: MotionCapabilities.action, service: MotionCapabilities.service, input: CoreDeviceEmptyInput(), as: MotionCapabilities.self)
    remember(capabilities)
    return capabilities
  }

  private func rememberedMotionCapabilities() -> MotionCapabilities? {
    lock.lock()
    defer { lock.unlock() }
    return cachedMotionCapabilities
  }

  private func remember(_ capabilities: MotionCapabilities) {
    lock.lock()
    defer { lock.unlock() }
    cachedMotionCapabilities = capabilities
  }

  // MARK: - CoreDevice actions

  /// One action, one reply, with the output decoded by the caller.
  func perform<Input: Encodable, Response: Sendable>(
    action: String, service: String, input: Input,
    decode: @escaping @Sendable (xpc_object_t) throws -> Response
  ) async throws -> Response {
    // The request is built before any connection is opened, so a host without CoreDevice fails
    // without touching the simulator.
    let request = try request(action: action, input: input)
    return try await session(for: service).read(request, decode: decode)
  }

  /// One action, one reply, with the output decoded into `Output`.
  func perform<Input: Encodable, Output: Decodable & Sendable>(
    action: String, service: String, input: Input, as type: Output.Type
  ) async throws -> Output {
    try await perform(action: action, service: service, input: input) { reply in
      try CoreDeviceReply.decode(type, from: reply)
    }
  }

  /// One action whose provider pushes events; see `CoreDeviceSession.stream`.
  func stream<Input: Encodable, Response: Sendable>(
    action: String, service: String, input: Input,
    sample: @escaping @Sendable (xpc_object_t) throws -> Response?
  ) async throws -> Response {
    let request = try request(action: action, input: input)
    return try await session(for: service).stream(request, sample: sample)
  }

  /// One action whose provider pushes events until the consumer stops; see `CoreDeviceSession.subscribe`.
  /// Throws before streaming when the simulator does not vend `service`.
  func subscribe<Input: Encodable, Response: Sendable>(
    action: String, service: String, input: Input,
    bufferingPolicy: AsyncThrowingStream<Response, any Error>.Continuation.BufferingPolicy = .unbounded,
    element: @escaping @Sendable (xpc_object_t) throws -> Response?
  ) throws -> AsyncThrowingStream<Response, any Error> {
    let request = try request(action: action, input: input)
    return try session(for: service).subscribe(request, bufferingPolicy: bufferingPolicy, element: element)
  }

  // MARK: - Plain messages

  /// One message to a service that speaks its own envelope rather than the CoreDevice action
  /// envelope (the `dtuhidd`-style orientation and universal HID services), and its one reply.
  func send<Response: Sendable>(
    service: String, message: xpc_object_t,
    decode: @escaping @Sendable (xpc_object_t) throws -> Response
  ) async throws -> Response {
    try await session(for: service).read(message, decode: decode)
  }

  // MARK: - Plumbing

  private func request<Input: Encodable>(action: String, input: Input) throws -> xpc_object_t {
    try CoreDeviceRequest(action: action, deviceID: deviceID, version: version(), input: input).encoded()
  }

  private func session<Response: Sendable>(for service: String) throws -> CoreDeviceSession<Response> {
    CoreDeviceSession(channel: SimulatorXPCChannel(connection: try SimulatorCoreDevice.connect(using: connector, service: service), queue: queue))
  }
}
