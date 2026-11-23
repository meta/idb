/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing

/// How `Simulator`'s spawn paths build the `SimDevice` launch-option dictionary: argv[0]
/// handling, `standalone` resolution, stdio keys. Pure-function assertions except the stdin
/// and teardown cases, which drive the launcher against device doubles.
@Suite
struct SimulatorSubprocessLauncherTests {

  private func simulator(state: TargetState) -> Simulator {
    SimulatorTestSupport.testableSimulator(withDevice: StubStateDevice(state: state))
  }

  // MARK: - Raw process spawn options

  @Test
  func rawSpawnOptionsPrependLaunchPathAsArgv0() {
    let options = SimulatorSubprocessLauncher.simDeviceLaunchOptions(
      withSimulator: simulator(state: .booted),
      launchPath: "/bin/echo",
      arguments: ["hello", "world"],
      environment: [:],
      waitForDebugger: false,
      standardOutput: nil,
      standardError: nil,
      mode: .launchd)

    #expect(
      options["arguments"] as? [String] == ["/bin/echo", "hello", "world"],
      "SimDevice does not set argv[0], so the launch path must be prepended to the arguments")
  }

  @Test
  func rawSpawnOptionsCarryEnvironmentAndOmitWaitForDebuggerWhenFalse() {
    let options = SimulatorSubprocessLauncher.simDeviceLaunchOptions(
      withSimulator: simulator(state: .booted),
      launchPath: "/bin/echo",
      arguments: [],
      environment: ["KEY": "VALUE"],
      waitForDebugger: false,
      standardOutput: nil,
      standardError: nil,
      mode: .launchd)

    #expect(options["environment"] as? [String: String] == ["KEY": "VALUE"])
    #expect(options["wait_for_debugger"] == nil, "wait_for_debugger must be absent when not requested")
    #expect(options["stdout"] == nil, "No stdout key should be set when no stdout attachment is provided")
    #expect(options["stderr"] == nil, "No stderr key should be set when no stderr attachment is provided")
  }

  @Test
  func rawSpawnOptionsSetWaitForDebuggerWhenRequested() {
    let options = SimulatorSubprocessLauncher.simDeviceLaunchOptions(
      withSimulator: simulator(state: .booted),
      launchPath: "/bin/echo",
      arguments: [],
      environment: [:],
      waitForDebugger: true,
      standardOutput: nil,
      standardError: nil,
      mode: .launchd)

    #expect((options["wait_for_debugger"] as? NSNumber)?.intValue == 1)
  }

  @Test
  func rawSpawnOptionsStandaloneReflectsMode() {
    let booted = simulator(state: .booted)

    let launchd = SimulatorSubprocessLauncher.simDeviceLaunchOptions(
      withSimulator: booted, launchPath: "/bin/echo", arguments: [], environment: [:],
      waitForDebugger: false, standardOutput: nil, standardError: nil, mode: .launchd)
    #expect((launchd["standalone"] as? NSNumber)?.boolValue == false)

    let posix = SimulatorSubprocessLauncher.simDeviceLaunchOptions(
      withSimulator: booted, launchPath: "/bin/echo", arguments: [], environment: [:],
      waitForDebugger: false, standardOutput: nil, standardError: nil, mode: .posixSpawn)
    #expect((posix["standalone"] as? NSNumber)?.boolValue == true)
  }

  // MARK: - standalone resolution

  @Test
  func standaloneIsTrueForPosixSpawnRegardlessOfState() {
    #expect(SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .booted), mode: .posixSpawn))
    #expect(SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .shutdown), mode: .posixSpawn))
  }

  @Test
  func standaloneIsFalseForLaunchdRegardlessOfState() {
    #expect(!SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .booted), mode: .launchd))
    #expect(!SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .shutdown), mode: .launchd))
  }

  @Test
  func standaloneDefaultModeFollowsBootState() {
    #expect(
      !(SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .booted), mode: .default)),
      "When booted, default mode launches into launchd (not standalone)")
    #expect(
      SimulatorSubprocessLauncher.shouldLaunchStandalone(onSimulator: simulator(state: .shutdown), mode: .default),
      "When not booted, default mode launches standalone")
  }

  // MARK: - SubprocessLauncher

  @Test
  func launcherSpawnsTheSpecWithExactlyItsExplicitEnvironment() async throws {
    let device = ExitingSpawnDevice(statLoc: 3 << 8)
    let launcher = SimulatorSubprocessLauncher(simulator: SimulatorTestSupport.testableSimulator(withDevice: device))
    let subprocess = Subprocess(executable: "/usr/bin/true", arguments: ["-a"], environment: .additions(["E": "1"]), mode: .posixSpawn)

    let completed = try await subprocess.run(on: launcher, output: .closed, error: .closed, exitPolicy: .mustExit([3]))

    #expect(completed.terminationStatus == .exited(3))
    #expect(completed.processIdentifier == 4242)
    let options = try #require(device.spawnedOptions)
    #expect(options["arguments"] as? [String] == ["/usr/bin/true", "-a"])
    // None of the host's DEVELOPER_DIR, HOME or PATH leak into the simulator.
    #expect(options["environment"] as? [String: String] == ["E": "1"])
    #expect((options["standalone"] as? NSNumber)?.boolValue == true)
    #expect(options["stdout"] == nil, "A closed stream is not handed to the device")
  }

  @Test
  func launcherGivesAnInheritingEnvironmentNothingFromTheHost() async throws {
    let device = ExitingSpawnDevice()
    let launcher = SimulatorSubprocessLauncher(simulator: SimulatorTestSupport.testableSimulator(withDevice: device))

    _ = try await Subprocess(executable: "/usr/bin/true", environment: .inherit).run(on: launcher, output: .closed, error: .closed)

    #expect(device.spawnedOptions?["environment"] as? [String: String] == [:])
  }

  @Test
  func launcherDrainsStdOutBeforeTheExitResolves() async throws {
    let payload = Data(repeating: UInt8(ascii: "x"), count: 12_000) + Data("end\n".utf8)
    let device = ExitingSpawnDevice(stdOutPayload: payload)
    let launcher = SimulatorSubprocessLauncher(simulator: SimulatorTestSupport.testableSimulator(withDevice: device))
    let received = Received()
    let consumer = SynchronousDataConsumer { data in
      Thread.sleep(forTimeInterval: 0.05)
      received.append(data)
    }

    let completed = try await Subprocess(executable: "/bin/echo").run(on: launcher, output: .consumer(consumer), error: .closed)

    #expect(completed.terminationStatus == .exited(0))
    #expect(received.data == payload)
  }

  @Test
  func launcherRejectsAStandardInputWithoutReachingTheDevice() async throws {
    let device = RecordingSpawnDevice()
    let launcher = SimulatorSubprocessLauncher(simulator: SimulatorTestSupport.testableSimulator(withDevice: device))

    do {
      _ = try await Subprocess(executable: "/bin/cat").run(on: launcher, output: .closed, error: .closed, input: .data(Data("in".utf8)))
      Issue.record("Expected the launch to be rejected, but it ran")
    } catch SubprocessError.inputUnsupported(let executable) {
      #expect(executable == "/bin/cat")
    }

    #expect(device.spawnedOptions == nil)
  }

  // MARK: - Application launch options

  @Test
  func appLaunchOptionsDoNotPrependLaunchPathAndCarryStdioPaths() {
    let configuration = ApplicationLaunchConfiguration(
      bundleID: "com.example.app",
      bundleName: "App",
      arguments: ["--flag"],
      environment: ["E": "1"],
      waitForDebugger: true,
      launchMode: .failIfRunning)

    let options = SimulatorApplicationCommands.simDeviceLaunchOptions(
      for: configuration, stdOutPath: "relative/out", stdErrPath: "relative/err")

    #expect(
      options["arguments"] as? [String] == ["--flag"],
      "App launch passes arguments through unchanged — unlike raw spawn, no argv[0] is prepended")
    #expect(options["environment"] as? [String: String] == ["E": "1"])
    #expect((options["wait_for_debugger"] as? NSNumber)?.intValue == 1)
    #expect(options["stdout"] as? String == "relative/out")
    #expect(options["stderr"] as? String == "relative/err")
  }
}

