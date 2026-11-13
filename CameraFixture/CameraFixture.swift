/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/*
 * Camera fixture: an ordinary public-API AVFoundation capture client that knows
 * nothing about injection. Every line it prints starts with `CAMFIXTURE`, and
 * every captured image is reported as `<W>x<H> centre=<c> top=<c> left=<c>`:
 * the pixel at the centre, at the horizontal centre 1/8 of the height from the
 * top, and at a quarter of the width on the vertical centre. BGRA colours are
 * `0xRRGGBB`; 4:2:0 ones are `yuv(Y,Cb,Cr)`.
 *
 *   CameraFixture stream <frames> <timeout>
 *   CameraFixture watch <seconds>                -- one report a second
 *   CameraFixture output-first <frames>          -- the output is added before the camera input
 *   CameraFixture preset-first <frames>          -- a preset is committed before the camera input; fails on a runtime error
 *   CameraFixture preset <name> <frames>
 *   CameraFixture nv12 <frames>
 *   CameraFixture rotate <angle> <frames>        -- clockwise, on the data output's connection
 *   CameraFixture preview
 *   CameraFixture roi                            -- session connections, and preview-layer rects and points at each gravity and angle
 *   CameraFixture photo <out.jpg>
 *   CameraFixture movie <seconds> <out.mov>
 *
 * With CAMFIXTURE_FRONT set in its environment it opens the front camera instead of the default one.
 */

import AVFoundation
import ImageIO
import os

func report(_ line: String) {
  fputs("CAMFIXTURE \(line)\n", stdout)
  fflush(stdout)
}

func samplePoints(_ width: Int, _ height: Int, _ at: (Int, Int) -> String) -> String {
  "\(width)x\(height) centre=\(at(width / 2, height / 2)) top=\(at(width / 2, height / 8)) left=\(at(width / 4, height / 2))"
}

func bgraColours(_ base: UnsafeRawPointer?, _ stride: Int, _ width: Int, _ height: Int) -> String {
  guard let base else { return "\(width)x\(height) unreadable" }
  return samplePoints(width, height) { x, y in
    let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
    return String(format: "0x%02x%02x%02x", pixel[2], pixel[1], pixel[0])
  }
}

func bufferColours(_ image: CVPixelBuffer) -> String {
  let width = CVPixelBufferGetWidth(image)
  let height = CVPixelBufferGetHeight(image)
  let format = CVPixelBufferGetPixelFormatType(image)
  let biplanar = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format)
  guard width > 0, height > 0, format == kCVPixelFormatType_32BGRA || biplanar,
    !biplanar || CVPixelBufferGetPlaneCount(image) >= 2,
    CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess
  else { return "\(width)x\(height) unreadable fmt=\(format)" }
  defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
  guard biplanar else { return bgraColours(CVPixelBufferGetBaseAddress(image), CVPixelBufferGetBytesPerRow(image), width, height) }
  guard let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
    let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self)
  else { return "\(width)x\(height) unreadable fmt=\(format)" }
  let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
  let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
  let fourCC = String((0..<4).map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: format >> (24 - $0 * 8)))) })
  return samplePoints(width, height) { x, y in
    let cbcr = chroma + (y / 2) * chromaStride + (x / 2) * 2
    return "yuv(\(luma[y * lumaStride + x]),\(cbcr[0]),\(cbcr[1]))"
  }.replacingOccurrences(of: " centre=", with: " fmt=\(fourCC) centre=")
}

func imageColours(_ image: CGImage) -> String {
  let width = image.width
  let height = image.height
  guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return "\(width)x\(height) unreadable" }
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return bgraColours(context.data, width * 4, width, height)
}

final class FrameObserver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var wanted = 10, quiet = false
  let done = DispatchSemaphore(value: 0)
  // Frames arrive on the capture queue while the main thread reports on them.
  private let lock = NSLock()
  private var count = 0, latest = ""

  var snapshot: (frameCount: Int, last: String) { lock.withLock { (count, latest) } }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let colours = bufferColours(image)
    let index: Int = lock.withLock {
      latest = colours
      count += 1
      return count - 1
    }
    if !quiet { report(String(format: "frame %ld pts=%.3f ", index, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) + colours) }
    if wanted > 0 && index + 1 == wanted { done.signal() }
  }
}

final class PhotoObserver: NSObject, AVCapturePhotoCaptureDelegate {
  let done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var photo: AVCapturePhoto?, error: Error?

