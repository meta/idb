/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import MobileDeviceAPI

private let CrashReportMoverService = "com.apple.crashreportmover"
private let CrashReportCopyService = "com.apple.crashreportcopymobile"
private let PingSuccess = "ping"

public enum DeviceCrashLogError: Error {
  case ingestFailed(name: String)
  case pingbackReceiveFailed(service: String, underlying: any Error)
  case pingbackNotDecodable(service: String)
  case pingbackUnsuccessful(service: String, response: String, expected: String)
}

extension DeviceCrashLogError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .ingestFailed(name):
      return "Failed to ingest crash log data for \(name)"
    case let .pingbackReceiveFailed(service, _):
      return "Failed to get pingback from \(service)"
    case let .pingbackNotDecodable(service):
      return "Failed to decode pingback from \(service)"
    case let .pingbackUnsuccessful(service, response, expected):
      return "Pingback from \(service) is '\(response)' not '\(expected)'"
    }
  }
}

public final class DeviceCrashLogCommands: CrashLogCommands {
  private weak var device: Device?
  private let store: CrashLogStore
  /// Resolved at the point of use: `FileConduit.defaultCalls` dlopens MobileDevice on first
  /// evaluation and aborts if the private frameworks are not loaded, so constructing these
  /// commands must not read it.
  private let injectedAFCCalls: AFCCalls?

  private var afcCalls: AFCCalls {
    injectedAFCCalls ?? FileConduit.defaultCalls
  }
  private var hasPerformedInitialIngestion: Bool = false

  // MARK: - Initializers

  public convenience init(device: Device) {
    let storeDirectory = (device.auxillaryDirectory as NSString).appendingPathComponent("crash_store")
    self.init(device: device, store: CrashLogStore(directories: [storeDirectory], logger: device.logger))
  }

  init(device: Device, store: CrashLogStore, afcCalls: AFCCalls? = nil) {
    self.device = device
    self.store = store
    self.injectedAFCCalls = afcCalls
  }

  // MARK: - Notify

  public func notifyOfCrash(matching predicate: CrashLogPredicate) async throws -> CrashLogInfo {
    let listener = store.listenForNextCrashLog(matching: predicate)
    // A crash ingested later, by any caller, still resolves the wait, so failing to ingest now does
    // not end it.
    do {
      try await ingestAllCrashLogs(useCache: false)
    } catch {
      device?.logger.log("Failed to ingest crash logs while waiting for a crash: \(error)")
    }
    return try await listener.next()
  }

  // MARK: - Async

  public func crashes(matching predicate: CrashLogPredicate, useCache: Bool) async throws -> [CrashLogInfo] {
    guard device != nil else {
      throw DeviceNilError.deviceNil
    }
    _ = try await ingestAllCrashLogs(useCache: useCache)
    return store.ingestedCrashLogs(matchingPredicate: predicate)
  }

  public func prune(matching predicate: CrashLogPredicate) async throws -> [CrashLogInfo] {
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    let logger = device.logger.withName("crash_remove")
    _ = try await ingestAllCrashLogs(useCache: true)
    let pruned = store.pruneCrashLogs(matchingPredicate: predicate)
    logger.log("Pruned \(CollectionInformation.oneLineDescription(from: pruned.map(\.name))) logs from local cache")
    return try await removeCrashLogsFromDevice(pruned, logger: logger)
  }

  public func withFiles<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    let queue = device.asyncQueue
    return try await device.withAFCConnection(CrashReportCopyService) { afc in
      try await body(DeviceFileContainer(afcConnection: afc, queue: queue))
    }
  }

  // MARK: - Private

  @discardableResult
  private func ingestAllCrashLogs(useCache: Bool) async throws -> [CrashLogInfo] {
    if hasPerformedInitialIngestion && useCache {
      return []
    }
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    let logger = device.logger
    _ = try await moveCrashReports()
    return try await withCrashReportFileConnection { afc in
      if !self.hasPerformedInitialIngestion {
        self.store.ingestAllExistingInDirectory()
        self.hasPerformedInitialIngestion = true
      }
      let paths = try afc.contents(ofDirectory: ".")
      var crashes: [CrashLogInfo] = []
      for path in paths {
        do {
          let crash = try self.crashLogInfo(afc: afc, path: path)
          crashes.append(crash)
        } catch {
          logger.log("Failed to ingest crash log \(path): \(error)")
        }
      }
      return crashes
    }
  }

  private func removeCrashLogsFromDevice(_ crashesToRemove: [CrashLogInfo], logger: (any ControlCoreLogger)?) async throws -> [CrashLogInfo] {
    guard device != nil else {
      throw DeviceNilError.deviceNil
    }
    return try await withCrashReportFileConnection { afc in
      var removed: [CrashLogInfo] = []
      for crash in crashesToRemove {
        do {
          try afc.removePath(crash.name, recursively: false)
          logger?.log("Crash \(crash.name) removed from device")
          removed.append(crash)
        } catch {
          logger?.log("Crash \(crash.name) could not be removed from device: \(error)")
        }
      }
      return removed
    }
  }

  private func crashLogInfo(afc: FileConduit, path: String) throws -> CrashLogInfo {
    let name = path
    if let existing = store.ingestedCrashLog(withName: path) {
      device?.logger.log("No need to re-ingest \(path)")
      return existing
    }
    let data = try afc.contents(ofPath: path)
    guard let crash = store.ingestCrashLogData(data, name: name) else {
      throw DeviceCrashLogError.ingestFailed(name: name)
    }
    return crash
  }

  private func moveCrashReports() async throws -> String {
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    return try await device.withServiceConnection(CrashReportMoverService) { connection in
      let data: Data
      do {
        data = try connection.receive(4)
      } catch {
        throw DeviceCrashLogError.pingbackReceiveFailed(service: CrashReportMoverService, underlying: error)
      }
      guard let response = String(data: data, encoding: .ascii) else {
        throw DeviceCrashLogError.pingbackNotDecodable(service: CrashReportMoverService)
      }
      if response != PingSuccess {
        throw DeviceCrashLogError.pingbackUnsuccessful(service: CrashReportMoverService, response: response, expected: PingSuccess)
      }
      return response
    }
  }

  private func withCrashReportFileConnection<T>(_ body: (FileConduit) async throws -> T) async throws -> T {
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    return try await device.withAFCConnection(CrashReportCopyService, calls: afcCalls, body)
  }
}
