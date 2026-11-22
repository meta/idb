/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CompanionDiscovery
import Darwin
import Foundation
internal import NIOCore
internal import NIOPosix
internal import NIOSSL

/// Writes a diagnostic line to stderr. The server keeps stdout free for a host's
/// own protocol (e.g. idb2's `companion` subcommand prints the socket path on
/// stdout as a readiness handshake), so all server logging goes to stderr.
func companionServerLog(_ message: String) {
  try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

/// Where a `CompanionServer` listens.
///
/// `.domainSocket` binds the conventional `<udid>_companion.sock` path and is the
/// default. `.tcp` binds a TCP socket whose TLS is selected by `CompanionServerTLS`
/// (plaintext, an explicit certificate PEM, or the registered provider's identity).
/// TLS is expressed as paths/modes so the public API stays free of NIOSSL types.
public enum CompanionListenTarget: Sendable, Equatable {
  case domainSocket
  case tcp(host: String, port: Int, tls: CompanionServerTLS)
}

/// A companion server that listens on a Unix domain socket or a TCP socket and
/// accepts incoming JSON-RPC connections.
///
/// On `start()` it binds its `listen` target (default `.domainSocket`, the
/// conventional socket path for its `udid` under the selected `CompanionVersion`).
/// A `.domainSocket` server records itself in that version's `CompanionDiscovery`
/// registry, so a discoverer (e.g. `CompanionManager(version: .v2)`) finds it; a
/// `.tcp` server is reached by explicit address and is not registered. Incoming
/// connections are framed as newline-delimited JSON-RPC and handed to `onRequest`.
///
/// When `idleShutdownTime` is set, the server shuts itself down (closes its
/// listening channel) after that many seconds without a received request, so a
/// spawned companion does not outlive its use. A bare connection that sends
/// nothing (e.g. a discovery liveness probe) does not count as activity.
///
/// `@unchecked Sendable`: the mutable state (`channel`, `idleMonitor`) is guarded
/// by `stateLock`, so instances can be used across concurrency domains (e.g.
/// awaited from a `@MainActor` caller).
public final class CompanionServer: @unchecked Sendable {
  /// Invoked for every JSON-RPC request received on any connection. Awaited to
  /// completion (the idle countdown is paused for its duration); the returned
  /// response, if any, is written back to the client before the connection is
  /// closed. Return nil for a request that warrants no reply.
  public typealias RequestHandler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse?

  private let udid: String
  private let paths: CompanionPaths
  private let registry: CompanionRegistry
  private let onRequest: RequestHandler
  private let idleShutdownTime: TimeInterval?
  private let listen: CompanionListenTarget
  private let group: MultiThreadedEventLoopGroup
  private let stateLock = NSLock()
  private var _channel: Channel?
  private var channel: Channel? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _channel
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _channel = newValue
    }
  }
  private var _idleMonitor: IdleShutdownMonitor?
  private var idleMonitor: IdleShutdownMonitor? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _idleMonitor
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _idleMonitor = newValue
    }
  }
  /// The address the server actually bound, set by `start()`. `close()` reads it
  /// to clean up transport-specific state (only a domain socket has a file to
  /// unlink and a registry entry to remove).
  private var _boundAddress: CompanionAddress?
  private var boundAddress: CompanionAddress? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _boundAddress
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _boundAddress = newValue
    }
  }

  /// - Parameters:
  ///   - udid: the target the server fronts. Determines the conventional socket
  ///     path (`<udid>_companion.sock`) and the registry key.
  ///   - version: which companion generation to register under. Determines the
  ///     base directory for the socket and registry (see `CompanionPaths`).
  ///     Defaults to `.v2`.
  ///   - idleShutdownTime: if set, the server closes itself after this many
  ///     seconds without a received request. If nil (default), it runs until
  ///     explicitly closed.
  ///   - listen: where to bind. Defaults to `.domainSocket` (the conventional
  ///     path for `udid`). Use `.tcp` to bind a TCP socket, optionally with TLS.
  ///   - registry: the registry to record this server in. Defaults to one rooted
  ///     at `version`'s state file; pass an explicit registry to override it
  ///     (e.g. a test fixture with an isolated state file).
  ///   - onRequest: invoked for each received JSON-RPC request. Defaults to
  ///     printing the request.
  public init(
    udid: String,
    version: CompanionVersion = .v2,
    idleShutdownTime: TimeInterval? = nil,
    listen: CompanionListenTarget = .domainSocket,
    registry: CompanionRegistry? = nil,
    onRequest: RequestHandler? = nil
  ) {
    let paths = CompanionPaths(version: version)
    self.udid = udid
    self.paths = paths
    self.idleShutdownTime = idleShutdownTime
    self.listen = listen
    self.registry = registry ?? CompanionRegistry(stateFilePath: paths.stateFile)
    self.onRequest =
      onRequest ?? { request in
        companionServerLog("CompanionServer received \(request)")
        return nil
      }
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }

  /// Binds the configured `listen` target, starts accepting connections, and (for
  /// a domain socket) records the server in the registry. Returns the
  /// `CompanionInfo` describing the bound address.
  @discardableResult
  public func start() async throws -> CompanionInfo {
    let sslContext = try makeServerSSLContext()

    let monitor: IdleShutdownMonitor?
    if let idleShutdownTime {
      monitor = IdleShutdownMonitor(timeout: idleShutdownTime) { [weak self] in self?.handleIdleTimeout() }
    } else {
      monitor = nil
    }
    self.idleMonitor = monitor

    // Each received request runs in its own Task, bracketed by the idle monitor
    // so the countdown is paused while the request is processed and restarts at
    // the full timeout once it completes.
    let onRequest = self.onRequest
    let submit: @Sendable (JSONRPCRequest, Channel) -> Void = { request, channel in
      // Pause the idle countdown synchronously, as the request is read on the
      // event loop, so it cannot fire in the gap before the async task starts.
      monitor?.beginActivity()
      // Detached so the work is not tied to (and cannot be cancelled by) the
      // connection — the client keeps it open only to read the reply back.
      Task.detached {
        defer { monitor?.endActivity() }
        let response = await onRequest(request)
        if let response, let data = try? JSONEncoder().encode(response) {
          var buffer = ByteBufferAllocator().buffer(capacity: data.count + 1)
          buffer.writeBytes(data)
          buffer.writeInteger(UInt8(ascii: "\n"))
          try? await channel.writeAndFlush(buffer).get()
        }
        // One request per connection: close once the reply (if any) is sent.
        try? await channel.close().get()
      }
    }

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .childChannelInitializer { channel in
        var handlers: [ChannelHandler] = []
        // TLS, when configured, must come first so it decrypts before framing.
        if let sslContext {
          handlers.append(NIOSSLServerHandler(context: sslContext))
        }
        handlers.append(ByteToMessageHandler(NewlineFrameDecoder()))
        handlers.append(JSONRPCConnectionHandler(submit: submit))
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandlers(handlers)
        }
      }

    let boundAddress: CompanionAddress
    switch listen {
    case .domainSocket:
      let socketPath = paths.companionSocketPath(forUDID: udid)
      try prepareSocketPath(socketPath)
      let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
      self.channel = channel
      boundAddress = .domainSocket(path: socketPath)
    case let .tcp(host, port, _):
      let channel: Channel
      do {
        channel = try await bootstrap.bind(host: host, port: port).get()
      } catch {
        throw CompanionServerError.tcpBindFailed(host: host, port: port, underlying: error)
      }
      self.channel = channel
      // Resolve the bound port so an ephemeral bind (port 0) reports its choice.
      boundAddress = .tcp(host: host, port: channel.localAddress?.port ?? port)
    }
    self.boundAddress = boundAddress

    let info = CompanionInfo(
      udid: udid,
      isLocal: true,
      pid: ProcessInfo.processInfo.processIdentifier,
      address: boundAddress)
    // Only domain-socket companions are registered for discovery. A TCP companion
    // is reached by explicit address, and a `.tcp` registry entry can't be
    // liveness-probed (isAlive trusts it unconditionally), so recording one would
    // leave a stale "alive" entry behind.
    if case .domainSocket = boundAddress {
      try registry.add(info)
    }

    monitor?.start()

    let addressDescription: String
    switch boundAddress {
    case let .domainSocket(path): addressDescription = path
    case let .tcp(host, port): addressDescription = "\(host):\(port)"
    }
    companionServerLog("CompanionServer listening on \(addressDescription) for udid \(udid)")
    return info
  }

  /// Closes the listening channel when the idle monitor fires. `waitUntilClosed()`
  /// then returns, and the owner is expected to call `close()` to deregister and
  /// clean up.
  private func handleIdleTimeout() {
    companionServerLog("CompanionServer idle for \(Int(idleShutdownTime ?? 0))s; shutting down")
    channel?.close(promise: nil)
  }

  /// Suspends until the server's listening channel is closed.
  public func waitUntilClosed() async throws {
    guard let channel else {
      throw CompanionServerError.notStarted
    }
    try await channel.closeFuture.get()
  }

  /// Stops accepting connections, and (for a domain socket) deregisters from the
  /// registry and removes the socket file, then shuts down the event loop group.
  public func close() async throws {
    idleMonitor?.stop()
    idleMonitor = nil
    if let channel {
      try? await channel.close().get()
      self.channel = nil
    }
    // Mirror start(): only a domain-socket companion was registered and has a
    // socket file to remove. A TCP companion left both untouched.
    if case let .domainSocket(path)? = boundAddress {
      _ = try? registry.remove(udid: udid)
      unlink(path)
    }
    try await shutdownGroup()
  }

  // MARK: - Helpers

  /// Builds the TLS context for a TCP listen, or nil for plaintext (always the case
  /// for a Unix domain socket, for `.disabled`, or for `.metaIdentity` when no
  /// provider is registered). The identity's PEM(s) supply the certificate chain
  /// and private key. TLS is server-auth only: clients are not asked for a cert.
  private func makeServerSSLContext() throws -> NIOSSLContext? {
    guard case let .tcp(_, _, tls) = listen else {
      return nil
    }
    let identity: CompanionTLSIdentity
    switch tls {
    case .disabled:
      return nil
    case let .certificate(path):
      identity = CompanionTLSIdentity(combinedPEMPath: path)
    case .metaIdentity:
      guard let serverIdentity = CompanionTLS.provider?.serverIdentity() else {
        return nil
      }
      identity = serverIdentity
    }
    do {
      let certificates = try NIOSSLCertificate.fromPEMFile(identity.certificateChainPath).map { NIOSSLCertificateSource.certificate($0) }
      var configuration = TLSConfiguration.makeServerConfiguration(
        certificateChain: certificates,
        privateKey: .privateKey(try NIOSSLPrivateKey(file: identity.privateKeyPath, format: .pem)))
      // NIOSSL defaults the floor to TLS 1.0; pin it to 1.2 so the deprecated
      // TLS 1.0/1.1 protocols and their legacy cipher suites are never negotiated.
      configuration.minimumTLSVersion = .tlsv12
      return try NIOSSLContext(configuration: configuration)
    } catch {
      throw CompanionServerError.tlsCertificateLoadFailed(path: identity.certificateChainPath, underlying: error)
    }
  }

  /// Ensures the base directory exists and clears a stale socket file: only an
  /// existing *socket* is unlinked, so a real file at the path is never clobbered.
  private func prepareSocketPath(_ path: String) throws {
    try paths.ensureBaseDirectory()
    var info = stat()
    guard stat(path, &info) == 0 else {
      return // nothing there (or unreadable); bind will surface any real error
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
      throw CompanionServerError.socketPathOccupied(path: path)
    }
    unlink(path)
  }

  private func shutdownGroup() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      group.shutdownGracefully { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

/// Errors raised while starting or running a `CompanionServer`.
public enum CompanionServerError: Error, CustomStringConvertible {
  /// A non-socket file already exists where the server wants to bind.
  case socketPathOccupied(path: String)
  /// An operation requiring a running server was called before `start()`.
  case notStarted
  /// The TLS certificate PEM at the given path could not be loaded.
  case tlsCertificateLoadFailed(path: String, underlying: Error)
  /// Binding the TCP listening socket failed.
  case tcpBindFailed(host: String, port: Int, underlying: Error)

  public var description: String {
    switch self {
    case let .socketPathOccupied(path):
      return "A non-socket file already exists at the companion socket path: \(path)"
    case .notStarted:
      return "The companion server has not been started"
    case let .tlsCertificateLoadFailed(path, underlying):
      return "Failed to load the TLS certificate at \(path): \(underlying)"
    case let .tcpBindFailed(host, port, underlying):
      return "Failed to bind the companion TCP socket at \(host):\(port): \(underlying)"
    }
  }
}