// MARK: - Device double

/// Stands in for `SimDevice` on the unit-test path, exposing only the two selectors
/// `Simulator` reads here: `-UDID` (logger naming at init) and `-state`
/// (consulted by `shouldLaunchStandalone`). Passed through `id`, so a Swift class
/// suffices — it never reaches real CoreSimulator.
private final class StubStateDevice {
  @objc(UDID) let udid = NSUUID()
  @objc let state: UInt64

  init(state: TargetState) {
    self.state = UInt64(state.rawValue)
  }
}

/// Device double for the raw-spawn path. Records the option dictionary it is handed,
/// so a test can distinguish a launch that reached `SimDevice` from one rejected before
/// it. The spawn completes rather than hanging, so a regression surfaces as a failed
/// assertion rather than as a timeout.
private final class RecordingSpawnDevice: @unchecked Sendable {
  @objc(UDID) let udid = NSUUID()
  @objc let state = UInt64(TargetState.booted.rawValue)

  private(set) var spawnedOptions: [String: Any]?

  @objc(spawnAsyncWithPath:options:terminationQueue:terminationHandler:completionQueue:completionHandler:)
  func spawnAsync(
    withPath path: String,
    options: [String: Any],
    terminationQueue: DispatchQueue,
    terminationHandler: @escaping @Sendable (Int32) -> Void,
    completionQueue: DispatchQueue,
    completionHandler: @escaping @Sendable (NSError?, pid_t) -> Void
  ) {
    spawnedOptions = options
    completionQueue.async { completionHandler(nil, 4242) }
  }
}

private final class Received: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  var data: Data {
    lock.withLock { storage }
  }

  func append(_ data: Data) {
    lock.withLock { storage.append(data) }
  }
}

/// Device double that behaves like a process which writes to stdout and exits at once: the
/// payload goes into the stdout descriptor it is handed, and termination is reported before
/// anything has read it.
private final class ExitingSpawnDevice: @unchecked Sendable {
  @objc(UDID) let udid = NSUUID()
  @objc let state = UInt64(TargetState.booted.rawValue)

  private let stdOutPayload: Data
  private let statLoc: Int32
  private(set) var spawnedOptions: [String: Any]?

  init(stdOutPayload: Data = Data(), statLoc: Int32 = 0) {
    self.stdOutPayload = stdOutPayload
    self.statLoc = statLoc
  }

  @objc(spawnAsyncWithPath:options:terminationQueue:terminationHandler:completionQueue:completionHandler:)
  func spawnAsync(
    withPath path: String,
    options: [String: Any],
    terminationQueue: DispatchQueue,
    terminationHandler: @escaping @Sendable (Int32) -> Void,
    completionQueue: DispatchQueue,
    completionHandler: @escaping @Sendable (NSError?, pid_t) -> Void
  ) {
    spawnedOptions = options
    if let fileDescriptor = (options["stdout"] as? NSNumber)?.int32Value {
      stdOutPayload.withUnsafeBytes { _ = write(fileDescriptor, $0.baseAddress, $0.count) }
    }
    let statLoc = statLoc
    completionQueue.async {
      completionHandler(nil, 4242)
      terminationQueue.async { terminationHandler(statLoc) }
    }
  }
}