  var snapshot: (photo: AVCapturePhoto?, error: Error?) { lock.withLock { (photo, error) } }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    lock.withLock { (self.photo, self.error) = (photo, error) }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    lock.withLock { self.error = self.error ?? error }
    done.signal()
  }
}

final class MovieObserver: NSObject, AVCaptureFileOutputRecordingDelegate {
  let started = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var error: Error?, startCount = 0, finishCount = 0

  var snapshot: (error: Error?, startCount: Int, finishCount: Int) { lock.withLock { (error, startCount, finishCount) } }

  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    lock.withLock { startCount += 1 }
    started.signal()
  }

  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    let succeeded = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
    let (starts, recordingError) = lock.withLock {
      finishCount += 1
      self.error = succeeded ? nil : error
      return (startCount, self.error)
    }
    report("recording finished starts=\(starts) error=\(recordingError.map { "\($0)" } ?? "(null)")")
    if !succeeded && starts == 0 { started.signal() }
    done.signal()
  }
}

func makeSession(outputBeforeInput: AVCaptureOutput? = nil, presetBeforeInput: AVCaptureSession.Preset? = nil) -> AVCaptureSession? {
  let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
  let device =
    ProcessInfo.processInfo.environment["CAMFIXTURE_FRONT"] == nil
    ? AVCaptureDevice.default(for: .video) : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
  let preferred = "\(AVCaptureDevice.systemPreferredCamera?.uniqueID ?? "(null)"),\(AVCaptureDevice.userPreferredCamera?.uniqueID ?? "(null)")"
  report("discovered=\(discovery.devices.count) device=\(device?.uniqueID ?? "(null)") preferred=\(preferred)")
  let input: AVCaptureDeviceInput
  do {
    guard let device else { throw CocoaError(.featureUnsupported) }
    input = try AVCaptureDeviceInput(device: device)
  } catch {
    report("no camera input: \(error)")
    return nil
  }
  let session = AVCaptureSession()
  if let presetBeforeInput {
    session.beginConfiguration()
    session.sessionPreset = presetBeforeInput
    session.commitConfiguration()
  }
  session.beginConfiguration()
  if let outputBeforeInput, session.canAddOutput(outputBeforeInput) { session.addOutput(outputBeforeInput) }
  let added = session.canAddInput(input)
  if added { session.addInput(input) }
  session.commitConfiguration()
  if !added { report("session rejected the camera input") }
  return added ? session : nil
}

func makeDataOutput(_ format: OSType, _ observer: FrameObserver) -> AVCaptureVideoDataOutput {
  let output = AVCaptureVideoDataOutput()
  output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
  output.setSampleBufferDelegate(observer, queue: DispatchQueue(label: "fixture.frames"))
  return output
}

/// Runs the session until the observer has its frames; the last frame is the result line.
func runFrames(_ mode: String, _ session: AVCaptureSession, _ observer: FrameObserver, _ timeout: TimeInterval) -> Int32 {
  session.startRunning()
  report("running=\(session.isRunning ? 1 : 0)")
  let wait = observer.done.wait(timeout: .now() + timeout)
  session.stopRunning()
  let (frames, last) = observer.snapshot
  report("result \(mode) frames=\(frames) last \(last)")
  return wait == .success ? 0 : 5
}

func capturePhoto(_ session: AVCaptureSession, _ path: String) -> Int32 {
  let output = AVCapturePhotoOutput()
  if session.canAddOutput(output) { session.addOutput(output) }
  session.startRunning()
  Thread.sleep(forTimeInterval: 1)
  let observer = PhotoObserver()
  output.capturePhoto(with: AVCapturePhotoSettings(), delegate: observer)
  let wait = observer.done.wait(timeout: .now() + 8)
  session.stopRunning()
  let (photo, error) = observer.snapshot
  guard wait == .success, error == nil, let data = photo?.fileDataRepresentation(), let resolved = photo?.resolvedSettings.photoDimensions,
    let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
    (try? data.write(to: URL(fileURLWithPath: path))) != nil
  else {
    report("result photo failed error=\(error.map { "\($0)" } ?? "(null)")")
    return 6
  }
  report("result photo bytes=\(data.count) resolved=\(resolved.width)x\(resolved.height) \(imageColours(image))")
  return 0
}

/// AVFoundation loads asset properties only asynchronously; this fixture reports synchronously, and
/// gives up on an asset that has not loaded in 30 seconds.
func movieDurationAndSize(_ url: URL) -> (duration: Double, size: CGSize)? {
  let loaded = OSAllocatedUnfairLock<(duration: Double, size: CGSize)?>(initialState: nil)
  let done = DispatchSemaphore(value: 0)
  Task {
    defer { done.signal() }
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration).seconds,
      let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
    else { return }
    loaded.withLock { $0 = (duration, size) }
  }
  guard done.wait(timeout: .now() + 30) == .success else {
    return nil
  }
  return loaded.withLock { $0 }
}

