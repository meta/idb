/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import XCTest
@preconcurrency import XPC
import os

private func hingeEvent(channel: UUID, degrees: Double = 130, timestamp: Double = 200, valid: Bool = true, unit: String = "°") -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  return hingeEvent(
    channel: channel,
    elements: [
      dictionary([
        "angle": dictionary([
          "value": xpc_double_create(degrees),
          "unit": dictionary([
            "symbol": xpc_string_create(unit),
            "converter": dictionary(["coefficient": xpc_double_create(1), "constant": xpc_double_create(0)]),
          ]),
        ]),
        "timestamp": xpc_double_create(timestamp),
        "isAngleValid": xpc_bool_create(valid),
      ])
    ])
}

private func hingeEvent(channel: UUID, elements: [xpc_object_t]) -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  return dictionary([
    "XPCSideChannel.uniqueIdentifier": xpc_string_create(channel.uuidString),
    "CoreDevice.XPCMessageKey.sideChannelStatus": dictionary([
      "pushing": dictionary(["elements": SimulatorCoreDevice.array(elements)])
    ]),
  ])
}

/// The stream request as the client encodes it for the hinge command.
private func hingeRequest(channel: UUID) throws -> xpc_object_t {
  try CoreDeviceRequest(
    action: SimulatorHingeProtocol.action, deviceID: "device", version: CoreDeviceVersion("651.13.4"),
    input: SimulatorHingeProtocol.StreamInput(channel: channel)
  ).encoded()
}

/// What a synthetic hinge provider does once the client asks it to stop.
private enum HingeStop {
  /// Sends the final reply, as a provider that has stopped does.
  case complete
  /// Never replies.
  case ignore
  /// Drops the connection.
  case interrupt
}

/// A monitormotion provider streaming `events`, pushing each once the client has acknowledged the
/// last, as the provider paces its side channel. Every acknowledgement's cancellation flag is kept.
private final class HingeProvider: Sendable {
  let services = SyntheticXPCServices()
  let peer: SyntheticXPCPeer
  private let acknowledged = OSAllocatedUnfairLock(initialState: [Bool]())

  init(events: [xpc_object_t], onStop stop: HingeStop = .complete, onAcknowledgement: @escaping @Sendable () -> Void = {}) {
    let acknowledged = acknowledged
    peer = services.register(SimulatorHingeProtocol.service) { request in
      @Sendable func push(_ index: Int) {
        guard index < events.count else { return }
        request.push(events[index]) { acknowledgement in
          guard xpc_get_type(acknowledgement) == XPC_TYPE_DICTIONARY else { return }
          let cancelling = xpc_dictionary_get_bool(acknowledgement, SimulatorCoreDevice.cancellationKey)
          acknowledged.withLock { $0.append(cancelling) }
          onAcknowledgement()
          guard cancelling else { return push(index + 1) }
          switch stop {
          case .complete: request.reply(hingeCompletion)
          case .ignore: break
          case .interrupt: request.interrupt()
          }
        }
      }
      push(0)
    }
  }

  var acknowledgements: [Bool] {
    acknowledged.withLock { $0 }
  }
}

private let hingeCompletion = SimulatorCoreDevice.dictionary(["CoreDevice.output": xpc_dictionary_create(nil, nil, 0)])

