/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
internal import ShimulatorAudioInjectionCore

/// What the armed processes played during a capture, mixed onto one timeline.
public struct CapturedAudio: Sendable {
  /// A two-channel, 32-bit float WAV of the mix, or nil when nothing was played.
  public let path: String?
  public let sampleRate: Double
  public let frames: Int
  /// When the mix's first frame played, in `mach_absolute_time` ticks.
  public let startHostTime: UInt64
  public let processes: [AudioCaptureProcess]
  /// What a process reported when it could not capture.
  public let failures: [String]
}

/// One captured process: what it played, and what of that the mix lacks.
public struct AudioCaptureProcess: Sendable {
  public let processIdentifier: Int32
  public let name: String
  /// Frames of the process's output in the mix.
  public let frames: Int
  /// Frames the process played but could not keep, or nil when it ended before saying: it exited,
  /// or was killed, during the capture.
  public let droppedFrames: UInt64?
  /// Frames left out because they were played at another rate than the mix.
  public let unmixedFrames: Int
  /// Times the process's audio moved to follow the host clock, which a device clock running fast or
  /// slow makes it drift from.
  public let realignments: Int
}

/// Lays every captured chunk on the host clock and sums them into one WAV.
///
/// Within a stream, chunks follow one another sample for sample, so the mix holds exactly what the
/// app rendered. Each run starts where its first chunk's host time puts it, a gap is left where
/// frames were dropped, and a stream whose device clock drifts from the host clock by more than
/// `realignmentSeconds` is moved back onto it.
enum AudioCaptureMixer {

  static let realignmentSeconds = 0.010
  /// The highest rate a chunk can be mixed at: above any rate an audio device runs at, and low enough
  /// for the WAV header's byte rate.
  static let maximumSampleRate = 1_000_000.0

  struct Source {
    let path: String
    let processName: String
  }

  private struct Placement {
    let source: Int
    let chunk: AudioCaptureFile.ChunkRecord
    let frame: Int
  }

  private static let wavHeaderSize = 44
  private static let channels = 2
  /// The most frames one WAV file can hold.
  static let maximumFrames = (Int(UInt32.max) - wavHeaderSize) / (channels * MemoryLayout<Float>.size)

  static func mix(_ sources: [Source], into outputPath: String, failures: [String] = []) throws -> CapturedAudio {
    let readers = try sources.map { try AudioCaptureFileReader(path: $0.path) }
    let chunks = readers.flatMap(\.index.chunks)
    let rate = mixRate(chunks)
    // A chunk without a host time continues its stream, so it does not decide where the mix starts.
    let origin = chunks.filter { $0.hostTime != 0 && mixes($0, at: rate) }.map(\.hostTime).min()

    var placements: [Placement] = []
    var processes: [AudioCaptureProcess] = []
    for (index, reader) in readers.enumerated() {
      let (placed, process) = try place(
        reader.index, from: index, source: sources[index], rate: rate, origin: origin)
      placements += placed
      processes.append(process)
    }
    let frames = placements.map { $0.frame + $0.chunk.frames }.max() ?? 0
    guard frames > 0 else {
      return CapturedAudio(
        path: nil, sampleRate: rate, frames: 0, startHostTime: 0, processes: processes, failures: failures)
    }
    try write(placements, frames: frames, rate: rate, readers: readers, to: outputPath)
    return CapturedAudio(
      path: outputPath, sampleRate: rate, frames: frames, startHostTime: origin ?? 0, processes: processes,
      failures: failures)
  }

  /// The rate most of the captured frames were played at, or 0 when no chunk names one it can be.
  private static func mixRate(_ chunks: [AudioCaptureFile.ChunkRecord]) -> Double {
    var framesAtRate: [Double: Int] = [:]
    for chunk in chunks where (1...maximumSampleRate).contains(chunk.sampleRate) {
      framesAtRate[chunk.sampleRate, default: 0] += chunk.frames
    }
    return framesAtRate.max { lhs, rhs in
      lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
    }?.key ?? 0
  }

  /// Whether the chunk was played at the mix's rate. One whose device rate could not be read is taken
  /// to have been: every process in a simulator plays through the same device.
  private static func mixes(_ chunk: AudioCaptureFile.ChunkRecord, at rate: Double) -> Bool {
    rate > 0 && (chunk.sampleRate == 0 || chunk.sampleRate == rate)
  }

