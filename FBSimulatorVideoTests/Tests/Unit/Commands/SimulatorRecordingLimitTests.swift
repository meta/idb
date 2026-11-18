/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@testable import FBSimulatorControl
@testable import FBSimulatorVideo
import Foundation
import Testing

private struct StartFailed: Error {}

private func isLimitReached(_ error: any Error) -> Bool {
  if case .recordingLimitReached(limit: 2, _) = error as? SimulatorVideoRecordingError { return true }
  return false
}

/// Whether the volume holding temporary files compares names without regard to case, as a Mac's
/// default volume does.
private let temporaryVolumeIgnoresCase = pathconf(NSTemporaryDirectory(), _PC_CASE_SENSITIVE) == 0

private func isAlreadyBeingWritten(_ error: any Error, path: String) -> Bool {
  if case .outputAlreadyBeingWritten(path) = error as? SimulatorVideoRecordingError { return true }
  return false
}

/// A directory of its own, deleted when the test ends.
private final class TemporaryDirectory {
  let path: String

  init() throws {
    path = (NSTemporaryDirectory() as NSString).appendingPathComponent("recording-limit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(atPath: path)
  }

  func file(_ name: String) -> String {
    (path as NSString).appendingPathComponent(name)
  }
}

@Suite("Simulator recording limit")
struct SimulatorRecordingLimitTests {

  @Test("Two recordings run at once, and a third is refused")
  func aThirdRecordingIsRefused() throws {
    let active = ActiveSimulatorRecordings(outputPaths: RecordingOutputPaths())
    let first = try active.reserve(filePath: "/tmp/first.mp4")
    let second = try active.reserve(filePath: "/tmp/second.mp4")
    #expect(first.others.isEmpty)
    #expect(second.others == ["/tmp/first.mp4"])

    #expect {
      try active.reserve(filePath: "/tmp/third.mp4")
    } throws: { error in
      isLimitReached(error)
        && error.localizedDescription
          == "Cannot create a new video recording session: the simulator already records 2 (/tmp/first.mp4, /tmp/second.mp4), the most it records at once"
    }
  }

  @Test("A stopped recording frees its place, once")
  func releasingFreesOnePlace() throws {
    let active = ActiveSimulatorRecordings(outputPaths: RecordingOutputPaths())
    let first = try active.reserve(filePath: "/tmp/first.mp4")
    _ = try active.reserve(filePath: "/tmp/second.mp4")

    active.release(first.reservation)
    active.release(first.reservation)

    let third = try active.reserve(filePath: "/tmp/third.mp4")
    #expect(third.others == ["/tmp/second.mp4"])
    #expect { try active.reserve(filePath: "/tmp/fourth.mp4") } throws: { isLimitReached($0) }
  }

  @Test("A file a recording is writing is refused, naming it, until that recording stops")
  func aFileBeingWrittenIsRefused() throws {
    let active = ActiveSimulatorRecordings(outputPaths: RecordingOutputPaths())
    let first = try active.reserve(filePath: "/tmp/same.mp4")

    #expect {
      try active.reserve(filePath: "/tmp/same.mp4")
    } throws: { error in
      isAlreadyBeingWritten(error, path: "/tmp/same.mp4")
        && error.localizedDescription == "Cannot record to /tmp/same.mp4: a recording is already writing to it"
    }
    // The refusal took no place: one recording still runs, so another file may start beside it.
    _ = try active.reserve(filePath: "/tmp/other.mp4")

