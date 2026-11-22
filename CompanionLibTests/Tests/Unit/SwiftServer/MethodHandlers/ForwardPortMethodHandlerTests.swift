/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ForwardPortMethodHandlerTests {
  private struct ObservedRequestStream: AsyncSequence, Sendable {
    let stream: AsyncThrowingStream<Idb_ForwardPortRequest, any Error>
    let readStarted: AsyncEvent<Void>

    struct AsyncIterator: AsyncIteratorProtocol {
      var iterator: AsyncThrowingStream<Idb_ForwardPortRequest, any Error>.AsyncIterator
      let readStarted: AsyncEvent<Void>

      mutating func next() async throws -> Idb_ForwardPortRequest? {
        readStarted.happen()
        return try await iterator.next()
      }
    }

    func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(iterator: stream.makeAsyncIterator(), readStarted: readStarted)
    }
  }

  private static func pair() throws -> (SocketStream, SocketStream) {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let first: SocketStream
    do { first = try SocketStream(adopting: descriptors[0]) } catch {
      close(descriptors[1])
      throw error
    }
    do { return (first, try SocketStream(adopting: descriptors[1])) } catch {
      first.close()
      throw error
    }
  }

  @Test
  func validatesOpeningAndPortPolicyBeforeConnecting() throws {
    #expect(try ForwardPortMethodHandler.parseAllowedPorts(nil) == [])
    #expect(try ForwardPortMethodHandler.parseAllowedPorts("") == [])
    #expect(try ForwardPortMethodHandler.parseAllowedPorts("8099, 8100") == [8099, 8100])
    for value in [
      "0", "65536", "8099,", "no", "*", " \t* \t", "*,8099", "8099,*", "*,",
      "0-65535", "1-65536", "8100-8000", "1--2", "1-2-3", "-1", "1-",
      "8000-8100,", "8099,1-65536", "1-2,no", "*,1-65535", "1-65535,*",
    ] {
      #expect(throws: RPCError.self) { try ForwardPortMethodHandler.parseAllowedPorts(value) }
    }
    for port in [UInt32(0), UInt32(65536), UInt32.max] {
      #expect(throws: RPCError.self) {
        try ForwardPortMethodHandler.openingPort(.with { $0.open.port = port }, allowedPorts: [])
      }
    }
    #expect(throws: RPCError.self) {
      try ForwardPortMethodHandler.openingPort(.with { $0.data = Data([1]) }, allowedPorts: [])
    }
    #expect(try ForwardPortMethodHandler.openingPort(.with { $0.open.port = 8099 }, allowedPorts: [8099]) == 8099)
    do {
      _ = try ForwardPortMethodHandler.openingPort(.with { $0.open.port = 8100 }, allowedPorts: [8099])
      Issue.record("Disallowed port was accepted")
    } catch let error as RPCError {
      #expect(error.code == .permissionDenied)
    }
  }

  @Test
  func fullRangePolicyAllowsEveryValidPort() throws {
    for policy in ["1-65535", " 1 - 65535 "] {
      let allowedPorts = try ForwardPortMethodHandler.parseAllowedPorts(policy)
      #expect(allowedPorts.count == Int(UInt16.max))
      #expect(!allowedPorts.contains(0))
      #expect((UInt16(1)...UInt16.max).allSatisfy { allowedPorts.contains($0) })
    }
  }

  @Test
  func rangePolicyCombinesInclusiveRangesAndIndividualPorts() throws {
    for policy in [
      "8000-8002,8002-8004,8001,9000-9000,65534-65535,8000-8002",
      "65534-65535,9000-9000,8002-8004,8000-8002,8001",
      " 8000 - 8002, 8002 - 8004, 8001, 9000 - 9000, 65534 - 65535 ",
    ] {
      #expect(try ForwardPortMethodHandler.parseAllowedPorts(policy) == [8000, 8001, 8002, 8003, 8004, 9000, 65534, 65535])
    }
  }

  @Test
  func fullRangePolicyValidatesOpeningBeforeConnecting() async throws {
    let allowedPorts = try ForwardPortMethodHandler.parseAllowedPorts("1-65535")
    for requestedPort in [UInt32(1), 8099, 65535] {
      var connectionAttempts = 0
      let port = try await ForwardPortMethodHandler.withAllowedPort(
        from: Self.openingRequest(port: requestedPort), allowedPorts: allowedPorts
      ) { port in
        connectionAttempts += 1
        return port
      }
      #expect(UInt32(port) == requestedPort)
      #expect(connectionAttempts == 1)
    }
    for requestedPort in [UInt32(0), 65536, UInt32.max] {
      var connectionAttempts = 0
      let error = await #expect(throws: RPCError.self) {
        try await ForwardPortMethodHandler.withAllowedPort(
          from: Self.openingRequest(port: requestedPort), allowedPorts: allowedPorts
        ) { _ in
          connectionAttempts += 1
        }
      }
      #expect(error?.code == .invalidArgument)
      #expect(connectionAttempts == 0)
    }
    for request in [Idb_ForwardPortRequest(), .with { $0.data = Data([1]) }] {
      let error = #expect(throws: RPCError.self) {
        try ForwardPortMethodHandler.openingPort(request, allowedPorts: allowedPorts)
      }
      #expect(error?.code == .invalidArgument)
    }
  }

  @Test
  func deniedPoliciesNeverAttemptADeviceConnection() async throws {
    for policy: String? in [nil, "", "8100", "8090-8098,8100-8102"] {
      let allowedPorts = try ForwardPortMethodHandler.parseAllowedPorts(policy)
      var connectionAttempts = 0
      let error = await #expect(throws: RPCError.self) {
        try await ForwardPortMethodHandler.withAllowedPort(
          from: Self.openingRequest(port: 8099), allowedPorts: allowedPorts
        ) { _ in
          connectionAttempts += 1
        }
      }
      #expect(error?.code == .permissionDenied)
      #expect(connectionAttempts == 0)
    }
  }

  @Test
  func explicitPolicyPassesTheRequestedPortToTheConnection() async throws {
    for policy in ["8099,8100", "8099-8100"] {
      let allowedPorts = try ForwardPortMethodHandler.parseAllowedPorts(policy)
      for requestedPort in [UInt32(8099), 8100] {
        var connectionAttempts = 0
        let port = try await ForwardPortMethodHandler.withAllowedPort(
          from: Self.openingRequest(port: requestedPort), allowedPorts: allowedPorts
        ) { port in
          connectionAttempts += 1
          return port
        }
        #expect(UInt32(port) == requestedPort)
        #expect(connectionAttempts == 1)
      }
    }
  }

  private static func openingRequest(port: UInt32) -> RequestStreamReader<Idb_ForwardPortRequest> {
    let stream = AsyncThrowingStream<Idb_ForwardPortRequest, any Error> { continuation in
      continuation.yield(.with { $0.open.port = port })
      continuation.finish()
    }
    return RequestStreamReader(RPCAsyncSequence(wrapping: stream))
  }

  @Test
  func clientEOFStillReceivesTheDevicesFinalResponse() async throws {
    let (socket, peer) = try Self.pair()
    defer {
      socket.close()
      peer.close()
    }
    let requests = AsyncThrowingStream<Idb_ForwardPortRequest, any Error> { continuation in
      continuation.yield(.with { $0.data = Data([0, 255]) })
      continuation.yield(.with { $0.data = Data() })
      continuation.finish()
    }
    let (responses, output) = AsyncStream<Idb_ForwardPortResponse>.makeStream()
    let responseReceived = AsyncEvent<Void>()
    async let pipe: Void = ForwardPortMethodHandler.pipe(socket: socket, requests: requests) { response in
      output.yield(response)
      responseReceived.happen()
    }
    var input = Data()
    while input.count < 2 {
      input.append(try #require(try await peer.read(maxBytes: 2 - input.count)))
    }
    #expect(input == Data([0, 255]))
    try await peer.write(Data([1, 2, 3]))
    try await responseReceived.wait()
    peer.close()
    try await pipe
    output.finish()
    var received = Data()
    for await response in responses {
      switch response.event {
      case let .data(data): received.append(data)
      case .opened, .none: Issue.record("Unexpected response")
      }
    }
    #expect(received == Data([1, 2, 3]))
  }

  @Test
  func deviceEOFCancelsTheBlockedRequestReader() async throws {
    let (socket, peer) = try Self.pair()
    defer {
      socket.close()
      peer.close()
    }
    let (requests, input) = AsyncThrowingStream<Idb_ForwardPortRequest, any Error>.makeStream()
    let readStarted = AsyncEvent<Void>()
    let inputEnded = AsyncEvent<Bool>()
    input.onTermination = { termination in
      switch termination {
      case .cancelled: inputEnded.happen(true)
      case .finished: inputEnded.happen(false)
      }
    }
    defer { input.finish() }
    let reader = RequestStreamReader(RPCAsyncSequence(wrapping: ObservedRequestStream(stream: requests, readStarted: readStarted)))
    async let pipe: Void = ForwardPortMethodHandler.pipe(socket: socket, requests: reader) { _ in
      Issue.record("Unexpected response")
    }
    try await readStarted.wait()
    #expect(!inputEnded.hasHappened)
    peer.close()
    try await pipe
    #expect(try await inputEnded.wait())
  }

  @Test
  func clientEOFReportsDrainTimeoutAndClosesTheSocket() async throws {
    let (socket, peer) = try Self.pair()
    defer {
      socket.close()
      peer.close()
    }
    let requests = AsyncThrowingStream<Idb_ForwardPortRequest, any Error> { input in
      input.yield(.with { $0.data = Data([7, 8]) })
      input.finish()
    }
    let pipe = Task {
      try await ForwardPortMethodHandler.pipe(
        socket: socket, requests: requests, drainTimeout: .milliseconds(20)
      ) { _ in Issue.record("Unexpected response") }
    }
    var received = Data()
    while let data = try await peer.read() { received.append(data) }
    let error = await #expect(throws: RPCError.self) { try await pipe.value }
    #expect(error?.code == .deadlineExceeded)
    #expect(error?.message.contains("Device response drain exceeded") == true)
    #expect(received == Data([7, 8]))
  }

  @Test
  func invalidInputCancelsTheBlockedSocketReader() async throws {
    for request in [
      Idb_ForwardPortRequest.with { $0.open.port = 8099 },
      Idb_ForwardPortRequest.with { $0.data = Data(repeating: 1, count: SocketStream.chunkSize + 1) },
      Idb_ForwardPortRequest(),
    ] {
      let (socket, peer) = try Self.pair()
      defer {
        socket.close()
        peer.close()
      }
      let requests = AsyncThrowingStream<Idb_ForwardPortRequest, any Error> { continuation in
        continuation.yield(request)
        continuation.finish()
      }
      await #expect {
        try await ForwardPortMethodHandler.pipe(socket: socket, requests: requests) { _ in }
      } throws: { $0 is RPCError }
      #expect(try await peer.read() == nil)
    }
  }

  @Test
  func responseFailureCancelsTheBlockedRequestReader() async throws {
    struct Failed: Error {}
    let (socket, peer) = try Self.pair()
    defer {
      socket.close()
      peer.close()
    }
    let (requests, input) = AsyncThrowingStream<Idb_ForwardPortRequest, any Error>.makeStream()
    defer { input.finish() }
    try await peer.write(Data([1]))
    await #expect {
      try await ForwardPortMethodHandler.pipe(socket: socket, requests: requests) { _ in throw Failed() }
    } throws: { $0 is Failed }
    #expect(try await peer.read() == nil)
  }
}
