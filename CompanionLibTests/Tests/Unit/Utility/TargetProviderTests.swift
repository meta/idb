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
      lock.withLock { made.append(name) }
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
        withUDID: "unknown", makingTargetSets: [log.maker("simulators"), log.maker("devices")], warmUp: false, appearanceTimeout: 0, logger: logger)
    }
    #expect(log.names == ["simulators", "devices"])
  }

  /// A device set lists a device by UDID only once MobileDevice has read its values, which can
  /// finish after the set is created.
  @Test func aUDIDThatAppearsAfterItsSetIsCreatedIsWaitedFor() async throws {
    let late = LateTargetSet(udid: "device", target: mac, absentLookups: 3)
    let target = try await TargetProvider.target(
      withUDID: "device", makingTargetSets: [{ TargetSetDouble(targets: [:]) }, { late }], warmUp: false, logger: logger)
    #expect(target is MacDevice)
    #expect(late.lookups > 3)
  }

  @Test func aUDIDThatNeverAppearsFailsSayingHowLongItWaited() async {
    let error = await #expect(throws: TargetProviderError.self) {
      _ = try await TargetProvider.target(
        withUDID: "device", makingTargetSets: [{ LateTargetSet(udid: "device", target: self.mac, absentLookups: .max) }], warmUp: false, appearanceTimeout: 0.2,
        logger: logger)
    }
    #expect(error?.localizedDescription.hasPrefix("No target with UDID device appeared within 0.2s") == true)
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

/// A set that holds its one target only after it has been asked for it `absentLookups` times.
private final class LateTargetSet: TargetSet, @unchecked Sendable {
  weak var delegate: (any TargetSetDelegate)?
  private let lock = NSLock()
  private let udid: String
  private let heldTarget: any TargetInfo
  private let absentLookups: Int
  private var lookupCount = 0

  init(udid: String, target: any TargetInfo, absentLookups: Int) {
    self.udid = udid
    self.heldTarget = target
    self.absentLookups = absentLookups
  }

  var lookups: Int { lock.withLock { lookupCount } }

  var allTargetInfos: [any TargetInfo] { [] }

  func target(withUDID udid: String) -> (any TargetInfo)? {
    lock.withLock {
      lookupCount += 1
      return udid == self.udid && lookupCount > absentLookups ? heldTarget : nil
    }
  }
}
