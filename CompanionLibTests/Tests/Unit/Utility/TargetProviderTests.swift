/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import Testing

/// Records which makers were called, in order.
private final class MakerLog: @unchecked Sendable {
  private let lock = NSLock()
  private var made: [String] = []

  var names: [String] {
    lock.lock()
    defer { lock.unlock() }
    return made
  }

  func maker(_ name: String, targets: [String: any TargetInfo] = [:]) -> TargetSetMaker {
    { [self] in
      lock.lock()
      made.append(name)
      lock.unlock()
      return TargetSetDouble(targets: targets)
    }
  }
}

@Suite("TargetProvider set makers")
struct TargetProviderTests {

  private let mac = MacDevice(logger: ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false))
  private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

  @Test func setsCreatedResolvingAUDIDTheFirstSetHolds() async throws {
    let log = MakerLog()
    let target = try await TargetProvider.target(
      withUDID: "first", makingTargetSets: [log.maker("simulators", targets: ["first": mac]), log.maker("devices")], warmUp: false, logger: logger)
    #expect(target is MacDevice)
    #expect(log.names == ["simulators"])
  }

  @Test func resolvingAUDIDALaterSetHoldsCreatesTheSetsBeforeIt() async throws {
    let log = MakerLog()
    let target = try await TargetProvider.target(
      withUDID: "second", makingTargetSets: [log.maker("simulators"), log.maker("devices", targets: ["second": mac])], warmUp: false, logger: logger)
    #expect(target is MacDevice)
    #expect(log.names == ["simulators", "devices"])
  }

  @Test func resolvingAnUnknownUDIDCreatesEverySet() async {
    let log = MakerLog()
    await #expect(throws: TargetProviderError.self) {
      _ = try await TargetProvider.target(
        withUDID: "unknown", makingTargetSets: [log.maker("simulators"), log.maker("devices")], warmUp: false, logger: logger)
    }
    #expect(log.names == ["simulators", "devices"])
  }

  @Test func resolvingTheSoleTargetCreatesEverySet() async throws {
    let log = MakerLog()
    let target = try await TargetProvider.target(
      withUDID: "only", makingTargetSets: [log.maker("simulators", targets: ["first": mac]), log.maker("devices")], warmUp: false, logger: logger)
    #expect(target is MacDevice)
    #expect(log.names == ["simulators", "devices"])
  }

  @Test func setsCreatedResolvingTheMac() async throws {
    let log = MakerLog()
    let target = try await TargetProvider.target(
      withUDID: "mac", makingTargetSets: [log.maker("simulators"), log.maker("devices")], warmUp: false, logger: logger)
    #expect(target is MacDevice)
    #expect(log.names == [])
  }
}
