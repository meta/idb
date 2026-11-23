/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import AccessibilityPlatformTranslation
import CoreSimulator
import FBSimulatorControl
import Foundation
import XPC

/// Carries one translator request to the simulator's accessibility service and brings back its answer.
///
/// Synchronous because `AXPTranslator` asks its bridge delegate for an answer synchronously: the transport
/// is the one place that waits, and it never waits longer than `timeout`.
/// Which path carried a read's translator requests.
public enum AXTranslationTransportKind: String, Sendable {
  /// Straight to CoreSimulatorBridge's accessibility service.
  case bridge
  /// Through CoreSimulator's own client.
  case coreSimulator = "coresimulator"
}

protocol AXTranslationTransport: Sendable {
  var kind: AXTranslationTransportKind { get }

  /// The service's answer, or nil when none arrived within `timeout`. Must not be called on the main queue.
  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse?

  /// Requests this transport stopped waiting for whose answer has not yet arrived. The service still answers
  /// them, one at a time, ahead of anything sent now.
  var abandonedRequests: Int { get }
}

/// Sends translator requests through CoreSimulator's own client,
/// `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`. The fallback when
/// `CoreSimulatorBridgeAXTranslationTransport` cannot reach the service.
///
/// CoreSimulator's client also forwards every notification the bridge pushes to
/// `-[AXPTranslator handleNotification:data:associatedObject:]`, on a CoreSimulator queue — outside the serial
/// queue that otherwise keeps every touch of the translator single-threaded. Nothing in idb asks for those
/// notifications and the client offers no way to decline them, which is one reason the bridge transport is
/// preferred: it receives the same pushes and drops them.
final class CoreSimulatorAXTranslationTransport: AXTranslationTransport, @unchecked Sendable {
  let kind = AXTranslationTransportKind.coreSimulator

  // SAFETY: all are only read after init; `SimDevice` messages its service from any queue.
  private let device: SimDevice
  private let completionQueue: DispatchQueue
  private let abandoned = AXAbandonedRequests()

  init(device: SimDevice) {
    self.device = device
    self.completionQueue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.accessibility_translator.callback")
  }

  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse? {
    let response: AXPTranslatorResponse?? = abandoned.wait(within: timeout) { answer in
      device.sendAccessibilityRequestAsync(request, completionQueue: completionQueue) { answer($0) }
    }
    return response ?? nil
  }

  /// Held for the simulator, as the bridge transport is, and queued on the same service, so it counts the same way.
  var abandonedRequests: Int {
    abandoned.count
  }
}

/// Sends translator requests straight to `com.apple.CoreSimulator.accessibility`, the service
/// CoreSimulatorBridge vends inside the simulator.
///
/// The bridge answers one archived `AXPTranslatorRequest` per message, on a single serial queue, so this
/// holds one connection and sends one request at a time. It ignores the notifications the bridge pushes to
/// every peer: nothing here consumes them, and handing them to the translator would touch it off the queue
/// that serializes it.
final class CoreSimulatorBridgeAXTranslationTransport: AXTranslationTransport, @unchecked Sendable {
  static let serviceName = "com.apple.CoreSimulator.accessibility"

  let kind = AXTranslationTransportKind.bridge

  // SAFETY: `channel` is only read or replaced under `lock`; the rest is immutable.
  private let connector: SimulatorXPCConnector
  private let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.accessibility_translator.bridge")
  private let lock = NSLock()
  private var channel: SimulatorXPCChannel?
  private let abandoned = AXAbandonedRequests()

  init(connector: SimulatorXPCConnector) {
    self.connector = connector
  }

  /// Connects to the service now, so a caller can tell a simulator that does not vend it from one that
  /// does before choosing this transport.
  func connect() throws {
    _ = try connectedChannel()
  }

  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse? {
    guard let message = AXTranslationWire.message(for: request), let channel = try? connectedChannel() else {
      return nil
    }
    let reply: Result<xpc_object_t, SimulatorXPCError>? = abandoned.wait(within: timeout) { answer in
      channel.request(message) { answer($0) }
    }
    guard let reply else {
      return nil
    }
    switch reply {
    case let .success(reply):
      return AXTranslationWire.response(from: reply)
    case .failure:
      // XPC answered for a bridge that went away; the reply can beat the invalidation event, so the next
      // send must not wait for it to look the service up again.
      discard(channel)
      return nil
    }
  }

