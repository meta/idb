/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Accelerate
import CoreImage
import Metal
@_implementationOnly import ShimulatorVideoInjectionAVFoundation
@_implementationOnly import ShimulatorVideoInjectionCore
import os

private let logger = Logger(subsystem: "com.facebook.idb", category: "video-injection")

func debug(_ message: String) {
  logger.debug("\(message, privacy: .public)")
}

func videoError(_ code: Int, _ message: String) -> NSError {
  NSError(domain: "com.facebook.idb.video-injection", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

enum Key {
  static var state = 0, connection = 0, recording = 0, pending = 0, previewSession = 0, previewConnection = 0,
    previewPending = 0, configurations = 0, nativeHandoff = 0, nativeRunning = 0
}

func associated<T>(_ object: AnyObject, _ key: UnsafeRawPointer) -> T? {
  objc_getAssociatedObject(object, key) as? T
}

func associate(_ object: AnyObject, _ key: UnsafeRawPointer, _ value: Any?) {
  objc_setAssociatedObject(object, key, value, .OBJC_ASSOCIATION_RETAIN)
}

func synchronized<T>(_ object: AnyObject, _ body: () throws -> T) rethrows -> T {
  objc_sync_enter(object)
  defer { objc_sync_exit(object) }
  return try body()
}

private func bufferAttributes(_ format: OSType, _ width: Int, _ height: Int) -> [String: Any] {
  [
    kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
  ]
}

/// The orientation that shows a track's stored frames upright. `preferredTransform` is in y-down
/// display space, so (a, b, c, d) = (0, 1, -1, 0) turns right into down: a clockwise quarter turn.
private func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
  switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
  case (0, 1, -1, 0): return .right
  case (-1, 0, 0, -1): return .down
  case (0, -1, 1, 0): return .left
  case (-1, 0, 0, 1): return .upMirrored
  case (1, 0, 0, -1): return .downMirrored
  case (0, 1, 1, 0): return .leftMirrored
  case (0, -1, -1, 0): return .rightMirrored
  default: return .up
  }
}

/// The camera's native, landscape frame for a preset, as a real device answers a preset by choosing
/// a sensor format. `High`, `InputPriority` and anything unlisted get the camera's own format.
private let nativeSize = CGSize(width: 1920, height: 1080)
private let presetSizes: [AVCaptureSession.Preset: CGSize] = [
  .cif352x288: CGSize(width: 352, height: 288), .vga640x480: CGSize(width: 640, height: 480),
  .hd1280x720: CGSize(width: 1280, height: 720), .iFrame1280x720: CGSize(width: 1280, height: 720),
  .hd1920x1080: CGSize(width: 1920, height: 1080), .hd4K3840x2160: CGSize(width: 3840, height: 2160),
  .iFrame960x540: CGSize(width: 960, height: 540), .low: CGSize(width: 192, height: 144),
  .medium: CGSize(width: 480, height: 360), .photo: CGSize(width: 1440, height: 1080),
]

private struct VideoTrack {
  let track: AVAssetTrack, transform: CGAffineTransform, size: CGSize, frameRate: Float
}

/// AVFoundation loads track properties only asynchronously; injection starts on the socket client's
/// own thread, which waits here. The semaphore orders the task's write before the read.
private func loadVideoTrack(_ asset: AVAsset) -> VideoTrack? {
  final class Loaded { var video: VideoTrack? }
  let loaded = Loaded()
  let done = DispatchSemaphore(value: 0)
  Task {
    defer { done.signal() }
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
      let properties = try? await track.load(.preferredTransform, .naturalSize, .nominalFrameRate)
    else { return }
    loaded.video = VideoTrack(track: track, transform: properties.0, size: properties.1, frameRate: properties.2)
  }
  // A file AVFoundation cannot finish loading is unplayable rather than a stuck injection.
  guard done.wait(timeout: .now() + 10) == .success else { return nil }
  return loaded.video
}

/// Decodes a video file into pixel buffers, looping; synthesises a portrait pattern when there is no
/// file. Frames are the file's stored frames: `orientation` shows them upright, and `width`/`height`
/// are the upright size. Frames are pulled only on the camera's queue.
final class FrameSource {
  private(set) var width: Int32 = 1080, height: Int32 = 1920, frameRate = 30.0
  private(set) var orientation = CGImagePropertyOrientation.up
  private(set) var exhausted = false, failed = false
  private let url: URL?, loops: Bool, asset: AVAsset?, track: AVAssetTrack?
  private var reader: AVAssetReader?, output: AVAssetReaderTrackOutput?, pool: CVPixelBufferPool?
  private var frameIndex: UInt64 = 0
  /// The frame outputs show now, held between frames and after a non-looping video ends, as a camera
  /// keeps delivering.
  private(set) var held: CVPixelBuffer?
  private var nextDue = 0.0

