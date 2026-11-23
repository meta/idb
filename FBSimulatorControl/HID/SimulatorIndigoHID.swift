/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Darwin
import FBControlCore
import Foundation
internal import SimulatorApp

/// Translates SimulatorHID events into Indigo structs.
// @safe: Holds only SimulatorKit's message builders; each call through them is marked `unsafe` where it is made.
@safe final class SimulatorIndigoHID {

  // The SimulatorKit `IndigoHIDMessageFor*` functions, resolved at runtime via dlsym.
  private typealias MessageForButtonFn = @convention(c) (Int32, Int32, Int32) -> UnsafeMutablePointer<IndigoMessage>
  private typealias MessageForKeyboardArbitraryFn = @convention(c) (Int32, Int32) -> UnsafeMutablePointer<IndigoMessage>
  // IndigoHIDMessageForHIDArbitrary(IndigoHIDTarget, usagePage, usage, IndigoHIDButtonOp) — the
  // generic HID-usage builder. It writes ButtonEventSourceHIDArbitrary rather than a dedicated
  // ButtonEventSource, so it can carry any (page, usage) pair the guest understands.
  private typealias MessageForHIDArbitraryFn =
    @convention(c) (Int32, UInt32, UInt32, Int32) -> UnsafeMutablePointer<IndigoMessage>
  // IndigoHIDMessageForMouseNSEvent(CGPoint *, CGPoint *, IndigoHIDTarget, NSEventType, NSSize,
  // IndigoHIDEdge). The builder derives the contact's xRatio/yRatio by dividing the point by the
  // NSSize, so passing a unit size makes that normalization the identity for callers that have
  // already converted to a ratio. The trailing IndigoHIDEdge selects the edge-swipe bits it ORs into
  // IndigoTouch.eventMask (see Indigo.h).
  private typealias MessageForMouseNSEventFn =
    @convention(c) (
      UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32
    ) -> UnsafeMutablePointer<IndigoMessage>
  // The SimulatorKit tvOS-trackpad builder: builds a touch-DOWN "changed" digitizer event for the
  // dedicated trackpad service (target 0x16). Callers set the returned message's digitizer phase
  // fields (see `trackpad(point:phase:)`) to express a began → changed → ended gesture.
  private typealias MessageForTrackpadMoveEventFn =
    @convention(c) (CGPoint, UInt32) -> UnsafeMutablePointer<IndigoMessage>

  private let messageForButton: MessageForButtonFn
  private let messageForKeyboardArbitrary: MessageForKeyboardArbitraryFn
  private let messageForHIDArbitrary: MessageForHIDArbitraryFn
  private let messageForMouseNSEvent: MessageForMouseNSEventFn
  private let messageForTrackpadMoveEvent: MessageForTrackpadMoveEventFn

  // MARK: - Initializers

  /// The SimulatorKit implementation. Loads the xcode private frameworks and resolves the
  /// `IndigoHIDMessageFor*` symbols from the SimulatorKit dylib.
  public convenience init() throws {
    try SimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(nil)
    guard let handle = unsafe Bundle(identifier: "com.apple.SimulatorKit")?.dlopenExecutablePath() else {
      throw SimulatorHIDError.simulatorKitUnavailable
    }
    unsafe self.init(
      messageForButton: unsafeBitCast(symbolFromHandle(handle, "IndigoHIDMessageForButton"), to: MessageForButtonFn.self),
      messageForKeyboardArbitrary: unsafeBitCast(
        symbolFromHandle(handle, "IndigoHIDMessageForKeyboardArbitrary"), to: MessageForKeyboardArbitraryFn.self),
      messageForHIDArbitrary: unsafeBitCast(
        symbolFromHandle(handle, "IndigoHIDMessageForHIDArbitrary"), to: MessageForHIDArbitraryFn.self),
      messageForMouseNSEvent: unsafeBitCast(
        symbolFromHandle(handle, "IndigoHIDMessageForMouseNSEvent"), to: MessageForMouseNSEventFn.self),
      messageForTrackpadMoveEvent: unsafeBitCast(
        symbolFromHandle(handle, "IndigoHIDMessageForTrackpadMoveEvent"), to: MessageForTrackpadMoveEventFn.self))
  }

