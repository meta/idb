/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/*
 * Host tool: writes an H.264 .mov at 30 fps that shows each colour in turn for
 * the given number of seconds. The left half of every frame is the colour and
 * the right half is white, so a rotated delivery shows which way it turned.
 *
 *   makevideo <out.mov> <width> <height> <seconds-per-colour> <hex colour>...
 */

import AVFoundation

struct Failure: Error {
  let message: String
}

func write(_ path: String, _ width: Int, _ height: Int, _ seconds: Double, _ colours: [UInt32]) throws -> Int64 {
  let url = URL(fileURLWithPath: path)
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])
  func failure(_ what: String) -> Failure {
    Failure(message: "\(what): \(writer.error?.localizedDescription ?? "unknown error")")
  }
  guard writer.canAdd(input) else { throw failure("cannot write \(path)") }
  writer.add(input)
  guard writer.startWriting() else { throw failure("cannot write \(path)") }
  writer.startSession(atSourceTime: .zero)
  var frame: Int64 = 0
  let framesPerColour = Int64((seconds * 30).rounded())
  for colour in colours {
    for _ in 0..<framesPerColour {
      while !input.isReadyForMoreMediaData && writer.status == .writing { Thread.sleep(forTimeInterval: 0.005) }
      guard writer.status == .writing else { throw failure("cannot write \(path)") }
      var buffer: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool, unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
        throw failure("no pixel buffer")
      }
      CVPixelBufferLockBaseAddress(buffer, [])
      guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { throw failure("no pixel buffer") }
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<height {
        let row = unsafe (base + y * stride).assumingMemoryBound(to: UInt32.self)
        // BGRA in memory is 0xAARRGGBB as a little-endian word.
        for x in 0..<width { unsafe row[x] = 0xFF00_0000 | (x < width / 2 ? colour : 0xFF_FFFF) }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: 30)) else { throw failure("append failed") }
      frame += 1
    }
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { throw failure("writing failed") }
  return frame
}

@main
enum MakeVideo {
  static func main() {
    let arguments = CommandLine.arguments
    let (width, height, seconds) = arguments.count > 5 ? (Int(arguments[2]) ?? 0, Int(arguments[3]) ?? 0, Double(arguments[4]) ?? 0) : (0, 0, 0)
    // A colour shorter than half a frame would be dropped from the video without a word.
    guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, seconds.isFinite,
      (seconds * 30).rounded() >= 1, (seconds * 30).rounded() < Double(Int64.max)
    else {
      unsafe fputs("usage: makevideo <out.mov> <even width> <even height> <seconds-per-colour> <hex colour>...\n", stderr)
      exit(2)
    }
    var colours: [UInt32] = []
    for colour in arguments[5...] {
      guard let rgb = UInt32(colour, radix: 16), rgb <= 0xFF_FFFF else {
        unsafe fputs("not a hex RGB colour: \(colour)\n", unsafe stderr)
        exit(2)
      }
      colours.append(rgb)
    }
    do {
      let frames = try write(arguments[1], width, height, seconds, colours)
      unsafe fputs("\(arguments[1]) \(width)x\(height) \(frames) frames at 30 fps\n", unsafe stdout)
    } catch {
      unsafe fputs("\((error as? Failure)?.message ?? "\(error)")\n", unsafe stderr)
      exit(1)
    }
  }
}