  init(url: URL?, loops: Bool) {
    self.url = url
    self.loops = loops
    asset = url.map { AVURLAsset(url: $0) }
    let video = asset.flatMap(loadVideoTrack)
    track = video?.track
    guard let url else { return }
    guard let video else {
      debug("no video track in \(url.path)")
      failed = true
      return
    }
    orientation = ShimulatorVideoInjectionCamera.orientation(for: video.transform)
    let size = video.size.applying(video.transform)
    width = Int32(abs(size.width))
    height = Int32(abs(size.height))
    if video.frameRate > 0 { frameRate = Double(video.frameRate) }
    debug("source \(url.lastPathComponent) \(width)x\(height) @\(frameRate) fps")
  }

  private func startReader() -> Bool {
    guard let asset, let track else { return false }
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ])
    output.alwaysCopiesSampleData = false
    do {
      let reader = try AVAssetReader(asset: asset)
      guard reader.canAdd(output) else { throw videoError(1, "Could not read the video track") }
      reader.add(output)
      (self.reader, self.output) = (reader, output)
      return reader.startReading()
    } catch {
      debug("could not read \(url?.path ?? ""): \(error)")
      return false
    }
  }

  func nextFrame() -> CVPixelBuffer? {
    frameIndex += 1
    if failed || (exhausted && !loops) { return nil }
    guard track != nil else { return generatedFrame() }
    if let sample = output?.copyNextSampleBuffer() { return CMSampleBufferGetImageBuffer(sample) }
    // The first pull starts the reader; a later one finds it finished and restarts it when looping.
    let first = reader == nil
    let completed = first || reader?.status == .completed
    if !completed { debug("video reader failed for \(url?.path ?? ""): \(String(describing: reader?.error))") }
    (reader, output) = (nil, nil)
    if completed && !first && !loops {
      exhausted = true
      return nil
    }
    guard completed, startReader(), let sample = output?.copyNextSampleBuffer() else {
      (failed, exhausted) = (true, true)
      return nil
    }
    return CMSampleBufferGetImageBuffer(sample)
  }

  /// Decodes the next frame once it is due at the file's own rate; true when outputs get a frame now.
  func advance(to now: Double) -> Bool {
    let interval = 1 / max(frameRate, 1)
    guard now + interval / 4 >= nextDue else { return false }
    nextDue = nextDue == 0 ? now + interval : max(nextDue, now - interval) + interval
    if let frame = nextFrame() { held = frame }
    return !failed && held != nil
  }

  /// The placeholder an armed camera shows with nothing injected: a dark frame naming itself, with a
  /// dot sweeping across so it still reads as a live camera.
  private func generatedFrame() -> CVPixelBuffer? {
    if idleBackground == nil { idleBackground = renderIdleBackground() }
    guard let background = idleBackground, let pool = pixelPool() else { return nil }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
      CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
    else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    background.withUnsafeBytes { bytes in
      if let source = bytes.baseAddress { memcpy(base, source, min(bytes.count, stride * Int(height))) }
    }
    let size = Int(width) / 12
    let travel = Int(width) - size
    let step = Int(frameIndex % UInt64(2 * travel / 12)) * 12
    let x = step <= travel ? step : 2 * travel - step
    var dot = vImage_Buffer(
      data: base + (Int(height) * 2 / 3) * stride + x * 4, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: stride)
    let orange: [UInt8] = [0x30, 0xA0, 0xFF, 0xFF] // filled in memory order, so B G R A
    vImageBufferFill_ARGB8888(&dot, orange, vImage_Flags(kvImageNoFlags))
    return buffer
  }

  private var idleBackground: Data?

  private func pixelPool() -> CVPixelBufferPool? {
    if pool == nil {
      CVPixelBufferPoolCreate(nil, nil, bufferAttributes(kCVPixelFormatType_32BGRA, Int(width), Int(height)) as CFDictionary, &pool)
    }
    return pool
  }

  /// The first and last columns of `image` with any opaque pixel.
  private func inkedColumns(of image: CIImage, in context: CIContext) -> (CGFloat, CGFloat)? {
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
    let columns = (0..<width).filter { x in (0..<height).contains { pixels[($0 * width + x) * 4 + 3] > 0 } }
    guard let first = columns.first, let last = columns.last else { return nil }
    return (image.extent.minX + CGFloat(first), image.extent.minX + CGFloat(last + 1))
  }

  /// Rendered once: CoreImage's text generator, inverted from black to white, on a dark grey frame.
  private func renderIdleBackground() -> Data? {
    let context = CIContext()
    guard let pool = pixelPool() else { return nil }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    let frame = CGRect(x: 0, y: 0, width: Int(width), height: Int(height))
    var image = CIImage(color: CIColor(red: 0.13, green: 0.13, blue: 0.14)).cropped(to: frame)
    if let label = CIFilter(
      name: "CITextImageGenerator",
      parameters: ["inputText": "idb camera\nno video injected", "inputFontName": "Helvetica-Bold", "inputFontSize": 56, "inputScaleFactor": 1]
    )?.outputImage?.applyingFilter("CIColorInvert") {
      // The generator's extent is wider than its text, so centre the inked columns instead.
      let ink = inkedColumns(of: label, in: context) ?? (label.extent.minX, label.extent.maxX)
      let origin = CGPoint(x: (frame.width - (ink.1 - ink.0)) / 2, y: (frame.height - label.extent.height) / 2)
      image = label.transformed(by: CGAffineTransform(translationX: origin.x - ink.0, y: origin.y - label.extent.minY))
        .composited(over: image)
    }
    context.render(image, to: buffer)
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    return Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * Int(height))
  }
}

