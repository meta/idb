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

private enum ProxyConfiguration {
  case http(host: String, port: Int32)
  case socks(host: String, port: Int32)
  case cleared

  init(host: String, port: Int32, type: String) {
    self = type == "socks" ? .socks(host: host, port: port) : .http(host: host, port: port)
  }

  var dictionary: [String: Any] {
    switch self {
    case let .http(host, port):
      return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port as NSNumber, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port as NSNumber, "FTPPassive": 1, "ExceptionsList": ["*.local", "169.254/16"]]
    case let .socks(host, port):
      return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port as NSNumber, "FTPPassive": 1, "ExceptionsList": ["*.local", "169.254/16"]]
    case .cleared:
      return ["FTPPassive": 1]
    }
  }
}

public enum ProxyService {

  public static func buildHTTPProxyDict(host: String, port: Int32) -> [String: Any] {
    ProxyConfiguration.http(host: host, port: port).dictionary
  }

  public static func buildSOCKSProxyDict(host: String, port: Int32) -> [String: Any] {
    ProxyConfiguration.socks(host: host, port: port).dictionary
  }

  public static func buildEmptyProxyDict() -> [String: Any] {
    ProxyConfiguration.cleared.dictionary
  }

  public static func handleProxyAction(action: String, arguments: [String]) -> Int {
    handleProxyAction(action: action, arguments: arguments, output: nil)
  }

  static func handleProxyAction(action: String, arguments: [String], output: BridgeOutput?) -> Int {
    NetworkConfigurationService(
      name: "proxy",
      logTag: "[ProxyService]",
      store: FBNetworkConfigurationStore.proxy(),
      clearedConfiguration: buildEmptyProxyDict(),
      clearingMessage: "Clearing proxy settings",
      updatedMessage: "Proxy settings updated successfully"
    ) { arguments in
      guard arguments.count >= 2 else {
        NSLog("[ProxyService] set requires <host> <port> [http|socks]")
        return nil
      }
      let host = arguments[0]
      let port = (arguments[1] as NSString).intValue
      let type = arguments.count >= 3 ? arguments[2] : "http"
      NSLog("[ProxyService] Setting %@ proxy to %@:%d", type, host, port)
      return ProxyConfiguration(host: host, port: port, type: type).dictionary
    }.handle(action: action, arguments: arguments, output: output)
  }
}
