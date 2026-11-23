/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ShimulatorAudioInjectionCore
import ShimulatorProtocol
import XCTest

final class AudioInjectionControllerTests: XCTestCase {
  private final class FakeEngine: AudioInjectionEngine {
    var samples: [Int16] = []
    var sampleRate = 0.0
    var generation: Int64 = -1
    var progress = AudioInjectionProgress(generation: -1, started: false, finished: false)

    func replace(samples: [Int16], sampleRate: Double, generation: Int64) {
      (self.samples, self.sampleRate, self.generation) = (samples, sampleRate, generation)
      progress = AudioInjectionProgress(generation: generation, started: false, finished: false)
    }

    func clear() {
      samples = []
      generation = -1
    }

    func pollProgress() -> AudioInjectionProgress { progress }
  }

  func testWAVDecoderMixesChannelsToMono() throws {
    let audio = try XCTUnwrap(WAVAudio(data: wav(samples: [100, 200, -300, 400], channels: 2)))

    XCTAssertEqual(audio.samples, [150, 50])
    XCTAssertEqual(audio.sampleRate, 48_000)
  }

  func testWAVDecoderAcceptsNoSamples() {
    XCTAssertEqual(WAVAudio(data: wav(samples: [], channels: 1))?.samples, [])
  }

  func testWAVDecoderRejectsInvalidInput() {
    XCTAssertNil(WAVAudio(data: wav(samples: [100], channels: 1, sampleRate: 0)))
    XCTAssertNil(WAVAudio(data: wav(samples: [100], channels: 1, sampleRate: 1)))
    XCTAssertNil(WAVAudio(data: wav(samples: [100], channels: 1, formatTag: 3)))

    var truncated = wav(samples: [100], channels: 1)
    truncated.replaceSubrange(40..<44, with: [4, 0, 0, 0])
    XCTAssertNil(WAVAudio(data: truncated))

    var outsideRIFF = wav(samples: [100], channels: 1)
    outsideRIFF.replaceSubrange(4..<8, with: [4, 0, 0, 0])
    XCTAssertNil(WAVAudio(data: outsideRIFF))
  }

  func testStartInstallsDecodedAudio() throws {
    let engine = FakeEngine()
    let controller = AudioInjectionController(engine: engine)

    _ = try controller.start(try parameters(wav(samples: [100, -200], channels: 1)))

    XCTAssertEqual(engine.samples, [100, -200])
    XCTAssertEqual(engine.sampleRate, 48_000)
    XCTAssertEqual(engine.generation, 0)
  }

  func testPollReportsPlaybackOnlyForItsOwnGeneration() throws {
    let engine = FakeEngine()
    let controller = AudioInjectionController(engine: engine)
    let admission = try controller.start(try parameters(wav(samples: [100], channels: 1)))
    XCTAssertNil(controller.poll(admission))

    engine.progress = AudioInjectionProgress(generation: 0, started: true, finished: false)
    XCTAssertEqual(controller.poll(admission), ShimulatorMethodUpdate(.accepted))
    engine.progress = AudioInjectionProgress(generation: 0, started: true, finished: true)
    XCTAssertEqual(controller.poll(admission), ShimulatorMethodUpdate(.completed))

    controller.stop(admission)
    XCTAssertTrue(engine.samples.isEmpty)
    let next = try controller.start(try parameters(wav(samples: [200], channels: 1)))
    XCTAssertNil(controller.poll(admission))
    XCTAssertEqual(engine.generation, 1)
    _ = next
  }

  func testStoppingAReplacedInjectionLeavesTheLaterOnePlaying() throws {
    let engine = FakeEngine()
    let controller = AudioInjectionController(engine: engine)
    let first = try controller.start(try parameters(wav(samples: [100], channels: 1)))
    let second = try controller.start(try parameters(wav(samples: [200], channels: 1)))

    controller.stop(first)
    XCTAssertEqual(engine.samples, [200])
    controller.stop(second)
    XCTAssertTrue(engine.samples.isEmpty)
  }

  func testStartRejectsInvalidAudio() throws {
    let engine = FakeEngine()

    XCTAssertThrowsError(try AudioInjectionController(engine: engine).start(try parameters(Data("not audio".utf8))))
    XCTAssertTrue(engine.samples.isEmpty)
  }

  private func parameters(_ audio: Data) throws -> AudioInjectionParameters {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try audio.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return AudioInjectionParameters(path: url.path)
  }

  private func wav(
    samples: [Int16],
    channels: UInt16,
    formatTag: UInt16 = 1,
    sampleRate: UInt32 = 48_000
  ) -> Data {
    var data = Data()
    func append(_ string: String) { data.append(contentsOf: string.utf8) }
    func append(_ value: UInt16) {
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
    }
    func append(_ value: UInt32) {
      append(UInt16(value & 0xFFFF))
      append(UInt16(value >> 16))
    }

    let payloadSize = UInt32(samples.count * MemoryLayout<Int16>.size)
    append("RIFF")
    append(36 + payloadSize)
    append("WAVE")
    append("fmt ")
    append(UInt32(16))
    append(formatTag)
    append(channels)
    append(sampleRate)
    append(sampleRate * UInt32(channels) * 2)
    append(UInt16(channels * 2))
    append(UInt16(16))
    append("data")
    append(payloadSize)
    for sample in samples {
      append(UInt16(bitPattern: sample))
    }
    return data
  }
}
