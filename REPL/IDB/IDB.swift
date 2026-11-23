/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation
import ImageIO
@_implementationOnly import ReplProtocol

// The API injected REPL code calls to drive the connected target. Everything public is
// nested under the `IDB` namespace enum, so importing this module adds only that one
// name to the caller's scope.
//
// The Swift module is named `IDBAPI`, not `IDB`: a type sharing its module's name breaks
// `.swiftinterface` generation (it emits unparseable `IDB.IDB.X` references).
//
// Commands reach the host through `FBReplInvokeHostCommand`, resolved with `dlsym` from
// the loaded shim (`libShimulator`) (same image, so no link dependency); the only link dependency is
// `ReplProtocol`.
//
// Calls do not throw: a lost connection ends the submission (see `haltReplExecution`),
// and a command that merely did not apply is ignored.
//
// Injected code must not write to stdout/stderr: in the REPL host those file descriptors
// can alias the control socket, so a stray write corrupts the protocol. Failures are
// therefore silent.

/// Sends `command` to the host and returns its `result`, or `nil` when it did not
/// apply or the connection was lost (which also halts the submission via
/// `haltReplExecution`).
@discardableResult
private func perform(_ command: ReplCommand) -> Any? {
  typealias InvokeFunction = @convention(c) (UnsafeRawPointer?, Int32, UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer?
  guard let symbol = unsafe dlsym(dlopen(nil, RTLD_NOW), "FBReplInvokeHostCommand") else {
    haltReplExecution() // not running inside an idb REPL host
    return nil
  }
  let invokeHostCommand = unsafe unsafeBitCast(symbol, to: InvokeFunction.self)
  // Encode the command as a binary property list so values (e.g. coordinates)
  // round-trip bit-for-bit rather than through a decimal string. It travels as
  // the raw payload of a length-prefixed frame -- there is no text envelope.
  let encoder = PropertyListEncoder()
  encoder.outputFormat = .binary
  guard let commandData = try? encoder.encode(command) else {
    return nil // a command that cannot be encoded cannot be sent; skip it
  }
  var responseLength: Int32 = 0
  let responsePtr = unsafe commandData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    unsafe invokeHostCommand(raw.baseAddress, Int32(raw.count), &responseLength)
  }
  guard let responsePtr = unsafe responsePtr else {
    haltReplExecution() // the REPL host disconnected mid-command
    return nil
  }
  defer { unsafe free(responsePtr) }
  let responseData = unsafe Data(bytes: responsePtr, count: Int(responseLength))
  let response = unsafe ((try? PropertyListSerialization.propertyList(from: responseData, options: [], format: nil)) as? [String: Any]) ?? [:]
  if response["success"] as? Bool == true {
    return response["result"]
  }
  return nil
}

/// Ends the current REPL submission because the companion is no longer reachable.
/// The test and simulator hosts are disposable, so this exits the process outright
/// -- injected code can do nothing useful once the host is gone, and the driver
/// observes the halt as the session disconnecting. In the app context the host
/// outlives the session (the server resets and waits for the next client), so this
/// returns instead; the caller then ends the submission quietly by returning `nil`,
/// leaving the app running.
private func haltReplExecution() {
  if hostOutlivesSession() {
    return
  }
  exit(EXIT_FAILURE)
}

/// Whether the REPL host process outlives a single session -- true in the app
/// context (`FBReplServeSocket(..., keepListening: YES)`), false for the disposable
/// test and simulator hosts. Resolved from the loaded shim (`libShimulator`) with `dlsym`, like
/// `FBReplInvokeHostCommand`; treated as false if the host predates this entry point.
private func hostOutlivesSession() -> Bool {
  typealias QueryFunction = @convention(c) () -> ObjCBool
  guard let symbol = unsafe dlsym(dlopen(nil, RTLD_NOW), "FBReplHostOutlivesSession") else {
    return false
  }
  return unsafe unsafeBitCast(symbol, to: QueryFunction.self)().boolValue
}

/// Interprets a host command's raw result as a UTF-8 string, or nil when the
/// result is absent or empty -- a command that did not apply or failed.
private func stringResult(_ value: Any?) -> String? {
  guard let data = value as? Data, !data.isEmpty else {
    return nil
  }
  return String(data: data, encoding: .utf8)
}

/// The idb command namespace. It is a caseless enum used purely to scope the API:
/// injected code reaches everything through `IDB.` (e.g. `IDB.ui`), and nothing
/// leaks into the importer's unqualified namespace.
public enum IDB {

  /// UI-automation commands for the connected target, reached through `IDB.ui`.
  public struct UI {

    /// Taps the connected target at the given point.
    public func tap(_ point: CGPoint) {
      perform(.tap(point))
    }

    /// Taps the frontmost-app accessibility element whose label contains `marker`.
    public func tap(marker: String) {
      perform(.tapMarker(marker))
    }

    /// Swipes between two points. `duration` is seconds; `delta` is the spacing in
    /// points between intermediate touches. 0 for either uses the companion's default.
    public func swipe(from: CGPoint, to: CGPoint, duration: Double = 0, delta: Double = 0) {
      perform(.swipe(from: from, to: to, duration: duration, delta: delta))
    }