/// The back camera's source and the front camera's, which is the same one unless the injection gave
/// the front camera its own video.
final class CameraSources {
  let back: FrameSource, front: FrameSource

  init(back: FrameSource, front: FrameSource? = nil) {
    (self.back, self.front) = (back, front ?? back)
  }

  var all: [FrameSource] { back === front ? [back] : [back, front] }
  var frameRate: Double { all.map(\.frameRate).max() ?? 30 }

  func source(for connection: ShimulatorCaptureConnection) -> FrameSource {
    for port in connection.virtualPorts {
      if let input = (port as? ShimulatorCaptureInputPort)?.owningInput as? ShimulatorCaptureDeviceInput {
        return input.virtualDevice.virtualPosition == .front ? front : back
      }
    }
    return back
  }
}

/// Held by the session as an associated object rather than in a table keyed on it:
/// AVCaptureSession's own -dealloc walks its inputs and outputs, and a weak table has already
/// stopped answering by then.
final class SessionState {
  var input: ShimulatorCaptureDeviceInput?
  var outputs: [AVCaptureOutput] = []
  var running = false
  var nativeAudioStartPending = false
  var preset = AVCaptureSession.Preset.high
}

func isNativeHandoff(_ session: AVCaptureSession?) -> Bool {
  guard let session else { return false }
  return (associated(session, &Key.nativeHandoff) as NSNumber?)?.boolValue ?? false
}

func withNativeView<T>(_ session: AVCaptureSession?, _ body: () -> T) -> T {
  guard let session,
    (associated(session, &Key.state) as SessionState?) != nil
      || (associated(session, &Key.nativeRunning) as NSNumber?) != nil || isNativeHandoff(session)
  else { return body() }
  synchronized(session) {
    let depth = (associated(session, &Key.nativeHandoff) as NSNumber?)?.intValue ?? 0
    associate(session, &Key.nativeHandoff, NSNumber(value: depth + 1))
  }
  defer {
    synchronized(session) {
      let depth = (associated(session, &Key.nativeHandoff) as NSNumber?)?.intValue ?? 1
      associate(session, &Key.nativeHandoff, depth > 1 ? NSNumber(value: depth - 1) : nil)
    }
  }
  return body()
}

func connectionSession(_ output: AVCaptureOutput) -> AVCaptureSession? {
  (associated(output, &Key.connection) as ShimulatorCaptureConnection?)?.virtualSession
}

func sessionState(_ session: AVCaptureSession?, create: Bool = false) -> SessionState? {
  guard let session, !isNativeHandoff(session) else { return nil }
  return synchronized(session) {
    guard !isNativeHandoff(session) else { return nil }
    if let state: SessionState = associated(session, &Key.state) { return state }
    guard create else { return nil }
    let state = SessionState()
    associate(session, &Key.state, state)
    return state
  }
}

/// Held by the output: an app reaches its connection through the output, and AVCaptureOutput does
/// not expose its session.
func virtualConnection(_ output: AVCaptureOutput) -> ShimulatorCaptureConnection? {
  guard let connection: ShimulatorCaptureConnection = associated(output, &Key.connection),
    !isNativeHandoff(connection.virtualSession)
  else { return nil }
  return connection
}

/// A preview layer's connection starts in portrait, as on a device; an output's is left unset, so
/// it follows the native landscape angle of whichever camera it reads.
func makeConnection(_ ports: [AVCaptureInput.Port], _ session: AVCaptureSession?, rotationAngle: CGFloat = -1) -> ShimulatorCaptureConnection {
  let connection = ShimulatorCaptureConnection()
  connection.virtualPorts = ports
  connection.virtualSession = session
  connection.storedRotationAngle = rotationAngle
  return connection
}