func recordMovie(_ session: AVCaptureSession, _ seconds: TimeInterval, _ path: String) -> Int32 {
  let output = AVCaptureMovieFileOutput()
  if session.canAddOutput(output) { session.addOutput(output) }
  session.startRunning()
  let observer = MovieObserver()
  let url = URL(fileURLWithPath: path)
  try? FileManager.default.removeItem(at: url)
  output.startRecording(to: url, recordingDelegate: observer)
  let started = observer.started.wait(timeout: .now() + 8)
  report("isRecording=\(output.isRecording ? 1 : 0)")
  if started == .success && observer.snapshot.startCount == 1 { Thread.sleep(forTimeInterval: seconds) }
  output.stopRecording()
  let wait = observer.done.wait(timeout: .now() + 10)
  session.stopRunning()
  let result = observer.snapshot
  guard started == .success, wait == .success, result.error == nil, result.startCount == 1, result.finishCount == 1 else {
    report("result movie failed error=\(result.error.map { "\($0)" } ?? "(null)")")
    return 7
  }
  let asset = AVURLAsset(url: url)
  guard let (duration, size) = movieDurationAndSize(url) else {
    report("result movie unreadable")
    return 7
  }
  report(String(format: "result movie duration=%.2fs size=%.0fx%.0f", duration, size.width, size.height))
  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  (generator.requestedTimeToleranceBefore, generator.requestedTimeToleranceAfter) = (.zero, .zero)
  for second in stride(from: 0, to: Int(duration.rounded(.up)), by: 1) {
    let image = try? generator.copyCGImage(at: CMTime(value: CMTimeValue(second), timescale: 1), actualTime: nil)
    report("movie t=\(second)s \(image.map(imageColours) ?? "no frame")")
  }
  return duration >= max(0.1, seconds - 0.75) ? 0 : 7
}

func convertRegions(_ session: AVCaptureSession) -> Int32 {
  report("roi connections no-output=\(session.connections.count)")
  let output = AVCapturePhotoOutput()
  if session.canAddOutput(output) { session.addOutput(output) }
  report("roi connections photo-output=\(session.connections.count)")
  let layer = AVCaptureVideoPreviewLayer(session: session)
  layer.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
  report("roi mirrored=\(layer.connection?.isVideoMirrored == true ? 1 : 0)")
  let rect = CGRect(x: 30, y: 150, width: 120, height: 200)
  let point = CGPoint(x: 75, y: 450)
  var drift: CGFloat = 0
  for gravity in [AVLayerVideoGravity.resizeAspect, .resizeAspectFill, .resize] {
    layer.videoGravity = gravity
    for angle: CGFloat in [0, 90, 180, 270] {
      if layer.connection?.isVideoRotationAngleSupported(angle) == true { layer.connection?.videoRotationAngle = angle }
      let metadata = layer.metadataOutputRectConverted(fromLayerRect: rect)
      let device = layer.captureDevicePointConverted(fromLayerPoint: point)
      let rectBack = layer.layerRectConverted(fromMetadataOutputRect: metadata)
      let pointBack = layer.layerPointConverted(fromCaptureDevicePoint: device)
      drift = max(
        drift, abs(rectBack.minX - rect.minX), abs(rectBack.minY - rect.minY), abs(rectBack.width - rect.width),
        abs(rectBack.height - rect.height), abs(pointBack.x - point.x), abs(pointBack.y - point.y))
      report(
        String(
          format: "roi gravity=%@ angle=%.0f rect=%.4f,%.4f,%.4f,%.4f point=%.4f,%.4f", gravity.rawValue, layer.connection?.videoRotationAngle ?? -1,
          metadata.minX, metadata.minY, metadata.width, metadata.height, device.x, device.y))
    }
  }
  session.inputs.forEach(session.removeInput)
  report("roi connections no-input=\(session.connections.count)")
  report(String(format: "roi round-trip drift=%.6f", drift))
  return drift < 0.001 ? 0 : 11
}

