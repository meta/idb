/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Dispatch
import Foundation
internal import IDBConcurrency

/// Contains no CoreDevice types: all private metadata use follows this gate.
enum DeviceHIDRuntime {
  struct Image: Sendable {
    let name: String
    let symbols: [String]
    var path: String { "/Library/Developer/PrivateFrameworks/\(name).framework/Versions/A/\(name)" }
  }

  struct Identity: Sendable {
    let path: String
    let uuid: String
    let version: String
  }

  private static let queue = DispatchQueue(label: "com.facebook.idb.device-hid.runtime")

  static func checkAsync(
    work: @escaping @Sendable () throws -> Void = { try DeviceHIDRuntime.check() },
    timeout: TimeInterval = 10,
    timerQueue: DispatchQueue = .global()
  ) async throws {
    guard timeout.isFinite, timeout >= 0, timeout <= 3600 else {
      throw DeviceHIDError.unsupportedRuntime("The preflight timeout must be between zero and one hour")
    }
    struct WaitState {
      var result: Result<Void, any Error>?
      var continuation: CheckedContinuation<Void, any Error>?
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    let state = Atomic(wrappedValue: WaitState())
    @Sendable func finish(_ raw: Result<Void, any Error>) {
      let result = raw.mapError { error -> any Error in
        if error is CancellationError { return CancellationError() }
        return DeviceHIDError.native(error, operation: "runtime preflight")
      }
      withExtendedLifetime(raw) {
        let publication = state.sync { state -> (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) in
          guard state.result == nil else { return (nil, result) }
          let accepted: Result<Void, any Error> = ContinuousClock.now < deadline ? result : .failure(DeviceHIDError.deadlineExceeded)
          state.result = accepted
          let continuation = state.continuation
          state.continuation = nil
          return (continuation, accepted)
        }
        publication.0?.resume(with: publication.1)
      }
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = state.sync { state -> Result<Void, any Error>? in
          if let result = state.result { return result }
          state.continuation = continuation
          return nil
        }
        if let result {
          continuation.resume(with: result)
          return
        }
        queue.async {
          guard state.sync(execute: { $0.result == nil }) else { return }
          guard ContinuousClock.now < deadline else {
            finish(.failure(DeviceHIDError.deadlineExceeded))
            return
          }
          finish(Result { try work() })
        }
        timerQueue.asyncAfter(deadline: .now() + timeout) {
          finish(.failure(DeviceHIDError.deadlineExceeded))
        }
      }
    } onCancel: {
      finish(.failure(CancellationError()))
    }
  }

  static let minimumVersion = "651.13.5"
  // Named weak references only; metadata reached through them needs no separate exported name.
  // Ownership names the defining image, which may differ from the re-exporting linked image.
  static let images: [Image] = [
    Image(
      name: "CoreDevice",
      symbols: [
        "$s10CoreDevice0B7ManagerC6sharedACvgZ",
        "$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF",
        "$s10CoreDevice06RemoteB0C2id10Foundation4UUIDVvg",
        "$s10CoreDevice26UsageAssertionRequirementsV12deviceStates12capabilitiesACShyAA010AssertableB5StateVG_ShyAA10CapabilityVGtcfC",
        "$s10CoreDevice010AssertableB5StateVSHAAMc",
        "$s10CoreDevice06RemoteB0C07acquireB14UsageAssertion10withReason12requirements27invokingCompletionHandlerOn010completionL0So10NSProgressCSS_AA0eF12RequirementsVSo17OS_dispatch_queueCSgys6ResultOyAA0beF0Cs5Error_pGYbctF",
        "$s10CoreDevice0B14UsageAssertionC07releaseD0yyFTj",
        "$s10CoreDevice0B14UsageAssertionC27registerInvalidationHandler15invokingOnQueue7handlerySo17OS_dispatch_queueCSg_ys5Error_pSgctFTj",
        "$s10CoreDevice010AssertableB5StateVMa",
        "$s10CoreDevice06RemoteB0CMa",
        "$s10CoreDevice06RemoteB0CMn",
        "$s10CoreDevice0B7ManagerCMa",
        "$s10CoreDevice26UsageAssertionRequirementsVMa",
        "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTjTu",
        "$s10CoreDevice0B10CapabilityTL",
        "$s12ProtocolType10CoreDevice0D10CapabilityPTl",
        "$s10CoreDevice22CapabilityStaticMemberVACyxGycfC",
        "$s10CoreDevice22CapabilityStaticMemberVMn",
        "$s10CoreDevice22DigitizerHIDCapabilityVMa",
        "$s10CoreDevice22DigitizerHIDCapabilityVMn",
        "$s10CoreDevice12HIDDigitizerMp",
        "$s10CoreDevice0B14UsageAssertionCMa",
        "$s10CoreDevice0B14UsageAssertionCMn",
        "$s10CoreDevice22DigitizerHIDCapabilityVAA0B10CapabilityAAWP",
        "$s10CoreDevice12HIDDigitizerPAAE4send8pointOne0E3Two9eventType4edge6targetySo7CGPointV_AKSgAA014DigitizerEventI0OAA0M4EdgeOAA0M6TargetOtKF",
        "$s10CoreDevice12HIDDigitizerP11sendBarrieryyFTj",
      ]),
    Image(
      name: "CoreDeviceUtilities",
      symbols: [
        "$s10CoreDevice10CapabilityVSHAAMc",
        "$s10CoreDevice10CapabilityVMa",
        "$s10CoreDevice18DigitizerEventTypeOMa",
        "$s10CoreDevice13DigitizerEdgeOMa",
        "$s10CoreDevice15DigitizerTargetOMa",
        "$s10CoreDevice18DigitizerEventTypeO5startyA2CmFWC",
        "$s10CoreDevice18DigitizerEventTypeO8positionyA2CmFWC",
        "$s10CoreDevice18DigitizerEventTypeO3endyA2CmFWC",
        "$s10CoreDevice13DigitizerEdgeO4noneyA2CmFWC",
        "$s10CoreDevice15DigitizerTargetO10mainScreenyA2CmFWC",
      ]),
  ]

