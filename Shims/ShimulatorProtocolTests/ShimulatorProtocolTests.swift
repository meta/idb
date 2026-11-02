/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import ShimulatorProtocol
import SimulatorIPC
import Synchronization
import XCTest

private struct Parameters: Codable, Equatable, Sendable {
  let value: String
}

private final class Handler: ShimulatorMethodHandler, Sendable {
  private enum Failure: Error { case rejected }

  private struct State {
    var started: [String] = []
    var stopped = 0
    var update: ShimulatorMethodUpdate?
  }

  private let state = Mutex(State())
  private let rejects: Bool

  init(rejects: Bool = false) {
    self.rejects = rejects
  }

  var started: [String] { state.withLock { $0.started } }
  var stopped: Int { state.withLock { $0.stopped } }

  func setUpdate(_ update: ShimulatorMethodUpdate?) {
    state.withLock { $0.update = update }
  }

  func start(_ parameters: Parameters) throws -> String {
    if rejects { throw Failure.rejected }
    state.withLock { $0.started.append(parameters.value) }
    return parameters.value
  }

  func stop(_ admission: String) {
    state.withLock { $0.stopped += 1 }
  }

  func poll(_ admission: String) -> ShimulatorMethodUpdate? {
    state.withLock { $0.update }
  }
}

final class ShimulatorProtocolTests: XCTestCase {
  private var directory = ""
  private var path = ""

