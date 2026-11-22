/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !os(tvOS)
import FBSimulatorBridgeProtocol
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif
// HKInternalAuthorizationStatus values, as healthd expects them (from `_HKInternalAuthorizationStatusMake`
// and `+[HDAuthorizationEntity _insertAuthorizationWith…]`). NOT the public HKAuthorizationStatus 0..4.
private let healthInternalAuthShareAndRead: UInt = 101
private let healthInternalAuthShareAndReadDenied: UInt = 104
// The default HKQuantity types used by `approve` when the caller does not specify any.
private func defaultApproveTypeIdentifiers() -> [String] {
  struct StaticVars {
    static let defaults = ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierBodyMass"]
  }
  return StaticVars.defaults
}

// MARK: - JSON output helpers

/// Answers in the frame, or prints the answer's line for the one-shot command, so both report the same.
private func printHealthJSON(_ answer: BridgeHealthAnswer, output: BridgeOutput?) {
  if let output {
    output.write(.health(answer))
    return
  }
  let json = (try? BridgeAnswer.health(answer).jsonLine()) ?? "(null)"
  // The existing C writer stops at the first NUL.
  // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
  print(String(json.prefix { $0 != "\0" }))
}

/// The runtime reads each of a record's values as a string or a number.
private func record(_ record: FBHealthAuthorizationRecord) -> BridgeHealthRecord {
  func flag(_ value: Any?) -> Bool? {
    (value as? NSNumber)?.boolValue
  }
  let identifier = record.identifier.flatMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
  return BridgeHealthRecord(
    identifier: identifier, sharingAuthorizationAllowed: flag(record.sharingAuthorizationAllowed),
    readingAuthorizationAllowed: flag(record.readingAuthorizationAllowed))
}

private func writeAction(_ name: String) -> BridgeHealthAnswer.WriteAction {
  name == "revoke" ? .revoke : .approve
}

// MARK: - Verb implementations

private func handleSetAction(
  client: FBHealthSettingsClient,
  bundleID: String,
  typeIdentifiers: [String],
  statusCode: UInt,
  actionName: String,
  sink: BridgeOutput?
) throws -> Int {
  let requested = !typeIdentifiers.isEmpty ? typeIdentifiers : defaultApproveTypeIdentifiers()

  let selection = FBHealthTypeSelection()
  var resolvedIdentifiers: [String] = []
  var unresolvedIdentifiers: [String] = []
  for identifier in requested {
    let resolved = try selection.resolveIdentifier(identifier)
    if resolved.boolValue {
      resolvedIdentifiers.append(identifier)
    } else {
      NSLog("[Health] Skipping unresolved HK type identifier: %@", identifier)
      unresolvedIdentifiers.append(identifier)
    }
  }
  if selection.isEmpty {
    printHealthJSON(.nothingResolved(action: writeAction(actionName), bundleID: bundleID, unresolvedTypes: unresolvedIdentifiers), output: sink)
    return sink?.failure(BridgeHealthAnswer.nothingResolvedError) ?? 1
  }
  // Seed first: the daemon drops status writes for unseen bundle/type pairs.
  let seed = try client.seedAuthorization(forBundleIdentifier: bundleID, selection: selection)

  if let sink, seed.status == .timedOut {
    sink.write(.health(.timedOut(action: actionName == "revoke" ? .revoke : .approve, bundleID: bundleID, error: "Health seed timed out")))
    return sink.failure("Health seed timed out")
  }
  let write = try client.setAuthorizationForBundleIdentifier(bundleID, selection: selection, status: statusCode)
  guard let set = write.operation else {
    printHealthJSON(
      .noAuthorizationSpelling(action: writeAction(actionName), bundleID: bundleID, resolvedTypes: resolvedIdentifiers, unresolvedTypes: unresolvedIdentifiers),
      output: sink)
    return sink?.failure(BridgeHealthAnswer.noAuthorizationSpellingError) ?? 1
  }
  if let sink, set.status == .timedOut {
    sink.write(.health(.timedOut(action: actionName == "revoke" ? .revoke : .approve, bundleID: bundleID, error: "Health authorization write timed out")))
    return sink.failure("Health authorization write timed out")
  }
  let seedError = try seed.readErrorValue() as? String
  let setError = try set.readErrorValue() as? String
  printHealthJSON(
    .write(
      action: writeAction(actionName), bundleID: bundleID, ok: seed.success && set.success, resolvedTypes: resolvedIdentifiers,
      unresolvedTypes: unresolvedIdentifiers, seedError: seedError, setError: setError),
    output: sink)
  guard seed.success && set.success else {
    return sink?.failure(setError ?? seedError ?? "Health \(actionName) failed") ?? 1
  }
  return 0
}

