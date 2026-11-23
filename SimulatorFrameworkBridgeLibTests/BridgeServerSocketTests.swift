/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeSupport
import SimulatorIPC
import XCTest
import os

final class BridgeServerSocketTests: XCTestCase {
  var socketPath = ""
  var finished: XCTestExpectation?

  override func tearDown() {
    if finished != nil {
      finishServer()
    }
    super.tearDown()
  }

  static func serve(_ path: String, exclusive: Bool, idleTimeoutSeconds: Int32 = 10) -> Int32 {
    BridgeServer.serve(socketPath: path, idleTimeoutSeconds: idleTimeoutSeconds, exitOnDisconnect: exclusive, prepareRuntime: {}) {
      BridgeRPC.handle($0)
    }
  }

  func startServerExclusive(exclusive: Bool, idleTimeoutSeconds: Int32 = 10) {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "server exits")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      XCTAssertEqual(Self.serve(path, exclusive: exclusive, idleTimeoutSeconds: idleTimeoutSeconds), 0)
      finished.fulfill()
    }
  }

  func finishServer() {
    if let finished {
      wait(for: [finished], timeout: 15)
    } else {
      XCTFail("server was not started")
    }
    finished = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    try? FileManager.default.removeItem(atPath: socketPath + ".lock")
  }

  func connectClient() -> Int32 {
    Self.connectClient(to: socketPath)
  }

  static func connectClient(to socketPath: String) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { path in
      path.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
        socketPath.withCString { source in
          _ = strlcpy(bytes, source, capacity)
        }
      }
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      if fd < 0 {
        XCTFail("socket failed")
        return -1
      }
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if connected == 0 {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
      }
      close(fd)
      usleep(1000)
    } while deadline.timeIntervalSinceNow > 0
    XCTFail("server did not accept a client")
    return -1
  }

  static func header(forLength length: UInt32) -> Data {
    Data([
      UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
  }

  static func frame(payload: String) -> Data {
    let data = Data(payload.utf8)
    var frame = Self.header(forLength: UInt32(data.count))
    frame.append(data)
    return frame
  }

  static func frame(command: BridgeCommand) throws -> Data {
    let bytes = try BridgeRequest(command: command).encoded()
    var frame = try IPCFrame.header(forSize: bytes.count)
    frame.append(bytes)
    return frame
  }

  /// The accessibility request these flat parameters spell, sent as a host sends it.
  static func frame(accessibility parameters: [String: Any]) throws -> Data {
    try Self.frame(command: .accessibility(AccessibilityParameters.request(parameters)))
  }

  static func exitCode(of response: NSDictionary?) -> Int? {
    (response?["result"] as? NSDictionary)?["exitCode"] as? Int
  }

  static func sendData(data: Data, to fd: Int32) {
    data.withUnsafeBytes { buffer in
      guard let bytes = buffer.baseAddress else { return }
      var offset = 0
      while offset < data.count {
        let count = send(fd, bytes.advanced(by: offset), data.count - offset, MSG_NOSIGNAL)
        XCTAssertGreaterThan(count, 0)
        if count <= 0 { return }
        offset += count
      }
    }
  }

  static func readBytes(length: Int, from fd: Int32) -> Data? {
    var data = Data(count: length)
    let complete = data.withUnsafeMutableBytes { buffer in
      guard let bytes = buffer.baseAddress else { return length == 0 }
      var offset = 0
      while offset < length {
        let count = recv(fd, bytes.advanced(by: offset), length - offset, 0)
        if count <= 0 {
          XCTFail("response ended before \(length) bytes")
          return false
        }
        offset += count
      }
      return true
    }
    return complete ? data : nil
  }

  static func readResponse(fd: Int32) -> NSDictionary? {
    guard let header = Self.readBytes(length: 4, from: fd) else { return nil }
    let length = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
    if length == 0 || length > 16 * 1024 * 1024 {
      XCTFail("invalid response length \(length)")
      return nil
    }
    guard let data = Self.readBytes(length: Int(length), from: fd) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
  }

  static func assertEOF(fd: Int32, file: StaticString = #filePath, line: UInt = #line) {
    var byte: UInt8 = 0
    let received = recv(fd, &byte, 1, 0)
    let error = errno
    XCTAssertEqual(
      received, 0, received < 0 ? "recv failed: \(String(cString: strerror(error)))" : "the server sent more",
      file: file, line: line)
  }

  func testAnotherStarterCannotUnlinkTheLiveListener() throws {
    startServerExclusive(exclusive: false)
    close(connectClient())
    XCTAssertEqual(Self.serve(socketPath, exclusive: false, idleTimeoutSeconds: 1), 0)
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: try Self.frame(command: .shutdown), to: client)
    XCTAssertEqual(Self.exitCode(of: Self.readResponse(fd: client)), 0)
    finishServer()
  }

  func testLargeIdleTimeoutCannotOverflowToAnUnboundedPoll() {
    XCTAssertEqual(BridgeServer.pollTimeoutMilliseconds(seconds: 300), 300_000)
    XCTAssertEqual(BridgeServer.pollTimeoutMilliseconds(seconds: .max), .max)
    XCTAssertGreaterThan(BridgeServer.pollTimeoutMilliseconds(seconds: 0), 0)
  }

  func testRPCHandlesMixedServicesAndMalformedRequestsOnOneConnection() throws {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "RPC server exits")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      XCTAssertEqual(
        BridgeServer.serve(socketPath: path, idleTimeoutSeconds: 5, exitOnDisconnect: true, prepareRuntime: {}) { data in
          BridgeRPC.handle(data) { command in
            BridgeResult(exitCode: command == .shutdown ? 0 : 23, answers: [.health(.clear(bundleID: "first", ok: true, error: nil)), .health(.clear(bundleID: "second", ok: true, error: nil))])
          }
        }, 0)
      finished.fulfill()
    }
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: Self.frame(payload: "malformed"), to: client)
    XCTAssertEqual((Self.readResponse(fd: client)?["result"] as? NSDictionary)?["exitCode"] as? Int, 1)
    let commands: [BridgeCommand] = [.dns(.list), .proxy(.clear), .health(.list(bundleID: "app")), .notifications(.delivered(bundleID: "app")), .clearContacts, .clearPhotos, .accessibility(.displays), .shutdown]
    for command in commands {
      let request = BridgeRequest(command: command)
      let bytes = try request.encoded()
      Self.sendData(data: try IPCFrame.header(forSize: bytes.count), to: client)
      Self.sendData(data: bytes, to: client)
      let object = try XCTUnwrap(Self.readResponse(fd: client))
      let response = try BridgeResponse.decode(JSONSerialization.data(withJSONObject: object), for: request)
      XCTAssertEqual(response.result, BridgeResult(exitCode: command == .shutdown ? 0 : 23, answers: [.health(.clear(bundleID: "first", ok: true, error: nil)), .health(.clear(bundleID: "second", ok: true, error: nil))]))
    }
    Self.assertEOF(fd: client)
    finishServer()
  }

  func testStalledReaderCannotHoldTheServerPastItsSendDeadline() {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "stalled writer exits")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      XCTAssertEqual(
        BridgeServer.serve(socketPath: path, idleTimeoutSeconds: 1, exitOnDisconnect: true, prepareRuntime: {}) { _ in
          BridgeSocketResponse.frame(data: Data(repeating: 120, count: IPCFrame.maximumSize), shutdown: false)
        }, 0)
      finished.fulfill()
    }
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: Self.frame(payload: "request"), to: client)
    wait(for: [finished], timeout: 5)
    self.finished = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    try? FileManager.default.removeItem(atPath: socketPath + ".lock")
  }

  func testFragmentedFramesAndShutdownResponseOnOneConnection() throws {
    startServerExclusive(exclusive: true)
    let client = connectClient()
    for (frame, expectedExitCode) in [(Self.frame(payload: "not json"), 1), (try Self.frame(command: .shutdown), 0)] {
      for index in 0..<frame.count {
        Self.sendData(data: frame.subdata(in: index..<(index + 1)), to: client)
        usleep(1000)
      }
      XCTAssertEqual(Self.exitCode(of: Self.readResponse(fd: client)), expectedExitCode)
    }
    Self.assertEOF(fd: client)
    close(client)
    finishServer()
  }

  func testInvalidFrameLengthsCloseTheConnection() {
    for length: UInt32 in [0, 16 * 1024 * 1024 + 1] {
      startServerExclusive(exclusive: true)
      let client = connectClient()
      Self.sendData(data: Self.header(forLength: length), to: client)
      Self.assertEOF(fd: client)
      close(client)
      finishServer()
    }
  }

  func testTruncatedHeaderAndPayloadCloseTheConnection() throws {
    let frame = try Self.frame(command: .shutdown)
    for length in [1, 6] {
      startServerExclusive(exclusive: true)
      let client = connectClient()
      Self.sendData(data: frame.subdata(in: 0..<length), to: client)
      shutdown(client, SHUT_WR)
      Self.assertEOF(fd: client)
      close(client)
      finishServer()
    }
  }

  func testSharedServerAcceptsAnotherClientAfterDisconnect() throws {
    startServerExclusive(exclusive: false)
    var client = connectClient()
    close(client)
    client = connectClient()
    Self.sendData(data: try Self.frame(command: .shutdown), to: client)
    XCTAssertEqual(Self.exitCode(of: Self.readResponse(fd: client)), 0)
    Self.assertEOF(fd: client)
    close(client)
    finishServer()
  }

  func testExclusiveServerExitsAfterDisconnect() {
    startServerExclusive(exclusive: true)
    close(connectClient())
    finishServer()
  }

  func testIdleClientTimesOutAndCloses() {
    startServerExclusive(exclusive: true, idleTimeoutSeconds: 3)
    let client = connectClient()
    Self.sendData(data: Self.header(forLength: 10), to: client)
    Self.assertEOF(fd: client)
    close(client)
    finishServer()
  }

  func testIdleListenerExitsAndRemovesItsSocket() {
    startServerExclusive(exclusive: false, idleTimeoutSeconds: 1)
    finishServer()
  }

  func startServerWithInitialTimeout() {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "server exits")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      let result = BridgeServer.serve(
        socketPath: path,
        idleTimeoutSeconds: 30,
        initialClientTimeoutSeconds: 1,
        exitOnDisconnect: true,
        prepareRuntime: {}
      ) { _ in
        BridgeSocketResponse.frame(data: Data(#"{"ok":true}"#.utf8), shutdown: false)
      }
      XCTAssertEqual(result, 0)
      finished.fulfill()
    }
  }

  func testInitialClientTimeoutExitsWithoutWaitingForTheIdleTimeout() {
    startServerWithInitialTimeout()
    finishServer()
  }

  func testAcceptedClientKeepsTheIdleTimeoutAfterTheInitialDeadline() {
    startServerWithInitialTimeout()
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: Self.frame(payload: "probe"), to: client)
    XCTAssertEqual(Self.readResponse(fd: client), ["ok": true])
    var connection = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
    XCTAssertEqual(poll(&connection, 1, 2000), 0)
    Self.sendData(data: Self.frame(payload: "probe"), to: client)
    XCTAssertEqual(Self.readResponse(fd: client), ["ok": true])
    shutdown(client, SHUT_WR)
    Self.assertEOF(fd: client)
    finishServer()
  }

  func testOverlongSocketPathIsRejected() {
    let path = "/tmp/".padding(toLength: 200, withPad: "x", startingAt: 0)
    XCTAssertEqual(Self.serve(path, exclusive: true), 1)
  }

  func testRuntimeCallbacksStayOnTheCallingThread() {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "client receives shutdown response")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      let client = Self.connectClient(to: path)
      Self.sendData(data: Self.frame(payload: "probe"), to: client)
      XCTAssertEqual(Self.readResponse(fd: client), ["ok": true])
      Self.assertEOF(fd: client)
      close(client)
      finished.fulfill()
    }
    let callingThread = Thread.current
    var preparations = 0
    var requests = 0
    let result = BridgeServer.serve(socketPath: socketPath, idleTimeoutSeconds: 10, exitOnDisconnect: true) {
      XCTAssertEqual(Thread.current, callingThread)
      preparations += 1
    } handleRequest: { request in
      XCTAssertEqual(Thread.current, callingThread)
      XCTAssertEqual(preparations, 1)
      XCTAssertEqual(request, "probe".data(using: .utf8))
      requests += 1
      return BridgeSocketResponse.frame(data: Data("{\"ok\":true}".utf8), shutdown: true)
    }
    XCTAssertEqual(result, 0)
    XCTAssertEqual(preparations, 1)
    XCTAssertEqual(requests, 1)
    finishServer()
  }

  private func serveStream(_ stream: ScriptedStream) {
    socketPath = "/tmp/sfb-" + UUID().uuidString
    let finished = expectation(description: "stream server exits")
    self.finished = finished
    let path = socketPath
    DispatchQueue.global().async {
      XCTAssertEqual(
        BridgeServer.serve(socketPath: path, idleTimeoutSeconds: 5, exitOnDisconnect: true, prepareRuntime: {}) { _ in
          .stream(stream)
        }, 0)
      finished.fulfill()
    }
  }

  func testAStreamThatEndsWritesItsFramesThenCloses() throws {
    let stream = ScriptedStream(frames: 3, untilCancelled: false)
    serveStream(stream)
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: Self.frame(payload: "{}"), to: client)
    for index in 0..<3 {
      XCTAssertEqual(Self.readResponse(fd: client), ["index": index])
    }
    Self.assertEOF(fd: client)
    finishServer()
    XCTAssertFalse(stream.wasCancelled)
  }

  func testAClientHangingUpCancelsTheStream() throws {
    let stream = ScriptedStream(frames: 1, untilCancelled: true)
    serveStream(stream)
    let client = connectClient()
    Self.sendData(data: Self.frame(payload: "{}"), to: client)
    XCTAssertEqual(Self.readResponse(fd: client), ["index": 0])
    close(client)
    finishServer()
    XCTAssertTrue(stream.wasCancelled)
  }

  func testAClientSendingMidStreamCancelsTheStream() throws {
    let stream = ScriptedStream(frames: 1, untilCancelled: true)
    serveStream(stream)
    let client = connectClient()
    defer { close(client) }
    Self.sendData(data: Self.frame(payload: "{}"), to: client)
    XCTAssertEqual(Self.readResponse(fd: client), ["index": 0])
    Self.sendData(data: Self.frame(payload: "{}"), to: client)
    Self.assertEOF(fd: client)
    finishServer()
    XCTAssertTrue(stream.wasCancelled)
  }
}

private final class ScriptedStream: BridgeResponseStream, Sendable {
  private let frames: Int
  private let untilCancelled: Bool
  private let cancelled = DispatchSemaphore(value: 0)
  private let cancellation = OSAllocatedUnfairLock(initialState: false)

  var wasCancelled: Bool {
    cancellation.withLock { $0 }
  }

  init(frames: Int, untilCancelled: Bool) {
    self.frames = frames
    self.untilCancelled = untilCancelled
  }

  func run(emit: @escaping (Data) -> Bool) {
    for index in 0..<frames {
      guard let data = try? JSONSerialization.data(withJSONObject: ["index": index]), emit(data) else { return }
    }
    if untilCancelled {
      XCTAssertEqual(cancelled.wait(timeout: .now() + 10), .success)
    }
  }

  func cancel() {
    cancellation.withLock { $0 = true }
    cancelled.signal()
  }
}
