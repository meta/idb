/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@testable import FBSimulatorCodeInjection
import Foundation
import ShimulatorAudioInjectionCore
import ShimulatorProtocol
import Testing

private let rate = 48_000.0

extension AudioCaptureProcess: @retroactive Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    (lhs.processIdentifier, lhs.name, lhs.frames, lhs.droppedFrames, lhs.unmixedFrames, lhs.realignments)
      == (rhs.processIdentifier, rhs.name, rhs.frames, rhs.droppedFrames, rhs.unmixedFrames, rhs.realignments)
  }
}

private func ticks(frames: Int) -> UInt64 {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return UInt64((Double(frames) / rate * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
}

private func chunk(
  stream: UInt64 = 1, at hostTime: UInt64, frames: Int, value: Float, channels: Int = 2, sampleRate: Double = rate,
  sampleTime: Double = 0, discontinuity: Bool = false
) -> AudioCaptureChunk {
  AudioCaptureChunk(
    stream: stream, device: 73, sampleRate: sampleRate, hostTime: hostTime, sampleTime: sampleTime,
    channels: channels, discontinuity: discontinuity,
    samples: Array(repeating: value, count: frames * channels))
}

private func privateDirectory() throws -> String {
  var template = Array("/tmp/cap.XXXXXX".utf8CString)
  guard let directory = mkdtemp(&template) else {
    throw POSIXError(.EIO)
  }
  return String(cString: directory)
}

/// Writes one process's capture file, as the shim would.
private func capture(
  _ chunks: [AudioCaptureChunk], pid: Int32, in directory: String, dropped: UInt64? = 0
) throws -> AudioCaptureMixer.Source {
  let writer = try AudioCaptureFileWriter(directory: directory, processIdentifier: pid)
  chunks.forEach(writer.append)
  guard let dropped else {
    return AudioCaptureMixer.Source(
      path: (writer.path as NSString).appendingPathExtension(AudioCaptureFile.partialPathExtension) ?? writer.path,
      processName: "pid \(pid)")
  }
  writer.finish(droppedFrames: dropped)
  return AudioCaptureMixer.Source(path: writer.path, processName: "pid \(pid)")
}

/// The left channel of a two-channel float WAV the mixer wrote.
private func leftChannel(_ path: String?) throws -> [Float] {
  let data = try Data(contentsOf: URL(fileURLWithPath: try #require(path)))
  let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
}

@Suite
final class AudioCaptureMixerTests {
  private let directory: String
  private let mixPath: String
  private let start = ticks(frames: 480_000)

  init() throws {
    directory = try privateDirectory()
    mixPath = (directory as NSString).appendingPathComponent("mix.wav")
  }

  deinit {
    try? FileManager.default.removeItem(atPath: directory)
  }

  @Test
  func chunksFollowOneAnotherFromTheFirstHostTime() throws {
    let source = try capture(
      [chunk(at: start, frames: 4, value: 0.25), chunk(at: start + ticks(frames: 4), frames: 4, value: 0.5)],
      pid: 7, in: directory)

    let mixed = try AudioCaptureMixer.mix([source], into: mixPath)

    #expect(try leftChannel(mixed.path) == [0.25, 0.25, 0.25, 0.25, 0.5, 0.5, 0.5, 0.5])
    #expect(mixed.startHostTime == start)
    #expect(mixed.sampleRate == rate)
    #expect(
      mixed.processes == [
        AudioCaptureProcess(
          processIdentifier: 7, name: "pid 7", frames: 8, droppedFrames: 0, unmixedFrames: 0, realignments: 0)
      ])
  }

  @Test
  func processesAreSummedWhereTheyOverlapAndMonoFillsBothChannels() throws {
    let first = try capture([chunk(at: start, frames: 4, value: 0.25)], pid: 1, in: directory)
    let second = try capture(
      [chunk(stream: 9, at: start + ticks(frames: 2), frames: 4, value: 0.5, channels: 1)], pid: 2, in: directory)

    let mixed = try AudioCaptureMixer.mix([first, second], into: mixPath)

    #expect(try leftChannel(mixed.path) == [0.25, 0.25, 0.75, 0.75, 0.5, 0.5])
    let data = try Data(contentsOf: URL(fileURLWithPath: try #require(mixed.path)))
    let rightOfLastFrame = data.suffix(4).withUnsafeBytes { $0.load(as: Float.self) }
    #expect(rightOfLastFrame == 0.5)
  }

  @Test
  func framesDroppedBeforeAChunkLeaveSilenceUntilItsHostTime() throws {
    let source = try capture(
      [
        chunk(at: start, frames: 2, value: 0.25),
        chunk(at: start + ticks(frames: 5), frames: 2, value: 0.5, discontinuity: true),
      ], pid: 3, in: directory, dropped: 3)

    let mixed = try AudioCaptureMixer.mix([source], into: mixPath)

    #expect(try leftChannel(mixed.path) == [0.25, 0.25, 0, 0, 0, 0.5, 0.5])
    #expect(mixed.processes.first?.droppedFrames == 3)
  }

  @Test
  func aChunkWithoutAHostTimeContinuesItsStream() throws {
    let source = try capture(
      [chunk(at: start, frames: 2, value: 0.25), chunk(at: 0, frames: 2, value: 0.5)], pid: 4, in: directory)

    let mixed = try AudioCaptureMixer.mix([source], into: mixPath)

    #expect(try leftChannel(mixed.path) == [0.25, 0.25, 0.5, 0.5])
  }

  @Test
  func aStreamIsMovedBackOntoTheHostClockOnlyOnceItHasDriftedPastTheLimit() throws {
    let limit = Int(AudioCaptureMixer.realignmentSeconds * rate)
    let close = try capture(
      [chunk(at: start, frames: 2, value: 0.25), chunk(at: start + ticks(frames: 2 + limit / 2), frames: 2, value: 0.5)],
      pid: 5, in: directory)
    let drifted = try capture(
      [
        chunk(stream: 2, at: start, frames: 2, value: 0.25),
        chunk(stream: 2, at: start + ticks(frames: 2 + 2 * limit), frames: 2, value: 0.5),
      ], pid: 6, in: directory)

    let kept = try AudioCaptureMixer.mix([close], into: mixPath)
    let moved = try AudioCaptureMixer.mix(
      [drifted], into: (directory as NSString).appendingPathComponent("moved.wav"))

    #expect(kept.frames == 4)
    #expect(kept.processes.first?.realignments == 0)
    #expect(moved.frames == 4 + 2 * limit)
    #expect(moved.processes.first?.realignments == 1)
  }

  @Test
  func audioPlayedAtAnotherRateIsLeftOutAndCounted() throws {
    let usual = try capture([chunk(at: start, frames: 8, value: 0.25)], pid: 1, in: directory)
    let unusual = try capture(
      [chunk(stream: 3, at: start, frames: 4, value: 0.5, sampleRate: 44_100)], pid: 2, in: directory)

    let mixed = try AudioCaptureMixer.mix([usual, unusual], into: mixPath)

    #expect(try leftChannel(mixed.path) == Array(repeating: 0.25, count: 8))
    #expect(mixed.processes.map(\.unmixedFrames) == [0, 4])
    #expect(mixed.processes.map(\.frames) == [8, 0])
  }

  @Test(arguments: [1e12, Double.infinity])
  func audioAtARateNoDeviceRunsAtIsLeftOutAndCounted(impossibleRate: Double) throws {
    let usual = try capture([chunk(at: start, frames: 8, value: 0.25)], pid: 1, in: directory)
    let corrupt = try capture(
      [chunk(stream: 3, at: start, frames: 4, value: 0.5, sampleRate: impossibleRate)], pid: 2, in: directory)

    let mixed = try AudioCaptureMixer.mix([usual, corrupt], into: mixPath)
    let alone = try AudioCaptureMixer.mix(
      [corrupt], into: (directory as NSString).appendingPathComponent("alone.wav"))

    #expect(mixed.sampleRate == rate)
    #expect(try leftChannel(mixed.path) == Array(repeating: 0.25, count: 8))
    #expect(mixed.processes.map(\.unmixedFrames) == [0, 4])
    #expect(alone.path == nil)
    #expect(alone.processes.map(\.unmixedFrames) == [4])
  }

  @Test
  func audioPlacedPastWhatOneWAVFileCanHoldFailsTheMix() throws {
    let source = try capture(
      [chunk(at: start, frames: 2, value: 0.25), chunk(at: UInt64.max, frames: 2, value: 0.5)], pid: 10, in: directory)

    #expect {
      _ = try AudioCaptureMixer.mix([source], into: mixPath)
    } throws: { error in
      guard case let .mixTooLong(frames) = error as? AudioCaptureError else {
        return false
      }
      return frames > AudioCaptureMixer.maximumFrames
    }
  }

  @Test
  func audioPlacedAtATimeThatIsNotANumberFailsTheMix() throws {
    let source = try capture(
      [
        chunk(at: start, frames: 2, value: 0.25),
        chunk(at: 0, frames: 2, value: 0.5, sampleTime: .nan, discontinuity: true),
      ], pid: 11, in: directory)

    #expect {
      _ = try AudioCaptureMixer.mix([source], into: mixPath)
    } throws: { error in
      guard case let .corruptCapture(path) = error as? AudioCaptureError else {
        return false
      }
      return path == source.path
    }
  }

  @Test
  func aProcessThatEndedDuringTheCaptureKeepsWhatItWrote() throws {
    let source = try capture([chunk(at: start, frames: 2, value: 0.25)], pid: 8, in: directory, dropped: nil)

    let mixed = try AudioCaptureMixer.mix([source], into: mixPath)

    #expect(mixed.frames == 2)
    #expect(mixed.processes.first?.droppedFrames == nil)
  }

  @Test
  func nothingPlayedWritesNoMix() throws {
    let silent = try capture([], pid: 9, in: directory)

    let mixed = try AudioCaptureMixer.mix([silent], into: mixPath)

    #expect(mixed.path == nil)
    #expect(mixed.frames == 0)
    #expect(!FileManager.default.fileExists(atPath: mixPath))
  }
}

/// Plays one chunk on the first drain, and one more once the capture ends.
///
/// `reported` yields on the second drain. The shim's client sends what the first drain produced
/// before it polls again, so by then its report is waiting for the session.
private final class ScriptedEngine: AudioCaptureEngine {
  private var pending: [AudioCaptureChunk]
  private let last: AudioCaptureChunk
  private let reported: AsyncStream<Void>.Continuation
  private var drains = 0

  init(first: AudioCaptureChunk, last: AudioCaptureChunk, reported: AsyncStream<Void>.Continuation) {
    pending = [first]
    self.last = last
    self.reported = reported
  }

  func begin() {}

  func drain(_ body: (AudioCaptureChunk) -> Void) -> UInt64 {
    drains += 1
    if drains == 2 {
      reported.yield()
    }
    pending.forEach(body)
    pending = []
    return 0
  }

  func end() {
    pending = [last]
  }
}

@Suite
struct AudioCaptureSessionTests {

  @Test
  func stopMixesEverythingAConnectedProcessPlayedIncludingWhatItHadLeft() async throws {
    let root = try privateDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let socketPath = (root as NSString).appendingPathComponent("s.sock")
    let directory = (root as NSString).appendingPathComponent("capture")
    #expect(mkdir(directory, 0o700) == 0)
    let start = ticks(frames: 480_000)
    let session = try AudioCaptureSession(socketPath: socketPath, directory: directory, udid: "TEST")
    await session.beginPolling()

    // The guest: the shim's client and controller in this process, playing a scripted engine.
    let (reported, reportedContinuation) = AsyncStream<Void>.makeStream()
    let engine = ScriptedEngine(
      first: chunk(at: start, frames: 4, value: 0.25), last: chunk(at: start + ticks(frames: 4), frames: 2, value: 0.5),
      reported: reportedContinuation)
    let client = ShimulatorClient(
      socketPath: socketPath, handler: AudioCaptureController(engine: engine), processName: "Player",
      pollIntervalMilliseconds: 10, log: { _ in })
    let served = AsyncStream<Bool> { continuation in
      Thread.detachNewThread {
        continuation.yield(client.serveOnce())
        continuation.finish()
      }
    }
    // A process is named by its report, so the capture stops only once the client has sent one.
    var reportedIterator = reported.makeAsyncIterator()
    await reportedIterator.next()

    let mixPath = (root as NSString).appendingPathComponent("mix.wav")
    let captured = try await session.stop(writingMixTo: mixPath)
    var results = served.makeAsyncIterator()

    #expect(await results.next() == true)
    #expect(try leftChannel(captured.path) == [0.25, 0.25, 0.25, 0.25, 0.5, 0.5])
    #expect(captured.processes.map(\.name) == ["Player"])
    #expect(captured.processes.first?.droppedFrames == 0)
    #expect(captured.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory))
  }

  @Test
  func aProcessStillWritingWhenTheCaptureStopsWaitingIsNamedAmongTheFailures() async throws {
    let root = try privateDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let socketPath = (root as NSString).appendingPathComponent("s.sock")
    let directory = (root as NSString).appendingPathComponent("capture")
    #expect(mkdir(directory, 0o700) == 0)
    let session = try AudioCaptureSession(socketPath: socketPath, directory: directory, udid: "TEST")
    // An unfinished file in the name of this process, which is running: one still being written.
    _ = try capture([chunk(at: ticks(frames: 480_000), frames: 4, value: 0.25)], pid: getpid(), in: directory, dropped: nil)

    let captured = try await session.stop(writingMixTo: (root as NSString).appendingPathComponent("mix.wav"))

    #expect(try leftChannel(captured.path) == [0.25, 0.25, 0.25, 0.25])
    #expect(
      captured.failures == [
        "pid \(getpid()): still writing its audio when the capture stopped waiting; what it had written is mixed"
      ])
  }

  @Test
  func aSecondSessionOnTheSameSocketIsRefused() throws {
    let root = try privateDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let socketPath = (root as NSString).appendingPathComponent("s.sock")
    let first = try AudioCaptureSession(socketPath: socketPath, directory: root, udid: "TEST")

    #expect {
      _ = try AudioCaptureSession(socketPath: socketPath, directory: root, udid: "TEST")
    } throws: { error in
      guard case .alreadyRunning(udid: "TEST") = error as? AudioCaptureError else {
        return false
      }
      return true
    }
    withExtendedLifetime(first) {}
  }
}
