/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeRuntime
import XCTest

final class HealthMutationTests: XCTestCase {
  private let bundleID = "com.example.health"
  private let defaults = [
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierBodyMass",
  ]

  private func run(_ runtime: FBHealthTestRuntime, action: String, types: [String] = []) throws -> (Int, NSDictionary) {
    let result = runtime.runAction(action, bundleID: bundleID, types: types)
    let status = try XCTUnwrap(result["status"] as? Int)
    let output = try XCTUnwrap(result["output"] as? String)
    XCTAssertTrue(output.hasSuffix("\n"))
    let data = try XCTUnwrap(output.data(using: .utf8))
    return (status, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary))
  }

  private func runtimeWithType() -> FBHealthTestRuntime {
    let runtime = FBHealthTestRuntime()
    runtime.typeFactories = ["step": "HKQuantityType"]
    return runtime
  }

  func testClearFailureDoesNotLeakIntoFollowingClearOrList() throws {
    let runtime = FBHealthTestRuntime()
    runtime.clearOK = false
    runtime.clearError = "clear failed"
    let (failedStatus, failedOutput) = try run(runtime, action: "clear")
    XCTAssertEqual(failedStatus, 1)
    XCTAssertEqual(failedOutput, ["action": "clear", "bundleID": bundleID, "ok": false, "error": "clear failed"] as NSDictionary)

    runtime.clearOK = true
    runtime.clearError = nil
    let (clearStatus, clearOutput) = try run(runtime, action: "clear")
    XCTAssertEqual(clearStatus, 0)
    XCTAssertEqual(clearOutput, ["action": "clear", "bundleID": bundleID, "ok": true] as NSDictionary)

    let (listStatus, listOutput) = try run(runtime, action: "list")
    XCTAssertEqual(listStatus, 0)
    XCTAssertEqual(listOutput, ["action": "list", "bundleID": bundleID, "ok": true, "records": []] as NSDictionary)
  }

  // Every health answer reports whether it succeeded as a boolean, as clears and failures always have.
  func testSetAndListStatusAreJSONBooleans() throws {
    for action in ["approve", "revoke", "list"] {
      for success in [true, false] {
        let runtime = runtimeWithType()
        runtime.setOK = success
        runtime.fetchError = success ? nil : "fetch failed"
        let (status, output) = try run(runtime, action: action, types: ["step"])
        let ok = try XCTUnwrap(output["ok"] as? NSNumber)
        XCTAssertEqual(status, success ? 0 : 1)
        XCTAssertEqual(ok.boolValue, success)
        XCTAssertEqual(CFGetTypeID(ok), CFBooleanGetTypeID(), action)
      }
    }
  }

  func testClearAndResolutionFailuresRemainJSONBooleans() throws {
    for success in [true, false] {
      let runtime = FBHealthTestRuntime()
      runtime.clearOK = success
      let (status, output) = try run(runtime, action: "clear")
      let ok = try XCTUnwrap(output["ok"] as? NSNumber)
      XCTAssertEqual(status, success ? 0 : 1)
      XCTAssertEqual(ok.boolValue, success)
      XCTAssertEqual(CFGetTypeID(ok), CFBooleanGetTypeID())
    }
    for variants in [0, 1] {
      let runtime = FBHealthTestRuntime()
      runtime.setterVariants = UInt(variants)
      runtime.typeFactories = variants == 0 ? ["step": "HKQuantityType"] : [:]
      let (status, output) = try run(runtime, action: "approve", types: ["step"])
      let ok = try XCTUnwrap(output["ok"] as? NSNumber)
      XCTAssertEqual(status, 1)
      XCTAssertFalse(ok.boolValue)
      XCTAssertEqual(CFGetTypeID(ok), CFBooleanGetTypeID())
    }
  }

  func testDefaultApprovalAndRevocationSeedBeforeEitherSetterSpelling() throws {
    for (action, statusCode) in [("approve", 101), ("revoke", 104)] {
      for variants in [1, 2, 3] {
        let runtime = FBHealthTestRuntime()
        runtime.setterVariants = UInt(variants)
        runtime.typeFactories = Dictionary(uniqueKeysWithValues: defaults.map { ($0, "HKQuantityType") })
        let (status, output) = try run(runtime, action: action)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
          output,
          [
            "action": action, "bundleID": bundleID, "ok": true, "resolvedTypes": defaults,
            "unresolvedTypes": [],
          ] as NSDictionary)
        XCTAssertEqual(
          runtime.operations as NSArray,
          [
            "healthStore", "authorizationStore", "seed", variants == 1 ? "setLegacy" : "setModern",
          ] as NSArray)
        XCTAssertEqual(runtime.arguments["expectedHealthStore"] as? Bool, true)
        XCTAssertEqual(runtime.arguments["seedBundle"] as? String, bundleID)
        XCTAssertEqual(runtime.arguments["setBundle"] as? String, bundleID)
        XCTAssertEqual(runtime.arguments["shareTypes"] as? Set<String>, Set(defaults))
        XCTAssertEqual(runtime.arguments["readTypes"] as? Set<String>, Set(defaults))
        XCTAssertEqual(runtime.arguments["statuses"] as? [String: Int], Dictionary(uniqueKeysWithValues: defaults.map { ($0, statusCode) }))
        XCTAssertEqual(runtime.arguments["options"] as? Int, 0)
        XCTAssertEqual(runtime.arguments["modes"] as? NSDictionary, [:] as NSDictionary)
        if variants == 1 {
          XCTAssertNil(runtime.arguments["modeInfos"])
        } else {
          XCTAssertEqual(runtime.arguments["modeInfos"] as? NSDictionary, [:] as NSDictionary)
        }
      }
    }
  }

  func testResolutionTriesEveryFactoryAndPreservesDuplicateOutputIdentifiers() throws {
    let runtime = FBHealthTestRuntime()
    runtime.typeFactories = [
      "quantity": "HKQuantityType", "category": "HKCategoryType", "characteristic": "HKCharacteristicType",
      "correlation": "HKCorrelationType", "document": "HKDocumentType",
    ]
    let resolved = ["quantity", "category", "characteristic", "correlation", "document", "quantity"]
    let (status, output) = try run(runtime, action: "approve", types: resolved + ["unknown"])
    XCTAssertEqual(status, 0)
    XCTAssertEqual(
      output,
      [
        "action": "approve", "bundleID": bundleID, "ok": true, "resolvedTypes": resolved,
        "unresolvedTypes": ["unknown"],
      ] as NSDictionary)
    XCTAssertEqual(runtime.arguments["shareTypes"] as? Set<String>, Set(resolved))
    XCTAssertEqual(runtime.arguments["readTypes"] as? Set<String>, Set(resolved))
    XCTAssertEqual(
      runtime.arguments["statuses"] as? [String: Int],
      [
        "quantity": 101, "category": 101, "characteristic": 101, "correlation": 101, "document": 101,
      ])
    let calls = try XCTUnwrap(runtime.factoryCalls as? [String])
    XCTAssertEqual(
      calls.filter { $0.hasSuffix(":document") },
      [
        "HKQuantityType:document", "HKCategoryType:document", "HKCharacteristicType:document",
        "HKCorrelationType:document", "HKDocumentType:document",
      ])
    XCTAssertEqual(
      calls.filter { $0.hasSuffix(":unknown") },
      [
        "HKQuantityType:unknown", "HKCategoryType:unknown", "HKCharacteristicType:unknown",
        "HKCorrelationType:unknown", "HKDocumentType:unknown",
      ])
    XCTAssertEqual(calls.filter { $0.hasSuffix(":quantity") }, ["HKQuantityType:quantity", "HKQuantityType:quantity"])
  }

  func testNoResolvableTypesDoesNotSeedOrSet() throws {
    let runtime = FBHealthTestRuntime()
    let (status, output) = try run(runtime, action: "revoke", types: ["bad", "bad"])
    XCTAssertEqual(status, 1)
    XCTAssertEqual(
      output,
      [
        "action": "revoke", "bundleID": bundleID, "ok": false,
        "error": "no resolvable HK types in request", "unresolvedTypes": ["bad", "bad"],
      ] as NSDictionary)
    XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore"] as NSArray)
  }

  func testMissingFactoryIsSkippedAndLaterFactoryCanResolve() throws {
    let runtime = FBHealthTestRuntime()
    runtime.missingClasses = ["HKQuantityType"]
    runtime.typeFactories = ["document": "HKDocumentType"]
    let (status, output) = try run(runtime, action: "approve", types: ["document"])
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output["resolvedTypes"] as? [String], ["document"])
    XCTAssertEqual(
      runtime.factoryCalls as NSArray,
      [
        "HKCategoryType:document", "HKCharacteristicType:document", "HKCorrelationType:document", "HKDocumentType:document",
      ] as NSArray)
  }

  func testMissingSetterReportsFailureAfterSeeding() throws {
    let runtime = runtimeWithType()
    runtime.setterVariants = 0
    let (status, output) = try run(runtime, action: "approve", types: ["step", "unknown"])
    XCTAssertEqual(status, 1)
    XCTAssertEqual(
      output,
      [
        "action": "approve", "bundleID": bundleID, "ok": false,
        "error": "HKAuthorizationStore declares no known setAuthorizationStatuses: spelling",
        "resolvedTypes": ["step"], "unresolvedTypes": ["unknown"],
      ] as NSDictionary)
    XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "seed"] as NSArray)
  }

  func testSetContinuesAfterSeedFailureAndUsesBothCompletionBooleans() throws {
    let cases: [(Bool, Bool, String?, String?)] = [
      (false, true, "seed failed", nil), (true, false, nil, "set failed"),
      (true, true, "seed warning", "set warning"), (false, false, nil, nil),
    ]
    for (seedOK, setOK, seedError, setError) in cases {
      let runtime = runtimeWithType()
      runtime.seedOK = seedOK
      runtime.setOK = setOK
      runtime.seedError = seedError
      runtime.setError = setError
      let (status, output) = try run(runtime, action: "approve", types: ["step"])
      XCTAssertEqual(status, seedOK && setOK ? 0 : 1)
      XCTAssertEqual(
        output,
        [
          "action": "approve", "bundleID": bundleID, "ok": seedOK && setOK,
          "resolvedTypes": ["step"], "unresolvedTypes": [],
          "seedError": seedError as Any? ?? NSNull(), "setError": setError as Any? ?? NSNull(),
        ].withoutNulls)
      XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "seed", "setModern"] as NSArray)
    }
  }

  func testClearResultUsesCompletionBooleanAndPreservesError() throws {
    for ok in [true, false] {
      for error in [nil, "clear message"] as [String?] {
        let runtime = FBHealthTestRuntime()
        runtime.clearOK = ok
        runtime.clearError = error
        let (status, output) = try run(runtime, action: "clear")
        XCTAssertEqual(status, ok ? 0 : 1)
        XCTAssertEqual(
          output,
          [
            "action": "clear", "bundleID": bundleID, "ok": ok, "error": error as Any? ?? NSNull(),
          ].withoutNulls)
        XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "clear"] as NSArray)
        XCTAssertEqual(runtime.arguments["clearBundle"] as? String, bundleID)
      }
    }
  }

  func testListNormalizesRecordsAndKeepsThemWhenFetchReportsAnError() throws {
    for error in [nil, "fetch failed"] as [String?] {
      let runtime = FBHealthTestRuntime()
      runtime.fetchError = error
      runtime.records = [
        ["identifier": "step", "sharingAuthorizationAllowed": true, "readingAuthorizationAllowed": 0],
        ["identifier": "<opaque>", "sharingAuthorizationAllowed": NSNull(), "ignored": "value"],
        [:],
      ]
      let (status, output) = try run(runtime, action: "list")
      XCTAssertEqual(status, error == nil ? 0 : 1)
      XCTAssertEqual(
        output,
        [
          "action": "list", "bundleID": bundleID, "ok": error == nil,
          "error": error as Any? ?? NSNull(),
          "records": [
            ["identifier": "step", "sharingAuthorizationAllowed": true, "readingAuthorizationAllowed": 0],
            ["identifier": "opaque-value"], [:],
          ],
        ].withoutNulls)
      XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "list"] as NSArray)
      XCTAssertEqual(runtime.arguments["listBundle"] as? String, bundleID)
    }
  }

  func testOmittedCompletionsPreserveCurrentTimeoutResults() throws {
    for omitted in ["seed", "set", "clear", "list"] {
      let runtime = runtimeWithType()
      runtime.omittedCompletion = omitted
      let action = ["seed", "set"].contains(omitted) ? "approve" : omitted
      let (status, output) = try run(runtime, action: action, types: ["step"])
      XCTAssertEqual(status, omitted == "list" ? 0 : 1)
      if action == "approve" {
        XCTAssertEqual(
          output,
          [
            "action": "approve", "bundleID": bundleID, "ok": false,
            "resolvedTypes": ["step"], "unresolvedTypes": [],
          ] as NSDictionary)
        XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "seed", "setModern"] as NSArray)
      } else if action == "clear" {
        XCTAssertEqual(output, ["action": "clear", "bundleID": bundleID, "ok": false] as NSDictionary)
      } else {
        XCTAssertEqual(output, ["action": "list", "bundleID": bundleID, "ok": true, "records": []] as NSDictionary)
      }
    }
  }

  func testLateCompletionsCannotChangeReturnedResultsOrTheNextOperation() throws {
    for stage in ["seed", "set", "clear", "list"] {
      let runtime = runtimeWithType()
      runtime.deferredCompletion = stage
      runtime.seedError = "late seed"
      runtime.setError = "late set"
      runtime.clearError = "late clear"
      runtime.fetchError = "late list"
      runtime.records = [["identifier": "late record"]]
      runtime.install()
      defer { runtime.uninstall() }
      let client = try XCTUnwrap(FBHealthSettingsClient.live())
      let selection = FBHealthTypeSelection()
      XCTAssertTrue(try selection.resolveIdentifier("step").boolValue)
      let operation: () throws -> FBHealthOperationResult = {
        switch stage {
        case "seed":
          return try client.seedAuthorization(forBundleIdentifier: self.bundleID, selection: selection)
        case "set":
          return try XCTUnwrap(client.setAuthorizationForBundleIdentifier(self.bundleID, selection: selection, status: 101).operation)
        case "clear":
          return try client.clearAuthorization(forBundleIdentifier: self.bundleID)
        default:
          return try client.fetchRecords(forBundleIdentifier: self.bundleID)
        }
      }
      let timedOut = try operation()
      XCTAssertFalse(timedOut.success, stage)
      XCTAssertFalse(timedOut.hasError, stage)
      XCTAssertTrue(try timedOut.readErrorValue() is NSNull, stage)
      runtime.completePendingCallbacks()
      XCTAssertFalse(timedOut.success, stage)
      XCTAssertFalse(timedOut.hasError, stage)
      XCTAssertTrue(try timedOut.readErrorValue() is NSNull, stage)
      if let records = timedOut as? FBHealthRecordsResult {
        XCTAssertTrue(try records.readRecords().isEmpty)
      }
      runtime.deferredCompletion = ""
      runtime.seedError = nil
      runtime.setError = nil
      runtime.clearError = nil
      runtime.fetchError = nil
      runtime.records = [["identifier": "next record"]]
      let next = try operation()
      XCTAssertFalse(next.hasError, stage)
      if let records = next as? FBHealthRecordsResult {
        XCTAssertEqual(try records.readRecords().map { $0.identifier as? String }, ["next record"])
      } else {
        XCTAssertTrue(next.success, stage)
      }
    }
  }

  func testMissingStoresAndRejectedCommandsDoNotCallAuthorizationMethods() {
    for (missingClass, operations) in [("HKHealthStore", []), ("HKAuthorizationStore", ["healthStore"])] {
      let runtime = FBHealthTestRuntime()
      runtime.missingClasses = [missingClass]
      XCTAssertEqual(runtime.runAction("approve", bundleID: bundleID, types: []) as NSDictionary, ["status": 1, "output": ""] as NSDictionary)
      XCTAssertEqual(runtime.operations as NSArray, operations as NSArray)
    }
    for (action, bundle) in [("approve", nil), ("unknown", Optional(bundleID))] {
      let runtime = FBHealthTestRuntime()
      XCTAssertEqual(runtime.runAction(action, bundleID: bundle, types: []) as NSDictionary, ["status": 1, "output": ""] as NSDictionary)
      XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore"] as NSArray)
    }
  }
  func testPrivateExceptionsAtCommandBoundary() {
    for operation in ["healthStore", "authorizationStore", "factory", "seed", "setModern", "setLegacy", "clear", "list", "record"] {
      let runtime = runtimeWithType()
      runtime.raisedOperation = operation
      runtime.setterVariants = operation == "setLegacy" ? 1 : 3
      runtime.records = [["identifier": "step"]]
      let action = operation == "clear" ? "clear" : (["list", "record"].contains(operation) ? "list" : "approve")
      XCTAssertEqual(runtime.runAction(action, bundleID: bundleID, types: ["step"]) as NSDictionary, ["status": 1, "output": ""] as NSDictionary)
    }
  }
  func testWaitsForAsynchronousCompletions() throws {
    for action in ["approve", "clear", "list"] {
      let runtime = runtimeWithType()
      runtime.asyncCompletions = true
      runtime.records = [["identifier": "step"]]
      let (status, output) = try run(runtime, action: action, types: ["step"])
      XCTAssertEqual(status, 0)
      XCTAssertEqual(output["ok"] as? Bool, true)
      if action == "approve" {
        XCTAssertEqual(output["resolvedTypes"] as? [String], ["step"])
        XCTAssertEqual(runtime.operations as NSArray, ["healthStore", "authorizationStore", "seed", "setModern"] as NSArray)
      } else if action == "list" {
        XCTAssertEqual(output["records"] as? NSArray, [["identifier": "step"]] as NSArray)
      }
    }
  }
}

extension Dictionary where Key == String, Value == Any {
  /// The fields that hold something: an answer leaves out what it does not have.
  fileprivate var withoutNulls: NSDictionary {
    filter { !($0.value is NSNull) } as NSDictionary
  }
}