  /// Held for the simulator, so a request abandoned by one read is still counted when the next read sends: XPC
  /// cannot withdraw a message, and the bridge answers it before anything sent after it.
  var abandonedRequests: Int {
    abandoned.count
  }

  /// The live channel, or a new one when there is none: on first use, and after the bridge went away, as it
  /// does when launchd restarts CoreSimulatorBridge.
  private func connectedChannel() throws -> SimulatorXPCChannel {
    lock.lock()
    defer { lock.unlock() }
    if let channel {
      return channel
    }
    let channel = SimulatorXPCChannel(connection: try connector.connect(Self.serviceName), queue: queue)
    channel.activate { [weak self, weak channel] event in
      guard case .invalidated = event, let self, let channel else { return }
      self.discard(channel)
    }
    self.channel = channel
    return channel
  }

  private func discard(_ invalidated: SimulatorXPCChannel) {
    lock.lock()
    defer { lock.unlock() }
    if channel === invalidated {
      channel = nil
    }
  }
}

/// The messages the accessibility service exchanges: a class name, and the archived object in a nested
/// payload dictionary.
enum AXTranslationWire {
  static let payloadClassNameKey = "SimAccessibility_PayloadClassName"
  static let payloadKey = "SimAccessibility_Payload"
  static let requestKey = "translatorRequest"
  static let responseKey = "translatorResponse"

  static func message(for request: AXPTranslatorRequest) -> xpc_object_t? {
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: request, requiringSecureCoding: true) else {
      return nil
    }
    return envelope(className: "AXPTranslatorRequest", key: requestKey, data: data)
  }

  /// Nil for anything but an archived `AXPTranslatorResponse`.
  static func response(from reply: xpc_object_t) -> AXPTranslatorResponse? {
    guard let data = payload(of: reply, className: "AXPTranslatorResponse", key: responseKey) else {
      return nil
    }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: AXPTranslatorResponse.self, from: data)
  }

  static func envelope(className: String, key: String, data: Data) -> xpc_object_t {
    let payload = xpc_dictionary_create(nil, nil, 0)
    unsafe xpc_dictionary_set_value(payload, key, data.withUnsafeBytes { unsafe xpc_data_create($0.baseAddress, $0.count) })
    let message = xpc_dictionary_create(nil, nil, 0)
    unsafe xpc_dictionary_set_string(message, payloadClassNameKey, className)
    unsafe xpc_dictionary_set_value(message, payloadKey, payload)
    return message
  }

  static func payload(of message: xpc_object_t, className: String, key: String) -> Data? {
    guard unsafe xpc_get_type(message) == XPC_TYPE_DICTIONARY,
      let name = unsafe xpc_dictionary_get_string(message, payloadClassNameKey), unsafe String(cString: name) == className,
      let payload = unsafe xpc_dictionary_get_value(message, payloadKey), unsafe xpc_get_type(payload) == XPC_TYPE_DICTIONARY
    else {
      return nil
    }
    var length = 0
    guard let bytes = unsafe xpc_dictionary_get_data(payload, key, &length) else {
      return nil
    }
    return unsafe Data(bytes: bytes, count: length)
  }
}

/// The requests a transport stopped waiting for whose answers have not yet arrived.
// SAFETY: `outstanding` and every `Pending` are only read or written under `lock`.
// patternlint-disable-next-line unchecked-sendable
final class AXAbandonedRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var outstanding = 0

  var count: Int {
    lock.withLock { outstanding }
  }

  /// The answer `send` delivers to the closure it is given, or nil when none arrived within `timeout`. A request
  /// not answered in time is counted until its answer does arrive.
  func wait<Answer>(within timeout: TimeInterval, send: (@escaping @Sendable (Answer) -> Void) -> Void) -> Answer? {
    let answered = DispatchSemaphore(value: 0)
    let pending = Pending<Answer>()
    send { [self] answer in
      lock.withLock {
        pending.answer = answer
        if pending.abandoned {
          outstanding -= 1
        }
      }
      answered.signal()
    }
    guard answered.wait(timeout: .now() + timeout) == .success else {
      lock.withLock {
        guard pending.answer == nil else { return }
        pending.abandoned = true
        outstanding += 1
      }
      return nil
    }
    return lock.withLock { pending.answer }
  }

  // SAFETY: only read or written under the owning `AXAbandonedRequests`'s lock.
  // patternlint-disable-next-line unchecked-sendable
  private final class Pending<Answer>: @unchecked Sendable {
    var answer: Answer?
    var abandoned = false
  }
}
