/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing

/// The one place a host connection into a booted simulator is built, and how each transport reads
/// its failures. The success path needs a live simulator and is exercised by the smoke suites.
@Suite
struct SimulatorXPCConnectionTests {

  private static let unsupported = NSError(domain: "com.apple.CoreSimulator.SimError", code: 405)
  private static let operational = NSError(domain: "com.apple.CoreSimulator.SimError", code: 165)

  private func connect(_ error: NSError?) -> SimulatorXPCConnectionError? {
    do {
      _ = try SimulatorXPCConnection.connect(service: "com.example.service") { _ in (mach_port_t(MACH_PORT_NULL), error) }
      return nil
    } catch let error as SimulatorXPCConnectionError {
      return error
    } catch {
      Issue.record("Unexpected error: \(error)")
      return nil
    }
  }

  @Test
  func aFailedLookupCarriesTheServiceAndTheUnderlyingError() {
    #expect(connect(Self.operational) == .lookupFailed(service: "com.example.service", underlying: Self.operational))
    #expect(connect(nil) == .lookupFailed(service: "com.example.service", underlying: nil))
  }

  @Test
  func onlySimError405MeansTheServiceIsUnsupported() {
    #expect(connect(Self.unsupported)?.isServiceUnsupported == true)
    #expect(connect(Self.operational)?.isServiceUnsupported == false)
    #expect(connect(nil)?.isServiceUnsupported == false)
    #expect(!SimulatorXPCConnectionError.symbolsUnavailable.isServiceUnsupported)
    #expect(!SimulatorXPCConnectionError.connectionFailed.isServiceUnsupported)
  }

  // MARK: - CoreDevice mapping

  @Test
  func coreDeviceTreatsAnUnsupportedServiceAndMissingSymbolsAsMissingCapabilities() {
    let unsupported = SimulatorCoreDeviceError(connection: .lookupFailed(service: "com.example.service", underlying: Self.unsupported))
    guard case let .unsupported(detail) = unsupported else {
      Issue.record("\(unsupported)")
      return
    }
    #expect(detail == "com.example.service")

    guard case .unsupported = SimulatorCoreDeviceError(connection: .symbolsUnavailable) else {
      Issue.record("Missing symbols should read as unsupported")
      return
    }
  }

  @Test
  func coreDeviceOnASimulatorThatIsStillBooting() throws {
    let services = SyntheticXPCServices()
    services.register("com.example.service", respond: SyntheticXPCPeer.silent)
    services.simulatorState = .booting

    let error = try #require(#expect(throws: (any Error).self) { try SimulatorCoreDevice.connect(using: services.connector, service: "com.example.service") })
    guard case SimulatorCoreDeviceError.unavailable = error else {
      Issue.record("\(error)")
      return
    }
  }

  @Test
  func coreDeviceTreatsOtherConnectionFailuresAsUnavailable() {
    for error: SimulatorXPCConnectionError in [
      .lookupFailed(service: "com.example.service", underlying: Self.operational),
      .lookupFailed(service: "com.example.service", underlying: nil),
      .connectionFailed,
    ] {
      guard case .unavailable = SimulatorCoreDeviceError(connection: error) else {
        Issue.record("\(error)")
        return
      }
    }
  }

  // MARK: - DTUHID mapping

  @Test
  func connectionFailuresMapOntoDTUHIDErrors() {
    let lookup = SimulatorHIDError(dtuhidConnection: .lookupFailed(service: "com.example.service", underlying: Self.operational))
    guard case let .dtuhidServiceUnavailable(name, underlying) = lookup else {
      Issue.record("\(lookup)")
      return
    }
    #expect(name == "com.example.service")
    #expect(underlying as NSError? == Self.operational)
    #expect(!lookup.isPermanentDTUHIDFailure)

    let symbols = SimulatorHIDError(dtuhidConnection: .symbolsUnavailable)
    guard case .dtuhidXPCSymbolsUnavailable = symbols else {
      Issue.record("\(symbols)")
      return
    }
    #expect(symbols.isPermanentDTUHIDFailure)

    let connection = SimulatorHIDError(dtuhidConnection: .connectionFailed)
    guard case .dtuhidConnectionFailed = connection else {
      Issue.record("\(connection)")
      return
    }
    #expect(!connection.isPermanentDTUHIDFailure)
  }
}