  override func setUp() {
    directory = "/tmp/shim-\(UUID().uuidString.prefix(8))"
    path = "\(directory)/test.sock"
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: directory)
  }

  func testSocketPathsFitSockaddrAndIgnoreUDIDSpelling() {
    let upper = ShimulatorWireProtocol.socketPath(
      capability: "audio", simulatorUDID: "AE4DEFD9-F94B-4543-84F1-849D4B5C4351", userID: 501)
    let lower = ShimulatorWireProtocol.socketPath(
      capability: "audio", simulatorUDID: "ae4defd9-f94b-4543-84f1-849d4b5c4351", userID: 501)

    XCTAssertEqual(upper, "/tmp/idb-shimulator-501/AE4DEFD9F94B454384F1849D4B5C4351.audio.sock")
    XCTAssertEqual(upper, lower)
    XCTAssertLessThan(upper.utf8.count, MemoryLayout.size(ofValue: sockaddr_un().sun_path))
  }

  func testRequestWireFormatAndVersionBoundary() throws {
    let data = Data(#"{"parameters":{"value":"x"},"version":1}"#.utf8)
    XCTAssertEqual(try ShimulatorRequest<Parameters>.decode(data), ShimulatorRequest(parameters: Parameters(value: "x")))

    let future = Data(#"{"parameters":{"value":"x"},"version":2}"#.utf8)
    XCTAssertThrowsError(try ShimulatorRequest<Parameters>.decode(future)) {
      XCTAssertEqual($0 as? ShimulatorProtocolError, .unsupportedVersion(2))
    }
    let response = Data(#"{"version":1,"processIdentifier":7,"processName":"app","state":"completed"}"#.utf8)
    XCTAssertEqual(
      try ShimulatorResponse.decode(response),
      ShimulatorResponse(processIdentifier: 7, processName: "app", state: .completed))
  }

  func testAConnectedProcessIsSentTheOperationAndReportsEachStateOnce() throws {
    var server = try ShimulatorServer(path: path, parameters: Parameters(value: "hello"))
    let handler = Handler()
    let finished = serveInBackground(handler)

    XCTAssertEqual(try responders(try XCTUnwrap(server)) { $0.first?.connected == true }.count, 1)
    handler.setUpdate(ShimulatorMethodUpdate(.accepted))
    let accepted = try responders(try XCTUnwrap(server)) { $0.first?.response?.state == .accepted }
    XCTAssertEqual(accepted.first?.response?.processName, "fixture")
    handler.setUpdate(ShimulatorMethodUpdate(.completed))
    _ = try responders(try XCTUnwrap(server)) { $0.first?.response?.state == .completed }

    XCTAssertEqual(handler.started, ["hello"])
    XCTAssertEqual(handler.stopped, 0)
    server = nil
    wait(for: [finished], timeout: 5)
  }

  func testDisconnectingStopsTheOperation() throws {
    var server = try ShimulatorServer(path: path, parameters: Parameters(value: "hello"))
    let handler = Handler()
    let finished = serveInBackground(handler)
    _ = try responders(try XCTUnwrap(server)) { $0.first?.connected == true }
    _ = try responders(try XCTUnwrap(server)) { _ in !handler.started.isEmpty }

    server = nil

    wait(for: [finished], timeout: 5)
    XCTAssertEqual(handler.stopped, 1)
  }

  func testAProcessThatCannotStartReportsWhy() throws {
    var server = try ShimulatorServer(path: path, parameters: Parameters(value: "hello"))
    let finished = serveInBackground(Handler(rejects: true))

    let response = try responders(try XCTUnwrap(server)) { $0.first?.response != nil }.first?.response
    XCTAssertEqual(response?.state, .failed)
    XCTAssertEqual(response?.message, "rejected")
    server = nil
    wait(for: [finished], timeout: 5)
  }

  func testAProcessThatExitsWithoutReportingIsForgotten() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "hello")))
    let client = try XCTUnwrap(try connect())
    _ = try responders(server) { $0.first?.connected == true }

    close(client)

    _ = try responders(server) { $0.isEmpty }
  }

  func testAHostRefusesASymlinkedDirectory() throws {
    let target = "\(directory)-target"
    XCTAssertEqual(mkdir(target, 0o700), 0)
    XCTAssertEqual(symlink(target, directory), 0)
    addTeardownBlock { try? FileManager.default.removeItem(atPath: target) }

    XCTAssertThrowsError(try ShimulatorServer(path: path, parameters: Parameters(value: ""))) {
      XCTAssertEqual($0 as? IPCError, .sharedDirectory(path: self.directory))
    }
  }

  func testOnlyOneHostServesAPath() throws {
    let first = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))

    XCTAssertNil(try ShimulatorServer(path: path, parameters: Parameters(value: "")))
    withExtendedLifetime(first) {}
  }

  func testAClientThatIsNeverSentAnOperationGivesUp() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))
    server.stopAdmitting()
    let logged = Mutex([String]())
    let client = ShimulatorClient(
      socketPath: path, handler: Handler(), log: { message in logged.withLock { $0.append(message) } })

    XCTAssertFalse(client.serveOnce())
    XCTAssertEqual(logged.withLock { $0 }, ["No operation arrived from \(path) within 5000 ms"])
    withExtendedLifetime(server) {}
  }

  func testAClientBacksOffFromAnOperationItCannotRead() throws {
    try IPCSocket.requirePrivateDirectory(directory, creating: true)
    let listener = try XCTUnwrap(try IPCListener.bind(path: path, backlog: 1))
    let descriptor = listener.fileDescriptor
    Thread.detachNewThread {
      let connection = accept(descriptor, nil, nil)
      var invalidHeader = UInt32(0)
      _ = withUnsafeBytes(of: &invalidHeader) { Darwin.send(connection, $0.baseAddress, 4, 0) }
      usleep(200_000)
      close(connection)
    }
    let logged = Mutex([String]())
    let client = ShimulatorClient(
      socketPath: path, handler: Handler(), log: { message in logged.withLock { $0.append(message) } })

    XCTAssertFalse(client.serveOnce())
    XCTAssertEqual(
      logged.withLock { $0 }, ["Could not read the operation from \(path): \(IPCError.invalidFrameSize(0))"])
    withExtendedLifetime(listener) {}
  }

  func testNoNewProcessesAreAdmittedOnceAdmissionStops() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))
    server.stopAdmitting()
    let client = try XCTUnwrap(try connect())
    defer { close(client) }

    usleep(50_000)
    XCTAssertTrue(server.poll().isEmpty)
    XCTAssertNil(try ShimulatorServer(path: path, parameters: Parameters(value: "")))
  }

  func testAPayloadIsReportedWithItsStateAndAChangeToItAloneIsReported() throws {
    var server = try ShimulatorServer(path: path, parameters: Parameters(value: "hello"))
    let handler = Handler()
    let finished = serveInBackground(handler)
    _ = try responders(try XCTUnwrap(server)) { $0.first?.connected == true }

    handler.setUpdate(ShimulatorMethodUpdate(.accepted, payload: Data("one".utf8)))
    _ = try responders(try XCTUnwrap(server)) { $0.first?.response?.payload == Data("one".utf8) }
    handler.setUpdate(ShimulatorMethodUpdate(.accepted, payload: Data("two".utf8)))
    let second = try responders(try XCTUnwrap(server)) { $0.first?.response?.payload == Data("two".utf8) }
    XCTAssertEqual(second.first?.response?.state, .accepted)

    server = nil
    wait(for: [finished], timeout: 5)
  }

  func testAResponseWithoutAPayloadStillDecodesAndOneWithAPayloadRoundTrips() throws {
    let older = Data(#"{"version":1,"processIdentifier":7,"processName":"app","state":"accepted"}"#.utf8)
    XCTAssertNil(try ShimulatorResponse.decode(older).payload)
    let response = ShimulatorResponse(processIdentifier: 7, processName: "app", state: .accepted, payload: Data([0, 1, 2]))
    XCTAssertEqual(try ShimulatorResponse.decode(JSONEncoder().encode(response)), response)
  }

  func testStatesReportedBetweenPollsAreEachReturned() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))
    let client = try XCTUnwrap(try connect())
    defer { close(client) }
    _ = try responders(server) { $0.first?.connected == true }

    for state in ["accepted", "completed"] {
      send(Data(#"{"version":1,"processIdentifier":1,"processName":"x","state":"\#(state)"}"#.utf8), to: client)
    }
    usleep(50_000)

    XCTAssertEqual(server.poll().first?.response?.state, .accepted)
    XCTAssertEqual(server.poll().first?.response?.state, .completed)
  }

  func testAnIncompatibleResponseIsReportedRatherThanTreatedAsAnExit() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))
    let client = try XCTUnwrap(try connect())
    defer { close(client) }
    _ = try responders(server) { $0.first?.connected == true }

    send(Data(#"{"version":2,"processIdentifier":1,"processName":"x","state":"accepted"}"#.utf8), to: client)

    let responder = try responders(server) { $0.first?.connected == false }.first
    XCTAssertEqual(responder?.error, String(describing: ShimulatorProtocolError.unsupportedVersion(2)))
    XCTAssertTrue(server.poll().isEmpty)
  }

  func testAClientRefusesADirectoryOthersCanWrite() throws {
    let server = try XCTUnwrap(ShimulatorServer(path: path, parameters: Parameters(value: "")))
    chmod(directory, 0o777)
    let logged = Mutex([String]())
    let client = ShimulatorClient(
      socketPath: path, handler: Handler(), log: { message in logged.withLock { $0.append(message) } })

    XCTAssertFalse(client.serveOnce())
    XCTAssertFalse(client.serveOnce())
    XCTAssertEqual(logged.withLock { $0 }, ["Will not connect to \(path): \(directory) is not private to this user"])
    withExtendedLifetime(server) {}
  }

  private func serveInBackground(_ handler: Handler) -> XCTestExpectation {
    let finished = expectation(description: "client finished")
    let path = path
    Thread.detachNewThread {
      _ = ShimulatorClient(
        socketPath: path,
        handler: handler,
        processIdentifier: 42,
        processName: "fixture",
        pollIntervalMilliseconds: 10,
        log: { _ in }
      ).serveOnce()
      finished.fulfill()
    }
    return finished
  }

  private func send(_ frame: Data, to descriptor: Int32) {
    var length = UInt32(frame.count).bigEndian
    _ = withUnsafeBytes(of: &length) { Darwin.send(descriptor, $0.baseAddress, 4, 0) }
    _ = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, frame.count, 0) }
  }

  private func connect() throws -> Int32? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return connected == 0 ? descriptor : nil
  }

  private func responders(
    _ server: ShimulatorServer,
    until condition: ([ShimulatorResponder]) -> Bool
  ) throws -> [ShimulatorResponder] {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let responders = server.poll()
      if condition(responders) { return responders }
      usleep(10_000)
    }
    XCTFail("timed out waiting for the responders")
    return server.poll()
  }
}
