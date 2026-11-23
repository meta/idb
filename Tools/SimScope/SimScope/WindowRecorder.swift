/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import AVFoundation
import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit

/// Records SimScope's own window to an `.mp4` — the session as the human sees it, simulator and log
/// together, rather than the simulator's video stream alone (which is what `SessionRecorder` keeps).
///
/// Frames come from the window server's composited copy of *our* window, not from a display capture
/// and not from a layer render. That choice buys three things at once: the title bar and toolbar are in
/// frame, the CoreAnimation touch feedback is caught mid-flight (a layer render draws the model tree, so
/// an in-flight ripple would render at its final, invisible state), and nothing that happens to be
/// sitting on top of the window — or anywhere else on the desktop — is ever in the recording.
///
/// ScreenCaptureKit, rather than `CGWindowListCreateImage` on a timer. The older call hands back a lazy
/// image whose pixels are only fetched when it is drawn, and for a window whose app is in the background
/// that fetch costs about a second — a rate of roughly one frame per second, on or off the main thread.
/// An unattended take is always in the background, so that is the only rate that matters here.
final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable { // state below is confined to `queue`

  enum Failure: LocalizedError {
    case windowNotShareable
    case writerRefused

    var errorDescription: String? {
      switch self {
      case .windowNotShareable: return "The window server would not share this window's pixels."
      case .writerRefused: return "The movie writer refused to start."
      }
    }
  }

  private let windowID: CGWindowID
  private let scale: CGFloat
  private let url: URL
  private let fps: Int
  private let queue = DispatchQueue(label: "com.facebook.simscope.window-recorder")
  /// Frames are scaled to fit this on their long edge. Backing-store pixels on a high-density display make
  /// for a needlessly large file to hand to someone.
  private static let maxDimension: CGFloat = 1800

  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  /// Capture timestamps are on the host clock, so the first frame's is the take's zero.
  private var firstFrameTime: CMTime?
  private var isRecording = false

  @MainActor
  init(window: NSWindow, url: URL, fps: Int = 15) {
    self.windowID = CGWindowID(window.windowNumber)
    self.scale = window.backingScaleFactor
    self.url = url
    self.fps = fps
  }

  func start() async throws {
    // A sleeping display composites nothing, so an unattended take started after the machine went idle
    // records blank frames from beginning to end. Declaring user activity wakes it; keeping it awake for
    // the length of the take is the caller's business. Nothing here needs the screen unlocked.
    var assertion = IOPMAssertionID(0)
    IOPMAssertionDeclareUserActivity("SimScope is recording its window" as CFString, kIOPMUserActiveLocal, &assertion)

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw Failure.windowNotShareable
    }
    let size = videoSize(for: window.frame)

    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
      ])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    guard writer.startWriting() else { throw Failure.writerRefused }
    writer.startSession(atSourceTime: .zero)

    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.scalesToFit = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 6
    // The system pointer is wherever the person who launched this left it, which is not where the
    // scripted human is touching — an arrow parked over the log would only mislead.
    configuration.showsCursor = false

    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

    queue.sync {
      self.writer = writer
      self.input = input
      self.adaptor = adaptor
      self.isRecording = true
    }
    try await stream.startCapture()
    self.stream = stream
  }

  /// Finishes the file and returns it, or nil if nothing was being recorded.
  @discardableResult
  func stop() async -> URL? {
    await withCheckedContinuation { continuation in
      finish { continuation.resume(returning: $0) }
    }
  }

  /// `stop()` for a caller that cannot await, blocking the calling thread until the file is closed.
  ///
  /// The quit path needs this. `applicationShouldTerminate` can ask AppKit to wait by answering
  /// `.terminateLater`, but the run loop it spins while waiting never services the main actor's queue,
  /// so a `Task` scheduled from there is simply never run and the reply never comes. Blocking is safe
  /// from any thread but the recorder's own: everything below hands off to `queue` and to AVFoundation.
  func stopBlocking(timeout: TimeInterval = 10) -> URL? {
    let result = Box()
    let finished = DispatchSemaphore(value: 0)
    finish {
      result.url = $0
      finished.signal()
    }
    return finished.wait(timeout: .now() + timeout) == .success ? result.url : nil
  }

  private final class Box: @unchecked Sendable { // handed between queues, but only ever before/after the semaphore
    var url: URL?
  }

  /// Ends the capture and closes the movie, calling back with the finalized file or nil if there was
  /// nothing in flight.
  ///
  /// The stream is not waited on: a sample that arrives after this point is dropped by the recording
  /// check in the output callback, which runs on the same queue as the teardown below.
  private func finish(completion: @escaping @Sendable (URL?) -> Void) {
    stream?.stopCapture { _ in }
    stream = nil
    queue.async { [self] in
      guard isRecording, let writer, let input else { return completion(nil) }
      isRecording = false
      input.markAsFinished()
      writer.finishWriting {
        completion(writer.status == .completed ? self.url : nil)
      }
      self.writer = nil
      self.input = nil
      self.adaptor = nil
    }
  }

  // MARK: - SCStreamOutput

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, isRecording, sampleBuffer.isValid, Self.isComplete(sampleBuffer) else { return }
    guard let adaptor, let input, input.isReadyForMoreMediaData else { return } // dropped frame: better than a stall
    guard let pixels = sampleBuffer.imageBuffer else { return }

    let time = sampleBuffer.presentationTimeStamp
    let start = firstFrameTime ?? time
    firstFrameTime = start
    adaptor.append(pixels, withPresentationTime: time - start)
  }

  // MARK: - SCStreamDelegate

  /// The stream can be torn down under us — the window closing, or the system withdrawing capture. The
  /// take is lost either way; saying so beats an empty file with no explanation.
  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    NSLog("SimScope: window capture stopped — %@", String(describing: error))
  }

  // MARK: - Private

  /// A frame the stream marks anything other than complete is a placeholder for "nothing changed" —
  /// appending those would pad the movie with duplicates of whatever was last on screen.
  private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int
    else { return false }
    return SCFrameStatus(rawValue: raw) == .complete
  }

  /// The recorded frame size: the window's pixels, capped on the long edge, and even on both axes
  /// because h264 macroblocks come in pairs.
  private func videoSize(for frame: CGRect) -> CGSize {
    let width = frame.width * scale
    let height = frame.height * scale
    let fit = min(1, Self.maxDimension / max(width, height))
    return CGSize(width: (width * fit / 2).rounded() * 2, height: (height * fit / 2).rounded() * 2)
  }
}
