/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

/// The `list`, `set` and `clear` actions over one network configuration store.
struct NetworkConfigurationService {
  let name: String
  let logTag: String
  let store: FBNetworkConfigurationStore?
  let clearedConfiguration: [String: Any]
  let clearingMessage: String
  let updatedMessage: String
  /// Logs and returns the configuration `set` writes, or nil when the arguments are invalid.
  let configurationToSet: ([String]) -> [String: Any]?

  func handle(action: String, arguments: [String], output: BridgeOutput?) -> Int {
    guard let store else {
      return output?.failure("The \(name) private API is unavailable") ?? 1
    }

    let selectedAction = NetworkConfigurationAction(rawValue: action)
    if selectedAction == .list {
      let read = store.readConfiguration()
      guard let read else {
        return output?.failure("Could not read \(name) configuration") ?? 1
      }
      if let output {
        do {
          return output.write(.networkConfiguration(try BridgeNetworkConfiguration(read.configuration ?? [String: Any]()))) ? 0 : 1
        } catch {
          return output.failure("Could not encode command output: \(error.localizedDescription)")
        }
      }
      if let configuration = read.configuration {
        if let json = try? JSONSerialization.data(withJSONObject: configuration, options: .prettyPrinted),
          let str = String(data: json, encoding: .utf8)
        {
          // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
          print(str)
        }
      } else {
        // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
        print("{}")
      }
      return 0
    }

    guard store.prepareToWrite() else {
      return output?.failure("Could not prepare \(name) configuration for writing") ?? 1
    }

    let configuration: [String: Any]
    if selectedAction == .set {
      guard let requested = configurationToSet(arguments) else {
        return output?.failure("Invalid \(name) set arguments") ?? 1
      }
      configuration = requested
    } else if selectedAction == .clear {
      configuration = clearedConfiguration
      NSLog("%@ %@", logTag, clearingMessage)
    } else {
      NSLog("%@ Unknown action: %@. Use 'set', 'clear', or 'list'.", logTag, action)
      return output?.failure("Unknown \(name) action") ?? 1
    }

    guard store.writeConfiguration(configuration) else {
      return output?.failure("Could not write \(name) configuration") ?? 1
    }

    store.notifyChange()

    NSLog("%@ %@", logTag, updatedMessage)
    return 0
  }
}
