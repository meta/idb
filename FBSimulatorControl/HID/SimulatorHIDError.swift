/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@preconcurrency import FBControlCore
import Foundation

/// The failure cases of the HID layer.
public enum SimulatorHIDError: Error, LocalizedError {
  /// The runtime-only `SimDeviceLegacyHIDClient` class could not be looked up by name.
  case clientClassUnavailable(className: String)
  /// The HID client class was found but `initWithDevice:error:` returned nil.
  case clientCreationFailed(clientClass: String, underlying: Error?)
  /// A HID operation was attempted after the client had been disposed of.
  case clientDisposed
  /// The `PurpleWorkspacePort` could not be found in the simulator's bootstrap namespace.
  case purpleWorkspacePortUnavailable(underlying: Error?)
  /// The `mach_msg` to `PurpleWorkspacePort` timed out (receive queue full).
  case machSendTimedOut(port: mach_port_t, timeoutMs: mach_msg_timeout_t, detail: String)
  /// The `mach_msg` to `PurpleWorkspacePort` failed for a reason other than timeout.
  case machSendFailed(port: mach_port_t, detail: String, code: kern_return_t)
  /// The SimulatorKit framework executable could not be opened.
  case simulatorKitUnavailable
  /// The guest drops the named kind of legacy Indigo input (Xcode 27+).
  case legacyInputSuppressed(operation: String)
  /// A primitive is not (yet) implemented on the DTUHID transport.
  case notImplementedOnDTUHIDTransport(operation: String)
  /// The named `dtuhidd` service could not be looked up in the simulator's bootstrap namespace.
  case dtuhidServiceUnavailable(name: String, underlying: Error?)
  /// The simulator's runtime does not vend the named `dtuhidd` service at all.
  case dtuhidServiceNotVended(name: String)
  /// The simulator is not booted, so it vends no `dtuhidd` service.
  case dtuhidSimulatorNotBooted(name: String, state: TargetState)
  /// The private `_4sim` XPC endpoint symbols could not be resolved (older toolchain).
  case dtuhidXPCSymbolsUnavailable
  /// The `dtuhidd` host XPC connection could not be created.
  case dtuhidConnectionFailed
  /// The connection was built, but no live `dtuhidd` answered behind it.
  case dtuhidUnresponsive(attempts: Int, underlying: Error?)
  /// An established connection to the named service has been invalidated, so nothing sent on it
  /// can arrive.
  case dtuhidConnectionInvalidated(name: String)
  /// A vendor-defined report for the named virtual-machine control could not be serialized.
  case vendorReportUnserializable(source: String)
  /// A touchscreen touch was attempted on a tvOS target, which has no touchscreen.
  case touchUnsupportedOnAppleTV
  /// `dtuhidd` dropped the connection while a gesture was in progress, and with it the gesture.
  case dtuhidGestureInterrupted
  /// A delay was negative, not finite, or too long to sleep for.
  case invalidDelay(TimeInterval)
  /// An operation ended with `cause`, and releasing or draining what it had sent then failed too.
  case cleanupFailed(cause: Error, failures: [Error])
  /// A Digital Crown rotation was attempted on a target that has no crown.
  case crownUnsupportedOnProductFamily(ProductFamily)
  /// A Digital Crown rotation was attempted over the legacy Indigo transport.
  case crownUnsupportedOnIndigoTransport
  /// An Apple Watch button was attempted on a target that does not have it.
  case watchButtonUnsupportedOnProductFamily(button: String, family: ProductFamily)
  /// An Apple Watch button was attempted over the legacy Indigo transport.
  case watchButtonUnsupportedOnIndigoTransport(button: String)
  /// The character at `offset` in text, counting characters of its NFC form from 0, cannot be typed
  /// on the named hardware keyboard layout. The character itself is not carried: an error can be
  /// logged, and typed text is kept out of logs.
  case characterNotOnKeyboardLayout(offset: Int, layout: String)
  /// Text was to be typed on a hardware keyboard layout that the simulator's runtime does not have.
  case unknownKeyboardLayout(name: String)

