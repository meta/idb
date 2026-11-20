/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A process on a Simulator with the shim injected, and the connection that runs code in it.
///
/// Code is injected as a compiled dylib: the host loads it and calls an exported entry point that
/// takes no arguments and returns a `malloc`'d C string, which the host frees. Compiling the dylib
/// is the caller's.
public final class CodeInjectionSession: Sendable {

  /// Answers a command the injected code sends back to the session mid-execute, as opaque bytes.
  /// The injected code receives the bytes returned, or the description of the error.
  public typealias HostCommandHandler = @Sendable (_ command: Data) async -> Result<Data, any Error>

  /// Identifies the host process: the same when reattaching to an app still running from an
  /// earlier session, and new when the host is relaunched.
  public let sessionID: String

  /// `.swiftinterface` files the host generated for its own modules, so code compiled to inject
  /// can import them. Empty when it generates none.
  public let generatedInterfacePaths: [String]

  /// Where the host serves the session.
  @_spi(IDBRepl) public let socketPath: String

  /// The run index the host numbers the next injected dylib from, persisted by an app across
  /// sessions.
  @_spi(IDBRepl) public let nextRunIndex: UInt32

  private let host: CodeInjectionHost
  private let client: ControlSocketClient

  init(host: CodeInjectionHost, client: ControlSocketClient, greeting: ControlSocketClient.Greeting) {
    self.host = host
    self.client = client
    self.sessionID = greeting.sessionID
    self.generatedInterfacePaths = greeting.interfaces
    self.socketPath = host.socketPath
    self.nextRunIndex = greeting.nextRunIndex
  }

  static func connect(to host: CodeInjectionHost, timeout: TimeInterval) async throws -> CodeInjectionSession {
    let client = try await ControlSocketClient.connect(path: host.socketPath, timeout: timeout)
    do {
      let greeting = try await client.readGreeting()
      return CodeInjectionSession(host: host, client: client, greeting: greeting)
    } catch {
      client.close()
      throw error
    }
  }

  /// Has the host load the dylib at `dylibAtPath` and call its entry point `symbol`, returning the
  /// string it returns. Throws `CodeInjectionError.executionFailed` when the host cannot run it.
  /// While the code runs it can send commands back, which `hostCommands` answers; without a
  /// handler, each is refused with `CodeInjectionError.hostCommandsUnsupported`.
  public func execute(dylibAtPath dylibPath: String, symbol: String, hostCommands: HostCommandHandler? = nil) async throws -> String {
    try await run(dylibAtPath: dylibPath, symbol: symbol, hostCommands: hostCommands).result.get()
  }

  /// As `execute`, with the run index the host numbers the next dylib from.
  @_spi(IDBRepl) public func run(dylibAtPath dylibPath: String, symbol: String, hostCommands: HostCommandHandler? = nil) async throws -> (result: Result<String, CodeInjectionError>, nextRunIndex: Int32) {
    let handler: ControlSocketClient.HostCommandHandler = { command in
      guard let hostCommands else {
        return .failure(CodeInjectionError.hostCommandsUnsupported)
      }
      return await hostCommands(command)
    }
    let (outcome, nextRunIndex) = try await client.run(dylibPath: dylibPath, symbol: symbol, hostCommandHandler: handler)
    return (outcome.mapError { CodeInjectionError.executionFailed(message: $0.message) }, nextRunIndex)
  }

  /// Ends the session. Closing the connection ends the host's session; a host that exits with it --
  /// the guest bridge, or a logic test -- is waited for, and an app keeps running for the next one.
  /// A session that is dropped closes its connection without waiting.
  public func close() async throws {
    client.close()
    try await host.waitForHostToFinish()
  }

  deinit {
    client.close()
  }
}
