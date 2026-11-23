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
struct PhotoLibraryServiceTests {

  @Test
  func unknownActionReturnsFailure() {
    #expect(PhotoLibraryService.handlePhotoLibraryAction(action: "delete") == 1)
    #expect(PhotoLibraryService.handlePhotoLibraryAction(action: "") == 1)
    #expect(PhotoLibraryService.handlePhotoLibraryAction(action: "add") == 1)
  }
}
