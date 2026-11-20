/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBDeviceControl
import Foundation

/// A scripted stand-in for one lockdown service.
///
/// Instances double as the `AMDServiceConnectionRef` the calls are given: a C function pointer
/// cannot capture, so the object itself travels as the opaque ref MobileDevice would have handed
/// back, and each callback recovers it from that pointer.
final class FakeLockdownService: NSObject {
  let serviceName: String

  /// Answers every `receiveMessage` that `messageReplies` does not, so a test scripting a service
  /// it calls repeatedly does not have to predict how many times.
  var repeatingReply: Any?

  /// What the device replies to each `receiveMessage`, consumed in order. A test scripts the far
  /// side of the exchange here.
  var messageReplies: [Any] = []

  /// What the device sends for each raw `receive`, consumed as it is read.
  var readBuffer = Data()

  /// The file service behind this connection, when a test drives one over AFC. Its socket is what
  /// `ServiceConnectionGetSocket` reports, which is how `AFCCalls.Create` finds it.
  var afc: FakeAFC?

  /// Makes raw sends or receives report a failure, the way a broken connection would.
  var sendFails = false
  var receiveFails = false

  private(set) var sentMessages: [Any] = []
  private(set) var sentBytes = Data()
  private(set) var isInvalidated = false

  /// The size of each raw call, so chunking can be asserted rather than inferred.
  private(set) var sendChunks: [Int] = []
  private(set) var receiveRequests: [Int] = []

  init(serviceName: String) {
    self.serviceName = serviceName
  }

  fileprivate func send(message: Any) {
    sentMessages.append(message)
  }

  fileprivate func nextReply() -> Any? {
    messageReplies.isEmpty ? repeatingReply : messageReplies.removeFirst()
  }

  fileprivate func send(bytes: Data) {
    sendChunks.append(bytes.count)
    sentBytes.append(bytes)
  }

  fileprivate func read(upTo count: Int) -> Data {
    receiveRequests.append(count)
    let taken = readBuffer.prefix(count)
    readBuffer.removeFirst(taken.count)
    return Data(taken)
  }

  fileprivate func invalidate() {
    isInvalidated = true
  }
}

/// Mounting is a named function rather than a closure literal assigned to `calls.MountImage`:
/// assigning a literal there crashes the Swift compiler outright, with no diagnostic. The
/// difference is the `AMDeviceProgressCallback` parameter — a C function pointer whose own
/// parameter is an Objective-C object type.
private func fakeMountImage(
  _ deviceRef: AMDevice?,
  _ image: CFString?,
  _ options: CFDictionary?,
  _ callback: AMDeviceProgressCallback?,
  _ context: UnsafeMutableRawPointer?
) -> Int32 {
  guard let device = deviceRef as? FakeAMDevice, let image = image as String? else {
    return 1
  }
  device.record("mount_image:\(image)")
  device.recordMount(path: image)
  return device.mountImageStatus
}

/// An `AMDCalls` table backed by scripted fakes, so a real `MobileDevice` and its commands can be
/// driven through their public API with nothing device-side.
///
/// Every entry a test might reach is populated: `CreateZeroedAMDCalls` leaves the rest as null
/// function pointers, which crash rather than fail. `CopyErrorText` in particular is reached by
/// every failure path.
final class FakeAMDevice: NSObject {

  /// Every call the device made, in order, as `event` or `event:detail`.
  private(set) var events: [String] = []

  /// Answers to `CopyValue`, which is also where `Device` reads its cached device info.
  var values: [String: Any] = [
    "UniqueDeviceID": "fake-udid",
    "ProductVersion": "17.0",
    "ProductType": "iPhone16,1",
    "DeviceName": "Fake Device",
  ]

  /// Status `MountImage` returns. Zero succeeds; the commands treat `0xe8000076` as the distinct
  /// "wrong image for this OS" case.
  var mountImageStatus: Int32 = 0

