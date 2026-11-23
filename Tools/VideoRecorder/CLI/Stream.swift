/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import FBControlCore
import FBSimulatorControl
import FBSimulatorVideo
import FBVideoCore
import Foundation

struct Stream: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Stream encoded frames with JSON-line overlay control")
  @OptionGroup var target: SimulatorOptions
  @OptionGroup var video: VideoOptions
  @Option(help: "h264 (default), hevc, mjpeg, minicap, or bgra") var encoding: StreamEncoding = .h264
  @Option(help: "Compressed video transport: annex-b, mpegts, or fmp4") var transport: String?
  @Argument(help: "Output file, or - for stdout") var output: String = "-"

  func validate() throws {
    if let transport {
      guard encoding == .h264 || encoding == .hevc else {
        throw ValidationError("--transport is only valid with h264 or hevc")
      }
      guard VideoStreamTransport(rawValue: transport) != nil else {
        throw ValidationError("Unknown transport: \(transport)")
      }
    }
  }

  @MainActor
  mutating func run() async throws {
    let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: false)
    let simulator = try target.simulator(logger: logger)
    let (insets, renderer, bars) = try video.composition(simulator: simulator, logger: logger)
    let framebuffer = try await simulator.framebuffer.connect(display: .active)
    let configuration = video.configuration(format: encoding.format(transport: transport.flatMap(VideoStreamTransport.init(rawValue:)) ?? .annexB))
    let stream = SimulatorVideoStream(framebuffer: framebuffer, configuration: configuration, edgeInsets: insets, logger: logger)
    let consumer: any DataConsumer
    if output == "-" {
      consumer = FileWriter.syncWriter(withFileDescriptor: FileHandle.standardOutput.fileDescriptor, closeOnEndOfFile: false)
    } else {
      let descriptor = unsafe open(output, O_WRONLY | O_CREAT | O_EXCL, 0o644)
      guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      consumer = FileWriter.syncWriter(withFileDescriptor: descriptor, closeOnEndOfFile: true)
    }
    try await stream.startStreaming(consumer)
    let (handler, timers) = VideoSession.makeHandler(videoStream: stream, renderer: renderer, screenshotDir: video.screenshotDir, parsedBars: bars, barStats: video.barStats, logger: logger)
    defer { timers.forEach { $0.cancel() } }
    FileHandle.standardError.write(Data("Going into PLAYING state.\n".utf8))
    await handler.driveUntilStoppedOrSignal(waitForSignal: waitForStopSignal)
    try await stream.stopStreaming()
  }
}

enum StreamEncoding: String, ExpressibleByArgument {
  case h264, hevc, mjpeg, minicap, bgra
  func format(transport: VideoStreamTransport) -> VideoStreamFormat {
    switch self {
    case .h264: return .compressedVideo(withCodec: .h264, transport: transport)
    case .hevc: return .compressedVideo(withCodec: .hevc, transport: transport)
    case .mjpeg: return .mjpeg(encoder: .requireHardware)
    case .minicap: return .minicap
    case .bgra: return .bgra
    }
  }
}
