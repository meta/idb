/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ShimulatorProtocol
import ShimulatorVideoInjectionCore
import Synchronization
import XCTest

final class VideoInjectionControllerTests: XCTestCase {
  private final class FakeEngine: VideoInjectionEngine {
    struct Played: Equatable {
      let bytes: Data
      let path: String
      let frontPath: String?
      let loops: Bool
      let generation: Int64
    }

    private struct State: Sendable {
      var played: [Played] = []
      var progress = VideoInjectionProgress(generation: -1, started: false, finished: false, failed: false)
      var clearCount = 0
      var rejectPlay = false
    }

    private let state = Mutex(State())

    var played: [Played] { state.withLock { $0.played } }
    var clearCount: Int { state.withLock { $0.clearCount } }

    func rejectNextPlay() {
      state.withLock { $0.rejectPlay = true }
    }

    func setProgress(started: Bool = false, finished: Bool = false, failed: Bool = false) {
      state.withLock { state in
        state.progress = VideoInjectionProgress(
          generation: state.progress.generation,
          started: started,
          finished: finished,
          failed: failed)
      }
    }

    func play(fileURL: URL, frontFileURL: URL?, loops: Bool, generation: Int64) throws {
      let bytes = try Data(contentsOf: fileURL)
      try state.withLock { state in
        if state.rejectPlay {
          state.rejectPlay = false
          throw CocoaError(.fileReadCorruptFile)
        }
        state.played.append(
          Played(bytes: bytes, path: fileURL.path, frontPath: frontFileURL?.path, loops: loops, generation: generation))
        state.progress = VideoInjectionProgress(
          generation: generation, started: false, finished: false, failed: false)
      }
    }

    func clear() {
      state.withLock { state in
        state.clearCount += 1
        state.progress = VideoInjectionProgress(
          generation: -1, started: false, finished: false, failed: false)
      }
    }

    func pollProgress() -> VideoInjectionProgress {
      state.withLock { $0.progress }
    }
  }

  func testStartPlaysTheFile() throws {
    let engine = FakeEngine()

    _ = try VideoInjectionController(engine: engine).start(try parameters(Data("frames".utf8), loop: true))

    let played = try XCTUnwrap(engine.played.first)
    XCTAssertEqual(played.bytes, Data("frames".utf8))
    XCTAssertTrue(played.loops)
    XCTAssertEqual(played.generation, 0)
  }

  func testStartPassesTheFrontVideo() throws {
    let engine = FakeEngine()
    let back = try parameters(Data("back".utf8))
    _ = try VideoInjectionController(engine: engine).start(
      VideoInjectionParameters(path: back.path, frontPath: "/tmp/front.mov", loop: false))
    XCTAssertEqual(engine.played.map(\.frontPath), ["/tmp/front.mov"])
  }

  func testFrontPathIsOptionalOnTheWire() throws {
    let decoded = try JSONDecoder().decode(VideoInjectionParameters.self, from: Data(#"{"path":"/a.mov","loop":true}"#.utf8))
    XCTAssertEqual(decoded, VideoInjectionParameters(path: "/a.mov", loop: true))
    XCTAssertNil(decoded.frontPath)
  }

  func testPollReportsTheCameraForItsOwnGeneration() throws {
    let engine = FakeEngine()
    let controller = VideoInjectionController(engine: engine)
    let admission = try controller.start(try parameters(Data("frames".utf8)))
    XCTAssertNil(controller.poll(admission))

    engine.setProgress(started: true)
    XCTAssertEqual(controller.poll(admission)?.state, .accepted)
    engine.setProgress(started: true, finished: true)
    XCTAssertEqual(controller.poll(admission)?.state, .completed)
    engine.setProgress(started: true, failed: true)
    XCTAssertEqual(controller.poll(admission)?.state, .failed)

    controller.stop(admission)
    _ = try controller.start(try parameters(Data("next".utf8)))
    XCTAssertNil(controller.poll(admission))
  }

  func testUnplayableVideoFailsToStart() throws {
    let engine = FakeEngine()
    engine.rejectNextPlay()

    XCTAssertThrowsError(try VideoInjectionController(engine: engine).start(try parameters(Data("x".utf8))))
  }

  func testStopClearsTheCamera() throws {
    let engine = FakeEngine()
    let controller = VideoInjectionController(engine: engine)

    controller.stop(try controller.start(try parameters(Data("frames".utf8))))

    XCTAssertEqual(engine.clearCount, 1)
  }

  func testStoppingAReplacedInjectionLeavesTheLaterOnePlaying() throws {
    let engine = FakeEngine()
    let controller = VideoInjectionController(engine: engine)
    let first = try controller.start(try parameters(Data("first".utf8)))
    let second = try controller.start(try parameters(Data("second".utf8)))

    controller.stop(first)
    XCTAssertEqual(engine.clearCount, 0)
    controller.stop(second)
    XCTAssertEqual(engine.clearCount, 1)
  }

  func testRejectedReplacementLeavesThePreviousInjectionStoppable() throws {
    let engine = FakeEngine()
    let controller = VideoInjectionController(engine: engine)
    let first = try controller.start(try parameters(Data("first".utf8)))
    engine.setProgress(started: true)
    engine.rejectNextPlay()

    XCTAssertThrowsError(try controller.start(try parameters(Data("rejected".utf8))))
    XCTAssertEqual(controller.poll(first)?.state, .accepted)
    controller.stop(first)
    XCTAssertEqual(engine.clearCount, 1)
    XCTAssertNil(controller.poll(first))

    let next = try controller.start(try parameters(Data("next".utf8)))
    XCTAssertEqual(engine.played.map(\.generation), [0, 2])
    controller.stop(first)
    XCTAssertEqual(engine.clearCount, 1)
    controller.stop(next)
    XCTAssertEqual(engine.clearCount, 2)
  }

  private func parameters(_ video: Data, loop: Bool = false) throws -> VideoInjectionParameters {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    try video.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return VideoInjectionParameters(path: url.path, loop: loop)
  }
}
