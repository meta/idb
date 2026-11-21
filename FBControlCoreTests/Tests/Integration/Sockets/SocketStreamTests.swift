/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@testable import FBControlCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SocketStreamTests {
  static func descriptors() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (descriptors[0], descriptors[1])
  }

  static func pair() throws -> (SocketStream, SocketStream) {
    let (first, second) = try descriptors()
    let left: SocketStream
    do { left = try SocketStream(adopting: first) } catch {
      Darwin.close(second)
      throw error
    }
    do { return (left, try SocketStream(adopting: second)) } catch {
      left.close()
      throw error
    }
  }

  static func read(_ socket: SocketStream, count: Int) async throws -> Data {
    var output = Data()
    while output.count < count {
      let data = try #require(try await socket.read(maxBytes: count - output.count))
      output.append(data)
    }
    return output
  }

  @Test
  func transfersBinaryRequestAndResponse() async throws {
    let (client, server) = try Self.pair()
    defer {
      client.close()
      server.close()
    }
    let request = Data([0, 255, 13, 10])
    async let exchange: Void = {
      #expect(try await Self.read(server, count: request.count) == request)
      try await server.write(Data("final response".utf8))
    }()
    try await client.write(request)
    #expect(try await Self.read(client, count: 14) == Data("final response".utf8))
    try await exchange
  }

  @Test
  func transfersLargeBinaryPayloadInBothDirections() async throws {
    let (client, server) = try Self.pair()
    defer {
      client.close()
      server.close()
    }
    let chunk = Data((0..<SocketStream.chunkSize).map { UInt8(truncatingIfNeeded: $0) })
    async let receivedByServer = Self.read(server, count: chunk.count * 32)
    async let receivedByClient = Self.read(client, count: chunk.count * 32)
    async let sendClient: Void = {
      for _ in 0..<32 { try await client.write(chunk) }
    }()
    async let sendServer: Void = {
      for _ in 0..<32 { try await server.write(chunk) }
    }()
    let (serverData, clientData, _, _) = try await (receivedByServer, receivedByClient, sendClient, sendServer)
    #expect(serverData == clientData)
    #expect(serverData == (0..<32).reduce(into: Data()) { output, _ in output.append(chunk) })
  }

  @Test
  func cancellationUnblocksAReadAndClosesTheConnection() async throws {
    let (client, server) = try Self.pair()
    defer {
      client.close()
      server.close()
    }
    let started = AsyncEvent<Void>()
    let read = Task {
      started.happen()
      return try await client.read()
    }
    try await started.wait()
    read.cancel()
    await #expect { try await read.value } throws: { $0 is CancellationError }
    #expect(try await server.read() == nil)
    await #expect { try await client.write(Data([1])) } throws: { ($0 as? POSIXError)?.code == .EBADF }
  }

  @Test
  func cancellationUnblocksAWriterWithAnUnreadPeer() async throws {
    let (client, server) = try Self.pair()
    defer {
      client.close()
      server.close()
    }
    let started = AsyncEvent<Void>()
    let write = Task {
      started.happen()
      while true { try await client.write(Data(repeating: 7, count: SocketStream.chunkSize)) }
    }
    try await started.wait()
    // The peer never reads. Let the writer fill its kernel buffer before cancelling.
    try await Task.sleep(for: .milliseconds(50))
    write.cancel()
    await #expect { try await write.value } throws: { $0 is CancellationError }
  }

  @Test
  func scopeClosesAnEscapedSocketAndIsIdempotent() async throws {
    let (descriptor, peer) = try Self.descriptors()
    let peerSocket = try SocketStream(adopting: peer)
    defer { peerSocket.close() }
    let escaped = try await SocketStream.withSocket(adopting: descriptor) { $0 }
    escaped.close()
    escaped.close()
    #expect(try await peerSocket.read() == nil)
    await #expect { try await escaped.read() } throws: { ($0 as? POSIXError)?.code == .EBADF }
  }

  @Test
  func scopeClosesTheSocketWhenTheBodyFails() async throws {
    struct Failed: Error {}
    let (descriptor, peer) = try Self.descriptors()
    let peerSocket = try SocketStream(adopting: peer)
    defer { peerSocket.close() }
    await #expect {
      try await SocketStream.withSocket(adopting: descriptor) { _ in throw Failed() }
    } throws: { $0 is Failed }
    #expect(try await peerSocket.read() == nil)
  }
}
