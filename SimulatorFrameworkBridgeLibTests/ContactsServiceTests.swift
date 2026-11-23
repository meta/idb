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
struct ContactsServiceTests {

  @Test
  func unknownActionReturnsFailure() {
    #expect(ContactsService.handleContactsAction(action: "delete") == 1)
    #expect(ContactsService.handleContactsAction(action: "") == 1)
    #expect(ContactsService.handleContactsAction(action: "add") == 1)
  }
}
