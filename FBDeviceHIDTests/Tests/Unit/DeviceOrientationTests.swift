/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
@testable import FBDeviceControl
@testable import FBDeviceHID
import Foundation
import Testing

@Suite(.serialized)
struct DeviceOrientationTests {
  @Test(arguments: [DeviceOrientation.unknown, .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight, .faceUp, .faceDown])
  func readsPhysicalOrientationWithoutNativeHID(_ value: DeviceOrientation) async throws {
    try await withFixture { root, launcher in
      await launcher.configure(current: value)
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let command = command(device, launcher, root)
      #expect(try await command.orientation(nil) == value)
      #expect(await launcher.operations() == ["details", "get"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test func fractionalTimeoutUsesWholeCLISeconds() async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root, timeout: 2.5)
      #expect(try await input.orientation(nil) == .faceUp)
      #expect(await launcher.timeoutArguments() == ["3"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: [0.0, -1.0, Double.nan, .infinity, -.infinity, Double(Int.max)])
  func invalidTimeoutLaunchesNothing(_ timeout: TimeInterval) async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root, timeout: timeout)
      await #expect(throws: DeviceHIDError.self) { try await input.orientation(.landscapeLeft) }
      #expect(await launcher.operations().isEmpty)
    }
  }

  @Test(arguments: [DeviceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight])
  func writesNamedCardinalOrientation(_ value: DeviceOrientation) async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = device.commandCache.resolve { command(device, launcher, root) }
      try await device.orientation.set(value)
      #expect(device.hid === input)
      #expect(await launcher.operations() == ["details", "get", "set"])
      #expect(await launcher.writtenOrientation() == value.rawValue)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: [DeviceOrientation.unknown, .faceUp, .faceDown])
  func rejectsNoncardinalWritesBeforeLaunch(_ value: DeviceOrientation) async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let orientation = DeviceOrientationCommands(input: input)
      await #expect(throws: DeviceHIDError.self) { try await orientation.set(value) }
      #expect(await launcher.operations().isEmpty)
    }
  }

  @Test func lockedWriteDoesNotQuarantineOrLaunchSet() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(locked: true)
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      do {
        _ = try await input.orientation(.landscapeLeft)
        Issue.record("Locked orientation was accepted")
      } catch DeviceHIDError.orientationLocked {}
      #expect(try await input.orientation(nil) == .faceUp)
      #expect(await launcher.operations() == ["details", "get", "details", "get"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: Fault.invalidReceipts)
  func rejectsGetReceiptWithoutLaunchingSet(_ fault: Fault) async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: fault, phase: "get")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      await #expect(throws: (any Error).self) { try await input.orientation(.landscapeLeft) }
      #expect(await launcher.operations() == ["details", "get"])
      await launcher.configure(fault: Fault.none)
      #expect(try await input.orientation(nil) == .faceUp)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: Fault.invalidReceipts + [.wrongState])
  func uncertainSetSticksAndNeverRetries(_ fault: Fault) async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: fault, phase: "set")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      do {
        _ = try await input.orientation(.landscapeLeft)
        Issue.record("Bad SET receipt was accepted")
      } catch DeviceHIDError.orientationMayHaveApplied {}
      await assertQuarantined(input)
      #expect(await launcher.operations() == ["details", "get", "set"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test func cancellationBeforePreparationLaunchesNothing() async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await input.orientation(.landscapeLeft)
      }
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(await launcher.operations().isEmpty)
      #expect(try await input.orientation(nil) == .faceUp)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: [false, true])
  func cancellationReapsItsProcessAndQuarantinesOnlySet(_ set: Bool) async throws {
    try await withFixture { root, launcher in
      let phase = set ? "set" : "get"
      await launcher.configure(fault: .blocked, phase: phase)
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let task = Task { try await input.orientation(.landscapeLeft) }
      try await launcher.events.waitFor(phase)
      task.cancel()
      if set {
        do {
          _ = try await task.value
          Issue.record("Cancelled SET returned success")
        } catch DeviceHIDError.orientationMayHaveApplied {}
        await assertQuarantined(input)
      } else {
        await #expect(throws: CancellationError.self) { try await task.value }
        await launcher.configure(fault: Fault.none)
        #expect(try await input.orientation(nil) == .faceUp)
      }
      try await checkCleanup(root, launcher)
    }
  }

  @Test func lateSetCompletionCannotClearCancellationOrAdmission() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .late, phase: "set")
      defer { launcher.gate.open() }
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let task = Task { try await input.orientation(.landscapeLeft) }
      try await launcher.events.waitFor("set")
      task.cancel()
      do {
        _ = try await input.orientation(nil)
        Issue.record("Pending SET gave away admission")
      } catch DeviceHIDError.busy {}
      launcher.gate.open()
      do {
        _ = try await task.value
        Issue.record("Late successful SET cleared cancellation")
      } catch DeviceHIDError.orientationMayHaveApplied {}
      await assertQuarantined(input)
      #expect(await launcher.operations() == ["details", "get", "set"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test func setTimeoutIsUncertainAndDoesNotRetry() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .blocked, phase: "set")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root, timeout: 2)
      do {
        _ = try await input.orientation(.landscapeLeft)
        Issue.record("Blocked SET returned success")
      } catch DeviceHIDError.orientationMayHaveApplied {}
      await assertQuarantined(input)
      #expect(await launcher.operations() == ["details", "get", "set"])
      try await checkCleanup(root, launcher)
    }
  }

  @Test func activeContactRejectsOrientationBeforeAnyProcess() async throws {
    try await withFixture { root, launcher in
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let fixture = DeviceHIDFixture(block: "start")
      defer { fixture.gate.open() }
      let input = DeviceHIDCommands(
        device: device,
        prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
        checkRuntime: {}, makeTransport: { _ in fixture.transport },
        orientationTool: DeviceOrientationTool(launcher: launcher, temporaryRoot: root))
      let task = Task { try await input.tap(x: 1, y: 1, duration: nil) }
      try await fixture.events.waitFor("start")
      for setting: DeviceOrientation? in [nil, .landscapeLeft] {
        do {
          _ = try await input.orientation(setting)
          Issue.record("Orientation overlapped contact")
        } catch DeviceHIDError.busy {}
      }
      fixture.gate.open()
      try await task.value
      #expect(await launcher.operations().isEmpty)
    }
  }

  @Test func orientationBlocksTouchAndButtonAdmissionUntilReaped() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .blocked, phase: "set")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let task = Task { try await input.orientation(.landscapeLeft) }
      try await launcher.events.waitFor("set")
      for button in [false, true] {
        do {
          if button { try await input.button(.home) } else { try await input.tap(x: 1, y: 1, duration: nil) }
          Issue.record("Input overlapped SET")
        } catch DeviceHIDError.busy {}
      }
      task.cancel()
      do {
        _ = try await task.value
        Issue.record("Cancelled SET returned success")
      } catch DeviceHIDError.orientationMayHaveApplied {}
      try await checkCleanup(root, launcher)
    }
  }

  @Test(arguments: [false, true])
  func lateHIDQuarantineStopsOrientationAtTheMutationBoundary(_ setAdmitted: Bool) async throws {
    try await withFixture { root, launcher in
      let phase = setAdmitted ? "set" : "get"
      await launcher.configure(fault: .late, phase: phase)
      defer { launcher.gate.open() }
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let fixture = DeviceHIDFixture(retainAcquisition: true)
      let input = DeviceHIDCommands(
        device: device,
        prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
        checkRuntime: {}, makeTransport: { _ in fixture.transport },
        orientationTool: DeviceOrientationTool(launcher: launcher, temporaryRoot: root))
      try await input.tap(x: 1, y: 1, duration: nil)
      let orientation = DeviceOrientationCommands(input: input)
      let task = Task { try await orientation.set(.landscapeLeft) }
      try await launcher.events.waitFor(phase)
      fixture.completeAcquisition()
      launcher.gate.open()
      do {
        _ = try await task.value
        Issue.record("Orientation survived prior HID quarantine")
      } catch DeviceHIDError.orientationMayHaveApplied {
        #expect(setAdmitted)
      } catch DeviceHIDError.uncertainState {
        #expect(!setAdmitted)
      }
      await assertQuarantined(input)
      #expect(await launcher.operations() == (setAdmitted ? ["details", "get", "set"] : ["details", "get"]))
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"))
  func successfulSetWithCleanupFailurePreservesSuccess() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .cleanupFailure, phase: "set")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      try await DeviceOrientationCommands(input: input).set(.landscapeLeft)
      #expect(await launcher.operations() == ["details", "get", "set"])
      #expect(await launcher.writtenOrientation() == "landscapeLeft")
      try await restorePermissions(root)
      await launcher.configure(fault: Fault.none)
      #expect(try await input.orientation(nil) == .faceUp)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"))
  func cleanupFailurePreservesOrientationLocked() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(locked: true, fault: .cleanupFailure, phase: "get")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      do {
        _ = try await input.orientation(.landscapeLeft)
        Issue.record("Locked orientation was accepted")
      } catch DeviceHIDError.orientationLocked {}
      #expect(await launcher.operations() == ["details", "get"])
      try await restorePermissions(root)
      await launcher.configure(fault: Fault.none)
      #expect(try await input.orientation(nil) == .faceUp)
      try await checkCleanup(root, launcher)
    }
  }

  @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"))
  func cleanupFailurePreservesCancellationBeforeSet() async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .blockedCleanupFailure, phase: "get")
      let device = DeviceHIDRetentionTests.makeInertDevice()
      let input = command(device, launcher, root)
      let task = Task { try await input.orientation(.landscapeLeft) }
      try await launcher.events.waitFor("get")
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(await launcher.operations() == ["details", "get"])
      try await restorePermissions(root)
      await launcher.configure(fault: Fault.none)
      #expect(try await input.orientation(nil) == .faceUp)
      try await checkCleanup(root, launcher)
    }
  }

  private func restorePermissions(_ root: URL) async throws {
    try await DeviceHIDPreparation.fileIO {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where directory.lastPathComponent != "sentinel" {
        try FileManager.default.removeItem(at: directory)
      }
    }
  }

  @Test func orientationFacadeDoesNotRetainDevice() async throws {
    var facade: DeviceOrientationCommands?
    weak var weakDevice: Device?
    autoreleasepool {
      let device = DeviceHIDRetentionTests.makeInertDevice()
      weakDevice = device
      facade = device.orientation
    }
    #expect(weakDevice == nil)
    let command = try #require(facade)
    do {
      _ = try await command.current()
      Issue.record("Released device accepted orientation")
    } catch DeviceHIDError.deviceUnavailable {}
  }

  @Test(arguments: ["get", "set"])
  func processFailureIncludesBoundedStderr(_ phase: String) async throws {
    try await withFixture { root, launcher in
      await launcher.configure(fault: .nonzero, phase: phase)
      let tool = DeviceOrientationTool(launcher: launcher, temporaryRoot: root)
      do {
        _ = try await tool.perform(udid: "test-phone", setting: .landscapeLeft, beforeSet: {})
        Issue.record("Nonzero process exit was accepted")
      } catch DeviceHIDError.preparationFailed(let message) {
        #expect(message.contains("devicectl orientation \(phase) failed"))
        #expect(message.hasSuffix("diagnostic-tail"))
        #expect(!message.contains("discarded-prefix"))
        #expect(message.utf8.count < Subprocess.errorMessageLength + 150)
      }
      try await checkCleanup(root, launcher)
    }
  }

  private func command(_ device: Device, _ launcher: OrientationLauncher, _ root: URL, timeout: TimeInterval = 10) -> DeviceHIDCommands {
    DeviceHIDCommands(
      device: device,
      checkRuntime: { Issue.record("Orientation constructed the native HID runtime") },
      orientationTool: DeviceOrientationTool(launcher: launcher, timeout: timeout, temporaryRoot: root))
  }

  private func assertQuarantined(_ input: DeviceHIDCommands) async {
    let orientation = DeviceOrientationCommands(input: input)
    for operation in 0..<4 {
      do {
        switch operation {
        case 0: _ = try await orientation.current()
        case 1: try await orientation.set(.portrait)
        case 2: try await input.tap(x: 1, y: 1, duration: nil)
        default: try await input.button(.home)
        }
        Issue.record("Uncertain SET admitted more input")
      } catch DeviceHIDError.uncertainState {
      } catch { Issue.record("Unexpected quarantine error: \(error)") }
    }
  }

  private func withFixture(_ body: @Sendable (URL, OrientationLauncher) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try await DeviceHIDPreparation.fileIO {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try Data("untouched".utf8).write(to: root.appendingPathComponent("sentinel"))
    }
    let result: Result<Void, any Error>
    do {
      try await body(root, OrientationLauncher())
      result = .success(())
    } catch { result = .failure(error) }
    try await DeviceHIDPreparation.fileIO {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try FileManager.default.removeItem(at: root)
    }
    try result.get()
  }

  private func checkCleanup(_ root: URL, _ launcher: OrientationLauncher) async throws {
    let pids = await launcher.processes()
    try await DeviceHIDPreparation.fileIO {
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      let sentinel = try Data(contentsOf: root.appendingPathComponent("sentinel"))
      #expect(entries == ["sentinel"])
      #expect(sentinel == Data("untouched".utf8))
      for pid in pids {
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
      }
    }
  }

  enum Fault: Sendable {
    case none, wrongTarget, wrongSelector, duplicateSelector, wrongCommand, wrongVersion, malformedVersion
    case failedOutcome, missingProducer, missing, malformed, oversized, nonzero, unknownOrientation, wrongState, blocked, late, cleanupFailure, blockedCleanupFailure

    static let invalidReceipts: [Self] = [.wrongTarget, .wrongSelector, .duplicateSelector, .wrongCommand, .wrongVersion, .malformedVersion, .failedOutcome, .missingProducer, .missing, .malformed, .oversized, .nonzero, .unknownOrientation]
  }

  private actor OrientationLauncher: SubprocessLauncher {
    nonisolated let supportsStandardInput = true
    nonisolated let events = DeviceHIDTestRecorder()
    nonisolated let gate = DeviceHIDTestGate()
    private var fault = Fault.none
    private var phase = "set"
    private var current = DeviceOrientation.faceUp
    private var locked = false
    private var calls: [String] = []
    private var timeouts: [String] = []
    private var pids: [pid_t] = []
    private var written: String?

    func configure(current: DeviceOrientation? = nil, locked: Bool? = nil, fault: Fault? = nil, phase: String? = nil) {
      if let current { self.current = current }
      if let locked { self.locked = locked }
      if let fault { self.fault = fault }
      if let phase { self.phase = phase }
    }

    func operations() -> [String] { calls }
    func timeoutArguments() -> [String] { timeouts }
    func processes() -> [pid_t] { pids }
    func writtenOrientation() -> String? { written }

    func spawn(_ subprocess: Subprocess, standardInput: Int32?, standardOutput: Int32?, standardError: Int32?, logger: (any ControlCoreLogger)?) async throws -> LaunchedProcess {
      #expect(subprocess.executable == "/usr/bin/xcrun")
      let arguments = subprocess.arguments
      let operation = try #require(arguments.count > 3 ? arguments[3] : nil)
      calls.append(operation)
      if operation != "details" {
        let timeoutIndex = try #require(arguments.firstIndex(of: "--timeout"))
        let text = arguments[timeoutIndex + 1]
        let seconds = try #require(Int(text))
        #expect(seconds > 0 && String(seconds) == text)
        timeouts.append(text)
      }
      let index = try #require(arguments.firstIndex(of: "--json-output"))
      let path = URL(fileURLWithPath: arguments[index + 1])
      let fault = operation == phase ? self.fault : .none
      let data = try receipt(arguments, operation: operation, fault: fault)
      let fixture: Subprocess
      switch fault {
      case .missing: fixture = Subprocess(executable: "/usr/bin/true")
      case .nonzero: fixture = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf 'discarded-prefix%0512d\\377diagnostic-tail' 0 >&2; exit 7"])
      case .blocked, .blockedCleanupFailure:
        let fifo = path.appendingPathExtension("fifo")
        try await DeviceHIDPreparation.fileIO {
          guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
          if fault == .blockedCleanupFailure {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path.deletingLastPathComponent().deletingLastPathComponent().path)
          }
        }
        fixture = Subprocess(executable: "/bin/cat", arguments: [fifo.path])
      case .oversized:
        fixture = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf '%1048577s' ' ' > \"$1\"", "orientation-fixture", path.path])
      case .cleanupFailure:
        fixture = Subprocess(
          executable: "/bin/sh",
          arguments: ["-c", "printf '%s' \"$1\" > \"$2\" && /bin/chmod 500 \"$3\"", "orientation-fixture", String(decoding: data, as: UTF8.self), path.path, path.deletingLastPathComponent().deletingLastPathComponent().path])
      case .none, .wrongTarget, .wrongSelector, .duplicateSelector, .wrongCommand, .wrongVersion, .malformedVersion,
        .failedOutcome, .missingProducer, .malformed, .unknownOrientation, .wrongState, .late:
        fixture = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\" > \"$2\"", "orientation-fixture", fault == .malformed ? "not json" : String(decoding: data, as: UTF8.self), path.path])
      }
      try await DeviceHIDPreparation.fileIO {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
      }
      let process = try await HostSubprocessLauncher().spawn(fixture, standardInput: standardInput, standardOutput: standardOutput, standardError: standardError, logger: logger)
      pids.append(process.processIdentifier)
      events.record(operation)
      if fault == .late { try await DeviceHIDPreparation.fileIO { self.gate.wait() } }
      return process
    }

    private func receipt(_ arguments: [String], operation: String, fault: Fault) throws -> Data {
      let identifier = "00000000-0000-0000-0000-000000000001"
      let selector = try #require(arguments.firstIndex(of: "--device"))
      let udid = arguments[selector + 1]
      var info: [String: Any] = ["arguments": arguments, "commandType": "devicectl.device.\(operation == "details" ? "info" : "orientation").\(operation)", "jsonVersion": 5, "outcome": "success", "version": "651.13.5"]
      var result: [String: Any]
      if operation == "details" {
        result = ["identifier": identifier, "properties": ["hardware": ["udid": udid, "reality": "physical", "deviceType": "iPhone", "platform": "iOS"]]]
      } else {
        #expect(Array(arguments.prefix(3)) == ["devicectl", "device", "orientation"])
        #expect(arguments.count == (operation == "set" ? 11 : 10))
        let value = operation == "set" ? try #require(arguments.last) : current.rawValue
        if operation == "set" { written = value }
        result = ["deviceIdentifier": identifier, "deviceOrientation": value, "deviceOrientationNonFlat": operation == "set" ? value : "portrait", "deviceIsOrientationLocked": locked]
      }
      switch fault {
      case .wrongTarget: result["deviceIdentifier"] = "00000000-0000-0000-0000-000000000002"
      case .wrongSelector:
        var changed = arguments
        changed[selector + 1] = "other-phone"
        info["arguments"] = changed
      case .duplicateSelector: info["arguments"] = arguments + ["--device", udid]
      case .wrongCommand: info["commandType"] = "devicectl.device.orientation.other"
      case .wrongVersion: info["jsonVersion"] = 6
      case .malformedVersion: info["jsonVersion"] = "5"
      case .failedOutcome: info["outcome"] = "failure"
      case .missingProducer: info.removeValue(forKey: "version")
      case .unknownOrientation: result["deviceOrientation"] = "futureOrientation"
      case .wrongState: result["deviceOrientation"] = "portrait"
      case .none, .missing, .malformed, .oversized, .nonzero, .blocked, .late, .cleanupFailure, .blockedCleanupFailure: break
      }
      return try JSONSerialization.data(withJSONObject: ["info": info, "result": result])
    }
  }
}
