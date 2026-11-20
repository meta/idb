/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_spi(IDBRepl) @testable import FBSimulatorCodeInjection
import Foundation
import Testing

private struct RefusedCommand: Error, CustomStringConvertible {
  var description: String { "refused" }
}

/// A session over a fake shim: what it reports about the host, what executing code returns, and how
/// host commands are answered with and without a handler.
@Suite
struct CodeInjectionSessionTests {

  @Test
  func describesTheHostFromItsGreeting() async throws {
    let shim = try FakeReplShim()
    let (session, _) = try await connect(to: shim, greeting: ["type": "greeting", "interfaces": ["/tmp/App.swiftinterface"], "nextRunIndex": 7, "sessionID": "session"])

    #expect(session.sessionID == "session")
    #expect(session.generatedInterfacePaths == ["/tmp/App.swiftinterface"])
    #expect(session.nextRunIndex == 7)
    #expect(session.socketPath == shim.path)
  }

  @Test
  func executeReturnsWhatTheEntryPointReturns() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    async let output = session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry")
    let request = try await connection.receive()
    #expect(request["dylib"] as? String == "/tmp/payload.dylib")
    #expect(request["symbol"] as? String == "payload_entry")
    try connection.send(["type": "result", "success": true, "result": "42", "nextRunIndex": 1])

    #expect(try await output == "42")
  }

  @Test
  func codeTheHostCannotRunThrowsItsError() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    let output = Task { try await session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry") }
    _ = try await connection.receive()
    try connection.send(["type": "result", "success": false, "error": "symbol not found"])

    await #expect(throws: CodeInjectionError.executionFailed(message: "symbol not found")) { try await output.value }
  }

  @Test
  func withoutAHandlerHostCommandsAreRefused() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    async let output = session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry")
    _ = try await connection.receive()
    try connection.send(["type": "host_command", "command": Data("ping".utf8)])
    let hostResult = try await connection.receive()
    #expect(hostResult["success"] as? Bool == false)
    #expect(hostResult["error"] as? String == CodeInjectionError.hostCommandsUnsupported.description)
    try connection.send(["type": "result", "success": true, "result": "done"])

    #expect(try await output == "done")
  }

  @Test
  func aHandlerAnswersHostCommands() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    async let output = session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry") { command in
      .success(Data("pong to ".utf8) + command)
    }
    _ = try await connection.receive()
    try connection.send(["type": "host_command", "command": Data("ping".utf8)])
    let hostResult = try await connection.receive()
    #expect(hostResult["success"] as? Bool == true)
    #expect(hostResult["result"] as? Data == Data("pong to ping".utf8))
    try connection.send(["type": "result", "success": true, "result": ""])

    _ = try await output
  }

  @Test
  func anActorOwnedHandlerAnswersSuccessiveHostCommands() async throws {
    actor Handler {
      var commands: [Data] = []

      func answer(_ command: Data) -> Result<Data, any Error> {
        commands.append(command)
        return .success(Data("reply to ".utf8) + command)
      }
    }
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)
    let handler = Handler()
    let commands = [Data("first".utf8), Data("second".utf8)]

    async let output = session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry") { command in
      await handler.answer(command)
    }
    _ = try await connection.receive()
    for command in commands {
      try connection.send(["type": "host_command", "command": command])
      let reply = try await connection.receive()
      #expect(reply["type"] as? String == "host_result")
      #expect(reply["success"] as? Bool == true)
      #expect(reply["result"] as? Data == Data("reply to ".utf8) + command)
    }
    try connection.send(["type": "result", "success": true, "result": "done"])

    #expect(try await output == "done")
    #expect(await handler.commands == commands)
  }

  @Test
  func aHandlerCanRefuseAHostCommand() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    async let output = session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry") { _ in .failure(RefusedCommand()) }
    _ = try await connection.receive()
    try connection.send(["type": "host_command", "command": Data()])
    let hostResult = try await connection.receive()
    #expect(hostResult["success"] as? Bool == false)
    #expect(hostResult["error"] as? String == "refused")
    try connection.send(["type": "result", "success": true, "result": ""])

    _ = try await output
  }

  @Test
  func runReportsTheNextRunIndex() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    async let run = session.run(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry")
    _ = try await connection.receive()
    try connection.send(["type": "result", "success": false, "error": "dlopen failed", "nextRunIndex": 4])

    let (result, nextRunIndex) = try await run
    #expect(result == .failure(.executionFailed(message: "dlopen failed")))
    #expect(nextRunIndex == 4)
  }

  @Test
  func aHostThatDisconnectsMidExecuteIsACodeInjectionError() async throws {
    let shim = try FakeReplShim()
    let (session, connection) = try await connect(to: shim)

    let output = Task { try await session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry") }
    _ = try await connection.receive()
    connection.close()

    await #expect(throws: CodeInjectionError.disconnected) { try await output.value }
  }

  @Test
  func aHostThatNeverServesTimesOut() async throws {
    let path = FakeReplShim.temporarySocketPath()

    await #expect(throws: CodeInjectionError.connectTimedOut(path: path)) {
      try await CodeInjectionSession.connect(to: CodeInjectionHost(socketPath: path, host: .app), timeout: 0.2)
    }
  }

  @Test
  func closingDisconnectsAndWaitsForAHostThatEndsWithTheSession() async throws {
    let shim = try FakeReplShim()
    let (hostFinishes, finishHost) = AsyncStream<Void>.makeStream()
    let run = Task<Void, any Error> {
      for await _ in hostFinishes {}
    }
    let (session, connection) = try await connect(to: shim, host: .testRun(run))

    async let closed: Void = session.close()
    await #expect(throws: (any Error).self) { try await connection.receive() }
    finishHost.finish()

    try await closed
  }

  private func connect(
    to shim: FakeReplShim,
    host: CodeInjectionHost.Host = .app,
    greeting: [String: Any] = ["type": "greeting"]
  ) async throws -> (CodeInjectionSession, FakeReplShim.Connection) {
    async let session = CodeInjectionSession.connect(to: CodeInjectionHost(socketPath: shim.path, host: host), timeout: 5)
    let connection = try await shim.accept()
    try connection.send(greeting)
    return (try await session, connection)
  }
}