  private init(
    messageForButton: @escaping MessageForButtonFn,
    messageForKeyboardArbitrary: @escaping MessageForKeyboardArbitraryFn,
    messageForHIDArbitrary: @escaping MessageForHIDArbitraryFn,
    messageForMouseNSEvent: @escaping MessageForMouseNSEventFn,
    messageForTrackpadMoveEvent: @escaping MessageForTrackpadMoveEventFn
  ) {
    unsafe self.messageForButton = unsafe messageForButton
    unsafe self.messageForKeyboardArbitrary = unsafe messageForKeyboardArbitrary
    unsafe self.messageForHIDArbitrary = unsafe messageForHIDArbitrary
    unsafe self.messageForMouseNSEvent = unsafe messageForMouseNSEvent
    unsafe self.messageForTrackpadMoveEvent = unsafe messageForTrackpadMoveEvent
  }

  // MARK: - Public

  /// A keyboard event. The keycodes are 'Hardware Independent' as described in `<HIToolbox/Events.h>`.
  func keyboard(with direction: SimulatorHIDDirection, keyCode: UInt32) -> Data {
    let message = unsafe messageForKeyboardArbitrary(Int32(bitPattern: keyCode), direction.rawValue)
    return unsafe SimulatorIndigoHID.data(fromMallocedMessage: message)
  }

  /// A button event. A button with a dedicated legacy `ButtonEventSource` goes through the sourced
  /// builder; one identified only by a HID Consumer-page usage goes through the arbitrary-HID builder,
  /// which addresses the same hardware-button service with the usage the DTUHID transport would send.
  func button(with direction: SimulatorHIDDirection, button: SimulatorHIDButton) -> Data {
    switch button.identity {
    case let .indigoSource(source), let .indigoSourceAndConsumerUsage(source, _, _):
      let message = unsafe messageForButton(source, direction.rawValue, Int32(ButtonEventTargetHardware))
      return unsafe SimulatorIndigoHID.data(fromMallocedMessage: message)
    case let .consumerUsage(page, code):
      return hidArbitrary(page: page, usage: code, direction: direction)
    }
  }

  /// A message carrying an arbitrary HID usage, addressed to the digitizer service.
  ///
  /// The counterpart to `button(with:button:)` for anything the legacy builder has no dedicated
  /// `ButtonEventSource` for: rather than naming a button, it names a usage — the code in
  /// `IndigoButton.keyCode` and its page in `IndigoButton.usagePage`, under
  /// `ButtonEventSourceHIDArbitrary`. Same envelope as a sourced button, so it is interchangeable
  /// with one everywhere downstream.
  func hidArbitrary(page: UInt16, usage: UInt16, direction: SimulatorHIDDirection) -> Data {
    let message = unsafe messageForHIDArbitrary(
      Int32(ButtonEventTargetDigitizer), UInt32(page), UInt32(usage), direction.rawValue)
    return unsafe SimulatorIndigoHID.data(fromMallocedMessage: message)
  }

  /// The HID service target the mouse/touch builder addresses.
  private static let mouseTarget: UInt32 = 0x32

  /// The `NSSize` handed to the mouse/touch builder. It normalizes the point by dividing by this, and
  /// every caller here passes a point that is already a ratio, so a unit size leaves it untouched.
  private static let unitScreenSize = CGSize(width: 1, height: 1)

  /// A contact that did not originate at a screen edge.
  private static let noEdge = UInt32(IndigoHIDEdgeNone)

  /// The dedicated tvOS trackpad HID service target (what Simulator.app's on-screen remote hard-codes;
  /// NOT the `screenID | 0x40000000` screen target, which binds to the main-screen digitizer and does
  /// not move tvOS focus).
  private static let trackpadTarget: UInt32 = 0x16

  /// Wire offset of the second `IndigoPayload` in a SimulatorKit-built message (Indigo.h: a single-payload
  /// allocation is 0xC0). NB: this is the *wire* offset — Swift's `MemoryLayout<IndigoMessage>.size`
  /// under-counts it (0xB0) because of the packed union, so it cannot be used to locate the payload.
  private static let secondPayloadWireOffset = 0xC0
  /// Wire stride between consecutive `IndigoPayload`s in a SimulatorKit-built message. The packed union
  /// makes this larger than `MemoryLayout<IndigoPayload>.size` (which is 0x90).
  private static let payloadWireStride = 0xA0
  /// Wire offset of the third `IndigoPayload` — the second finger in a multi-touch message.
  private static let thirdPayloadWireOffset = secondPayloadWireOffset + payloadWireStride

