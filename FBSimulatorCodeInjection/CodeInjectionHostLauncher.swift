/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@preconcurrency import FBSimulatorControl
import FBSimulatorServices
import FBSimulatorXCTest
@preconcurrency import FBXCTestCore
import Foundation

/// Each host is started with the shim injected. `additionalLibraries` are loaded into the host
/// alongside it, before any code is injected, so injected code resolves their symbols at load.
struct CodeInjectionHostLauncher {

  let simulator: Simulator

  // MARK: - Async

  func startTest(bundlePath: String, shim: CodeInjectionShim, additionalLibraries: [String]) async throws -> CodeInjectionHost {
    let logger = simulator.logger
    let shimPath = try shim.resolvedPath()

    // The shim binds this socket; the session connects to it.
    let socketPath = "/tmp/idb_repl_\(UUID().uuidString).sock"

    let bundle = try BundleDescriptor(path: bundlePath)
    let architectures = Set((bundle.binary?.architectures ?? []).map(\.rawValue))

    let configuration = LogicTestConfiguration(
      environment: [
        "IDB_REPL_SOCKET_PATH": socketPath,
        "IDB_REPL_GEN_INTERFACE_DIR": "/tmp/idb_repl_interfaces",
        "IDB_REPL_PROBE_IMAGE": "ReplTest",
      ],
      workingDirectory: simulator.auxillaryDirectory,
      testBundlePath: bundlePath,
      waitForDebugger: false,
      timeout: 3_600,
      testFilter: "TestRepl/start",
      mirroring: .fileLogs,
      coverageConfiguration: nil,
      binaryPath: bundle.binary?.path,
      logDirectoryPath: nil,
      architectures: architectures,
      injectLibraries: [shimPath] + additionalLibraries
    )

    let runner = LogicTestRunner(
      target: simulator,
      configuration: configuration,
      reporter: ReplNullReporter(),
      logger: logger)
    return CodeInjectionHost(socketPath: socketPath, host: .testRun(Task { try await runner.run() }))
  }

  func startSimulator(shim: CodeInjectionShim, additionalLibraries: [String]) async throws -> CodeInjectionHost {
    guard let bridgePath = simulator.frameworkBridgePath else {
      throw CodeInjectionError.resourceMissing(name: "SimulatorFrameworkBridge binary")
    }
    return try await startSimulator(bridgePath: bridgePath, shimPath: shim.resolvedPath(), additionalLibraries: additionalLibraries)
  }

  func startSimulator(bridgePath: String, shimPath: String, additionalLibraries: [String] = []) async throws -> CodeInjectionHost {
    // `repl start` blocks until the socket is closed, which is what keeps the session alive.
    let socketPath = "/tmp/idb_repl_\(UUID().uuidString).sock"

    let process = try await Subprocess(
      executable: bridgePath,
      arguments: ["repl", "start", socketPath, shimPath] + additionalLibraries,
      environment: .exact(XCTestShimConfiguration.unarmedAudioInjectionEnvironment([:])),
      mode: .posixSpawn
    ).launch(on: SimulatorSubprocessLauncher(simulator: simulator), output: .nullDevice, error: .nullDevice)
    return CodeInjectionHost(socketPath: socketPath, host: .process(process))
  }

  func appLaunchEnvironment(bundleID: String, shim: CodeInjectionShim, additionalLibraries: [String]) throws -> [String: String] {
    try [
      "DYLD_INSERT_LIBRARIES": ([shim.resolvedPath()] + additionalLibraries).joined(separator: ":"),
      "IDB_REPL_APP_AUTOSTART": "1",
      "IDB_REPL_SOCKET_PATH": replSocketPath(udid: simulator.udid, bundleID: bundleID),
    ]
  }

