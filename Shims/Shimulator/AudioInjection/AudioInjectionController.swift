/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ShimulatorProtocol

public enum ShimulatorAudioInjection {
  public static let capability = "audio"
  /// Set to `1` in an armed simulator's `launchd`. The shim does nothing in a process without it.
  public static let armedEnvironmentVariable = "IDB_AUDIO_INJECTION"
  public static let maximumPayloadBytes = 32 * 1024 * 1024
}

public struct AudioInjectionParameters: Codable, Equatable, Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

public struct AudioInjectionProgress: Equatable, Sendable {
  public let generation: Int64
  public let started: Bool
  public let finished: Bool

  public init(generation: Int64, started: Bool, finished: Bool) {
    self.generation = generation
    self.started = started
    self.finished = finished
  }
}

public protocol AudioInjectionEngine {
  func replace(samples: [Int16], sampleRate: Double, generation: Int64)
  func clear()
  func pollProgress() -> AudioInjectionProgress
}

public struct WAVAudio: Equatable, Sendable {
  public let samples: [Int16]
  public let sampleRate: Double

  /// Decodes 16-bit PCM, mixing any number of channels down to mono.
  public init?(data: Data) {
    guard data.count <= ShimulatorAudioInjection.maximumPayloadBytes else { return nil }
    let bytes = [UInt8](data)
    guard bytes.count >= 12,
      bytes[0..<4].elementsEqual("RIFF".utf8),
      bytes[8..<12].elementsEqual("WAVE".utf8)
    else {
      return nil
    }

    // Every read below stays inside `riffEnd`, which the guard keeps inside `bytes`.
    func uint16(at offset: Int) -> UInt16 {
      UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    func uint32(at offset: Int) -> UInt32 {
      UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    let riffEnd = Int(uint32(at: 4)) + 8
    guard riffEnd <= bytes.count else { return nil }
    var formatTag: UInt16 = 0
    var channels: UInt16 = 0
    var rate: UInt32 = 0
    var bitsPerSample: UInt16 = 0
    var audioRange: Range<Int>?
    var offset = 12
    while offset + 8 <= riffEnd {
      let body = offset + 8
      let length = Int(uint32(at: offset + 4))
      let paddedLength = length + (length & 1)
      guard paddedLength <= riffEnd - body else { return nil }
      let identifier = bytes[offset..<(offset + 4)]
      if identifier.elementsEqual("fmt ".utf8), length >= 16 {
        formatTag = uint16(at: body)
        channels = uint16(at: body + 2)
        rate = uint32(at: body + 4)
        bitsPerSample = uint16(at: body + 14)
        if formatTag == 0xFFFE, length >= 40 {
          formatTag = uint16(at: body + 24)
        }
      } else if identifier.elementsEqual("data".utf8), audioRange == nil {
        audioRange = body..<(body + length)
      }
      offset = body + paddedLength
    }

    guard formatTag == 1, channels > 0, bitsPerSample == 16, (8_000...384_000).contains(rate),
      let audioRange
    else {
      return nil
    }
    let channelCount = Int(channels)
    let frameSize = channelCount * MemoryLayout<Int16>.size
    guard audioRange.count.isMultiple(of: frameSize) else { return nil }

    let frames = stride(from: audioRange.lowerBound, to: audioRange.upperBound, by: frameSize)
    self.samples = frames.map { frame in
      let sum = (0..<channelCount).reduce(0) { total, channel in
        total + Int(Int16(bitPattern: uint16(at: frame + channel * MemoryLayout<Int16>.size)))
      }
      return Int16(sum / channelCount)
    }
    self.sampleRate = Double(rate)
  }
}

public final class AudioInjectionController: ShimulatorMethodHandler {
  public typealias Admission = Int64

  private let engine: any AudioInjectionEngine
  private var nextGeneration: Int64 = 0

  public init(engine: any AudioInjectionEngine) {
    self.engine = engine
  }

  public func start(_ parameters: AudioInjectionParameters) throws -> Admission {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: parameters.path))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: ShimulatorAudioInjection.maximumPayloadBytes + 1) ?? Data()
    guard let audio = WAVAudio(data: data) else {
      throw AudioInjectionControllerError.invalidAudio
    }
    let generation = nextGeneration
    nextGeneration += 1
    engine.replace(samples: audio.samples, sampleRate: audio.sampleRate, generation: generation)
    return generation
  }

  /// A stop for an injection that a later one has replaced leaves the later one playing.
  public func stop(_ admission: Admission) {
    guard admission == nextGeneration - 1 else { return }
    engine.clear()
  }

  public func poll(_ admission: Admission) -> ShimulatorMethodUpdate? {
    let progress = engine.pollProgress()
    guard progress.generation == admission else { return nil }
    if progress.finished {
      return ShimulatorMethodUpdate(.completed)
    }
    return progress.started ? ShimulatorMethodUpdate(.accepted) : nil
  }
}

private enum AudioInjectionControllerError: Error, CustomStringConvertible {
  case invalidAudio

  var description: String {
    "Could not decode the injection audio"
  }
}