    active.release(first.reservation)
    _ = try active.reserve(filePath: "/tmp/same.mp4")
  }

  @Test("A file is the same file however its directory is spelled; a link at its name is its own entry")
  func pathsAreComparedResolved() throws {
    let directory = try TemporaryDirectory()
    let linkedDirectory = directory.file("linked")
    try FileManager.default.createSymbolicLink(atPath: linkedDirectory, withDestinationPath: directory.path)
    let recorded = directory.file("screen.mp4")
    FileManager.default.createFile(atPath: recorded, contents: Data())
    let linkedFile = directory.file("link.mp4")
    try FileManager.default.createSymbolicLink(atPath: linkedFile, withDestinationPath: recorded)
    let paths = RecordingOutputPaths()
    _ = try paths.claim(recorded)

    for spelling in [
      (linkedDirectory as NSString).appendingPathComponent("screen.mp4"),
      directory.file("sub/../screen.mp4"),
      directory.file("./screen.mp4"),
    ] {
      #expect(throws: SimulatorVideoRecordingError.self, "\(spelling)") { try paths.claim(spelling) }
    }
    // A writer into the link replaces the link, so it does not touch the file being recorded.
    _ = try paths.claim(linkedFile)
    let workingDirectory = FileManager.default.currentDirectoryPath
    #expect(
      RecordingOutputPaths.resolved("relative.mp4")
        == RecordingOutputPaths.resolved((workingDirectory as NSString).appendingPathComponent("relative.mp4")))
    #expect(RecordingOutputPaths.resolved(directory.file("other.mp4")) != RecordingOutputPaths.resolved(recorded))
  }

  @Test("A file claimed before it exists is the same file once its recording has created it")
  func aFileIsTheSameBeforeAndAfterItExists() throws {
    let directory = try TemporaryDirectory()
    let recorded = directory.file("screen.mp4")
    let paths = RecordingOutputPaths()
    _ = try paths.claim(recorded)
    // `/var` and `/tmp` are links into `/private`, so a path spelled through either names the same file.
    let throughPrivate = recorded.hasPrefix("/private/") ? recorded : "/private" + recorded

    #expect(throws: SimulatorVideoRecordingError.self) { try paths.claim(throughPrivate) }
    FileManager.default.createFile(atPath: recorded, contents: Data())
    #expect(throws: SimulatorVideoRecordingError.self) { try paths.claim(recorded) }
    #expect(throws: SimulatorVideoRecordingError.self) { try paths.claim(throughPrivate) }
  }

  @Test("A name is compared without regard to Unicode normalization")
  func namesAreComparedNormalized() throws {
    let directory = try TemporaryDirectory()
    let paths = RecordingOutputPaths()
    _ = try paths.claim(directory.file("caf\u{E9}.mp4"))

    #expect(throws: SimulatorVideoRecordingError.self) { try paths.claim(directory.file("cafe\u{301}.mp4")) }
  }

  @Test(
    "A name is compared without regard to case on a volume that ignores case",
    .enabled(if: temporaryVolumeIgnoresCase, "the temporary volume distinguishes case"))
  func namesAreComparedWithoutCaseWhereTheVolumeIgnoresIt() throws {
    let directory = try TemporaryDirectory()
    let paths = RecordingOutputPaths()
    _ = try paths.claim(directory.file("Screen.mp4"))

    #expect(throws: SimulatorVideoRecordingError.self) { try paths.claim(directory.file("screen.MP4")) }
    _ = try paths.claim(directory.file("other.mp4"))
  }

  @Test("Every start on one simulator is counted by the same commands")
  func oneSimulatorHasOneCount() {
    let simulator = SimulatorTestSupport.testableSimulator()

    #expect(simulator.videoRecording.active === simulator.videoRecording.active)
    #expect(simulator.videoRecording.active !== SimulatorTestSupport.testableSimulator().videoRecording.active)
  }

  @Test("A file is refused to a recording of another simulator too")
  func aFileIsRefusedAcrossSimulators() throws {
    let paths = RecordingOutputPaths()
    let one = ActiveSimulatorRecordings(outputPaths: paths)
    let another = ActiveSimulatorRecordings(outputPaths: paths)
    _ = try one.reserve(filePath: "/tmp/shared.mp4")

    #expect { try another.reserve(filePath: "/tmp/shared.mp4") } throws: {
      isAlreadyBeingWritten($0, path: "/tmp/shared.mp4")
    }
  }

  @Test("A recording refused for the limit claims no file")
  func aRefusalForTheLimitClaimsNoFile() throws {
    let paths = RecordingOutputPaths()
    let full = ActiveSimulatorRecordings(outputPaths: paths)
    _ = try full.reserve(filePath: "/tmp/first.mp4")
    _ = try full.reserve(filePath: "/tmp/second.mp4")
    #expect { try full.reserve(filePath: "/tmp/third.mp4") } throws: { isLimitReached($0) }

    _ = try ActiveSimulatorRecordings(outputPaths: paths).reserve(filePath: "/tmp/third.mp4")
  }

  @Test("A recording that fails to start takes neither a place nor its file")
  func aFailedStartReleasesItsPlace() async throws {
    let active = ActiveSimulatorRecordings(outputPaths: RecordingOutputPaths())
    let logger = CapturingLogger()
    _ = try active.reserve(filePath: "/tmp/running.mp4")

    await #expect(throws: StartFailed.self) {
      _ = try await active.start(filePath: "/tmp/failed.mp4", logger: logger) { () async throws -> Int in
        throw StartFailed()
      }
    }

    _ = try active.reserve(filePath: "/tmp/failed.mp4")
    #expect(logger.messages.count == 0)
  }

  @Test("Starting beside another recording logs both files; starting alone logs nothing")
  func startingBesideAnotherLogsBothFiles() async throws {
    let active = ActiveSimulatorRecordings(outputPaths: RecordingOutputPaths())
    let logger = CapturingLogger()

    _ = try await active.start(filePath: "/tmp/first.mp4", logger: logger) { 1 }
    #expect(logger.messages.count == 0)
    _ = try await active.start(filePath: "/tmp/second.mp4", logger: logger) { 2 }

    #expect(logger.messages as? [String] == ["Recording to /tmp/second.mp4 alongside /tmp/first.mp4, each with an encoder of its own"])
  }
}