  public var errorDescription: String? {
    switch self {
    case let .clientClassUnavailable(className):
      return "Could not look up class \(className)"
    case let .clientCreationFailed(clientClass, underlying):
      guard let underlying else {
        return "Could not create instance of \(clientClass)"
      }
      return "Could not create instance of \(clientClass): \(underlying.localizedDescription)"
    case .clientDisposed:
      return "Cannot Connect, HID client has already been disposed of"
    case .purpleWorkspacePortUnavailable:
      return "Could not find PurpleWorkspacePort in simulator bootstrap namespace"
    case let .machSendTimedOut(port, timeoutMs, detail):
      return
        "mach_msg to PurpleWorkspacePort \(port) timed out after \(timeoutMs) ms — receive queue full, SpringBoard is likely not draining HID events: \(detail)"
    case let .machSendFailed(port, detail, code):
      return "mach_msg to PurpleWorkspacePort \(port) failed: \(detail) (kr=0x\(String(code, radix: 16)))"
    case .simulatorKitUnavailable:
      return "Could not open the SimulatorKit framework executable"
    case let .legacyInputSuppressed(operation):
      return
        "\(operation) over Indigo is suppressed: CoreSimulator-1155.4 (Xcode 27) and later do not reliably deliver legacy Indigo \(operation.lowercased()) events. Use the DTUHID transport, which is the default on this CoreSimulator."
    case let .notImplementedOnDTUHIDTransport(operation):
      return "\(operation) is not implemented on the DTUHID transport"
    case let .dtuhidServiceUnavailable(name, _):
      return "Could not look up the dtuhidd service (\(name))"
    case let .dtuhidServiceNotVended(name):
      return "The simulator's runtime does not vend the dtuhidd service (\(name))"
    case let .dtuhidSimulatorNotBooted(name, state):
      return "The simulator is \(state.stateString.rawValue), not booted, so the dtuhidd service (\(name)) cannot be looked up"
    case .dtuhidXPCSymbolsUnavailable:
      return "Could not resolve the private _4sim XPC endpoint symbols required for the DTUHID transport"
    case .dtuhidConnectionFailed:
      return "Could not create the dtuhidd host XPC connection"
    case let .dtuhidUnresponsive(attempts, underlying):
      let detail = underlying.map { " (\($0))" } ?? ""
      return
        "dtuhidd did not answer a liveness probe in \(attempts) attempts\(detail) — the daemon is not running and launchd is not keeping it up, so every HID event sent to it would be discarded without error"
    case let .dtuhidConnectionInvalidated(name):
      return "The dtuhidd connection (\(name)) has been invalidated; events sent on it would be discarded"
    case let .vendorReportUnserializable(source):
      return "Could not serialize the vendor-defined HID report for \(source)"
    case .touchUnsupportedOnAppleTV:
      return "Touch input is not supported on tvOS targets (no touchscreen)"
    case .dtuhidGestureInterrupted:
      return "The dtuhidd connection was interrupted during the gesture, so the guest no longer has it"
    case let .invalidDelay(seconds):
      return "A HID delay must be finite, non-negative and representable in nanoseconds, not \(seconds)s"
    case let .cleanupFailed(cause, failures):
      return "\(cause.localizedDescription); releasing the gesture then failed: \(failures.map(\.localizedDescription).joined(separator: "; "))"
    case let .crownUnsupportedOnProductFamily(family):
      return "Digital Crown rotation is only supported on Apple Watch targets, not \(family)"
    case .crownUnsupportedOnIndigoTransport:
      return "Digital Crown rotation requires the DTUHID transport"
    case let .watchButtonUnsupportedOnProductFamily(button, family):
      return "The Apple Watch \(button) button is only supported on Apple Watch targets, not \(family)"
    case let .watchButtonUnsupportedOnIndigoTransport(button):
      return "The Apple Watch \(button) button requires the DTUHID transport"
    case let .characterNotOnKeyboardLayout(offset, layout):
      return "Cannot type the character at offset \(offset) on the \(layout) hardware keyboard layout"
    case let .unknownKeyboardLayout(name):
      return "The simulator's runtime has no hardware keyboard layout named \"\(name)\""
    }
  }

  /// How a failure to build the host XPC connection reads for the DTUHID transport.
  init(dtuhidConnection error: SimulatorXPCConnectionError) {
    switch error {
    case .symbolsUnavailable:
      self = .dtuhidXPCSymbolsUnavailable
    case let .notBooted(service, state):
      self = .dtuhidSimulatorNotBooted(name: service, state: state)
    case let .lookupFailed(service, _) where error.isServiceUnsupported:
      self = .dtuhidServiceNotVended(name: service)
    case let .lookupFailed(service, underlying):
      self = .dtuhidServiceUnavailable(name: service, underlying: underlying)
    case .connectionFailed:
      self = .dtuhidConnectionFailed
    }
  }

  /// Whether this failure is a property of the toolchain, runtime or simulator that no amount of
  /// waiting changes, so connecting is not worth another attempt.
  ///
  /// Anything else is retried: the case retrying exists for — a `dtuhidd` that aborted early in boot
  /// and whose respawn launchd is throttling — shows up as an unanswered probe, and a failure not
  /// known to be permanent is worth riding out with it.
  var isPermanentDTUHIDFailure: Bool {
    switch self {
    case .dtuhidXPCSymbolsUnavailable, .dtuhidServiceNotVended, .dtuhidSimulatorNotBooted:
      return true
    default:
      return false
    }
  }
}
