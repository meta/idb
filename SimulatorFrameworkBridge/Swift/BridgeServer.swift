/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
internal import SimulatorIPC

/// Frames a response goes on writing after its request, until it ends or the peer goes away.
public protocol BridgeResponseStream: AnyObject {
  /// Whether the stream ended because its source failed rather than because it was cancelled.
  var failed: Bool { get }
  /// Runs on the serving thread until the stream ends, writing each frame through `emit`, which answers
  /// false once a frame could not be written. The connection closes when this returns.
  func run(emit: @escaping (Data) -> Bool)
  /// Asks a running stream to end. Called from another thread, once, when the peer sends anything or
  /// disconnects; `run` must return promptly afterwards.
  func cancel()
}

public extension BridgeResponseStream {
  var failed: Bool { false }
}

public enum BridgeSocketResponse {
  case frame(data: Data, shutdown: Bool)
  case stream(any BridgeResponseStream)

  /// The one frame this response writes, or nil when it streams.
  public var frame: (data: Data, shutdown: Bool)? {
    guard case let .frame(data, shutdown) = self else { return nil }
    return (data, shutdown)
  }
}

public enum BridgeServer {
  public static let defaultIdleTimeoutSeconds: Int32 = 300
  public static let serveBacklog: Int32 = 16
  public static func pollTimeoutMilliseconds(seconds: Int32) -> Int32 {
    Int32(clamping: Int64(max(1, seconds)) * 1000)
  }

  /// Runs synchronously; runtime preparation and request handling stay on the caller's thread.
  public static func serve(
    socketPath: String,
    idleTimeoutSeconds: Int32,
    exitOnDisconnect: Bool,
    prepareRuntime: () -> Void,
    handleRequest: (Data) -> BridgeSocketResponse
  ) -> Int32 {
    serve(
      socketPath: socketPath,
      idleTimeoutSeconds: idleTimeoutSeconds,
      initialClientTimeoutSeconds: nil,
      exitOnDisconnect: exitOnDisconnect,
      prepareRuntime: prepareRuntime,
      handleRequest: handleRequest
    )
  }

  public static func serve(
    socketPath: String,
    idleTimeoutSeconds: Int32,
    initialClientTimeoutSeconds: Int32?,
    exitOnDisconnect: Bool,
    prepareRuntime: () -> Void,
    handleRequest: (Data) -> BridgeSocketResponse
  ) -> Int32 {
    let server: IPCListener
    do {
      guard let bound = try IPCListener.bind(path: socketPath, backlog: serveBacklog) else { return 0 }
      server = bound
    } catch {
      NSLog("[BridgeServer] could not serve on %@: %@", socketPath, String(describing: error))
      return 1
    }
    let listenFD = server.fileDescriptor
    return withExtendedLifetime(server) {
      prepareRuntime()
      var initialClientDeadline = initialClientTimeoutSeconds.map {
        ProcessInfo.processInfo.systemUptime + Double(max(1, $0))
      }
      NSLog("[BridgeServer] serving on %@ (idle timeout %ds)", socketPath, idleTimeoutSeconds)
      while true {
        var listener = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let timeout: Int32
        if let initialClientDeadline {
          let remaining = initialClientDeadline - ProcessInfo.processInfo.systemUptime
          guard remaining > 0 else { break }
          timeout = Int32(clamping: Int64(ceil(remaining * 1000)))
        } else {
          timeout = pollTimeoutMilliseconds(seconds: idleTimeoutSeconds)
        }
        let ready = unsafe poll(&listener, 1, timeout)
        if ready == 0 {
          if initialClientDeadline != nil {
            NSLog("[BridgeServer] initial client timeout; exiting")
          } else {
            NSLog("[BridgeServer] idle %ds with no client; exiting", idleTimeoutSeconds)
          }
          break
        }
        if ready < 0 {
          if errno == EINTR { continue }
          break
        }
        let connection = accept(listenFD, nil, nil)
        if connection < 0 {
          if errno == EINTR { continue }
          break
        }
        initialClientDeadline = nil
        let shutdown = serveConnection(connection, idleTimeoutSeconds: idleTimeoutSeconds, handleRequest: handleRequest)
        close(connection)
        if exitOnDisconnect {
          NSLog("[BridgeServer] exclusive client disconnected; exiting")
          break
        }
        if shutdown {
          NSLog("[BridgeServer] shutdown requested by client; exiting")
          break
        }
      }
      return 0
    }
  }

  private enum ConnectionStep {
    case next, disconnected, shutdown
  }

  private static func serveConnection(
    _ connection: Int32,
    idleTimeoutSeconds: Int32,
    handleRequest: (Data) -> BridgeSocketResponse
  ) -> Bool {
    IPCSocket.setTimeout(connection, seconds: Int(idleTimeoutSeconds))
    while true {
      let step: ConnectionStep = autoreleasepool {
        guard let request = try? IPCSocket.readFrame(connection) else { return .disconnected }
        switch handleRequest(request) {
        case let .frame(data, shutdown):
          guard (try? IPCSocket.writeFrame(connection, data)) != nil else { return .disconnected }
          return shutdown ? .shutdown : .next
        case let .stream(stream):
          serveStream(stream, on: connection)
          return .disconnected
        }
      }
      switch step {
      case .next: continue
      case .disconnected: return false
      case .shutdown: return true
      }
    }
  }

  /// A peer has nothing to say mid-stream, so anything readable — a byte or end-of-file — ends it.
  private static func serveStream(_ stream: any BridgeResponseStream, on connection: Int32) {
    let watcher = DispatchSource.makeReadSource(fileDescriptor: connection, queue: .global())
    let watcherCancelled = DispatchSemaphore(value: 0)
    watcher.setEventHandler {
      watcher.cancel()
      stream.cancel()
    }
    watcher.setCancelHandler { watcherCancelled.signal() }
    watcher.resume()
    stream.run { (try? IPCSocket.writeFrame(connection, $0)) != nil }
    watcher.cancel()
    // The descriptor must stay open until the source has let go of it.
    watcherCancelled.wait()
  }
}
