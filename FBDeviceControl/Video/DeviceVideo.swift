/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import CoreMediaIO
import FBControlCore
import FBVideoCore
import Foundation

private enum DeviceVideoError: Error {
  case failedToEnableScreenCaptureDevices(status: OSStatus)
  case timedOutWaitingForCaptureDevice(timeout: TimeInterval, deviceDescription: String)
  case cannotAddDeviceInput(captureDeviceDescription: String)
}

extension DeviceVideoError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .failedToEnableScreenCaptureDevices(let status):
      return "Failed to enable Screen Capture devices with status \(status)"
    case let .timedOutWaitingForCaptureDevice(timeout, deviceDescription):
      return "Timed out waiting \(timeout)s for device \(deviceDescription) to have an associated capture device appear"
    case .cannotAddDeviceInput(let captureDeviceDescription):
      return "Cannot add Device Input to session for \(captureDeviceDescription)"
    }
  }
}

public final class DeviceVideo {
  private let encoder: VideoFileWriter

  // MARK: - Initialization Helpers

  private static func allowAccessToScreenCaptureDevices() throws {
    var properties = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    let status = unsafe CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject),
      &properties,
      0,
      nil,
      UInt32(MemoryLayout<UInt32>.size),
      &allow
    )
    if status != 0 {
      throw DeviceVideoError.failedToEnableScreenCaptureDevices(status: status)
    }
  }

  private static func findCaptureDevice(for device: Device) async throws -> AVCaptureDevice {
    let timeout = ControlCoreGlobalConfiguration.fastTimeout
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let captureDevice = AVCaptureDevice(uniqueID: device.udid) {
        return captureDevice
      }
      if Date() >= deadline {
        throw DeviceVideoError.timedOutWaitingForCaptureDevice(timeout: timeout, deviceDescription: "\(device)")
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  public static func captureSession(for device: Device) async throws -> AVCaptureSession {
    try allowAccessToScreenCaptureDevices()
    let captureDevice = try await findCaptureDevice(for: device)
    let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
    let session = AVCaptureSession()
    if !session.canAddInput(deviceInput) {
      throw DeviceVideoError.cannotAddDeviceInput(captureDeviceDescription: "\(captureDevice)")
    }
    session.addInput(deviceInput)
    return session
  }

  /// Opens a capture session on `device`'s screen that will record to `filePath`.
  public convenience init(device: Device, filePath: String) async throws {
    let session = try await DeviceVideo.captureSession(for: device)
    let encoder = try VideoFileWriter(session: session, filePath: filePath, logger: device.logger)
    self.init(encoder: encoder)
  }

  private init(encoder: VideoFileWriter) {
    self.encoder = encoder
  }

  public func startRecording() async throws {
    try await encoder.start()
  }

  public func stop() async throws -> URL {
    try await encoder.stop()
  }

}
