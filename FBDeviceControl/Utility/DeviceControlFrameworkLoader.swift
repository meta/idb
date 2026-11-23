/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

/// Reinterprets a `dlsym` result as the function pointer the call table expects.
///
/// The optional variant is used so a name that does not resolve is reported as an error naming it.
/// `symbolFromHandle` traps instead, which would take the process down on a missing symbol rather
/// than let the loader report which one is absent.
private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
  guard let address = unsafe symbolFromHandleIfPresent(handle, name) else {
    throw DeviceControlFrameworkLoaderError.symbolNotFound(name: name)
  }
  return unsafe unsafeBitCast(address, to: T.self)
}

/// Loads the frameworks FBDeviceControl depends on and initializes values.
///
/// `@unchecked Sendable`: the resolved call table is the only mutable state, and `lock` guards it.
// patternlint-disable-next-line unchecked-sendable
public final class DeviceControlFrameworkLoader: FrameworkLoading, @unchecked Sendable {

  private let frameworks = FrameworkLoader(name: "FBDeviceControl", frameworks: [WeakFramework.mobileDevice])
  private let lock = NSLock()
  private var resolvedCalls: AMDCalls?

  public init() {}

  /// Loads MobileDevice and resolves its call table, at most once per instance.
  public func loadPrivateFrameworks(_ logger: (any ControlCoreLogger)?) throws {
    try lock.withLock {
      if resolvedCalls != nil {
        return
      }
      try frameworks.loadPrivateFrameworks(logger)
      let calls = try Self.resolveAMDeviceCalls()
      calls.InitializeMobileDevice()
      resolvedCalls = calls
    }
  }

  /// The AMDevice calls to use, resolved by a successful `loadPrivateFrameworks`.
  var amDeviceCalls: AMDCalls {
    get throws {
      guard let resolvedCalls = lock.withLock({ resolvedCalls }) else {
        throw DeviceControlFrameworkLoaderError.frameworksNotLoaded
      }
      return resolvedCalls
    }
  }

