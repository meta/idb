/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import Testing

@Suite
struct ServiceCommandTests {
  @Test
  func orientationRejectsWritesAndExtraArguments() {
    #expect(OrientationService.run(action: "set", arguments: []) == 1)
    #expect(OrientationService.run(action: "get", arguments: ["ignored"]) == 1)
  }

  @Test
  func incompleteCommandDoesNotCallAService() {
    let services = RecordingServices()
    for arguments in [[], ["bridge"], ["bridge", "dns"]] {
      #expect(BridgeCommandLine.run(arguments: arguments, services: services) == 1)
    }
    #expect(services.calls.isEmpty)
  }

  @Test
  func commandForwardsArgumentsAndExitStatus() {
    let services = RecordingServices()
    #expect(BridgeCommandLine.run(arguments: ["bridge", "dns", "set", "", "8.8.8.8"], services: services) == 23)
    #expect(services.calls == [Call(service: "dns", action: "set", arguments: ["", "8.8.8.8"])])
  }

  @Test
  func eachRouteReceivesItsOriginalArgumentShape() {
    let services = RecordingServices()
    for service in ["contacts", "dns", "dynamic-store", "photos", "notifications", "health", "privacy", "proxy", "accessibility", "orientation"] {
      #expect(BridgeCommandLine.dispatch(service: service, action: "action", arguments: ["bundle", "type1", "type2"], services: services) == 23)
    }
    #expect(
      services.calls == [
        Call(service: "contacts", action: "action", arguments: []),
        Call(service: "dns", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "dynamic-store", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "photos", action: "action", arguments: []),
        Call(service: "notifications", action: "action", arguments: ["bundle"]),
        Call(service: "health", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "privacy", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "proxy", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "accessibility", action: "action", arguments: ["bundle", "type1", "type2"]),
        Call(service: "orientation", action: "action", arguments: ["bundle", "type1", "type2"]),
      ])
  }

  @Test
  func missingBundleIDsRemainNil() {
    let services = RecordingServices()
    for service in ["notifications", "health"] {
      #expect(BridgeCommandLine.dispatch(service: service, action: "list", arguments: [], services: services) == 23)
    }
    #expect(
      services.calls == [
        Call(service: "notifications", action: "list", arguments: [nil]),
        Call(service: "health", action: "list", arguments: [nil]),
      ])
  }

  @Test
  func deliveredNotificationsUsesItsOwnRouteAndOnlyTheBundleID() {
    let services = RecordingServices()
    #expect(BridgeCommandLine.dispatch(service: "notifications", action: "delivered", arguments: ["com.example.app", "ignored"], services: services) == 23)
    #expect(BridgeCommandLine.dispatch(service: "notifications", action: "delivered", arguments: [], services: services) == 23)
    #expect(BridgeCommandLine.dispatch(service: "notifications", action: "clear-delivered", arguments: ["com.example.app"], services: services) == 23)
    #expect(
      services.calls == [
        Call(service: "deliveredNotifications", action: "delivered", arguments: ["com.example.app"]),
        Call(service: "deliveredNotifications", action: "delivered", arguments: [nil]),
        Call(service: "deliveredNotifications", action: "clear-delivered", arguments: ["com.example.app"]),
      ])
  }

  @Test
  func invalidServiceAndReplCommandsDoNotCallTheLoader() {
    let services = RecordingServices()
    #expect(BridgeCommandLine.dispatch(service: "unknown", action: "start", arguments: [], services: services) == 1)
    for (action, arguments) in [("stop", ["socket", "library"]), ("start", []), ("start", ["socket"]), ("start", ["socket", ""])] {
      #expect(BridgeCommandLine.dispatch(service: "repl", action: action, arguments: arguments, services: services) == 1)
    }
    #expect(services.calls.isEmpty)
  }

  @Test
  func replForwardsSocketLibraryAndAdditionalLibraryPaths() {
    let services = RecordingServices()
    #expect(BridgeCommandLine.dispatch(service: "repl", action: "start", arguments: ["socket", "library"], services: services) == 23)
    #expect(BridgeCommandLine.dispatch(service: "repl", action: "start", arguments: ["socket", "library", "first", "second"], services: services) == 23)
    #expect(
      services.calls == [
        Call(service: "repl", action: "start", arguments: ["socket", "library"]),
        Call(service: "repl", action: "start", arguments: ["socket", "library", "first", "second"]),
      ])
  }
}

private struct Call: Equatable {
  let service: String
  let action: String
  let arguments: [String?]
}

private final class RecordingServices: CommandLineServiceHandling {
  var calls: [Call] = []

  private func record(_ service: String, _ action: String, _ arguments: [String?]) -> Int32 {
    calls.append(Call(service: service, action: action, arguments: arguments))
    return 23
  }

  func contacts(_ action: String) -> Int32 { record("contacts", action, []) }
  func health(_ action: String, bundleID: String?, typeIDs: [String]) -> Int32 { record("health", action, [bundleID] + typeIDs.map { $0 }) }
  func dns(_ action: String, arguments: [String]) -> Int32 { record("dns", action, arguments) }
  func dynamicStore(_ action: String, arguments: [String]) -> Int32 { record("dynamic-store", action, arguments) }
  func photos(_ action: String) -> Int32 { record("photos", action, []) }
  func notifications(_ action: String, bundleID: String?) -> Int32 { record("notifications", action, [bundleID]) }
  func deliveredNotifications(_ action: String, bundleID: String?) -> Int32 { record("deliveredNotifications", action, [bundleID]) }
  func privacy(_ action: String, arguments: [String]) -> Int32 { record("privacy", action, arguments) }
  func proxy(_ action: String, arguments: [String]) -> Int32 { record("proxy", action, arguments) }
  func accessibility(_ action: String, arguments: [String]) -> Int32 { record("accessibility", action, arguments) }
  func orientation(_ action: String, arguments: [String]) -> Int32 { record("orientation", action, arguments) }
  func repl(_ socketPath: String?, libraryPath: String, additionalLibraryPaths: [String]) -> Int32 {
    record("repl", "start", [socketPath, libraryPath] + additionalLibraryPaths.map { $0 })
  }
}
