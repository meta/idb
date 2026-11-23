/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

enum TargetStateChangeNotifierError: Error {
  case noTargetSets
  case targetsFileCreationFailed(path: String, message: String)
  case initialStateWriteFailed
  case updateSerializationFailed
  case updateWriteFailed(underlying: any Error)
}

extension TargetStateChangeNotifierError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .noTargetSets:
      return "Cannot initialize TargetStateChangeNotifier without any sets to monitor"
    case let .targetsFileCreationFailed(path, message):
      return "Failed to create local targets file: \(path) \(message)"
    case .initialStateWriteFailed:
      return "Failed to write the initial target state"
    case .updateSerializationFailed:
      return "error writing update to consumer"
    case let .updateWriteFailed(underlying):
      return "Failed writing updates \(underlying)"
    }
  }
}

public final class TargetStateChangeNotifier: TargetSetDelegate {

  private let filePath: String?
  private let targetSets: [any TargetSet]
  private let logger: any ControlCoreLogger
  private var current: [String: TargetDescription]
  private let donePromise = AsyncEvent<Void>()

  /// Writes each update to `filePath`, which is created holding an empty list.
  public convenience init(filePath: String, targetSets: [any TargetSet], logger: any ControlCoreLogger) throws {
    if targetSets.isEmpty {
      throw TargetStateChangeNotifierError.noTargetSets
    }

    let didCreateFile = FileManager.default.createFile(
      atPath: filePath,
      contents: "[]".data(using: .utf8),
      attributes: [.posixPermissions: NSNumber(value: Int16(0o666))]
    )

    if !didCreateFile {
      throw TargetStateChangeNotifierError.targetsFileCreationFailed(path: filePath, message: String(cString: strerror(errno)))
    }

    self.init(destination: filePath, targetSets: targetSets, logger: logger)
  }

  /// Writes each update to stdout.
  public convenience init(targetSets: [any TargetSet], logger: any ControlCoreLogger) throws {
    if targetSets.isEmpty {
      throw TargetStateChangeNotifierError.noTargetSets
    }

    self.init(destination: nil, targetSets: targetSets, logger: logger)
  }

  private init(destination filePath: String?, targetSets: [any TargetSet], logger: any ControlCoreLogger) {
    self.filePath = filePath
    self.targetSets = targetSets
    self.logger = logger
    self.current = [:]
    for targetSet in targetSets {
      targetSet.delegate = self
    }
  }

  public func startNotifier() throws {
    for targetSet in targetSets {
      for target in targetSet.allTargetInfos {
        current[target.uniqueIdentifier] = TargetDescription(target: target)
      }
    }
    guard writeTargets() else {
      throw TargetStateChangeNotifierError.initialStateWriteFailed
    }
    // If we're writing to a file, we also need to signal to stdout on the first update
    if filePath != nil {
      if let jsonOutput = try? JSONSerialization.data(withJSONObject: ["report_initial_state": true]) {
        var readyOutput = Data(jsonOutput)
        if let newline = "\n".data(using: .utf8) {
          readyOutput.append(newline)
        }
        writeToStandardOutput(readyOutput)
        fflush(stdout)
      }
    }
  }

  /// Suspends until the notifier finishes (on a write error) or is cancelled.
  public func waitUntilDone() async throws {
    try await donePromise.wait()
  }

  @discardableResult
  private func writeTargets() -> Bool {
    var jsonArray: [[String: Any]] = []
    for target in current.values {
      jsonArray.append(target.asJSON)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: jsonArray) else {
      donePromise.fail(TargetStateChangeNotifierError.updateSerializationFailed)
      return false
    }
    if let filePath {
      return writeTargetsData(data, toFilePath: filePath)
    } else {
      return writeTargetsDataToStdOut(data)
    }
  }

  private func writeTargetsData(_ data: Data, toFilePath filePath: String) -> Bool {
    do {
      try (data as NSData).write(toFile: filePath, options: .atomic)
      return true
    } catch {
      logger.log("Failed writing updates \(error)")
      donePromise.fail(TargetStateChangeNotifierError.updateWriteFailed(underlying: error))
      return false
    }
  }

  private func writeTargetsDataToStdOut(_ data: Data) -> Bool {
    writeToStandardOutput(data)
    writeToStandardOutput(Data("\n".utf8))
    fflush(stdout)
    return true
  }

  // MARK: - TargetSetDelegate

  public func targetAdded(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    current[targetInfo.uniqueIdentifier] = TargetDescription(target: targetInfo)
    writeTargets()
  }

  public func targetRemoved(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    current.removeValue(forKey: targetInfo.uniqueIdentifier)
    writeTargets()
  }

  public func targetUpdated(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    current[targetInfo.uniqueIdentifier] = TargetDescription(target: targetInfo)
    writeTargets()
  }
}

public final class TargetDescription: TargetInfo {

  public let uniqueIdentifier: String
  public let udid: String
  public let name: String
  public let deviceType: DeviceType
  public let architectures: [Architecture]
  public let osVersion: OSVersion
  public let extendedInformation: [String: Any]
  public let targetType: TargetType
  public let state: TargetState

  private let model: DeviceModel?

  // These values are parsed into TargetDescription in idb/common/types.py, so need to be stable.
  private static let keyModel = "model"
  private static let keyName = "name"
  private static let keyOSVersion = "os_version"
  private static let keyState = "state"
  private static let keyType = "type"
  private static let keyUDID = "udid"

  public init(target: any TargetInfo) {
    self.extendedInformation = target.extendedInformation
    self.model = target.deviceType.model
    self.name = target.name
    self.osVersion = target.osVersion
    self.state = target.state
    self.targetType = target.targetType
    self.udid = target.udid
    self.uniqueIdentifier = target.uniqueIdentifier
    self.deviceType = target.deviceType
    self.architectures = target.architectures
  }

  public var asJSON: [String: Any] {
    var representation: [String: Any] = [
      Self.keyModel: model.map { $0.rawValue as Any } ?? NSNull(),
      Self.keyName: name as Any? ?? NSNull(),
      Self.keyOSVersion: osVersion.name.rawValue,
      Self.keyState: state.stateString.rawValue,
      Self.keyType: targetType.stringRepresentation,
      Self.keyUDID: udid as Any? ?? NSNull(),
    ]
    for (key, value) in extendedInformation {
      representation[key] = value
    }
    return representation
  }
}