func run(_ arguments: [String]) -> Int32 {
  let mode = arguments.count > 1 ? arguments[1] : "stream"
  let argument = arguments.count > 2 ? arguments[2] : nil
  let third = arguments.count > 3 ? arguments[3] : nil
  let watchDuration = argument.flatMap { Int($0) } ?? 10
  if mode == "watch" && watchDuration < 0 { return 2 }
  let observer = FrameObserver()
  observer.wanted = third.flatMap { Int($0) } ?? 10

  if mode == "output-first" {
    observer.wanted = argument.flatMap { Int($0) } ?? 2
    guard let session = makeSession(outputBeforeInput: makeDataOutput(kCVPixelFormatType_32BGRA, observer)) else { return 1 }
    return runFrames(mode, session, observer, 8)
  }
  if mode == "preset-first" {
    observer.wanted = argument.flatMap { Int($0) } ?? 30
    guard let session = makeSession(presetBeforeInput: .vga640x480) else { return 1 }
    let output = makeDataOutput(kCVPixelFormatType_32BGRA, observer)
    if session.canAddOutput(output) { session.addOutput(output) }
    let errors = OSAllocatedUnfairLock(initialState: 0)
    let token = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
      errors.withLock { $0 += 1 }
      report("runtime error \(note.userInfo?[AVCaptureSessionErrorKey].map { "\($0)" } ?? "(null)")")
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let status = runFrames(mode, session, observer, 8)
    // AVCaptureSession posts runtime errors from the main run loop, which runFrames does not turn.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    let count = errors.withLock { $0 }
    report("runtimeErrors=\(count)")
    return count == 0 ? status : 10
  }
  guard let session = makeSession() else { return 1 }
  switch mode {
  case "photo":
    return capturePhoto(session, argument ?? "/tmp/fixture.jpg")
  case "movie":
    let seconds = argument.flatMap { Double($0) } ?? 3
    return seconds > 0 ? recordMovie(session, seconds, third ?? "/tmp/fixture.mov") : 2
  case "preview":
    // The virtual camera draws a preview by setting the layer's contents, which is what this reads;
    // a camera-backed layer renders out of process and leaves them nil.
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
    report("preview mirrored=\(layer.connection?.isVideoMirrored == true ? 1 : 0)")
    session.startRunning()
    for tick in 1...4 {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
      let image = layer.contents.flatMap { CFGetTypeID($0 as AnyObject) == CGImage.typeID ? unsafeBitCast($0 as AnyObject, to: CGImage.self) : nil }
      report("preview t=\(tick)s \(image.map(imageColours) ?? "no image")")
    }
    session.stopRunning()
    return layer.contents == nil ? 9 : 0
  case "roi":
    return convertRegions(session)
  default:
    break
  }
  let output = makeDataOutput(mode == "nv12" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA, observer)
  if session.canAddOutput(output) { session.addOutput(output) }
  switch mode {
  case "stream", "nv12":
    observer.wanted = argument.flatMap { Int($0) } ?? 10
    return observer.wanted > 0 ? runFrames(mode, session, observer, mode == "stream" ? third.flatMap { Double($0) } ?? 10 : 8) : 2
  case "watch":
    observer.quiet = true
    session.startRunning()
    for tick in 0..<watchDuration {
      Thread.sleep(forTimeInterval: 1)
      let (frames, last) = observer.snapshot
      report("t=\(tick + 1)s frames=\(frames) \(last)")
    }
    session.stopRunning()
    return observer.snapshot.frameCount > 0 ? 0 : 5
  case "preset":
    let presets: [String: AVCaptureSession.Preset] = [
      "photo": .photo, "high": .high, "medium": .medium, "low": .low,
      "640x480": .vga640x480, "1280x720": .hd1280x720, "1920x1080": .hd1920x1080,
    ]
    guard let argument, let preset = presets[argument], session.canSetSessionPreset(preset) else {
      report("unknown preset \(argument ?? "(null)")")
      return 2
    }
    session.sessionPreset = preset
    report("preset requested=\(argument) reported=\(session.sessionPreset.rawValue)")
    return runFrames(mode, session, observer, 8)
  case "rotate":
    let angle = CGFloat(argument.flatMap { Double($0) } ?? 90)
    let connection = output.connection(with: .video)
    if connection?.isVideoRotationAngleSupported(angle) == true { connection?.videoRotationAngle = angle }
    let reported = connection?.videoRotationAngle ?? -1
    report(String(format: "rotation requested=%.0f reported=%.0f", angle, reported))
    return observer.wanted > 0 ? runFrames(mode, session, observer, 8) : 2
  default:
    report("unknown mode \(mode)")
    return 2
  }
}

@main
enum CameraFixture {
  static func main() {
    exit(run(CommandLine.arguments))
  }
}
