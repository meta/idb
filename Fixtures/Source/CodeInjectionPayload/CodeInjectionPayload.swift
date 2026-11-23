/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Foundation
import UIKit

// Entry points that FBSimulatorCodeInjection's smoke tests inject into a Simulator process. Most
// read something only code running inside the process can know; one has the app flash and click for
// a recording to capture. The shim finds them by C symbol with `dlsym`, which is why they are
// `@_cdecl`, calls them on its own thread with no arguments, and frees the C string they return.

private func returning(_ string: String) -> UnsafeMutablePointer<CChar>? {
  unsafe strdup(string)
}

/// The Simulator the process runs in, as the process itself sees it, then its bundle identifier
/// (empty for a process that is not an app).
// patternlint-disable-next-line cdecl-unsupported
@_cdecl("CodeInjectionPayloadDescribeProcess")
public func describeProcess() -> UnsafeMutablePointer<CChar>? {
  let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? ""
  return unsafe returning("\(udid) \(Bundle.main.bundleIdentifier ?? "")")
}

/// How many views the app's windows hold right now, read on the main thread as UIKit requires.
// patternlint-disable-next-line cdecl-unsupported
@_cdecl("CodeInjectionPayloadCountViews")
public func countViews() -> UnsafeMutablePointer<CChar>? {
  let count = DispatchQueue.main.sync {
    // patternlint-disable-next-line swift-mainactor-assumeisolated
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .reduce(0) { $0 + viewCount(in: $1) }
    }
  }
  return unsafe returning(String(count))
}

@MainActor
private func viewCount(in view: UIView) -> Int {
  view.subviews.reduce(1) { $0 + viewCount(in: $1) }
}

private final class InjectionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}

private let injections = InjectionCounter()

/// How many times this entry point has run in the process, so a later session can see state an
/// earlier one left behind.
// patternlint-disable-next-line cdecl-unsupported
@_cdecl("CodeInjectionPayloadCountInjections")
public func countInjections() -> UnsafeMutablePointer<CChar>? {
  unsafe returning(String(injections.increment()))
}

/// How many times `CodeInjectionPayloadFlashAndClick` flashes and clicks, and how far apart.
private let flashCount = 8
private let flashInterval: TimeInterval = 0.5
private let flashLength: TimeInterval = 0.1
/// The click is ten cycles of a 1 kHz sine at half of full scale.
private let clickFrequency = 1_000.0
private let clickPeak: Float = 0.5

/// Flashes the whole screen green and plays a click at the same moment, `flashCount` times, so that
/// a recording of the app can show whether its sound keeps step with its picture. Green, because no
/// app the payload is injected into is green, so only the flashes are. Returns the number of flashes
/// and the click's peak, or what failed.
// patternlint-disable-next-line cdecl-unsupported
@_cdecl("CodeInjectionPayloadFlashAndClick")
public func flashAndClick() -> UnsafeMutablePointer<CChar>? {
  let clicks: ClickPlayer
  do {
    clicks = try ClickPlayer()
  } catch {
    return unsafe returning("error: \(error)")
  }
  defer { clicks.stop() }
  guard let overlay = onMain({ Overlay() }) else {
    return unsafe returning("error: the app has no window scene to flash")
  }
  // A new window takes longer to appear than a colour takes to change, so the overlay is up and
  // black before the first flash.
  Thread.sleep(forTimeInterval: flashInterval - flashLength)
  for _ in 0..<flashCount {
    onMain { overlay.show(flash: true) }
    clicks.click()
    Thread.sleep(forTimeInterval: flashLength)
    onMain { overlay.show(flash: false) }
    Thread.sleep(forTimeInterval: flashInterval - flashLength)
  }
  onMain { overlay.remove() }
  return unsafe returning("\(flashCount) \(clickPeak)")
}

private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
  DispatchQueue.main.sync {
    // patternlint-disable-next-line swift-mainactor-assumeisolated
    MainActor.assumeIsolated(body)
  }
}

/// A window over the app's own, black or green.
@MainActor
private final class Overlay {
  private let window: UIWindow

  init?() {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
      return nil
    }
    window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    window.backgroundColor = .black
    window.isHidden = false
  }

  func show(flash: Bool) {
    window.backgroundColor = flash ? .green : .black
  }

  func remove() {
    window.isHidden = true
  }
}

private final class ClickPlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let buffer: AVAudioPCMBuffer

  init() throws {
    try AVAudioSession.sharedInstance().setCategory(.playback)
    try AVAudioSession.sharedInstance().setActive(true)
    let format = engine.outputNode.outputFormat(forBus: 0)
    guard
      let standard = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: standard, frameCapacity: AVAudioFrameCount(format.sampleRate * 10 / clickFrequency)),
      let channels = unsafe buffer.floatChannelData
    else {
      throw ClickError.noBuffer
    }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
      let sample = clickPeak * Float(sin(2 * Double.pi * clickFrequency * Double(frame) / format.sampleRate))
      unsafe channels[0][frame] = sample
      unsafe channels[1][frame] = sample
    }
    self.buffer = buffer
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: standard)
    try engine.start()
    player.play()
  }

  func click() {
    player.scheduleBuffer(buffer, completionHandler: nil)
  }

  func stop() {
    player.stop()
    engine.stop()
  }
}

private enum ClickError: Error {
  case noBuffer
}