final class SimulatorHingeReadTests: XCTestCase {
  func testRequestUsesNativeUUIDAndUnsignedDurationLowBits() throws {
    let channel = UUID()
    let request = try hingeRequest(channel: channel)
    XCTAssertEqual(String(cString: xpc_dictionary_get_string(request, "CoreDevice.actionIdentifier")!), SimulatorHingeProtocol.action)
    let version = try XCTUnwrap(xpc_dictionary_get_dictionary(request, "CoreDevice.coreDeviceVersion"))
    let components = try XCTUnwrap(xpc_dictionary_get_array(version, "components"))
    XCTAssertEqual(xpc_array_get_count(components), 3)
    XCTAssertEqual(xpc_get_type(xpc_array_get_value(components, 0)), XPC_TYPE_UINT64)
    XCTAssertEqual(xpc_array_get_uint64(components, 0), 651)
    let input = try XCTUnwrap(xpc_dictionary_get_dictionary(request, "CoreDevice.input"))
    let proxy = try XCTUnwrap(xpc_dictionary_get_dictionary(input, "streamProxy"))
    let identifier = try XCTUnwrap(xpc_dictionary_get_value(proxy, "sideChannel"))
    XCTAssertEqual(xpc_get_type(identifier), XPC_TYPE_UUID)
    let config = try XCTUnwrap(xpc_dictionary_get_dictionary(input, "actualInput"))
    let interval = try XCTUnwrap(xpc_dictionary_get_array(config, "updateInterval"))
    XCTAssertEqual(xpc_get_type(xpc_array_get_value(interval, 0)), XPC_TYPE_INT64)
    XCTAssertEqual(xpc_get_type(xpc_array_get_value(interval, 1)), XPC_TYPE_UINT64)
    XCTAssertEqual(xpc_array_get_uint64(interval, 1), 100_000_000_000_000_000)
    XCTAssertThrowsError(try CoreDeviceVersion("651..4"))
  }

