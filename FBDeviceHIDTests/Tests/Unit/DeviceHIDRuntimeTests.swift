/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
@testable import FBDeviceHID
import Foundation
import Testing

@Suite("Physical HID runtime validation")
struct DeviceHIDRuntimeTests {
  @Test func latePreflightCannotBeatADelayedTimer() async throws {
    let timers = DispatchQueue(label: "device-hid-test.runtime-timers")
    let events = DeviceHIDTestRecorder()
    let gate = DeviceHIDTestGate()
    timers.suspend()
    defer {
      timers.resume()
      gate.open()
    }
    let task = Task {
      try await DeviceHIDRuntime.checkAsync(
        work: {
          events.record("preflightEntered")
          gate.wait()
        },
        timeout: 1,
        timerQueue: timers)
    }
    try await events.waitFor("preflightEntered")
    let entered = try #require(events.time("preflightEntered"))
    let expires = entered.advanced(by: .milliseconds(1100))
    events.onDeadline(expires, signal: "preflightDeadline") { gate.open() }
    do {
      try await task.value
      Issue.record("A late preflight result bypassed the deadline")
    } catch DeviceHIDError.deadlineExceeded {
    } catch { Issue.record("Unexpected error: \(error)") }
    let observed = try #require(events.time("preflightDeadline"))
    #expect(observed >= expires)
  }