/// The shape of the frames a connection delivers: the preset's native size turned by the
/// connection's rotation, as a video data output delivers physically rotated buffers. The file's
/// own size only decides the crop.
func frameSize(_ connection: ShimulatorCaptureConnection) -> CGSize {
  let preset = sessionState(connection.virtualSession).map { state in synchronized(state) { state.preset } }
  let size = preset.flatMap { presetSizes[$0] } ?? nativeSize
  let angle = connection.rotationAngle
  return angle == 90 || angle == 270 ? CGSize(width: size.height, height: size.width) : size
}

final class MovieRecording {
  let writer: AVAssetWriter, adaptor: AVAssetWriterInputPixelBufferAdaptor
  let delegate: AVCaptureFileOutputRecordingDelegate, url: URL, frameSize: CGSize, rotationAngle: CGFloat, mirrored: Bool
  var start = CMTime.zero, started = false, finalizing = false, appendFailed = false

  init(_ writer: AVAssetWriter, _ adaptor: AVAssetWriterInputPixelBufferAdaptor, _ delegate: AVCaptureFileOutputRecordingDelegate, _ url: URL, _ connection: ShimulatorCaptureConnection, _ frameSize: CGSize) {
    (self.writer, self.adaptor, self.delegate, self.url) = (writer, adaptor, delegate, url)
    (self.frameSize, rotationAngle, mirrored) = (frameSize, connection.frameRotationAngle, connection.isVideoMirrored)
  }

  deinit {
    if writer.status == .writing {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
    }
  }
}

/// `lock` guards the session and layer sets, the sources and the progress, and recordings; take it
/// before a session's state, never inside one. Decoding, rendering and delivery run on `queue` without
/// it, so `tickCache`, `pools` and the frame sources themselves are only ever touched there.
@objc(ShimulatorVirtualCamera)
final class VirtualCamera: NSObject {
  static let shared = VirtualCamera()

  let backDevice = ShimulatorCaptureDevice(), frontDevice = ShimulatorCaptureDevice()
  private let lock = NSRecursiveLock()
  private let runningSessions = NSHashTable<AVCaptureSession>.weakObjects()
  private let previewLayers = NSHashTable<AVCaptureVideoPreviewLayer>.weakObjects()
  private let queue = DispatchQueue(label: "com.facebook.idb.video-injection")
  private let callbackQueue = DispatchQueue(label: "com.facebook.idb.video-injection.callbacks")
  // A CPU CoreImage context cannot keep up with per-output crop and scale at frame rate.
  private let context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
  private var sources = CameraSources(back: FrameSource(url: nil, loops: true))
  private var timer: DispatchSourceTimer?
  private var pools: [String: CVPixelBufferPool] = [:], tickCache: [String: CVPixelBuffer] = [:]
  private var generation: Int64 = -1, delivered = false
  /// The sources' terminal state, copied under `lock` from `queue`, which is the only thread the
  /// sources themselves may be read on once they are decoding.
  private var sourceFailed = false, sourceExhausted = false

  override private init() {
    super.init()
    for (device, position, id) in [(backDevice, AVCaptureDevice.Position.back, "back"), (frontDevice, .front, "front")] {
      device.virtualFormat = format(for: sources.back)
      device.virtualPosition = position
      device.virtualUniqueID = "idb-injected-camera-\(id)"
    }
  }

  @objc static func install() {
    installSwizzles()
    debug("installed in \(ProcessInfo.processInfo.processName)")
  }

  @objc(isConnectionActive:) static func isActive(_ connection: AVCaptureConnection) -> Bool {
    guard let connection = connection as? ShimulatorCaptureConnection,
      connection.storedEnabled, let state = sessionState(connection.virtualSession),
      synchronized(state, { state.running && state.input != nil })
    else { return false }
    return connection.virtualPorts.contains { $0.isEnabled }
  }

  var devices: [AVCaptureDevice] {
    _ = videoInjectionClientStarted
    return [backDevice, frontDevice]
  }

  func devices(at position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
    devices.filter { position == .unspecified || $0.position == position }
  }