  /// A tvOS Siri Remote trackpad move. Builds `IndigoHIDMessageForTrackpadMoveEvent(point, 0x16)` and
  /// sets its digitizer phase fields so the focus engine reads a began → changed → ended gesture
  /// rather than a stream of stationary positions (a bare position stream is accepted but does not
  /// move focus). `point` is absolute-normalized (0..1, top-left origin).
  ///
  /// The builder emits a *two*-`IndigoPayload` message (like the multi-touch builder): the primary
  /// contact in `message.payload` and a repeated contact in the second `IndigoPayload` at
  /// `secondPayloadWireOffset` (0xC0). Both carry the digitizer state in `IndigoTouch.eventMask`
  /// (IOHIDDigitizerEventMask: Range 0x1 | Touch 0x2 | Position 0x4 | Identity 0x20), `range`, and
  /// `touch`; the builder defaults to a Position/touch-down "changed" contact.
  func trackpad(point: CGPoint, phase: SimulatorTrackpadPhase) throws -> Data {
    let message = unsafe messageForTrackpadMoveEvent(point, SimulatorIndigoHID.trackpadTarget)
    let secondary = unsafe SimulatorIndigoHID.payload(at: SimulatorIndigoHID.secondPayloadWireOffset, of: message)
    switch phase {
    case .began:
      unsafe message.pointee.payload.event.touch.eventMask = 0x23 // Range|Touch|Identity
      unsafe secondary.pointee.event.touch.eventMask = 3
    case .changed:
      break // builder default: Position mask, touch down
    case .ended:
      unsafe message.pointee.payload.event.touch.eventMask = 0x21 // Range|Identity, Touch cleared
      unsafe message.pointee.payload.event.touch.range = 0 // out of range
      unsafe message.pointee.payload.event.touch.touch = 0 // contact up
      unsafe secondary.pointee.event.touch.eventMask = 1
      unsafe secondary.pointee.event.touch.range = 0
      unsafe secondary.pointee.event.touch.touch = 0
    }
    return unsafe SimulatorIndigoHID.data(fromMallocedMessage: message)
  }

  /// A single-finger touch event. `x`/`y` are in points; `screenSize` is in pixels. `edge` tags the
  /// contact as originating at a screen edge, which the builder folds into `IndigoTouch.eventMask`.
  func touchScreenSize(
    _ screenSize: CGSize, screenScale: Float, direction: SimulatorHIDDirection, x: Double, y: Double,
    edge: SimulatorHIDEdge = .none
  ) -> Data {
    let point = SimulatorIndigoHID.screenRatio(from: CGPoint(x: x, y: y), screenSize: screenSize, screenScale: screenScale)
    return touchMessage(point: point, direction: direction, edge: edge)
  }

  /// A two-finger touch event for multi-touch gestures (pinch, rotate, etc.).
  func twoFingerTouchScreenSize(
    _ screenSize: CGSize, screenScale: Float, direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint
  ) -> Data {
    var ratio1 = SimulatorIndigoHID.screenRatio(from: finger1, screenSize: screenSize, screenScale: screenScale)
    var ratio2 = SimulatorIndigoHID.screenRatio(from: finger2, screenSize: screenSize, screenScale: screenScale)

    // Passing a non-NULL second point makes IndigoHIDMessageForMouseNSEvent produce a 3-payload message
    // with eventType=0x03 (multi-touch) instead of 0x02 (single-touch).
    let message = unsafe messageForMouseNSEvent(
      &ratio1, &ratio2, SimulatorIndigoHID.mouseTarget, UInt(direction.indigoEventType),
      SimulatorIndigoHID.unitScreenSize, SimulatorIndigoHID.noEdge)

    // Patch each contact's xRatio/yRatio rather than trusting the builder's own normalization to reach
    // all three. Finger 1 is the primary contact, the digitizer summary (payload 2) mirrors it, and
    // finger 2 is payload 3.
    unsafe message.pointee.payload.event.touch.xRatio = ratio1.x
    unsafe message.pointee.payload.event.touch.yRatio = ratio1.y
    let digitizer = unsafe SimulatorIndigoHID.payload(at: SimulatorIndigoHID.secondPayloadWireOffset, of: message)
    unsafe digitizer.pointee.event.touch.xRatio = ratio1.x
    unsafe digitizer.pointee.event.touch.yRatio = ratio1.y
    let finger2Payload = unsafe SimulatorIndigoHID.payload(at: SimulatorIndigoHID.thirdPayloadWireOffset, of: message)
    unsafe finger2Payload.pointee.event.touch.xRatio = ratio2.x
    unsafe finger2Payload.pointee.event.touch.yRatio = ratio2.y

    return unsafe SimulatorIndigoHID.data(fromMallocedMessage: message)
  }

