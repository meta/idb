/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@unsafe @preconcurrency import CoreSimulator
import Darwin
import FBControlCore
import Foundation
import XPC

/// Why a host XPC connection to a guest service could not be built. Each transport maps these onto
/// its own error vocabulary, so the mapping is decided where the consequences are known.
package enum SimulatorXPCConnectionError: Error, Equatable {
  /// The private `_4sim` endpoint symbols are not in this process. A property of the toolchain.
  case symbolsUnavailable
  /// The simulator is not booted, so it vends nothing yet.
  case notBooted(service: String, state: TargetState)
  /// The simulator's bootstrap namespace has no such service, or the lookup failed.
  case lookupFailed(service: String, underlying: NSError?)
  /// The endpoint or connection could not be created from the looked-up port.
  case connectionFailed

  /// CoreSimulator reports a service the runtime does not vend as `SimError` 405, as opposed to a
  /// lookup that failed for an operational reason. It gives every lookup before the boot completes
  /// the same 405, which is why the connector reports those as `notBooted` without looking up.
  package var isServiceUnsupported: Bool {
    guard case let .lookupFailed(_, underlying) = self else { return false }
    return underlying?.domain == "com.apple.CoreSimulator.SimError" && underlying?.code == 405
  }
}

/// Where a guest service name becomes a host connection to it. Every XPC connection into a simulator,
/// CoreDevice and DTUHID alike, is built here, so it is the one place a test substitutes its own
/// peers. The connection is returned unresumed.
package struct SimulatorXPCConnector: Sendable {
  package let namespace: any SimulatorXPCNamespace

  package init(namespace: any SimulatorXPCNamespace) {
    self.namespace = namespace
  }

  package func connect(_ service: String) throws -> xpc_connection_t {
    let state = namespace.simulatorState
    guard state == .booted else {
      throw SimulatorXPCConnectionError.notBooted(service: service, state: state)
    }
    return try namespace.lookup(service)
  }

  /// Resolves once the simulator is no longer booting.
  package func bootFinished() async throws {
    try await namespace.bootFinished()
  }
}

/// The simulator whose bootstrap namespace a connector looks services up in.
package protocol SimulatorXPCNamespace: Sendable {
  var simulatorState: TargetState { get }
  func lookup(_ service: String) throws -> xpc_connection_t
  func bootFinished() async throws
}

extension SimulatorXPCConnector {
  /// Looks services up in `simulator`'s bootstrap namespace.
  package static func simulator(_ simulator: Simulator) -> SimulatorXPCConnector {
    SimulatorXPCConnector(namespace: SimDeviceNamespace(device: simulator.device, queue: simulator.workQueue))
  }
}

/// Holds the `SimDevice` rather than the `Simulator`, whose command cache keeps this namespace's owners.
private struct SimDeviceNamespace: SimulatorXPCNamespace {
  let device: SimDevice
  let queue: DispatchQueue

  var simulatorState: TargetState {
    TargetState(rawValue: UInt(device.state)) ?? .unknown
  }

  func lookup(_ service: String) throws -> xpc_connection_t {
    try SimulatorXPCConnection.connect(service: service) { service in
      var error: NSError?
      let port = unsafe device.lookup(service, error: &error)
      return (port, error)
    }
  }

  func bootFinished() async throws {
    try await pollUntilTrue(on: queue) { simulatorState != .booting }
  }
}

/// Builds the host side of an XPC connection to a service inside a booted simulator.
///
/// Both CoreDevice features and `dtuhidd` are reached this way: the service's Mach port is looked up
/// in the simulator's bootstrap namespace, wrapped in an endpoint by the private
/// `xpc_endpoint_create_mach_port_4sim`, and the connection made from that is marked
/// simulator-to-host with `xpc_connection_enable_sim2host_4sim`, without which the service observes
/// the peer but never a payload. The connection is returned before it is resumed, so the caller
/// installs its own event handler and target queue first.
enum SimulatorXPCConnection {
  typealias ServiceLookup = (String) -> (port: mach_port_t, error: NSError?)

  private typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
  private typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
  private typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void

  static func connect(service: String, lookup: ServiceLookup) throws -> xpc_connection_t {
    guard let handle = unsafe dlopen(nil, RTLD_NOW) else { throw SimulatorXPCConnectionError.symbolsUnavailable }
    defer { unsafe dlclose(handle) }
    guard
      let endpointFromPort = unsafe symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromPort.self),
      let connectionFromEndpoint = unsafe symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpoint.self),
      let enableSim2Host = unsafe symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2Host.self)
    else { throw SimulatorXPCConnectionError.symbolsUnavailable }
    let looked = lookup(service)
    guard looked.port != MACH_PORT_NULL else {
      throw SimulatorXPCConnectionError.lookupFailed(service: service, underlying: looked.error)
    }
    // Both Create functions return +1. The endpoint consumes the lookup's send right.
    guard let endpoint = unsafe endpointFromPort(looked.port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
      let connection = unsafe connectionFromEndpoint(endpoint)?.takeRetainedValue() as? xpc_connection_t
    else { throw SimulatorXPCConnectionError.connectionFailed }
    enableSim2Host(connection)
    return connection
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let pointer = unsafe dlsym(handle, name) else { return nil }
    return unsafe unsafeBitCast(pointer, to: type)
  }
}
