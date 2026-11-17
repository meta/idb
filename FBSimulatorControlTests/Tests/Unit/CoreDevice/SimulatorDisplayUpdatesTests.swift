/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing
@preconcurrency import XPC

private func displayValue(id: String, active: Bool) -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  let array = SimulatorCoreDevice.array
  return dictionary([
    "uniqueId": xpc_string_create(id), "name": xpc_string_create(id),
    "active": xpc_bool_create(active), "primary": xpc_bool_create(false),
    "bounds": array([array([xpc_double_create(0), xpc_double_create(0)]), array([xpc_double_create(2007), xpc_double_create(2853)])]),
    "pointScale": xpc_int64_create(3), "currentOrientation": xpc_string_create("rot0"),
    "type": dictionary(["integrated": dictionary([:])]),
  ])
}

private func report(_ displays: [xpc_object_t]) -> xpc_object_t {
  SimulatorCoreDevice.dictionary(["current": xpc_bool_create(true), "displays": SimulatorCoreDevice.array(displays)])
}

private func push(channel: UUID, _ reports: [xpc_object_t]) -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  return dictionary([
    "XPCSideChannel.uniqueIdentifier": xpc_string_create(channel.uuidString),
    "CoreDevice.XPCMessageKey.sideChannelStatus": dictionary(["pushing": dictionary(["elements": SimulatorCoreDevice.array(reports)])]),
  ])
}

private func target(_ event: xpc_object_t, channel: UUID) throws -> SimulatorDisplayTarget? {
  guard let report = try SimulatorDisplayUpdatesProtocol.report(event, channel: channel), case let .target(target) = SimulatorDisplayResolution(report, interactingWith: .integrated) else {
    return nil
  }
  return target
}

@Suite
struct SimulatorDisplayUpdatesTests {

  @Test
  func requestNamesTheSideChannelAndTakesNoInput() throws {
    let channel = UUID()
    let request = try CoreDeviceRequest(
      action: SimulatorDisplayUpdatesProtocol.action, deviceID: "device", version: CoreDeviceVersion("651.13.4"),
      input: SimulatorDisplayUpdatesProtocol.StreamInput(channel: channel)
    ).encoded()
    let input = try #require(xpc_dictionary_get_dictionary(request, "CoreDevice.input"))
    let proxy = try #require(xpc_dictionary_get_dictionary(input, "streamProxy"))
    let identifier = try #require(xpc_dictionary_get_value(proxy, "sideChannel"))
    #expect(xpc_get_type(identifier) == XPC_TYPE_UUID)
    let actualInput = try #require(xpc_dictionary_get_dictionary(input, "actualInput"))
    #expect(xpc_dictionary_get_count(actualInput) == 0)
  }

  @Test
  func theLatestReportInAPushSelectsTheActiveDisplay() throws {
    let channel = UUID()
    let target = try target(
      push(
        channel: channel,
        [
          report([displayValue(id: "cover", active: true), displayValue(id: "inner", active: false)]),
          report([displayValue(id: "cover", active: false), displayValue(id: "inner", active: true)]),
        ]), channel: channel)
    guard case let .selected(inner)? = target else {
      Issue.record("Expected a selected display, got \(String(describing: target))")
      return
    }
    #expect(inner.uniqueID == "inner")
  }

  @Test
  func aPushThatCannotSelectADisplayYieldsNothing() throws {
    let channel = UUID()
    let noneActive = report([displayValue(id: "cover", active: false), displayValue(id: "inner", active: false)])
    #expect(try target(push(channel: channel, [noneActive]), channel: channel) == nil)
    #expect(try target(push(channel: channel, []), channel: channel) == nil)
  }

  @Test
  func aPushOnAnotherSideChannelIsMalformed() {
    let pushed = push(channel: UUID(), [report([displayValue(id: "lcd", active: true)])])
    #expect(throws: (any Error).self) { try target(pushed, channel: UUID()) }
  }
}
