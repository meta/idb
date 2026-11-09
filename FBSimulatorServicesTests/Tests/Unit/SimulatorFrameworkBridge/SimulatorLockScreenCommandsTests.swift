/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
@testable import FBSimulatorServices
import Foundation
import Testing

@Suite("Simulator lock screen commands")
struct SimulatorLockScreenCommandsTests {
  @Test("The guest's lock state decodes from its one JSON value")
  func decodesTheGuestsLockState() throws {
    let state = try SimulatorLockState.decode(bridgeOutput: #"{"locked":true}"# + "\n")
    #expect(state.locked)
  }

  @Test("Output that is not a lock state fails with what the guest printed")
  func rejectsOutputThatIsNotALockState() {
    #expect {
      try SimulatorLockState.decode(bridgeOutput: #"{"locked":"yes"}"#)
    } throws: { error in
      guard case let .undecodableState(output, _) = error as? SimulatorLockScreenError else { return false }
      return output == #"{"locked":"yes"}"#
    }
  }

  @Test("Each command names its lock screen action in failures")
  func commandsNameTheirAction() {
    #expect(BridgeCommand.lockScreen(.state).serviceAndAction == "lock-screen state")
    #expect(BridgeCommand.lockScreen(.lock).serviceAndAction == "lock-screen lock")
    #expect(BridgeCommand.lockScreen(.unlock).serviceAndAction == "lock-screen unlock")
  }

  @Test("A passcode the guest reports decodes, and a guest that does not report one leaves it unknown")
  func decodesThePasscodeState() throws {
    #expect(try SimulatorLockState.decode(bridgeOutput: #"{"locked":true,"passcodeEnabled":false}"#).passcodeEnabled == false)
    #expect(try SimulatorLockState.decode(bridgeOutput: #"{"locked":true}"#).passcodeEnabled == nil)
  }

  @Test(
    "Unlock presses Home only for a device locked without a passcode, then lets the guest confirm",
    arguments: [
      (SimulatorLockState(locked: true, passcodeEnabled: false), ["state", "home", "unlock"]),
      (SimulatorLockState(locked: true, passcodeEnabled: true), ["state", "unlock"]),
      (SimulatorLockState(locked: true, passcodeEnabled: nil), ["state", "unlock"]),
      (SimulatorLockState(locked: false, passcodeEnabled: false), ["state"]),
    ])
  func unlockPressesHomeOnlyWhenItCanUnlock(_ before: SimulatorLockState, expected: [String]) async throws {
    var calls: [String] = []

    let after = try await SimulatorLockScreenCommands.unlock(
      state: {
        calls.append("state")
        return before
      },
      pressHome: { calls.append("home") },
      unlock: {
        calls.append("unlock")
        return SimulatorLockState(locked: false, passcodeEnabled: before.passcodeEnabled)
      })

    #expect(calls == expected)
    #expect(!after.locked)
  }

  @Test("A Home press that fails is the unlock's failure, and the guest is not asked")
  func failedHomePressFailsTheUnlock() async {
    var askedGuestToUnlock = false

    await #expect(throws: HomePressFailed.self) {
      try await SimulatorLockScreenCommands.unlock(
        state: { SimulatorLockState(locked: true, passcodeEnabled: false) },
        pressHome: { throw HomePressFailed() },
        unlock: {
          askedGuestToUnlock = true
          return SimulatorLockState(locked: false, passcodeEnabled: false)
        })
    }
    #expect(!askedGuestToUnlock)
  }

  @Test("The guest's verdict after the press is the answer, even when SpringBoard still reports the device locked")
  func guestFailureAfterThePressIsReported() async {
    await #expect(throws: GuestRefused.self) {
      try await SimulatorLockScreenCommands.unlock(
        state: { SimulatorLockState(locked: true, passcodeEnabled: false) },
        pressHome: {},
        unlock: { throw GuestRefused() })
    }
  }
}

private struct HomePressFailed: Error {}
private struct GuestRefused: Error {}
