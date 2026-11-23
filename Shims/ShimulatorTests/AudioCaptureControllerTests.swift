/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import ShimulatorAudioInjectionCore
import ShimulatorProtocol
import Testing

private final class FakeCaptureEngine: AudioCaptureEngine {
  var pending: [AudioCaptureChunk] = []
  var afterEnd: [AudioCaptureChunk] = []
  var dropped: UInt64 = 0
  var calls: [String] = []

  func begin() {
    calls.append("begin")
  }

  func drain(_ body: (AudioCaptureChunk) -> Void) -> UInt64 {
    calls.append("drain")
    pending.forEach(body)
    pending = []
    return dropped
  }

  func end() {
    calls.append("end")
    pending = afterEnd
  }
}

private func chunk(
  hostTime: UInt64, samples: [Float], channels: Int = 2, discontinuity: Bool = false
)
  -> AudioCaptureChunk
{
  AudioCaptureChunk(
    stream: 0xABC, device: 73, sampleRate: 48_000, hostTime: hostTime, sampleTime: Double(hostTime) * 2,
    channels: channels, discontinuity: discontinuity, samples: samples)
}

/// The file's chunks, samples included, in the order it holds them.
private func readBack(_ path: String) throws -> (index: AudioCaptureFile.Index, chunks: [AudioCaptureChunk]) {
  let reader = try AudioCaptureFileReader(path: path)
  let chunks = try reader.index.chunks.map {
    AudioCaptureChunk(
      stream: $0.stream, device: $0.device, sampleRate: $0.sampleRate, hostTime: $0.hostTime,
      sampleTime: $0.sampleTime, channels: $0.channels, discontinuity: $0.discontinuity,
      samples: try reader.samples(of: $0))
  }
  return (reader.index, chunks)
}

private func written(_ data: Data, in directory: String) throws -> String {
  let path = (directory as NSString).appendingPathComponent("written.idbcap")
  try data.write(to: URL(fileURLWithPath: path))
  return path
}

private func temporaryDirectory() throws -> String {
  var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("capture.XXXXXX").utf8CString)
  guard let directory = mkdtemp(&template) else {
    throw POSIXError(.EIO)
  }
  return String(cString: directory)
}

struct AudioCaptureControllerTests {

  @Test
  func stopLeavesAWholeFileWithEverythingThatWasKept() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let engine = FakeCaptureEngine()
    let controller = AudioCaptureController(engine: engine, processIdentifier: 4_242)
    let first = chunk(hostTime: 10, samples: [0.5, -0.5, 0.25, -0.25])
    let last = chunk(hostTime: 20, samples: [1, -1], discontinuity: true)

    let writer = try controller.start(AudioCaptureParameters(directory: directory))
    engine.pending = [first]
    #expect(controller.poll(writer) == ShimulatorMethodUpdate(.accepted))
    #expect(!FileManager.default.fileExists(atPath: writer.path))
    engine.afterEnd = [last]
    engine.dropped = 7
    controller.stop(writer)

    let (index, chunks) = try readBack(writer.path)
    #expect(index.processIdentifier == 4_242)
    #expect(chunks == [first, last])
    #expect(index.droppedFrames == 7)
    #expect(index.timebaseDenominator > 0)
    #expect(engine.calls == ["begin", "drain", "drain", "end", "drain"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == [(writer.path as NSString).lastPathComponent])
  }

  @Test
  func aProcessThatPlaysNothingIsNotReportedAsPlaying() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let controller = AudioCaptureController(engine: FakeCaptureEngine(), processIdentifier: 1)

    let writer = try controller.start(AudioCaptureParameters(directory: directory))

    #expect(controller.poll(writer) == nil)
    controller.stop(writer)
    #expect(try readBack(writer.path).chunks.isEmpty)
  }

  @Test
  func aDirectoryOthersCanReachIsRefused() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    #expect(chmod(directory, 0o755) == 0)
    let engine = FakeCaptureEngine()

    #expect(throws: AudioCaptureFileError.directoryNotPrivate(path: directory)) {
      try AudioCaptureController(engine: engine).start(AudioCaptureParameters(directory: directory))
    }
    #expect(engine.calls.isEmpty)
  }

  @Test
  func aFileCutShortReadsUpToTheCut() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var data = AudioCaptureFile.header(processIdentifier: 9, timebase: mach_timebase_info_data_t(numer: 125, denom: 3))
    let whole = chunk(hostTime: 1, samples: [0.1, 0.2])
    data.append(AudioCaptureFile.record(whole))
    data.append(AudioCaptureFile.record(chunk(hostTime: 2, samples: [0.3, 0.4])).dropLast(3))

    let (index, chunks) = try readBack(try written(data, in: directory))

    #expect(chunks == [whole])
    #expect(index.droppedFrames == nil)
    #expect(index.timebaseNumerator == 125)
    #expect(index.timebaseDenominator == 3)
  }

  @Test
  func malformedFilesAreRefused() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let header = AudioCaptureFile.header(processIdentifier: 9, timebase: mach_timebase_info_data_t(numer: 1, denom: 1))
    var unknownRecord = header
    unknownRecord.append(contentsOf: [1, 0, 0, 0, 9])
    var wrongSize = header
    var record = AudioCaptureFile.record(chunk(hostTime: 1, samples: [0.1, 0.2, 0.3, 0.4]))
    record[8] = 3
    wrongSize.append(record)

    #expect(throws: AudioCaptureFileError.notACaptureFile) {
      try AudioCaptureFileReader(path: try written(Data("not a capture".utf8), in: directory))
    }
    #expect(throws: AudioCaptureFileError.malformedRecord) {
      try AudioCaptureFileReader(path: try written(unknownRecord, in: directory))
    }
    #expect(throws: AudioCaptureFileError.malformedRecord) {
      try AudioCaptureFileReader(path: try written(wrongSize, in: directory))
    }
  }
}