  /// Memberwise, so a symbol added to `AMDCalls` without being resolved here fails to compile.
  private static func resolveAMDeviceCalls() throws -> AMDCalls {
    guard let handle = unsafe Bundle(identifier: "com.apple.mobiledevice")?.dlopenExecutablePath() else {
      throw DeviceControlFrameworkLoaderError.mobileDeviceUnavailable
    }
    return unsafe try AMDCalls(
      Connect: symbol(handle, "AMDeviceConnect"),
      Disconnect: symbol(handle, "AMDeviceDisconnect"),
      IsPaired: symbol(handle, "AMDeviceIsPaired"),
      Pair: symbol(handle, "AMDevicePair"),
      StartSession: symbol(handle, "AMDeviceStartSession"),
      StopSession: symbol(handle, "AMDeviceStopSession"),
      ValidatePairing: symbol(handle, "AMDeviceValidatePairing"),
      Retain: symbol(handle, "AMDeviceRetain"),
      Release: symbol(handle, "AMDeviceRelease"),
      CopyDeviceIdentifier: symbol(handle, "AMDeviceCopyDeviceIdentifier"),
      CopyValue: symbol(handle, "AMDeviceCopyValue"),
      CreateDeviceList: symbol(handle, "AMDCreateDeviceList"),
      NotificationSubscribe: symbol(handle, "AMDeviceNotificationSubscribe"),
      NotificationUnsubscribe: symbol(handle, "AMDeviceNotificationUnsubscribe"),
      ServiceConnectionGetSocket: symbol(handle, "AMDServiceConnectionGetSocket"),
      ServiceConnectionInvalidate: symbol(handle, "AMDServiceConnectionInvalidate"),
      ServiceConnectionReceive: symbol(handle, "AMDServiceConnectionReceive"),
      ServiceConnectionReceiveMessage: symbol(handle, "AMDServiceConnectionReceiveMessage"),
      ServiceConnectionSend: symbol(handle, "AMDServiceConnectionSend"),
      ServiceConnectionSendMessage: symbol(handle, "AMDServiceConnectionSendMessage"),
      ServiceConnectionGetSecureIOContext: symbol(handle, "AMDServiceConnectionGetSecureIOContext"),
      EnterRecovery: symbol(handle, "AMDeviceEnterRecovery"),
      RestorableDeviceGetRecoveryModeDevice: symbol(handle, "AMRestorableDeviceGetRecoveryModeDevice"),
      RecoveryModeDeviceSetAutoBoot: symbol(handle, "AMRecoveryModeDeviceSetAutoBoot"),
      RecoveryDeviceReboot: symbol(handle, "AMRecoveryModeDeviceReboot"),
      CreateHouseArrestService: symbol(handle, "AMDeviceCreateHouseArrestService"),
      LookupApplications: symbol(handle, "AMDeviceLookupApplications"),
      SecureInstallApplication: symbol(handle, "AMDeviceSecureInstallApplication"),
      SecureInstallApplicationBundle: symbol(handle, "AMDeviceSecureInstallApplicationBundle"),
      SecureStartService: symbol(handle, "AMDeviceSecureStartService"),
      SecureTransferPath: symbol(handle, "AMDeviceSecureTransferPath"),
      SecureUninstallApplication: symbol(handle, "AMDeviceSecureUninstallApplication"),
      MountImage: symbol(handle, "AMDeviceMountImage"),
      CopyProvisioningProfiles: symbol(handle, "AMDeviceCopyProvisioningProfiles"),
      ProvisioningProfileCopyPayload: symbol(handle, "MISProfileCopyPayload"),
      ProvisioningProfileCreateWithData: symbol(handle, "MISProfileCreateWithData"),
      InstallProvisioningProfile: symbol(handle, "AMDeviceInstallProvisioningProfile"),
      RemoveProvisioningProfile: symbol(handle, "AMDeviceRemoveProvisioningProfile"),
      ProvisioningProfileGetUUID: symbol(handle, "MISProvisioningProfileGetUUID"),
      ProvisioningProfileCopyErrorStringForCode: symbol(handle, "MISCopyErrorStringForErrorCode"),
      RestorableDeviceRegisterForNotifications: symbol(handle, "AMRestorableDeviceRegisterForNotifications"),
      RestorableDeviceUnregisterForNotifications: symbol(handle, "AMRestorableDeviceUnregisterForNotifications"),
      RestorableDeviceCopyBoardConfig: symbol(handle, "AMRestorableDeviceCopyBoardConfig"),
      RestorableDeviceCopyProductString: symbol(handle, "AMRestorableDeviceCopyProductString"),
      RestorableDeviceCopySerialNumber: symbol(handle, "AMRestorableDeviceCopySerialNumber"),
      RestorableDeviceCopyUserFriendlyName: symbol(handle, "AMRestorableDeviceCopyUserFriendlyName"),
      RestorableDeviceGetBoardID: symbol(handle, "AMRestorableDeviceGetBoardID"),
      RestorableDeviceGetChipID: symbol(handle, "AMRestorableDeviceGetChipID"),
      RestorableDeviceGetDeviceClass: symbol(handle, "AMRestorableDeviceGetDeviceClass"),
      RestorableDeviceGetECID: symbol(handle, "AMRestorableDeviceGetECID"),
      RestorableDeviceGetLocationID: symbol(handle, "AMRestorableDeviceGetLocationID"),
      RestorableDeviceGetProductType: symbol(handle, "AMRestorableDeviceGetProductType"),
      RestorableDeviceGetState: symbol(handle, "AMRestorableDeviceGetState"),
      AMSInitialize: symbol(handle, "AMSInitialize"),
      AMSEraseDevice: symbol(handle, "AMSEraseDevice"),
      GetConnectionID: symbol(handle, "AMDeviceGetConnectionID"),
      USBMuxConnectByPort: symbol(handle, "USBMuxConnectByPort"),
      InitializeMobileDevice: symbol(handle, "_InitializeMobileDevice"),
      SetLogLevel: symbol(handle, "AMDSetLogLevel"),
      CopyErrorText: symbol(handle, "AMDCopyErrorText")
    )
  }
}

public enum DeviceControlFrameworkLoaderError: Error, LocalizedError {
  case mobileDeviceUnavailable
  case frameworksNotLoaded
  case symbolNotFound(name: String)

  public var errorDescription: String? {
    switch self {
    case .mobileDeviceUnavailable:
      return "MobileDevice.framework could not be opened"
    case .frameworksNotLoaded:
      return "The AMDevice calls are not available until the private frameworks have been loaded"
    case let .symbolNotFound(name):
      return "\(name) could not be located in MobileDevice.framework"
    }
  }
}