    /// Pinches centered at the given point. `scale` < 1 pinches in, > 1 pinches out.
    public func pinch(at center: CGPoint, scale: Double, duration: Double = 0.5, radius: Double = 100) {
      perform(.pinch(at: center, scale: scale, duration: duration, radius: radius))
    }

    /// Presses a hardware button: "home", "lock", "side_button", "siri", or "apple_pay".
    public func button(_ name: String) {
      perform(.button(name))
    }

    /// Types `string` on the hardware keyboard.
    public func text(_ string: String) {
      perform(.text(string))
    }

    /// Begins a touch at the given point. Hold it with `touchMove`, end with `touchUp`.
    public func touchDown(_ point: CGPoint) {
      perform(.touchDown(point))
    }

    /// Moves an in-progress touch to the given point.
    public func touchMove(_ point: CGPoint) {
      perform(.touchMove(point))
    }

    /// Ends an in-progress touch at the given point.
    public func touchUp(_ point: CGPoint) {
      perform(.touchUp(point))
    }

    /// Returns the connected target's accessibility hierarchy as a tree of
    /// `AXElement`, or nil if it could not be retrieved.
    public func describeAll() -> AXElement? {
      guard let data = perform(.describeAll) as? Data else {
        return nil
      }
      if let root = try? PropertyListDecoder().decode(AXElement.self, from: data) {
        return root
      }
      return try? PropertyListDecoder().decode([AXElement].self, from: data).first
    }
  }

  /// The UI-automation command namespace, reached as `IDB.ui`.
  ///
  /// A computed property rather than a stored global on purpose: injected code is
  /// compiled against the library-evolution `IDB.swiftinterface` and so reaches
  /// `ui` through a getter, but the shim is built without library evolution,
  /// where a stored value would export only an addressor (no getter symbol) and
  /// the load-time lookup would fail. A computed property's getter is an ordinary
  /// exported function, resolved like the command methods. `UI` is stateless, so
  /// a fresh value per access costs nothing.
  public static var ui: UI { UI() }

  /// Screenshot commands for the connected target, reached through `IDB.screenshot`.
  public struct Screenshot {

    /// Captures the full screen to a PNG artifact on the companion and returns its
    /// path, or nil on failure. The path is on the companion's filesystem, which is
    /// where other `IDB` commands operate.
    @discardableResult
    public func capture() -> String? {
      fileResult(.full)
    }

    /// Captures `rect` (in screen points, the same coordinate space as
    /// `IDB.ui.tap`) to a PNG artifact and returns its path, or nil on failure.
    @discardableResult
    public func capture(rect: CGRect) -> String? {
      fileResult(.rect(rect))
    }

    /// Captures the frontmost-app accessibility element whose label contains
    /// `label` (the same lookup as `IDB.ui.tap(marker:)`) to a PNG artifact and
    /// returns its path, or nil on failure.
    @discardableResult
    public func capture(label: String) -> String? {
      fileResult(.element(label: label))
    }

    /// Captures the full screen and returns it as a `CGImage` (nothing is written
    /// to disk), or nil on failure.
    func captureImage() -> CGImage? {
      imageResult(.full)
    }

    /// Captures `rect` (in screen points) and returns it as a `CGImage`, or nil on
    /// failure.
    func captureImage(rect: CGRect) -> CGImage? {
      imageResult(.rect(rect))
    }

    /// Captures the frontmost-app accessibility element whose label contains
    /// `label` and returns it as a `CGImage`, or nil on failure.
    func captureImage(label: String) -> CGImage? {
      imageResult(.element(label: label))
    }

    /// Saves the capture as a PNG artifact and returns its companion-side path.
    private func fileResult(_ area: ScreenshotArea) -> String? {
      stringResult(perform(.screenshot(area: area, output: .file)))
    }

    /// Returns the capture as a `CGImage`, decoded from the uncompressed TIFF the
    /// companion sends back (preserving the screen's color space).
    private func imageResult(_ area: ScreenshotArea) -> CGImage? {
      guard let data = perform(.screenshot(area: area, output: .data)) as? Data,
        !data.isEmpty,
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        return nil
      }
      return image
    }
  }

  /// The screenshot command namespace, reached as `IDB.screenshot`. Computed for
  /// the same library-evolution reason as `ui`.
  public static var screenshot: Screenshot { Screenshot() }

  /// Video-recording commands for the connected target, reached through `IDB.video`.
  public struct Video {

    /// Starts recording the connected target's screen into an auto-named file in
    /// the session's temporary directory. Only one recording runs at a time;
    /// returns false if one is already in progress or recording could not start.
    @discardableResult
    public func startRecording() -> Bool {
      guard let data = perform(.startRecording) as? Data else {
        return false
      }
      return !data.isEmpty
    }

    /// Stops the in-progress recording and returns the companion-side path to the
    /// recorded file, or nil if no recording was in progress. The path is on the
    /// companion's filesystem, which is the correct path for other `IDB` commands.
    @discardableResult
    public func stopRecording() -> String? {
      stringResult(perform(.stopRecording))
    }
  }

  /// The video command namespace, reached as `IDB.video`. Computed for the same
  /// library-evolution reason as `ui`.
  public static var video: Video { Video() }
}