  func testAcceptsMeasuredIntermediateAngle() throws {
    let channel = UUID()
    let angle = try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, degrees: 121.64), channel: channel, notBefore: 199, now: 201)
    XCTAssertEqual(angle?.degrees, 121.64)
  }

  func testIgnoresStaleAndInvalidSamples() throws {
    let channel = UUID()
    XCTAssertNil(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, timestamp: 198), channel: channel, notBefore: 199, now: 201))
    XCTAssertNil(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, valid: false), channel: channel, notBefore: 199, now: 201))
  }

  func testSkippedSamplesAreNotRead() throws {
    let channel = UUID()
    let junk = xpc_string_create("junk")
    let invalid = SimulatorCoreDevice.dictionary(["isAngleValid": xpc_bool_create(false), "timestamp": junk, "angle": junk])
    let stale = SimulatorCoreDevice.dictionary(["isAngleValid": xpc_bool_create(true), "timestamp": xpc_double_create(198), "angle": junk])
    let event = hingeEvent(channel: channel, elements: [invalid, stale])
    XCTAssertNil(try SimulatorHingeProtocol.sample(event, channel: channel, notBefore: 199, now: 201))
  }

  func testRejectsBadValuesAndFutureTimestamps() {
    let channel = UUID()
    for degrees in [-1, 181, Double.nan, .infinity] {
      XCTAssertThrowsError(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, degrees: degrees), channel: channel, notBefore: 199, now: 201))
    }
    XCTAssertThrowsError(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, timestamp: 202), channel: channel, notBefore: 199, now: 201))
    XCTAssertThrowsError(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel, unit: "rad"), channel: channel, notBefore: 199, now: 201))
    XCTAssertThrowsError(try SimulatorHingeProtocol.sample(hingeEvent(channel: channel), channel: UUID(), notBefore: 199, now: 201))
  }

  // MARK: - Streaming through the session

  func testSubscriptionKeepsObservingMeasuredAnglesAndClosesOnCancellation() async throws {
    let channel = UUID()
    let acknowledged = expectation(description: "All streamed events acknowledged by the provider")
    acknowledged.expectedFulfillmentCount = 4
    let provider = HingeProvider(
      events: [
        hingeEvent(channel: channel, degrees: 180, timestamp: 199),
        hingeEvent(channel: channel, degrees: 180),
        hingeEvent(channel: channel, degrees: 121.64),
        hingeEvent(channel: channel, degrees: 90),
      ],
      onAcknowledgement: { acknowledged.fulfill() })
    let request = try hingeRequest(channel: channel)
    let xpc = try provider.services.channel(to: SimulatorHingeProtocol.service)
    let stream = CoreDeviceSession<SimulatorHingeAngle>(channel: xpc).subscribe(request) { event in
      try SimulatorHingeProtocol.sample(event, channel: channel, notBefore: 200, now: 200)
    }
    let consumer = Task {
      var iterator = stream.makeAsyncIterator()
      var values: [Double] = []
      for _ in 0..<3 {
        if let angle = try await iterator.next() { values.append(angle.degrees) }
      }
      let acknowledgementResult = await XCTWaiter.fulfillment(of: [acknowledged], timeout: 5)
      XCTAssertEqual(acknowledgementResult, .completed)
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await iterator.next()
      return values
    }
    let values = try await consumer.value
    XCTAssertEqual(values, [180, 121.64, 90])
    XCTAssertEqual(provider.acknowledgements, [false, false, false, false])
    let closed = await provider.peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  /// A hinge read as `SimulatorHingeCommands` performs it: a stream that samples until a fresh
  /// angle arrives, with the clock pinned so timestamps are deterministic.
  private static func readAngle(
    from services: SyntheticXPCServices, channel: UUID = UUID(), timeout: DispatchTimeInterval = .seconds(5)
  ) async throws -> SimulatorHingeAngle {
    let request = try hingeRequest(channel: channel)
    let xpc = try services.channel(to: SimulatorHingeProtocol.service)
    return try await CoreDeviceSession<SimulatorHingeAngle>(channel: xpc, timeout: timeout).stream(request) { event in
      try SimulatorHingeProtocol.sample(event, channel: channel, notBefore: 200, now: 200)
    }
  }

  func testStaleInitialSampleDoesNotCompleteRead() async throws {
    let channel = UUID()
    let provider = HingeProvider(events: [
      hingeEvent(channel: channel, degrees: 180, timestamp: 199),
      hingeEvent(channel: channel, degrees: 0),
      hingeEvent(channel: channel, degrees: 90),
    ])
    let angle = try await Self.readAngle(from: provider.services, channel: channel)
    XCTAssertEqual(angle.degrees, 0)
    XCTAssertEqual(provider.acknowledgements, [false, true])
    let closed = await provider.peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testProviderMustFinishCancellationBeforeReadCompletes() async {
    let channel = UUID()
    let provider = HingeProvider(events: [hingeEvent(channel: channel)], onStop: .ignore)
    do {
      _ = try await Self.readAngle(from: provider.services, channel: channel, timeout: .milliseconds(500))
      XCTFail("Expected timeout awaiting provider cancellation")
    } catch {
      guard case SimulatorCoreDeviceError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertEqual(provider.acknowledgements, [true])
    let closed = await provider.peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testPrematureCompletionIsAnError() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorHingeProtocol.service, respond: SyntheticXPCPeer.replying(hingeCompletion))
    do {
      _ = try await Self.readAngle(from: services)
      XCTFail("Expected missing sample error")
    } catch {
      guard case SimulatorCoreDeviceError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }

  func testAProviderErrorInTheFinalReplyFails() async {
    let channel = UUID()
    let services = SyntheticXPCServices()
    services.register(SimulatorHingeProtocol.service) { request in
      request.push(hingeEvent(channel: channel)) { _ in }
      request.reply(
        SimulatorCoreDevice.dictionary([
          "CoreDevice.error": SimulatorCoreDevice.dictionary(["domain": xpc_string_create("com.example"), "code": xpc_int64_create(9)])
        ]))
    }
    do {
      _ = try await Self.readAngle(from: services, channel: channel)
      XCTFail("Expected provider error")
    } catch {
      guard case let SimulatorCoreDeviceError.unavailable(detail) = error else { return XCTFail("Unexpected error: \(error)") }
      XCTAssertEqual(detail, "com.example (9)")
    }
  }

  func testPeerLossWhileAwaitingCancellationFails() async {
    let channel = UUID()
    let provider = HingeProvider(events: [hingeEvent(channel: channel)], onStop: .interrupt)
    do {
      _ = try await Self.readAngle(from: provider.services, channel: channel)
      XCTFail("Expected connection error")
    } catch {
      guard case SimulatorCoreDeviceError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertEqual(provider.acknowledgements, [true])
  }

  func testCancellationBeforeSetupDoesNotStartRequest() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorHingeProtocol.service, respond: SyntheticXPCPeer.silent)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await Self.readAngle(from: services)
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(peer.received.count, 0)
  }

  func testCancellationClosesAnIdleConnection() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorHingeProtocol.service, respond: SyntheticXPCPeer.silent)
    let task = Task { try await Self.readAngle(from: services) }
    _ = await peer.received(atLeast: 1)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    let closed = await peer.closed(atLeast: 1)
    XCTAssertEqual(closed, 1)
  }
}
