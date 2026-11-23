/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

/// The entry point to a simulator device set: loads the private frameworks, opens the service
/// context and vends the `SimulatorSet`. Named distinctly from the module on purpose: a type
/// that shares its module's name shadows the module in qualified lookups and cannot be emitted
/// into a module interface.
public final class SimulatorControlBootstrap {

  public var configuration: SimulatorControlConfiguration
  public let serviceContext: SimulatorServiceContext
  public let set: SimulatorSet

  public init(configuration: SimulatorControlConfiguration) throws {
    try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(configuration.logger)
    let serviceContext = try SimulatorServiceContext.sharedServiceContext(withLogger: configuration.logger)
    let deviceSet = try serviceContext.createDeviceSet(with: configuration)
    self.configuration = configuration
    self.serviceContext = serviceContext
    self.set = try SimulatorSet(
      configuration: configuration,
      deviceSet: deviceSet,
      delegate: nil,
      logger: configuration.logger.withName("simulator_set"))
  }
}