  /// Status `StartSession` returns; zero succeeds.
  var startSessionStatus: Int32 = 0

  /// Run inside `Connect`, before it returns, so a test can hold the connect open while other
  /// callers arrive.
  var onConnect: (@Sendable () -> Void)?

  private(set) var mountedImagePaths: [String] = []

  /// The device as it appears while restoring, when a test drives one. Must be set before the
  /// device is made, since the call table is built then.
  var restorable: FakeRestorableDevice?

  private var services: [String: FakeLockdownService] = [:]

  /// What `LookupApplications` reports, keyed by bundle identifier.
  var installedApplications: [String: [String: Any]] = [:]

  /// The scripted service of this name, created empty on first use so a test can set up a reply
  /// before the code under test starts it.
  func service(_ serviceName: String) -> FakeLockdownService {
    if let existing = services[serviceName] {
      return existing
    }
    let created = FakeLockdownService(serviceName: serviceName)
    services[serviceName] = created
    return created
  }

  func clearEvents() {
    events.removeAll()
  }

  fileprivate func record(_ event: String) {
    events.append(event)
  }

  fileprivate func recordMount(path: String) {
    mountedImagePaths.append(path)
  }

  // MARK: - Building a device

  /// A `MobileDevice` whose every `MobileDevice.framework` interaction lands on this fake.
  ///
  /// Both queues are the main queue, matching the other AMDevice tests: the callbacks mutate this
  /// object from whichever queue the device uses, so the assertions have to read it from the same
  /// one.
  func makeAMDevice() -> MobileDevice {
    let device = MobileDevice(
      allValues: values,
      calls: calls,
      connectionReuseTimeout: nil,
      serviceReuseTimeout: nil,
      work: DispatchQueue.main,
      asyncQueue: DispatchQueue.main,
      logger: ControlCoreGlobalConfiguration.defaultLogger)
    device.amDeviceRef = self
    clearEvents()
    return device
  }

  /// A `Device` — the type the command classes take, and so the type public-API tests need.
  func makeDevice(
    developerDiskImages: any DeveloperDiskImageProviding = InstalledDeveloperDiskImages(),
    devicectlLauncher: any SubprocessLauncher = HostSubprocessLauncher()
  ) -> Device {
    Device(
      amDevice: makeAMDevice(),
      restorableDevice: nil,
      logger: ControlCoreGlobalConfiguration.defaultLogger,
      developerDiskImages: developerDiskImages,
      devicectlLauncher: devicectlLauncher)
  }

  // MARK: - The call table

