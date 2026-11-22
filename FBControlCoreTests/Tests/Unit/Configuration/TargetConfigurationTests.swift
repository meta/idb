/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore
import Foundation
import Testing

@Suite
struct TargetConfigurationTests {
  @Test
  func metadataDoesNotRequireKnownNames() {
    let device = DeviceType(model: DeviceModel(rawValue: "Future Device"), family: .unknown)
    let os = OSVersion(name: OSVersionName(rawValue: "Future Platform"), versionString: "99.10.2")
    #expect(device.model.rawValue == "Future Device")
    #expect(os.name.rawValue == "Future Platform")
    #expect(os.version.majorVersion == 99)
    #expect(os.version.minorVersion == 10)
    #expect(os.version.patchVersion == 2)
  }

  @Test
  func versionWithoutPlatformName() {
    let os = OSVersion.generic(withName: "27.10.2")
    #expect(os.versionString == "27.10.2")
    #expect(os.version.majorVersion == 27)
    #expect(os.version.minorVersion == 10)
    #expect(os.version.patchVersion == 2)
  }

  @Test
  func versionWithTrailingQualifier() {
    let os = OSVersion.generic(withName: "iOS 15.2 Beta")
    #expect(os.versionString == "15.2")
    #expect(os.version.majorVersion == 15)
    #expect(os.version.minorVersion == 2)
  }

  @Test
  func explicitVersionOverridesDisplayName() {
    let os = OSVersion(name: OSVersionName(rawValue: "iOS 15.2 Beta"), versionString: "99.10.2")
    #expect(os.versionString == "99.10.2")
    #expect(os.version.majorVersion == 99)
  }

  @Test
  func missingVersionDoesNotCrash() {
    let os = OSVersion.generic(withName: "unknown")
    #expect(os.versionString == "")
    #expect(os.version.majorVersion == 0)
  }

  @Test
  func supportsDuo() {
    #expect(TargetConfiguration.baseArchsToCompatibleArch([Architecture(rawValue: "arm64e.x1")]).contains(.arm64))
  }
}