  func startApp(bundleID: String, reuseSession: Bool, shim: CodeInjectionShim, additionalLibraries: [String]) async throws -> CodeInjectionHost {
    let logger = simulator.logger

    // Deterministic so a later session can reattach to an app still serving one.
    guard ensureReplSocketDirectory(replSocketDirectory()) else {
      throw CodeInjectionError.socketDirectoryCreationFailed(path: replSocketDirectory())
    }
    let socketPath = replSocketPath(udid: simulator.udid, bundleID: bundleID)

    if reuseSession, await replListenerIsAlive(at: socketPath) {
      logger.info().log("Reattaching to the running REPL for \(bundleID) at \(socketPath)")
      return CodeInjectionHost(socketPath: socketPath, host: .app)
    }

    // `.relaunchIfRunning` so an app already running without the REPL dylib picks it up. Armed as
    // an idb `launch` is: camera injection after microphone injection has added the shim.
    let environment = simulator.videoInjection.appLaunchEnvironment(
      await simulator.audioInjection.appLaunchEnvironment(
        try appLaunchEnvironment(bundleID: bundleID, shim: shim, additionalLibraries: additionalLibraries)))
    let configuration = ApplicationLaunchConfiguration(
      bundleID: bundleID,
      bundleName: nil,
      arguments: [],
      environment: environment,
      waitForDebugger: false,
      launchMode: .relaunchIfRunning
    )
    let launched = try await simulator.application.launch(configuration)

    // A launched app registers a `UIKitApplication:` service with the simulator's
    // launchd; a launchd-managed target such as SpringBoard never does. CoreSimulator
    // still reports success for one -- it resolves to the process already running, so
    // the injected environment is dropped and nothing ever binds the control socket.
    // Without this the client spends its entire deadline waiting for a socket that
    // cannot appear, then reports only a hashed path.
    //
    // This is the same lookup `confirmApplicationLaunchState` already trusts to decide
    // whether an app is running, so it introduces no new signal. It is deliberately not
    // `installType == .system`: Apple's system apps host a REPL perfectly well, and
    // refusing them would be wrong.
    guard (try? await simulator.application.processID(forBundleID: bundleID)) != nil else {
      throw CodeInjectionError.notALaunchableApplication(
        bundleID: bundleID,
        processIdentifier: launched.processIdentifier)
    }

    return CodeInjectionHost(socketPath: socketPath, host: .app)
  }
}

// MARK: - Reporter

/// A no-op logic-test reporter. REPL mode runs the shim's single test purely to
/// host the control socket, so the normal test-reporting events are discarded.
final class ReplNullReporter: LogicXCTestReporter {
  func processWaitingForDebugger(processIdentifier pid: pid_t) {}
  func didBeginExecutingTestPlan() {}
  func didFinishExecutingTestPlan() {}
  func testHadOutput(_ output: String) {}
  func handleEventJSONData(_ data: Data) {}
  func didCrashDuringTest(_ error: any Error) {}
}

// MARK: - App-context REPL socket helpers

/// The per-user directory that holds app-context REPL control sockets. Placed
/// under /tmp -- a namespace shared between the host process and the simulator
/// app (which runs as the same user) -- but scoped to the owning user by a 0700
/// directory.
func replSocketDirectory() -> String {
  return "/tmp/idb_repl_\(getuid())"
}

/// Verifies with `lstat` rather than trusting creation: the directory may pre-exist with the wrong
/// owner or mode.
@discardableResult
func ensureReplSocketDirectory(_ dir: String) -> Bool {
  let fm = FileManager.default
  if !fm.fileExists(atPath: dir) {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  var st = stat()
  guard lstat(dir, &st) == 0 else { return false }
  return (st.st_mode & UInt16(S_IFMT)) == UInt16(S_IFDIR)
    && st.st_uid == getuid()
    && (st.st_mode & 0o777) == 0o700
}

/// The deterministic control socket path for an app-context REPL, derived from
/// the simulator udid and app bundle id, inside the per-user socket directory.
/// Reattach relies on this being stable across sessions and across restarts of
/// the process that injects. Hashed to a fixed length: `sockaddr_un.sun_path` is only
/// 104 bytes, so the raw udid + bundle id would not reliably fit.
func replSocketPath(udid: String, bundleID: String) -> String {
  return "\(replSocketDirectory())/\(stableHashHex("\(udid)\u{0}\(bundleID)")).sock"
}

/// A stable, process-independent 64-bit FNV-1a hash of `string` as 16 hex
/// digits. Swift's `Hasher` is seeded per process, so it cannot back a path
/// that must match across processes.
func stableHashHex(_ string: String) -> String {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in string.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 0x0000_0100_0000_01b3
  }
  let hex = String(hash, radix: 16)
  return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
}

/// Whether a REPL control socket is already listening at `path`. A single, fast
/// connect attempt: connect() to an absent or dead socket fails at once
/// (ENOENT/ECONNREFUSED), so a closed app is detected without waiting.
func replListenerIsAlive(at path: String) async -> Bool {
  let queue = DispatchQueue(label: "com.facebook.idb.repl.probe")
  return await queue.perform {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return false
    }
    defer { Darwin.close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < maxLength else {
      return false
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      path.withCString { src in memcpy(ptr, src, path.utf8.count + 1) }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, size)
      }
    }
    return result == 0
  }
}
