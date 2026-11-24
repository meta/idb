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
  case timedOutWaitingForCaptureDevice(timeout: TimeInterval, deviceDescription: String, screenDevices: [String], discoveryDetail: String?)
  case cannotAddDeviceInput(captureDeviceDescription: String)
}

extension DeviceVideoError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .failedToEnableScreenCaptureDevices(let status):
      return "Failed to enable Screen Capture devices with status \(status)"
    case let .timedOutWaitingForCaptureDevice(timeout, deviceDescription, screenDevices, discoveryDetail):
      let seen = screenDevices.isEmpty ? "none" : screenDevices.joined(separator: ", ")
      let detail = discoveryDetail.map { "; \($0)" } ?? ""
      return "Timed out waiting \(timeout)s for device \(deviceDescription) to have an associated capture device appear (screen capture devices seen: \(seen))\(detail)"
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

  /// Discovers the screen capture devices of attached devices: muxed external devices. Its
  /// `devices` stay current while it is held, and some macOS releases list a device's screen only
  /// once a discovery session has been held.
  private static func screenCaptureDiscovery() -> AVCaptureDevice.DiscoverySession {
    // Consumers link this library with deployment targets below macOS 14, where `.external` was
    // still `.externalUnknown`.
    let external: AVCaptureDevice.DeviceType
    if #available(macOS 14.0, *) {
      external = .external
    } else {
      external = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: [external], mediaType: .muxed, position: .unspecified)
  }

  struct CaptureIdentity {
    private let identifier: String?
    private let wiredName: String?
    private let wiredNameCount: Int

    init(udid: String, coreDevices: [CoreDeviceEntry]) {
      let requested = coreDevices.filter { $0.udid == udid }
      identifier = requested.count == 1 ? requested.first?.identifier : nil
      if requested.count == 1, let device = requested.first, device.isWired, let name = device.name, !name.isEmpty {
        wiredName = name
        wiredNameCount = coreDevices.count { $0.isWired && $0.name == name }
      } else {
        wiredName = nil
        wiredNameCount = 0
      }
    }

    var nameAmbiguity: String? {
      guard let wiredName, wiredNameCount > 1 else { return nil }
      return "\(wiredNameCount) wired devices are named '\(wiredName)'; give the requested device a unique name in Settings > General > About"
    }

    func match<Candidate>(among candidates: [Candidate], uniqueID: (Candidate) -> String, localizedName: (Candidate) -> String) -> Candidate? {
      if let identifier, let exact = candidates.first(where: { uniqueID($0).caseInsensitiveCompare(identifier) == .orderedSame }) {
        return exact
      }
      guard let wiredName, wiredNameCount == 1 else { return nil }
      let named = candidates.filter { localizedName($0) == wiredName }
      return named.count == 1 ? named.first : nil
    }
  }

  private static func findCaptureDevice(for device: Device) async throws -> AVCaptureDevice {
    let discovery = screenCaptureDiscovery()
    if let captureDevice = AVCaptureDevice(uniqueID: device.udid) {
      return captureDevice
    }
    var coreDevices: [CoreDeviceEntry] = []
    var coreDeviceFailure: String?
    do {
      coreDevices = try await AppleDevicectlCommandExecutor.listDevices(logger: device.logger)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch {
      coreDeviceFailure = "CoreDevice identity unavailable: \(error.localizedDescription)"
    }
    let identity = CaptureIdentity(udid: device.udid, coreDevices: coreDevices)
    let timeout = ControlCoreGlobalConfiguration.regularTimeout
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let candidates = discovery.devices
      if let captureDevice = AVCaptureDevice(uniqueID: device.udid)
        ?? identity.match(among: candidates, uniqueID: \.uniqueID, localizedName: \.localizedName)
      {
        return captureDevice
      }
      if Date() >= deadline {
        throw DeviceVideoError.timedOutWaitingForCaptureDevice(
          timeout: timeout, deviceDescription: "\(device)", screenDevices: candidates.map { "\($0.localizedName) (\($0.uniqueID))" },
          discoveryDetail: coreDeviceFailure ?? identity.nameAmbiguity)
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
