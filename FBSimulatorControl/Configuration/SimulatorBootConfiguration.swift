/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// An Option Set for Direct Launching.
///
/// The raw values are not contiguous; callers compare and persist them, so they must not change.
public struct SimulatorBootOptions: OptionSet, Hashable, Sendable {

  public let rawValue: UInt

  public init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  /// Ties the Simulator's lifecycle to that of the launching process, so that the Simulator is
  /// shut down automatically when the process that booted it dies.
  public static let tieToProcessLifecycle = SimulatorBootOptions(rawValue: 1 << 1)

  /// Requires that the Simulator is 'Usable' before the boot API completes. A Simulator can report
  /// itself 'Booted' very quickly while not yet being usable. Booting without this returns as soon
  /// as the Simulator reports `.booted`; `SimulatorLifecycleCommands.resolveUsable(deadline:)`
  /// performs the same wait afterwards, for a caller that wants the state first and the usability
  /// later.
  public static let verifyUsable = SimulatorBootOptions(rawValue: 1 << 3)
}

public struct SimulatorBootConfiguration: Equatable, Hashable, Sendable, CustomStringConvertible {

  public let options: SimulatorBootOptions

  public let environment: [String: String]

  public static let `default` = SimulatorBootConfiguration(
    options: .verifyUsable,
    environment: [:]
  )

  public init(options: SimulatorBootOptions, environment: [String: String]) {
    self.options = options
    self.environment = environment
  }

  public var description: String {
    unsafe String(
      format: "Boot Environment %@ | Options %@",
      CollectionInformation.oneLineDescription(from: environment as [String: Any]),
      CollectionInformation.oneLineDescription(from: Self.stringsFromBootOptions(options) as [Any])
    )
  }

  private static let bootOptionStringDirectLaunch = "Direct Launch"

  private static func stringsFromBootOptions(_ options: SimulatorBootOptions) -> [String] {
    var strings: [String] = []
    if options.contains(.tieToProcessLifecycle) {
      strings.append(bootOptionStringDirectLaunch)
    }
    return strings
  }
}