private func handleClearAction(client: FBHealthSettingsClient, bundleID: String, sink: BridgeOutput?) throws -> Int {
  let result = try client.clearAuthorization(forBundleIdentifier: bundleID)
  if let sink, result.status == .timedOut {
    sink.write(.health(.timedOut(action: .clear, bundleID: bundleID, error: "Health clear timed out")))
    return sink.failure("Health clear timed out")
  }
  let clearError = try result.readErrorValue() as? String
  printHealthJSON(.clear(bundleID: bundleID, ok: result.success, error: clearError), output: sink)
  guard result.success else {
    return sink?.failure(clearError ?? "Health clear failed") ?? 1
  }
  return 0
}

private func handleListAction(client: FBHealthSettingsClient, bundleID: String, sink: BridgeOutput?) throws -> Int {
  let result = try client.fetchRecords(forBundleIdentifier: bundleID)
  if let sink, result.status == .timedOut {
    sink.write(.health(.timedOut(action: .list, bundleID: bundleID, error: "Health list timed out")))
    return sink.failure("Health list timed out")
  }
  let records = try result.readRecords().map(record)
  let fetchError = try result.readErrorValue() as? String
  printHealthJSON(.list(bundleID: bundleID, ok: !result.hasError, error: fetchError, records: records), output: sink)
  guard !result.hasError else {
    return sink?.failure(fetchError ?? "Health list failed") ?? 1
  }
  return 0
}

// MARK: - Dispatch

private func handleHealthSettingsActionImpl(
  action: String,
  bundleID: String?,
  typeIdentifiers: [String],
  sink: BridgeOutput?
) throws -> Int {
  let client = FBHealthSettingsClient.live()
  guard let client else {
    return sink?.failure("The Health authorization private API is unavailable") ?? 1
  }
  guard let bundleID else {
    NSLog("[Health] bundleID is required for action '%@'", action)
    return sink?.failure("Health requires a bundle identifier") ?? 1
  }
  if action == "list" {
    return try handleListAction(client: client, bundleID: bundleID, sink: sink)
  }
  if action == "clear" {
    return try handleClearAction(client: client, bundleID: bundleID, sink: sink)
  }
  if action == "approve" {
    return try handleSetAction(
      client: client,
      bundleID: bundleID,
      typeIdentifiers: typeIdentifiers,
      statusCode: healthInternalAuthShareAndRead,
      actionName: "approve",
      sink: sink
    )
  }
  if action == "revoke" {
    return try handleSetAction(
      client: client,
      bundleID: bundleID,
      typeIdentifiers: typeIdentifiers,
      statusCode: healthInternalAuthShareAndReadDenied,
      actionName: "revoke",
      sink: sink
    )
  }
  NSLog("[Health] Unknown action '%@'. Supported: list, clear, approve, revoke", action)
  return sink?.failure("Unknown Health action: \(action)") ?? 1
}

public enum HealthSettingsService {

  public static func handleHealthSettingsAction(
    action: String,
    bundleID: String?,
    typeIdentifiers: [String]
  ) -> Int {
    handleHealthSettingsAction(action: action, bundleID: bundleID, typeIdentifiers: typeIdentifiers, output: nil)
  }

  static func handleHealthSettingsAction(action: String, bundleID: String?, typeIdentifiers: [String], output: BridgeOutput?) -> Int {
    do {
      return try handleHealthSettingsActionImpl(action: action, bundleID: bundleID, typeIdentifiers: typeIdentifiers, sink: output)
    } catch {
      return output?.failure("Health authorization failed: \(error.localizedDescription)") ?? 1
    }
  }
}
#endif