  private static func place(
    _ index: AudioCaptureFile.Index, from position: Int, source: Source, rate: Double, origin: UInt64?
  ) throws -> ([Placement], AudioCaptureProcess) {
    let realignment = Int((realignmentSeconds * rate).rounded())
    var placements: [Placement] = []
    var streams: [UInt64: (end: Int, sampleTimeEnd: Double)] = [:]
    var mixed = 0
    var unmixed = 0
    var realignments = 0
    for chunk in index.chunks {
      guard mixes(chunk, at: rate) else {
        unmixed += chunk.frames
        continue
      }
      let onHostClock = try origin.flatMap { origin in
        chunk.hostTime >= origin && chunk.hostTime != 0
          ? try mixFrame(seconds(chunk.hostTime - origin, in: index) * rate, source: source) : nil
      }
      let frame: Int
      switch (streams[chunk.stream], onHostClock) {
      case let (previous?, hostFrame?) where !chunk.discontinuity:
        if abs(hostFrame - previous.end) > realignment {
          realignments += 1
          frame = hostFrame
        } else {
          frame = previous.end
        }
      case let (previous?, nil):
        let gap = chunk.discontinuity ? chunk.sampleTime - previous.sampleTimeEnd : 0
        frame = try mixFrame(Double(previous.end) + gap, notBefore: previous.end, source: source)
      case let (_, hostFrame?):
        frame = hostFrame
      case (nil, nil):
        frame = 0
      }
      let end = try mixFrame(Double(frame + chunk.frames), source: source)
      placements.append(Placement(source: position, chunk: chunk, frame: frame))
      streams[chunk.stream] = (end, chunk.sampleTime + Double(chunk.frames))
      mixed += chunk.frames
    }
    let process = AudioCaptureProcess(
      processIdentifier: index.processIdentifier, name: source.processName, frames: mixed,
      droppedFrames: index.droppedFrames, unmixedFrames: unmixed, realignments: realignments)
    return (placements, process)
  }

  /// The mix frame at `position`, where a capture file put a chunk, and not before `earliest`. A time
  /// that is not a number, or past what one WAV file can hold, fails the mix.
  private static func mixFrame(_ position: Double, notBefore earliest: Int = 0, source: Source) throws -> Int {
    guard !position.isNaN else {
      throw AudioCaptureError.corruptCapture(path: source.path)
    }
    let frame = max(Double(earliest), position.rounded())
    guard frame <= Double(maximumFrames) else {
      throw AudioCaptureError.mixTooLong(frames: Int(exactly: frame) ?? .max)
    }
    return Int(frame)
  }

  private static func seconds(_ ticks: UInt64, in index: AudioCaptureFile.Index) -> Double {
    guard index.timebaseDenominator > 0 else {
      return 0
    }
    return Double(ticks) * Double(index.timebaseNumerator) / Double(index.timebaseDenominator) / 1e9
  }

  /// Sums every placement into a file sized for the whole mix, mapped rather than held in memory.
  private static func write(
    _ placements: [Placement], frames: Int, rate: Double, readers: [AudioCaptureFileReader], to path: String
  ) throws {
    let dataBytes = frames * channels * MemoryLayout<Float>.size
    let descriptor = unsafe open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw unsafe AudioCaptureError.mixUnwritable(path: path, reason: String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    let size = wavHeaderSize + dataBytes
    guard ftruncate(descriptor, off_t(size)) == 0,
      let mapped = unsafe mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), unsafe mapped != MAP_FAILED
    else {
      throw unsafe AudioCaptureError.mixUnwritable(path: path, reason: String(cString: strerror(errno)))
    }
    defer { unsafe munmap(mapped, size) }
    let header = wavHeader(dataBytes: dataBytes, rate: rate)
    unsafe header.withUnsafeBytes { bytes in
      if let base = bytes.baseAddress {
        unsafe mapped.copyMemory(from: base, byteCount: bytes.count)
      }
    }
    let mix = unsafe (mapped + wavHeaderSize).bindMemory(to: Float.self, capacity: frames * channels)
    for placement in placements {
      let samples = try readers[placement.source].samples(of: placement.chunk)
      let sourceChannels = placement.chunk.channels
      for frame in 0..<placement.chunk.frames {
        let left = samples[frame * sourceChannels]
        let right = sourceChannels > 1 ? samples[frame * sourceChannels + 1] : left
        let output = (placement.frame + frame) * channels
        unsafe mix[output] += left
        unsafe mix[output + 1] += right
      }
    }
    guard unsafe msync(mapped, size, MS_SYNC) == 0 else {
      throw unsafe AudioCaptureError.mixUnwritable(path: path, reason: String(cString: strerror(errno)))
    }
  }

  private static func wavHeader(dataBytes: Int, rate: Double) -> Data {
    var data = Data()
    func append<Value: FixedWidthInteger>(_ value: Value) {
      withUnsafeBytes(of: value.littleEndian) { unsafe data.append(contentsOf: $0) }
    }
    let bytesPerFrame = channels * MemoryLayout<Float>.size
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataBytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3)) // IEEE float
    append(UInt16(channels))
    append(UInt32(rate))
    append(UInt32(Int(rate) * bytesPerFrame))
    append(UInt16(bytesPerFrame))
    append(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(dataBytes))
    return data
  }
}
