/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// The video codec for compressed video streams.
public enum VideoStreamCodec: String, Sendable {
  case h264
  case hevc
}

/// The transport/container framing for compressed video streams.
public enum VideoStreamTransport: String, Sendable {
  case annexB = "annex-b"
  case mpegts
  case fmp4
}

/// The encoders an MJPEG stream may use. Hardware encoding is required by default; software
/// encoding is a deliberate opt-in for hosts without a usable hardware JPEG encoder, trading CPU
/// for availability.
///
/// There is no user-facing switch: each entry point picks for its use. The live paths — the
/// companion's gRPC stream, `sim-video stream` and sime2e's `video-stream` — require hardware,
/// because a software JPEG encoder cannot hold a screen-rate stream and the failure is better
/// reported at session creation than as a stream that falls behind. `sim-video record` allows
/// software: a recording tolerates a slower encoder, and the tool is run on developer machines
/// where availability matters more than latency.
public enum MJPEGEncoderSelection: Hashable, Sendable {
  case requireHardware
  case allowSoftware
}

/// The format of a video stream: a compressed codec over a transport, or a raw/JPEG format that has neither.
public enum VideoStreamFormat: Hashable, Sendable {
  case compressedVideo(withCodec: VideoStreamCodec, transport: VideoStreamTransport)
  case mjpeg(encoder: MJPEGEncoderSelection)
  case minicap
  case bgra
}

extension VideoStreamFormat: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .compressedVideo(codec, transport):
      return "\(codec.rawValue) over \(transport.rawValue)"
    case .mjpeg(encoder: .requireHardware):
      return "MJPEG"
    case .mjpeg(encoder: .allowSoftware):
      return "MJPEG (software encoder permitted)"
    case .minicap:
      return "Minicap"
    case .bgra:
      return "BGRA"
    }
  }
}

/// The rate-control strategy for VTCompression: derived automatically, a target quality (0–1), or an
/// average bitrate in bits per second.
public enum VideoStreamRateControl: Hashable, Sendable {
  /// The default: derive a rate from what is being encoded. JPEG formats (MJPEG/Minicap) use their
  /// quality knob at 0.75; H.264/HEVC derive an average bitrate from the encoded output dimensions
  /// at session setup.
  case automatic
  /// A constant target quality (0–1). JPEG formats pass it to the encoder. For H.264/HEVC it scales
  /// the automatic bitrate budget linearly, meeting it at 0.75 — the low-latency hardware encoder
  /// ignores a quality property, so the budget is how a quality is honored there.
  case quality(Double)
  case bitrate(Int)
}

extension VideoStreamRateControl: CustomStringConvertible {
  public var description: String {
    switch self {
    case .automatic:
      return "Automatic"
    case let .quality(quality):
      return "Quality \(quality)"
    case let .bitrate(bitrate):
      let bps = Double(bitrate)
      if bps >= 1_000_000.0 {
        return unsafe String(format: "Bitrate %.1f Mbps", bps / 1_000_000.0)
      } else {
        return unsafe String(format: "Bitrate %.0f kbps", bps / 1000.0)
      }
    }
  }
}

/// How frames are encoded, independent of the output format and sink.
public struct VideoEncodeOptions: Hashable, Sendable {
  public let framesPerSecond: Int?
  public let scaleFactor: Double?
  public let rateControl: VideoStreamRateControl
  public let keyFrameRate: Double

  public init(framesPerSecond: Int?, rateControl: VideoStreamRateControl?, scaleFactor: Double?, keyFrameRate: Double?) {
    self.framesPerSecond = framesPerSecond
    self.rateControl = rateControl ?? .automatic
    self.scaleFactor = scaleFactor
    // Four seconds between forced keyframes: at retina sizes each IDR costs tens of kilobytes and resets
    // temporal prediction. Late joiners wait at most this long for a sync point; WebRTC re-syncs via
    // requestKeyFrame.
    self.keyFrameRate = keyFrameRate ?? 4.0
  }
}

/// Describes a video stream: the display it captures, the output format and the options controlling how frames are encoded.
public struct VideoStreamConfiguration: Hashable, CustomStringConvertible, Sendable {

  public let format: VideoStreamFormat
  public let encodeOptions: VideoEncodeOptions
  public let display: DisplaySelection

  public var framesPerSecond: Int? { encodeOptions.framesPerSecond }
  public var rateControl: VideoStreamRateControl { encodeOptions.rateControl }
  public var scaleFactor: Double? { encodeOptions.scaleFactor }
  public var keyFrameRate: Double { encodeOptions.keyFrameRate }

  public init(format: VideoStreamFormat, encodeOptions: VideoEncodeOptions, display: DisplaySelection = .active) {
    self.format = format
    self.encodeOptions = encodeOptions
    self.display = display
  }

  public init(format: VideoStreamFormat, framesPerSecond: Int?, rateControl: VideoStreamRateControl?, scaleFactor: Double?, keyFrameRate: Double?, display: DisplaySelection = .active) {
    self.init(format: format, encodeOptions: VideoEncodeOptions(framesPerSecond: framesPerSecond, rateControl: rateControl, scaleFactor: scaleFactor, keyFrameRate: keyFrameRate), display: display)
  }

  public var description: String {
    "Format \(format) | FPS \(framesPerSecond.map { "\($0)" } ?? "nil") | Rate Control \(rateControl) | Scale \(scaleFactor.map { "\($0)" } ?? "nil") | Key frame rate \(keyFrameRate) | Display \(display)"
  }
}