  private func format(for source: FrameSource) -> ShimulatorCaptureDeviceFormat {
    let format = ShimulatorCaptureDeviceFormat()
    var description: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA, width: Int32(nativeSize.width), height: Int32(nativeSize.height), extensions: nil, formatDescriptionOut: &description)
    format.formatDescriptionRef = description
    format.range.rate = source.frameRate
    return format
  }

  // MARK: - Injection

  /// Returns the file that holds no playable video, if either does, and leaves the camera unchanged.
  func play(_ url: URL?, front frontURL: URL?, loops: Bool, generation: Int64) -> URL? {
    let back = FrameSource(url: url, loops: loops)
    if back.failed { return url }
    let front = frontURL.map { FrameSource(url: $0, loops: loops) }
    if let front, front.failed { return frontURL }
    let sources = CameraSources(back: back, front: front)
    lock.lock()
    self.sources = sources
    backDevice.virtualFormat = format(for: sources.back)
    frontDevice.virtualFormat = format(for: sources.front)
    (self.generation, delivered) = (generation, false)
    (sourceFailed, sourceExhausted) = (false, false)
    lock.unlock()
    reconcileTimer(resetRate: true)
    debug("injection \(generation): \(url?.path ?? "idle")\(frontURL.map { ", front \($0.path)" } ?? "")")
    return nil
  }

  var progress: VideoInjectionProgress {
    locked { VideoInjectionProgress(generation: generation, started: delivered, finished: !sourceFailed && sourceExhausted, failed: sourceFailed) }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  // MARK: - Sessions

  func session(_ session: AVCaptureSession, added output: AVCaptureOutput) {
    guard let state = sessionState(session, create: true) else { return }
    synchronized(state) {
      if !state.outputs.contains(output) { state.outputs.append(output) }
      let connection = virtualConnection(output) ?? makeConnection([], nil)
      connection.virtualOutput = output
      associate(output, &Key.connection, connection)
      connection.virtualSession = session
      connection.virtualPorts = state.input?.ports ?? []
    }
  }

  /// Posts the KVO a real session posts for `running`, which the shim's state replaces.
  private func set(_ session: AVCaptureSession, running: Bool) -> Bool {
    guard let state = sessionState(session), synchronized(state, { state.running != running }) else { return false }
    session.willChangeValue(forKey: "running")
    let changed: Bool = locked {
      let changed = synchronized(state) { () -> Bool in
        defer { state.running = running }
        return state.running != running
      }
      if changed { running ? runningSessions.add(session) : runningSessions.remove(session) }
      return changed
    }
    session.didChangeValue(forKey: "running")
    return changed
  }

  func start(_ session: AVCaptureSession) {
    guard set(session, running: true) else { return }
    reconcileTimer(resetRate: false)
    NotificationCenter.default.post(name: .AVCaptureSessionDidStartRunning, object: session)
  }

  func stop(_ session: AVCaptureSession) {
    guard set(session, running: false), let state = sessionState(session) else { return }
    for output in synchronized(state, { state.outputs }) {
      synchronized(output) { associate(output, &Key.pending, nil) }
      (output as? AVCaptureMovieFileOutput).map(stopRecording)
    }
    reconcileTimer(resetRate: false)
    NotificationCenter.default.post(name: .AVCaptureSessionDidStopRunning, object: session)
  }

  /// A running session without the camera input stays running, as a real one does, but gets no frames.
  func setReceivesFrames(_ session: AVCaptureSession, _ receives: Bool) {
    locked { receives ? runningSessions.add(session) : runningSessions.remove(session) }
    reconcileTimer(resetRate: false)
  }

  private func reconcileTimer(resetRate: Bool) {
    var cancelled: DispatchSourceTimer?
    var started: DispatchSourceTimer?
    let rate: Double = locked {
      let shouldRun = runningSessions.count > 0
      if resetRate || !shouldRun { (cancelled, timer) = (timer, nil) }
      guard shouldRun, timer == nil else { return 0 }
      let rate = sources.frameRate
      let interval = 1 / max(rate, 1)
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(Int(interval * 1e8)))
      timer.setEventHandler { [weak self] in self?.deliverFrame() }
      (self.timer, started) = (timer, timer)
      return rate
    }
    cancelled?.cancel()
    if let started {
      started.resume()
      debug("camera running at \(rate) fps")
    }
  }

  // MARK: - Frame delivery

  /// The frame as a connection at `angle` sees it, aspect-filled into `size` and centre-cropped, as a
  /// real camera crops its sensor rather than letterboxing it. One CoreImage pass. The file is upright
  /// in portrait (90); the camera's native frame is a quarter turn back from that. A mirrored
  /// connection flips the result left to right.
  private func render(_ frame: CVPixelBuffer, _ source: FrameSource, _ format: OSType, _ size: CGSize, _ angle: CGFloat, _ mirrored: Bool) -> CVPixelBuffer? {
    let width = Int(size.width.rounded())
    let height = Int(size.height.rounded())
    let turn = (angle + 270).truncatingRemainder(dividingBy: 360)
    let rotation: CGImagePropertyOrientation = [90: .right, 180: .down, 270: .left][turn] ?? .up
    if rotation == .up, !mirrored, source.orientation == .up, CVPixelBufferGetPixelFormatType(frame) == format,
      CVPixelBufferGetWidth(frame) == width, CVPixelBufferGetHeight(frame) == height
    {
      return frame
    }
    let key = "\(format)-\(width)-\(height)"
    if pools[key] == nil {
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, bufferAttributes(format, width, height) as CFDictionary, &pool)
      pools[key] = pool
    }
    var destination: CVPixelBuffer?
    guard let pool = pools[key], CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
      let destination
    else { return nil }
    var image = CIImage(cvPixelBuffer: frame).oriented(source.orientation).oriented(rotation)
    if mirrored { image = image.oriented(.upMirrored) }
    let extent = image.extent
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    if extent != target {
      let scale = max(target.width / extent.width, target.height / extent.height)
      image = image.transformed(
        by: CGAffineTransform(
          a: scale, b: 0, c: 0, d: scale,
          tx: (target.width - extent.width * scale) / 2 - extent.minX * scale,
          ty: (target.height - extent.height * scale) / 2 - extent.minY * scale
        )
      ).cropped(to: target)
    }
    context.render(image, to: destination)
    return destination
  }

  /// Cached for the tick: the same shape is rendered once, however many outputs want it.
  private func shaped(_ frame: CVPixelBuffer, _ source: FrameSource, _ format: OSType, _ size: CGSize, _ angle: CGFloat, _ mirrored: Bool) -> CVPixelBuffer? {
    let key = "\(ObjectIdentifier(source).hashValue)-\(format)-\(size.width)-\(size.height)-\(angle)-\(mirrored)"
    if let cached = tickCache[key] { return cached }
    tickCache[key] = render(frame, source, format, size, angle, mirrored)
    return tickCache[key]
  }

  private func deliverFrame() {
    let (sessions, layers, sources) = locked { (runningSessions.allObjects, previewLayers.allObjects, self.sources) }
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    let ticked = Set(sources.all.filter { $0.advance(to: now.seconds) }.map(ObjectIdentifier.init))
    let failed = sources.all.contains { $0.failed }
    let exhausted = sources.all.allSatisfy { $0.exhausted }
    // An injection that replaced the sources while these frames decoded owns the camera now.
    let current: Bool = locked {
      guard self.sources === sources else { return false }
      (sourceFailed, sourceExhausted) = (failed, exhausted)
      return true
    }
    guard current, !ticked.isEmpty else { return }
    /// The new frame for the camera a connection shows, if that camera has one this tick.
    let frame = { (connection: ShimulatorCaptureConnection) -> (CVPixelBuffer, FrameSource)? in
      let source = sources.source(for: connection)
      guard ticked.contains(ObjectIdentifier(source)), let held = source.held else { return nil }
      return (held, source)
    }
    var delivered = false
    for session in sessions {
      for output in sessionState(session).map({ state in synchronized(state) { state.outputs } }) ?? [] {
        guard let connection = virtualConnection(output), Self.isActive(connection), let (image, source) = frame(connection) else { continue }
        if let output = output as? AVCaptureVideoDataOutput {
          delivered = deliver(image, source, to: output, connection, at: now) || delivered
        } else if let output = output as? AVCaptureMovieFileOutput {
          delivered = deliver(image, source, to: output, at: now) || delivered
        }
      }
    }
    delivered = deliver(to: layers, frame) || delivered
    if delivered { locked { if self.sources === sources { self.delivered = true } } }
    tickCache.removeAll()
  }

  private func deliver(_ frame: CVPixelBuffer, _ source: FrameSource, to output: AVCaptureVideoDataOutput, _ connection: ShimulatorCaptureConnection, at time: CMTime) -> Bool {
    // A late frame is skipped while the delegate still holds the last one; only this queue sets the
    // flag, so checking it here and setting it below cannot race.
    let discardsLate = output.alwaysDiscardsLateVideoFrames
    let format = (output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? kCVPixelFormatType_32BGRA
    guard let delegate = output.sampleBufferDelegate, let queue = output.sampleBufferCallbackQueue,
      delegate.responds(to: #selector(AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didOutput:from:))),
      !discardsLate || (associated(output, &Key.pending) as NSObject?) == nil,
      let converted = shaped(frame, source, format, frameSize(connection), connection.frameRotationAngle, connection.isVideoMirrored),
      let description = try? CMVideoFormatDescription(imageBuffer: converted),
      let sample = try? CMSampleBuffer(
        imageBuffer: converted, formatDescription: description,
        sampleTiming: CMSampleTimingInfo(
          duration: CMTime(seconds: 1 / source.frameRate, preferredTimescale: 600_000), presentationTimeStamp: time, decodeTimeStamp: .invalid))
    else { return false }
    let pending = discardsLate ? NSObject() : nil
    if let pending { synchronized(output) { associate(output, &Key.pending, pending) } }
    queue.async {
      if virtualConnection(output) === connection, Self.isActive(connection) {
        delegate.captureOutput?(output, didOutput: sample, from: connection)
      }
      if let pending {
        synchronized(output) { if associated(output, &Key.pending) === pending { associate(output, &Key.pending, nil) } }
      }
    }
    return true
  }

  private func deliver(_ frame: CVPixelBuffer, _ source: FrameSource, to output: AVCaptureMovieFileOutput, at time: CMTime) -> Bool {
    guard let recording: MovieRecording = associated(output, &Key.recording),
      let converted = shaped(frame, source, kCVPixelFormatType_32BGRA, recording.frameSize, recording.rotationAngle, recording.mirrored)
    else { return false }
    // Under the lock, so a concurrent stop cannot mark the input finished between check and append.
    let appended: Bool? = locked {
      guard !recording.finalizing, recording.adaptor.assetWriterInput.isReadyForMoreMediaData else { return nil }
      if !recording.started {
        (recording.started, recording.start) = (true, time)
        recording.writer.startSession(atSourceTime: .zero)
      }
      let appended = recording.adaptor.append(converted, withPresentationTime: time - recording.start)
      if !appended { recording.appendFailed = true }
      return appended
    }
    if appended == false { stopRecording(output, expected: recording) }
    return appended == true
  }

  private func deliver(to layers: [AVCaptureVideoPreviewLayer], _ frame: (ShimulatorCaptureConnection) -> (CVPixelBuffer, FrameSource)?) -> Bool {
    var delivered = false
    for layer in layers {
      // Only this queue sets the pending flag, as for the video data output.
      guard let connection = layer.connection as? ShimulatorCaptureConnection, Self.isActive(connection),
        (associated(layer, &Key.previewPending) as NSObject?) == nil, let (image, source) = frame(connection),
        let shaped = shaped(image, source, kCVPixelFormatType_32BGRA, frameSize(connection), connection.frameRotationAngle, connection.isVideoMirrored)
      else { continue }
      let ciImage = CIImage(cvPixelBuffer: shaped)
      guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { continue }
      let pending = NSObject()
      synchronized(layer) { associate(layer, &Key.previewPending, pending) }
      delivered = true
      DispatchQueue.main.async {
        if layer.connection === connection, Self.isActive(connection) {
          // Setting `contents` bypasses the layer's own video path, so videoGravity is mapped by hand.
          layer.contentsGravity = [.resizeAspectFill: .resizeAspectFill, .resize: .resize][layer.videoGravity] ?? .resizeAspect
          layer.masksToBounds = true
          layer.contents = image
        }
        synchronized(layer) { if associated(layer, &Key.previewPending) === pending { associate(layer, &Key.previewPending, nil) } }
      }
    }
    return delivered
  }

  func restoreNativePreviews(_ session: AVCaptureSession) {
    let layers = locked { previewLayers.allObjects }
    DispatchQueue.main.async {
      for layer in layers {
        guard associated(layer, &Key.previewSession) === session,
          (associated(session, &Key.state) as SessionState?) == nil
        else { continue }
        synchronized(layer) {
          associate(layer, &Key.previewConnection, nil)
          associate(layer, &Key.previewPending, nil)
        }
        layer.contents = nil
        layer.shimulator_setSession(session)
      }
    }
  }

  /// Registered whatever the session's state: apps routinely bind the preview layer before adding
  /// the camera input. Which layers are live is decided per frame, from the session each one holds.
  func track(_ layer: AVCaptureVideoPreviewLayer, session: AVCaptureSession?) {
    associate(layer, &Key.previewSession, session)
    let state = sessionState(session)
    let connection = state.flatMap { state in synchronized(state) { state.input.map { makeConnection($0.ports, session, rotationAngle: 90) } } }
    associate(layer, &Key.previewConnection, connection)
    locked { previewLayers.add(layer) }
  }

  // MARK: - Recording

  private func finish(_ output: AVCaptureMovieFileOutput, _ url: URL, _ delegate: AVCaptureFileOutputRecordingDelegate, _ connections: [AVCaptureConnection], _ error: Error?) {
    callbackQueue.async { delegate.fileOutput(output, didFinishRecordingTo: url, from: connections, error: error) }
  }

  /// Records video only, straight to `url`: the frames are the injected file's, whatever audio the session has.
  func startRecording(_ output: AVCaptureMovieFileOutput, to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
    let connections = output.connections
    let connection = virtualConnection(output)
    let error: Error? = locked {
      guard let connection, Self.isActive(connection) else { return videoError(6, "The movie output has no active video connection") }
      guard associated(output, &Key.recording) as MovieRecording? == nil else { return videoError(7, "Recording is already in progress") }
      // Checked first so a failed recording never deletes a file it did not create.
      guard !FileManager.default.fileExists(atPath: url.path) else { return videoError(9, "The recording destination already exists") }
      let size = frameSize(connection)
      let width = Int(size.width.rounded())
      let height = Int(size.height.rounded())
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
      input.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: bufferAttributes(kCVPixelFormatType_32BGRA, width, height))
      do {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard writer.canAdd(input) else { return videoError(1, "Could not create the movie writer") }
        writer.add(input)
        guard writer.startWriting() else {
          try? FileManager.default.removeItem(at: url)
          return writer.error ?? videoError(3, "Could not start the movie writer")
        }
        associate(output, &Key.recording, MovieRecording(writer, adaptor, delegate, url, connection, size))
        return nil
      } catch {
        return error
      }
    }
    if let error {
      debug("could not record to \(url.path): \(error)")
      return finish(output, url, delegate, connections, error)
    }
    callbackQueue.async { delegate.fileOutput?(output, didStartRecordingTo: url, from: connections) }
  }

  func stopRecording(_ output: AVCaptureMovieFileOutput) {
    stopRecording(output, expected: nil)
  }

  private func stopRecording(_ output: AVCaptureMovieFileOutput, expected: MovieRecording?) {
    let state: (MovieRecording, Bool)? = locked {
      guard let recording: MovieRecording = associated(output, &Key.recording), !recording.finalizing,
        expected == nil || recording === expected
      else { return nil }
      recording.finalizing = true
      if !recording.started { recording.writer.startSession(atSourceTime: .zero) }
      recording.adaptor.assetWriterInput.markAsFinished()
      return (recording, recording.appendFailed)
    }
    guard let (recording, appendFailed) = state else { return }
    let connections = output.connections
    recording.writer.finishWriting { [self] in
      let writer = recording.writer
      let appendError = appendFailed ? writer.error ?? videoError(10, "Could not append the movie frame") : nil
      let error: Error? = appendError ?? (writer.status == .completed ? nil : writer.error ?? videoError(8, "The movie writer did not complete"))
      if error != nil { try? FileManager.default.removeItem(at: recording.url) }
      locked { if associated(output, &Key.recording) === recording { associate(output, &Key.recording, nil) } }
      finish(output, recording.url, recording.delegate, connections, error)
    }
  }

  func isRecording(_ output: AVCaptureMovieFileOutput) -> Bool {
    locked { (associated(output, &Key.recording) as MovieRecording?).map { !$0.finalizing } ?? false }
  }

  // MARK: - Photo capture

  /// Serialised on `queue` behind frame delivery, so overlapping captures queue as on a real output.
  func capturePhoto(_ output: AVCapturePhotoOutput, settings: AVCapturePhotoSettings, delegate: AVCapturePhotoCaptureDelegate) {
    queue.async { [self] in
      let connection = virtualConnection(output).flatMap { Self.isActive($0) ? $0 : nil }
      let sources = locked { self.sources }
      let source = connection.map { sources.source(for: $0) } ?? sources.back
      let resolved = ShimulatorCaptureResolvedPhotoSettings()
      resolved.storedUniqueID = settings.uniqueID
      let photo = ShimulatorCapturePhoto()
      var error: Error?
      if let connection, !source.failed {
        let size = frameSize(connection)
        resolved.storedPhotoDimensions = CMVideoDimensions(width: Int32(size.width.rounded()), height: Int32(size.height.rounded()))
        callbackQueue.async {
          delegate.photoOutput?(output, willBeginCaptureFor: resolved)
          delegate.photoOutput?(output, willCapturePhotoFor: resolved)
        }
        let frame = source.held ?? source.nextFrame()
        if let frame, let shaped = render(frame, source, kCVPixelFormatType_32BGRA, size, connection.frameRotationAngle, connection.isVideoMirrored),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let jpeg = context.jpegRepresentation(of: CIImage(cvPixelBuffer: shaped), colorSpace: colorSpace, options: [:])
        {
          photo.jpeg = jpeg
          photo.storedPixelBuffer = shaped
          photo.storedImage = context.createCGImage(CIImage(cvPixelBuffer: shaped), from: CGRect(origin: .zero, size: size))
          photo.storedTimestamp = CMClockGetTime(CMClockGetHostTimeClock())
          locked { if self.sources === sources { delivered = true } }
        } else {
          error = frame == nil ? videoError(4, "No injected camera frame is available") : videoError(5, "Could not encode the injected camera frame")
        }
      } else {
        error = connection == nil ? videoError(6, "The photo output has no active video connection") : videoError(4, "The injected camera source failed")
      }
      photo.storedResolvedSettings = resolved
      callbackQueue.async {
        delegate.photoOutput?(output, didFinishProcessingPhoto: photo, error: error)
        delegate.photoOutput?(output, didFinishCaptureFor: resolved, error: error)
      }
    }
  }
}