  @Test func hostRejectionIncludesObservedValues() {
    do {
      try DeviceHIDRuntime.validateHost(
        arm64: false,
        version: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2),
        build: "25B123")
      Issue.record("An unsupported host was accepted")
    } catch DeviceHIDError.unsupportedRuntime(let message) {
      #expect(message.contains("arm64=false"))
      #expect(message.contains("macOS 26.6 or newer"))
      #expect(message.contains("26.1.2"))
      #expect(message.contains("25B123"))
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func acceptsSupportedHostsWithoutABuildAllowlist() throws {
    for (version, build) in [
      (OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0), "minimum-build"),
      (OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 1), "later-patch"),
      (OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 0), "later-minor"),
      (OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0), "next-major"),
      (OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), "26B123"),
      (OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1), "26B131"),
      (OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0), "later-build"),
      (OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0), "future-build"),
    ] {
      try DeviceHIDRuntime.validateHost(arm64: true, version: version, build: build)
    }
  }

  @Test func rejectsOldOSAndUnsupportedArchitectures() {
    for version in [
      OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 9),
      OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 99),
    ] {
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateHost(arm64: true, version: version, build: "26B999")
      }
    }
    for version in [
      OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0),
      OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0),
    ] {
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateHost(arm64: false, version: version, build: "unsupported-architecture")
      }
    }
  }

  @Test(arguments: ["651.13.5", "651.13.6", "651.13.10", "651.13.5.1", "651.14", "651.100.0", "652", "700.0.0"])
  func acceptsFrameworkVersionsAtOrAboveTheMinimum(_ version: String) throws {
    for image in DeviceHIDRuntime.images {
      try DeviceHIDRuntime.validateImage(image, version: version)
    }
  }

  @Test(arguments: [nil, "", "650.999.999", "651", "651.13", "651.9.99", "651.13.4", "651.13.4.999", "-652", "+652", "652a", "652.", "652..1", ".652", " 652", "652\n"] as [String?])
  func rejectsOldMissingOrMalformedVersions(_ version: String?) {
    for image in DeviceHIDRuntime.images {
      do {
        try DeviceHIDRuntime.validateImage(image, version: version)
        Issue.record("An unsupported image version was accepted")
      } catch DeviceHIDError.unsupportedRuntime(let message) {
        #expect(message.contains(image.name))
        #expect(message.contains("observed version \(version.map { String(reflecting: $0) } ?? "<missing>")"))
        #expect(message.contains("651.13.5 or newer"))
      } catch { Issue.record("Unexpected error: \(error)") }
    }
  }

  @Test func acceptsDifferentNewerVersionsForTheTwoFrameworks() throws {
    let coreDevice = try #require(DeviceHIDRuntime.images.first { $0.name == "CoreDevice" })
    let utilities = try #require(DeviceHIDRuntime.images.first { $0.name == "CoreDeviceUtilities" })
    try DeviceHIDRuntime.validateImage(coreDevice, version: "652.0.0")
    try DeviceHIDRuntime.validateImage(utilities, version: "653.1.0")
  }

  @Test(arguments: DeviceHIDRuntime.images)
  func requiresTheVersionCheckedLoadedOwnerForEverySymbol(_ image: DeviceHIDRuntime.Image) throws {
    let canonical = URL(fileURLWithPath: image.path).resolvingSymlinksInPath().path
    let wrongImage = try #require(DeviceHIDRuntime.images.first { $0.name != image.name })
    let newUUID = String(repeating: "1", count: 32)
    let installedVersions = [newUUID: "651.13.5"]
    for symbol in image.symbols {
      try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: newUUID, version: "651.13.5"), image: image, installedVersions: installedVersions, symbol: symbol)
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateIdentity(nil, image: image, installedVersions: installedVersions, symbol: symbol)
      }
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateIdentity(.init(path: wrongImage.path, uuid: newUUID, version: "651.13.5"), image: image, installedVersions: installedVersions, symbol: symbol)
      }
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: String(repeating: "2", count: 32), version: "651.13.5"), image: image, installedVersions: installedVersions, symbol: symbol)
      }
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: newUUID, version: "651.13.5"), image: image, installedVersions: [:], symbol: symbol)
      }
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: newUUID, version: "651.13.4"), image: image, installedVersions: installedVersions, symbol: symbol)
      }
    }
  }

  @Test(arguments: DeviceHIDRuntime.images)
  func rejectsRollbackBeforeTheBinarySnapshot(_ image: DeviceHIDRuntime.Image) {
    var installed = thinImage()
    var reads = 0
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDRuntime.captureImage(image) { path in
        #expect(path == image.path)
        reads += 1
        installed = thinImage(version: (651 << 40) | (13 << 30) | (4 << 20))
        return installed
      }
    }
    #expect(reads == 1)
  }

  @Test(arguments: DeviceHIDRuntime.images)
  func keepsTheAcceptedVersionBoundAcrossRollback(_ image: DeviceHIDRuntime.Image) throws {
    let canonical = URL(fileURLWithPath: image.path).resolvingSymlinksInPath().path
    let symbol = try #require(image.symbols.first)
    let newUUID = String(repeating: "11", count: 16)
    let oldUUID = String(repeating: "22", count: 16)
    var installed = thinImage()
    var reads = 0
    let versions = try DeviceHIDRuntime.captureImage(image) { _ in
      reads += 1
      let snapshot = installed
      installed = thinImage(uuid: 0x22, version: (651 << 40) | (13 << 30) | (4 << 20))
      return snapshot
    }
    #expect(reads == 1)
    #expect(versions == [newUUID: "651.13.5"])
    #expect(DeviceHIDRuntime.fileIdentities(in: installed) == [oldUUID: "651.13.4"])
    try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: newUUID, version: "651.13.5"), image: image, installedVersions: versions, symbol: symbol)
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: oldUUID, version: "651.13.4"), image: image, installedVersions: versions, symbol: symbol)
    }
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: newUUID, version: "651.13.4"), image: image, installedVersions: versions, symbol: symbol)
    }
  }

  @Test func rejectsAnOldLoadedSliceEvenWhenAnotherSliceIsNewEnough() throws {
    let image = try #require(DeviceHIDRuntime.images.first)
    let canonical = URL(fileURLWithPath: image.path).resolvingSymlinksInPath().path
    let symbol = try #require(image.symbols.first)
    let data = fatImage(slices: [thinImage(version: (651 << 40) | (13 << 30) | (4 << 20)), thinImage(uuid: 0x22)], fat64: true, bigEndian: true)
    let versions = try DeviceHIDRuntime.captureImage(image) { _ in data }
    try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: String(repeating: "22", count: 16), version: "651.13.5"), image: image, installedVersions: versions, symbol: symbol)
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDRuntime.validateIdentity(.init(path: canonical, uuid: String(repeating: "11", count: 16), version: "651.13.4"), image: image, installedVersions: versions, symbol: symbol)
    }
  }

  @Test func readsInstalledThinIdentityWithoutAKnownUUID() {
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage()) == [String(repeating: "11", count: 16): "651.13.5"])
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage(uuid: 0x22, version: 652 << 40)) == [String(repeating: "22", count: 16): "652"])
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage(cpu: 0x0100_0007)).isEmpty)
  }

  @Test func decodesAllSourceVersionComponents() {
    let uuid = String(repeating: "11", count: 16)
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage(version: UInt64.max)) == [uuid: "16777215.1023.1023.1023.1023"])
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage(version: (651 << 40) | (13 << 30) | (5 << 20) | (2 << 10) | 3)) == [uuid: "651.13.5.2.3"])
    #expect(DeviceHIDRuntime.fileIdentities(in: thinImage(version: 0)) == [uuid: "0"])
  }

  @Test(arguments: [false, true], [false, true])
  func selectsArm64IdentitiesFromUniversalImages(fat64: Bool, bigEndian: Bool) {
    let data = fatImage(
      slices: [thinImage(cpu: 0x0100_0007), thinImage(uuid: 0x22), thinImage(uuid: 0x33, version: 652 << 40)],
      fat64: fat64, bigEndian: bigEndian)
    #expect(DeviceHIDRuntime.fileIdentities(in: data) == [String(repeating: "22", count: 16): "651.13.5", String(repeating: "33", count: 16): "652"])
  }

  @Test func rejectsTruncatedOrMalformedThinImages() {
    let valid = thinImage()
    for count in 0..<valid.count {
      #expect(DeviceHIDRuntime.fileIdentities(in: valid.prefix(count)).isEmpty)
    }
    for (offset, value) in [(0, UInt32(0)), (16, 1), (16, 4096), (20, UInt32.max), (32, 0), (36, 0), (36, UInt32.max), (56, 0), (60, 8), (60, UInt32.max)] {
      var data = valid
      replaceWord(value, at: offset, in: &data)
      #expect(DeviceHIDRuntime.fileIdentities(in: data).isEmpty)
    }
    for command in [valid[32..<56], valid[56..<72]] {
      var duplicate = valid
      replaceWord(3, at: 16, in: &duplicate)
      replaceWord(UInt32(40 + command.count), at: 20, in: &duplicate)
      duplicate.append(command)
      #expect(DeviceHIDRuntime.fileIdentities(in: duplicate).isEmpty)
    }
  }

  @Test func rejectsMalformedUniversalImages() {
    let valid = fatImage(slices: [thinImage()], fat64: false, bigEndian: true)
    for count in 0..<valid.count {
      #expect(DeviceHIDRuntime.fileIdentities(in: valid.prefix(count)).isEmpty)
    }
    for (offset, value) in [(4, UInt32.max), (16, 0), (16, UInt32.max), (20, UInt32.max)] {
      var data = valid
      replaceWord(value, at: offset, in: &data, bigEndian: true)
      #expect(DeviceHIDRuntime.fileIdentities(in: data).isEmpty)
    }
    var wrongCPU = valid
    replaceWord(0x0100_0007, at: 32, in: &wrongCPU)
    #expect(DeviceHIDRuntime.fileIdentities(in: wrongCPU).isEmpty)
    var overflow = fatImage(slices: [thinImage()], fat64: true, bigEndian: true)
    overflow.replaceSubrange(16..<24, with: repeatElement(UInt8.max, count: 8))
    #expect(DeviceHIDRuntime.fileIdentities(in: overflow).isEmpty)
    let ambiguous = fatImage(slices: [thinImage(), thinImage(version: 652 << 40)], fat64: true, bigEndian: true)
    #expect(DeviceHIDRuntime.fileIdentities(in: ambiguous).isEmpty)
  }

  @Test func rejectsMissingAndZeroSourceVersionsBeforeLoading() throws {
    let image = try #require(DeviceHIDRuntime.images.first)
    var missingVersion = thinImage()
    replaceWord(0, at: 56, in: &missingVersion)
    for data in [Data(), missingVersion, thinImage(version: 0)] {
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDRuntime.captureImage(image) { _ in data }
      }
    }
  }
}

