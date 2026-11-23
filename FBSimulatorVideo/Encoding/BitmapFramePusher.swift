/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
import FBSimulatorControl
import Foundation

/// Writes raw BGRA pixel bytes (optionally scaled) straight through to the consumer, unframed.
final class BitmapFramePusher: FramePusher {
  let consumer: any DataConsumer
  /// The scale factor between 0-1. nil for no scaling.
  let scaleFactor: Double?
  /// Present only when scaling; a frame that fails to scale is written at source size.
  private(set) var scaler: PixelBufferConverter?

  init(consumer: any DataConsumer, scaleFactor: Double?) {
    self.consumer = consumer
    self.scaleFactor = scaleFactor
  }

  func setup(source: VideoFrameSource, edgeInsets: VideoStreamEdgeInsets) throws {
    guard let scaleFactor, scaleFactor > 0, scaleFactor < 1 else {
      return
    }
    scaler = try PixelBufferConverter(
      outputWidth: Int(floor(scaleFactor * Double(source.width))),
      outputHeight: Int(floor(scaleFactor * Double(source.height))),
      pixelFormat: source.pixelFormat)
  }

  func tearDown() throws {
    scaler?.invalidate()
    scaler = nil
  }

  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool
  ) throws {
    var bufferToWrite = pixelBuffer
    if let scaler, case let .converted(scaled) = scaler.convert(pixelBuffer) {
      bufferToWrite = scaled
    }

    CVPixelBufferLockBaseAddress(bufferToWrite, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(bufferToWrite, .readOnly) }

    guard let baseAddress = unsafe CVPixelBufferGetBaseAddress(bufferToWrite) else { return }
    let size = CVPixelBufferGetDataSize(bufferToWrite)

    if case .synchronous = consumer.consumption {
      let data = unsafe Data(bytesNoCopy: baseAddress, count: size, deallocator: .none)
      consumer.consumeData(data)
    } else {
      let data = unsafe Data(bytes: baseAddress, count: size)
      consumer.consumeData(data)
    }
  }
}