  static func validateHost(arm64: Bool, version: OperatingSystemVersion, build: String) throws {
    let supportedOS = version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 6)
    guard arm64, supportedOS else {
      throw DeviceHIDError.unsupportedRuntime("Native arm64 macOS 26.6 or newer is required; observed arm64=\(arm64), macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion), build \(build)")
    }
  }

  private static func supportsVersion(_ version: String?) -> Bool {
    guard let version, !version.isEmpty,
      version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ component in
        !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
      })
    else { return false }
    return version.compare(minimumVersion, options: .numeric) != .orderedAscending
  }

  static func validateImage(_ image: Image, version: String?) throws {
    guard supportsVersion(version) else {
      throw DeviceHIDError.unsupportedRuntime("\(image.name) \(minimumVersion) or newer is required; observed version \(version.map { String(reflecting: $0) } ?? "<missing>")")
    }
  }

  static func validateIdentity(_ identity: Identity?, image: Image, installedVersions: [String: String], symbol: String) throws {
    guard let identity, identity.path == canonicalPath(image.path), installedVersions[identity.uuid] == identity.version else {
      throw DeviceHIDError.unsupportedRuntime("Missing or unexpected owner for \(symbol)")
    }
    try validateImage(image, version: identity.version)
  }

  /// Version and UUID come from the same bytes, never separately replaceable bundle metadata.
  static func captureImage(
    _ image: Image,
    read: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
  ) throws -> [String: String] {
    let versions = fileIdentities(in: try read(image.path))
    guard !versions.isEmpty else {
      throw DeviceHIDError.unsupportedRuntime("Cannot read the installed arm64 identity and source version of \(image.name)")
    }
    guard versions.values.contains(where: { supportsVersion($0) }) else {
      throw DeviceHIDError.unsupportedRuntime("\(image.name) \(minimumVersion) or newer is required; observed source versions \(versions.values.sorted().joined(separator: ", "))")
    }
    return versions
  }

  /// Synchronous file/dyld work; the command invokes it on its native-work queue.
  static func check() throws {
    #if arch(arm64)
    let arm64 = true
    #else
    let arm64 = false
    #endif
    var length = 0
    guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0, length < 256 else {
      throw DeviceHIDError.unsupportedRuntime("Cannot read the host build")
    }
    var bytes = [UInt8](repeating: 0, count: length)
    let result = bytes.withUnsafeMutableBytes { sysctlbyname("kern.osversion", $0.baseAddress, &length, nil, 0) }
    guard result == 0 else { throw DeviceHIDError.unsupportedRuntime("Cannot read the host build") }
    try validateHost(arm64: arm64, version: ProcessInfo.processInfo.operatingSystemVersion, build: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))

    // Capture both images before loading either; the loaded headers must match these snapshots.
    let installed = try images.map { image in (image, try captureImage(image)) }
    // Handles remain live for process lifetime.
    for (image, versions) in installed {
      guard let handle = dlopen(image.path, RTLD_NOW | RTLD_LOCAL), let anchor = image.symbols.first,
        let address = dlsym(handle, anchor)
      else { throw DeviceHIDError.unsupportedRuntime("Cannot load \(image.name)") }
      try validateIdentity(loadedIdentity(address), image: image, installedVersions: versions, symbol: anchor)
    }
    for (image, versions) in installed {
      for symbol in image.symbols {
        let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol)
        try validateIdentity(address.flatMap { loadedIdentity($0) }, image: image, installedVersions: versions, symbol: symbol)
      }
    }
  }

  /// UUID-to-source-version pairs from the installed arm64 slices, not a historical allowlist.
  static func fileIdentities(in data: Data) -> [String: String] {
    func read<Value: FixedWidthInteger>(_ type: Value.Type, at offset: Int, swapped: Bool = false) -> Value? {
      guard offset >= 0, offset <= data.count, MemoryLayout<Value>.size <= data.count - offset else { return nil }
      let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
      return swapped ? value.byteSwapped : value
    }
    func sliceIdentity(at offset: Int, size: Int) -> (uuid: String, version: String)? {
      guard size >= 32, offset >= 0, offset <= data.count, size <= data.count - offset,
        read(UInt32.self, at: offset) == 0xfeedfacf,
        read(UInt32.self, at: offset + 4) == 0x0100_000c,
        let commandBytes = read(UInt32.self, at: offset + 20), Int(commandBytes) <= size - 32
      else { return nil }
      return data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return nil }
        return headerIdentity(base.advanced(by: offset))
      }
    }
    guard let magic = read(UInt32.self, at: 0) else { return [:] }
    if magic == 0xfeedfacf {
      return sliceIdentity(at: 0, size: data.count).map { [$0.uuid: $0.version] } ?? [:]
    }
    let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
    guard fat64 || magic == 0xcafebabe || magic == 0xbebafeca else { return [:] }
    let swapped = magic == 0xbebafeca || magic == 0xbfbafeca
    let entrySize = fat64 ? 32 : 20
    guard let count = read(UInt32.self, at: 4, swapped: swapped), count <= 4096,
      Int(count) <= (data.count - 8) / entrySize
    else { return [:] }
    let headerEnd = 8 + Int(count) * entrySize
    var versions: [String: String] = [:]
    for index in 0..<Int(count) {
      let entry = 8 + index * entrySize
      guard let cpuType = read(UInt32.self, at: entry, swapped: swapped) else { return [:] }
      let rawOffset: UInt64?
      let rawSize: UInt64?
      if fat64 {
        rawOffset = read(UInt64.self, at: entry + 8, swapped: swapped)
        rawSize = read(UInt64.self, at: entry + 16, swapped: swapped)
      } else {
        rawOffset = read(UInt32.self, at: entry + 8, swapped: swapped).map(UInt64.init)
        rawSize = read(UInt32.self, at: entry + 12, swapped: swapped).map(UInt64.init)
      }
      guard let rawOffset, let rawSize, let offset = Int(exactly: rawOffset), let size = Int(exactly: rawSize),
        offset >= headerEnd, offset <= data.count, size <= data.count - offset
      else { return [:] }
      guard cpuType == 0x0100_000c else { continue }
      guard let identity = sliceIdentity(at: offset, size: size),
        versions[identity.uuid] == nil || versions[identity.uuid] == identity.version
      else { return [:] }
      versions[identity.uuid] = identity.version
    }
    return versions
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private static func loadedIdentity(_ address: UnsafeRawPointer) -> Identity? {
    var info = Dl_info()
    guard dladdr(address, &info) != 0, let name = info.dli_fname, let base = info.dli_fbase,
      let identity = headerIdentity(base)
    else { return nil }
    return Identity(path: canonicalPath(String(cString: name)), uuid: identity.uuid, version: identity.version)
  }

  private static func headerIdentity(_ base: UnsafeRawPointer) -> (uuid: String, version: String)? {
    guard base.loadUnaligned(as: UInt32.self) == 0xfeedfacf else { return nil }
    let count = Int(base.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
    let bytes = Int(base.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
    guard count < 4096, bytes < 16 * 1024 * 1024 else { return nil }
    var offset = 32
    var uuid: String?
    var version: String?
    for _ in 0..<count {
      guard offset + 8 <= 32 + bytes else { return nil }
      let command = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
      let size = Int(base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
      guard size >= 8, size <= 32 + bytes - offset else { return nil }
      if command == 0x1b {
        guard size == 24, uuid == nil else { return nil }
        let value = UnsafeBufferPointer(start: base.advanced(by: offset + 8).assumingMemoryBound(to: UInt8.self), count: 16)
        uuid = value.map { String(format: "%02x", $0) }.joined()
      } else if command == 0x2a {
        guard size == 16, version == nil else { return nil }
        let value = base.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)
        var components = [value >> 40, (value >> 30) & 0x3ff, (value >> 20) & 0x3ff, (value >> 10) & 0x3ff, value & 0x3ff]
        while components.count > 1, components.last == 0 { components.removeLast() }
        version = components.map { String($0) }.joined(separator: ".")
      }
      offset += size
    }
    guard offset == 32 + bytes, let uuid, let version else { return nil }
    return (uuid, version)
  }
}