  var calls: AMDCalls {
    var calls = CreateZeroedAMDCalls()

    // Lifecycle. Reference counting is a no-op: this object is owned by the test.
    calls.Retain = { _ in }
    calls.Release = { _ in }

    calls.Connect = { deviceRef in
      guard let device = FakeAMDevice.device(deviceRef) else {
        return 1
      }
      device.record("connect")
      device.onConnect?()
      return 0
    }
    calls.Disconnect = { deviceRef in
      FakeAMDevice.device(deviceRef)?.record("disconnect")
      return 0
    }
    calls.IsPaired = { deviceRef in
      FakeAMDevice.device(deviceRef)?.record("is_paired")
      return 1
    }
    calls.ValidatePairing = { deviceRef in
      FakeAMDevice.device(deviceRef)?.record("validate_pairing")
      return 0
    }
    calls.StartSession = { deviceRef in
      guard let device = FakeAMDevice.device(deviceRef) else {
        return 1
      }
      device.record("start_session")
      return device.startSessionStatus
    }
    calls.StopSession = { deviceRef in
      FakeAMDevice.device(deviceRef)?.record("stop_session")
      return 0
    }

    calls.CopyValue = { deviceRef, _, key in
      guard let device = FakeAMDevice.device(deviceRef), let key = key as? String else {
        return nil
      }
      device.record("copy_value:\(key)")
      guard let value = device.values[key] else {
        return nil
      }
      // The header declares this as returning `CFStringRef`, but MobileDevice returns whatever CF
      // type the key holds — `AMDeviceManager` reads `UniqueChipID` back as an `NSNumber`. The
      // fake has to under-declare in the same way to answer non-string keys.
      return unsafeBitCast(Unmanaged.passRetained(value as AnyObject), to: Unmanaged<CFString>.self)
    }

    // Starting a service hands back the scripted service as the connection ref.
    calls.SecureStartService = { deviceRef, serviceName, _, serviceOut in
      guard let device = FakeAMDevice.device(deviceRef), let serviceName = serviceName as? String else {
        return 1
      }
      device.record("secure_start_service:\(serviceName)")
      // Handed over at +1: `AMDServiceConnectionInvalidate` does not release the connection, so
      // `LockdownServiceConnection.invalidate` `CFRelease`s it itself. This object stays alive
      // regardless, since the service dictionary holds its own reference.
      serviceOut?.pointee = Unmanaged.passRetained(device.service(serviceName) as CFTypeRef)
      return 0
    }

    calls.MountImage = fakeMountImage

    calls.LookupApplications = { deviceRef, _, attributesOut in
      guard let device = FakeAMDevice.device(deviceRef) else {
        return 1
      }
      // The caller takes this at +1.
      attributesOut.pointee = Unmanaged.passRetained(device.installedApplications as CFDictionary)
      return 0
    }

    calls.ServiceConnectionGetSocket = { connectionRef in
      FakeAMDevice.service(connectionRef)?.afc?.socket ?? -1
    }

    calls.ServiceConnectionGetSecureIOContext = { _ in nil }

    calls.ServiceConnectionInvalidate = { connectionRef in
      guard let service = FakeAMDevice.service(connectionRef) else {
        return 1
      }
      service.invalidate()
      return 0
    }

    // The plist data plane.
    calls.ServiceConnectionSendMessage = { connectionRef, propertyList, _, _, _, _ in
      guard let service = FakeAMDevice.service(connectionRef) else {
        return 1
      }
      service.send(message: propertyList as Any)
      return 0
    }
    calls.ServiceConnectionReceiveMessage = { connectionRef, messageOut, _, _, _, _ in
      guard let service = FakeAMDevice.service(connectionRef), let reply = service.nextReply() else {
        return 1
      }
      // The caller CFBridgingReleases this, so it must be handed over at +1.
      messageOut?.pointee = Unmanaged.passRetained(reply as CFTypeRef)
      return 0
    }

    // The raw data plane.
    calls.ServiceConnectionSend = { connectionRef, buffer, size in
      guard let service = FakeAMDevice.service(connectionRef), let buffer, !service.sendFails else {
        return -1
      }
      service.send(bytes: Data(bytes: buffer, count: size))
      return Int32(size)
    }
    calls.ServiceConnectionReceive = { connectionRef, buffer, size in
      guard let service = FakeAMDevice.service(connectionRef), let buffer, !service.receiveFails else {
        return -1
      }
      let data = service.read(upTo: size)
      data.withUnsafeBytes { source in
        guard let base = source.baseAddress else { return }
        buffer.copyMemory(from: base, byteCount: data.count)
      }
      return Int32(data.count)
    }

    // Reached by every failure path, so it cannot be left null.
    calls.CopyErrorText = { status in
      Unmanaged.passRetained("fake AMDevice error \(status)" as CFString)
    }

    restorable?.install(into: &calls)

    return calls
  }

  // MARK: - Recovering the fakes from the opaque refs

  fileprivate static func device(_ ref: AnyObject?) -> FakeAMDevice? {
    ref as? FakeAMDevice
  }

  private static func service(_ ref: AnyObject?) -> FakeLockdownService? {
    ref as? FakeLockdownService
  }
}