private func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data, bigEndian: Bool = false) {
  var encoded = bigEndian ? value.bigEndian : value.littleEndian
  withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func replaceWord(_ value: UInt32, at offset: Int, in data: inout Data, bigEndian: Bool = false) {
  var encoded = Data()
  append(value, to: &encoded, bigEndian: bigEndian)
  data.replaceSubrange(offset..<(offset + 4), with: encoded)
}

private func thinImage(cpu: UInt32 = 0x0100_000c, uuid: UInt8 = 0x11, version: UInt64 = (651 << 40) | (13 << 30) | (5 << 20)) -> Data {
  var data = Data()
  let words: [UInt32] = [0xfeedfacf, cpu, 0, 6, 2, 40, 0, 0, 0x1b, 24]
  for word in words {
    append(word, to: &data)
  }
  data.append(contentsOf: repeatElement(uuid, count: 16))
  append(UInt32(0x2a), to: &data)
  append(UInt32(16), to: &data)
  append(version, to: &data)
  return data
}

private func fatImage(slices: [Data], fat64: Bool, bigEndian: Bool) -> Data {
  var data = Data()
  append(fat64 ? UInt32(0xcafebabf) : 0xcafebabe, to: &data, bigEndian: bigEndian)
  append(UInt32(slices.count), to: &data, bigEndian: bigEndian)
  var offset = 8 + slices.count * (fat64 ? 32 : 20)
  for slice in slices {
    let cpu = slice.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    append(cpu, to: &data, bigEndian: bigEndian)
    append(UInt32(0), to: &data, bigEndian: bigEndian)
    if fat64 {
      append(UInt64(offset), to: &data, bigEndian: bigEndian)
      append(UInt64(slice.count), to: &data, bigEndian: bigEndian)
    } else {
      append(UInt32(offset), to: &data, bigEndian: bigEndian)
      append(UInt32(slice.count), to: &data, bigEndian: bigEndian)
    }
    append(UInt32(0), to: &data, bigEndian: bigEndian)
    if fat64 { append(UInt32(0), to: &data, bigEndian: bigEndian) }
    offset += slice.count
  }
  for slice in slices { data.append(slice) }
  return data
}
