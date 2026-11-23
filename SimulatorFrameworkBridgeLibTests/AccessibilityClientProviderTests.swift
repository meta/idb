/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeRuntime
import Testing

/// Direct tests for `FBAXClientProvider`: which runtime a client is built on,
/// how initialization failures surface through `client()`, and the per-process
/// unanswered-read bookkeeping. The service-layer suites exercise these only
/// indirectly through `AccessibilityService.handleRequest`.
@Suite(.serialized)
struct AccessibilityClientProviderTests {
  private final class FactoryCalls: @unchecked Sendable {
    var count = 0
  }

  private func resetProvider() {
    FBAXClientProvider.setRuntimeForTesting(nil)
    FBAXClientProvider.setRuntimeFactoryForTesting(nil)
  }

  private func installFactory(calls: FactoryCalls, message: String?, runtime: (any FBAXRuntime)?) {
    FBAXClientProvider.setRuntimeFactoryForTesting { errorPointer in
      calls.count += 1
      if let message {
        errorPointer?.pointee = message as NSString
      }
      return runtime
    }
  }

  @Test
  func clientWrapsTheInjectedRuntime() throws {
    resetProvider()
    defer { resetProvider() }
    let runtime = FBAXFakeRuntime()
    runtime.applicationElements[4321] = FBAXFakeElement.readable("root")
    FBAXClientProvider.setRuntimeForTesting(runtime)

    let client = try FBAXClientProvider.client()
    let present = try client.applicationElement(forProcessIdentifier: 4321)
    #expect(present.value != nil)
    let absent = try client.applicationElement(forProcessIdentifier: 9999)
    #expect(absent.value == nil)
  }

  @Test
  func clientErrorCarriesTheFactoryMessage() {
    resetProvider()
    defer { resetProvider() }
    installFactory(calls: FactoryCalls(), message: "missing test framework", runtime: nil)

    do {
      _ = try FBAXClientProvider.client()
      Issue.record("client() should have thrown")
    } catch {
      let nsError = error as NSError
      #expect(nsError.domain == "FBAXRuntimeInitialization")
      #expect(nsError.code == 1)
      #expect(nsError.localizedDescription == "missing test framework")
    }
  }

  @Test
  func clientErrorFallsBackWhenTheFactoryGivesNoMessage() {
    resetProvider()
    defer { resetProvider() }
    installFactory(calls: FactoryCalls(), message: nil, runtime: nil)

    do {
      _ = try FBAXClientProvider.client()
      Issue.record("client() should have thrown")
    } catch {
      #expect((error as NSError).localizedDescription == "accessibility setup failed")
    }
  }

  @Test
  func factoryIsAskedAnewForEveryClient() throws {
    resetProvider()
    defer { resetProvider() }
    let calls = FactoryCalls()
    installFactory(calls: calls, message: nil, runtime: FBAXFakeRuntime())

    let first = try FBAXClientProvider.client()
    let second = try FBAXClientProvider.client()
    #expect(first !== second)
    #expect(calls.count == 2)
  }

  @Test
  func injectedRuntimeWinsOverTheFactory() throws {
    resetProvider()
    defer { resetProvider() }
    let runtime = FBAXFakeRuntime()
    runtime.applicationElements[4321] = FBAXFakeElement.readable("root")
    FBAXClientProvider.setRuntimeForTesting(runtime)
    let calls = FactoryCalls()
    installFactory(calls: calls, message: "must not be asked", runtime: nil)

    let client = try FBAXClientProvider.client()
    let element = try client.applicationElement(forProcessIdentifier: 4321)
    #expect(element.value != nil)
    #expect(calls.count == 0)
  }

  @Test
  func prepareLeavesFailuresForTheClientToReport() {
    resetProvider()
    defer { resetProvider() }
    installFactory(calls: FactoryCalls(), message: "missing test framework", runtime: nil)

    FBAXClientProvider.prepare()
    do {
      _ = try FBAXClientProvider.client()
      Issue.record("client() should have thrown")
    } catch {
      #expect((error as NSError).localizedDescription == "missing test framework")
    }
  }

  @Test
  func unansweredReadsTrackOneProcessAtATime() {
    resetProvider()
    defer { resetProvider() }

    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 4321) == false)
    FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: 4321)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 4321) == true)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 8765) == false)
    FBAXClientProvider.setHasUnansweredRead(false, forProcessIdentifier: 4321)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 4321) == false)
  }

  @Test
  func unansweredReadsIgnoreNonPositiveProcessIdentifiers() {
    resetProvider()
    defer { resetProvider() }

    FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: 0)
    FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: -1)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 0) == false)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: -1) == false)
    FBAXClientProvider.setHasUnansweredRead(false, forProcessIdentifier: 0)
  }

  @Test
  func resettingTheRuntimeForgetsUnansweredReads() {
    resetProvider()
    defer { resetProvider() }

    FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: 4321)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 4321) == true)
    FBAXClientProvider.setRuntimeForTesting(nil)
    #expect(FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: 4321) == false)
  }
}