  // MARK: - Event Generation

  private func touchMessage(point: CGPoint, direction: SimulatorHIDDirection, edge: SimulatorHIDEdge) -> Data {
    var point = point
    // SimulatorKit has no single-touch builder: IndigoHIDMessageForMouseNSEvent always emits a
    // multi-touch (eventType 0x03) message. So source a valid touch-down IndigoTouch from it, then
    // hand-envelope it as a single-touch (eventType 0x02) two-payload message.
    let source = unsafe messageForMouseNSEvent(
      &point, nil, SimulatorIndigoHID.mouseTarget, UInt(direction.indigoEventType),
      SimulatorIndigoHID.unitScreenSize, edge.rawValue)
    unsafe source.pointee.payload.event.touch.xRatio = point.x
    unsafe source.pointee.payload.event.touch.yRatio = point.y
    let sourceBytes = UnsafeMutableRawPointer(source)

    // Build a fresh single-touch message (320 / 0x140 bytes) and copy the Digitizer payload in.
    let messageSize = MemoryLayout<IndigoMessage>.size + MemoryLayout<IndigoPayload>.size
    let stride = MemoryLayout<IndigoPayload>.size // 0x90
    guard let destination = unsafe calloc(1, messageSize) else {
      fatalError("Failed to allocate \(messageSize) bytes for an Indigo touch message")
    }
    let message = unsafe destination.assumingMemoryBound(to: IndigoMessage.self)
    unsafe message.pointee.innerSize = UInt32(MemoryLayout<IndigoPayload>.size)
    unsafe message.pointee.eventType = UInt8(IndigoEventTypeTouch)
    unsafe message.pointee.payload.eventKind = 0x0000_000B
    unsafe message.pointee.payload.timestamp = mach_absolute_time()

    // Copy in the Digitizer (IndigoTouch) payload from the source, at event offset 0x30.
    unsafe memcpy(destination.advanced(by: 0x30), sourceBytes.advanced(by: 0x30), MemoryLayout<IndigoTouch>.size)
    unsafe free(source)

    // Duplicate the first IndigoPayload (at 0x20) into the second slot, then mark the copied contact
    // (touch.field1 = 1, field2 = 2). NB: this self-allocated message uses the Swift `IndigoPayload`
    // stride (0x90), so the second payload sits at 0xB0 — not the 0xC0 wire offset of the
    // SimulatorKit-built messages.
    unsafe memcpy(destination.advanced(by: 0x20 + stride), destination.advanced(by: 0x20), stride)
    let secondPayload = unsafe SimulatorIndigoHID.payload(at: 0x20 + stride, of: message)
    unsafe secondPayload.pointee.event.touch.field1 = 1
    unsafe secondPayload.pointee.event.touch.field2 = 2

    return unsafe Data(bytesNoCopy: destination, count: messageSize, deallocator: .free)
  }

  // MARK: - Helpers

  /// Wraps a `malloc`'d `IndigoMessage` as `Data` that frees the buffer when deallocated.
  private static func data(fromMallocedMessage message: UnsafeMutablePointer<IndigoMessage>) -> Data {
    let raw = UnsafeMutableRawPointer(message)
    return unsafe Data(bytesNoCopy: raw, count: malloc_size(raw), deallocator: .free)
  }

  /// A typed view of the `IndigoPayload` at a wire offset the Swift `IndigoMessage.payload` field cannot
  /// address — SimulatorKit lays the second and third payloads at `payloadWireStride`, which the packed
  /// union under-counts. Used for the digitizer/second-finger contacts in multi-payload messages.
  private static func payload(
    at wireOffset: Int, of message: UnsafeMutablePointer<IndigoMessage>
  ) -> UnsafeMutablePointer<IndigoPayload> {
    unsafe UnsafeMutableRawPointer(message).advanced(by: wireOffset).assumingMemoryBound(to: IndigoPayload.self)
  }

  static func screenRatio(from point: CGPoint, screenSize: CGSize, screenScale: Float) -> CGPoint {
    CGPoint(
      x: (point.x * CGFloat(screenScale)) / screenSize.width,
      y: (point.y * CGFloat(screenScale)) / screenSize.height)
  }
}

// MARK: - Indigo wire-format mappings

private extension SimulatorHIDDirection {
  /// The Indigo `eventType` value for this direction.
  var indigoEventType: Int32 {
    switch self {
    case .down:
      return Int32(ButtonEventTypeDown)
    case .up:
      return Int32(ButtonEventTypeUp)
    }
  }
}
