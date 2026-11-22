/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

public enum DynamicStoreService {
  private enum Action: String {
    case snapshot
    case restore
  }

  public static func key(forName name: String) -> String? {
    switch name {
    case "dns": return "State:/Network/Global/DNS"
    case "proxy": return "State:/Network/Global/Proxies"
    default: return name.contains(":") ? name : nil
    }
  }

  public static func handleDynamicStoreAction(action: String, arguments: [String]) -> Int {
    handleDynamicStoreAction(action: action, arguments: arguments, input: { FileHandle.standardInput.readDataToEndOfFile() }, output: nil)
  }

  static func handleDynamicStoreAction(action: String, arguments: [String], input: () -> Data, output: BridgeOutput?) -> Int {
    guard let selectedAction = Action(rawValue: action) else {
      NSLog("[DynamicStoreService] Unknown action: %@. Use 'snapshot' or 'restore'.", action)
      return failed("Unknown dynamic-store action", output: output)
    }
    guard let name = arguments.first, !name.isEmpty else {
      NSLog("[DynamicStoreService] %@ requires a configd key, or one of 'dns' and 'proxy'", action)
      return failed("Dynamic-store requires a key or alias", output: output)
    }
    guard let key = key(forName: name) else {
      NSLog("[DynamicStoreService] %@ is neither a configd key nor a known alias", name)
      return failed("Unknown dynamic-store key or alias", output: output)
    }
    guard let client = FBDynamicStoreClient.open(key: key) else { return failed("The dynamic-store private API is unavailable", output: output) }
    guard let current = client.read() else {
      NSLog("[DynamicStoreService] Cannot read the dynamic store key")
      return failed("Could not read the dynamic-store key", output: output)
    }
    switch selectedAction {
    case .snapshot:
      return writeSnapshot(current.value, output: output)
    case .restore:
      guard let snapshot = requestedSnapshot(input()) else { return failed("Invalid dynamic-store snapshot", output: output) }
      switch snapshot {
      case let .present(value):
        guard client.writeValue(value) else { return failed("Could not restore the dynamic-store value", output: output) }
      case .absent:
        if current.value != nil && !client.removeValue() { return failed("Could not remove the dynamic-store value", output: output) }
      }
      client.notifyChange()
      guard let restored = client.read() else {
        NSLog("[DynamicStoreService] Cannot read back the restored value")
        return failed("Could not read back the restored value", output: output)
      }
      return writeSnapshot(restored.value, output: output)
    }
  }

  private static func failed(_ message: String, output: BridgeOutput?) -> Int {
    output?.failure(message) ?? 1
  }

  private enum Snapshot {
    case present(Any)
    case absent
  }

  private static func requestedSnapshot(_ data: Data) -> Snapshot? {
    do {
      let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      guard let fields = object as? [String: Any], let present = fields["present"] as? NSNumber else {
        NSLog("[DynamicStoreService] Cannot read the snapshot to restore: %@", String(describing: object as AnyObject))
        return nil
      }
      guard present.boolValue else { return .absent }
      guard let value = fields["value"] else {
        NSLog("[DynamicStoreService] The snapshot to restore is present but carries no value")
        return nil
      }
      return .present(value)
    } catch {
      NSLog("[DynamicStoreService] Cannot read the snapshot to restore: %@", error as NSError)
      return nil
    }
  }

  private static func writeSnapshot(_ value: Any?, output: BridgeOutput?) -> Int {
    let snapshot: [String: Any] = value.map { ["present": true, "value": $0] } ?? ["present": false]
    let encoder = output ?? BridgeOutput()
    guard encoder.write(propertyList: snapshot), let data = encoder.propertyList else {
      NSLog("[DynamicStoreService] Cannot serialise the snapshot: %@", encoder.error ?? "")
      return 1
    }
    if output == nil { FileHandle.standardOutput.write(data) }
    return 0
  }
}
