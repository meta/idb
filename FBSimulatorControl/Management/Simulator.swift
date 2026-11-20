/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation

private let DefaultDeviceSet = "~/Library/Developer/CoreSimulator/Devices"

/// An implementation of `Target` for iOS Simulators.
///
/// Instances are safe to pass across Swift concurrency domains: apart from immutable properties,
/// the only state is the temporary directory and `commandCache`, each behind its own lock.
public final class Simulator: Target, Hashable, CustomStringConvertible, @unchecked Sendable {

  // MARK: - Properties

  /// The underlying `SimDevice`.
  public let device: SimDevice

  /// The `SimulatorConfiguration` representing this Simulator.
  public let configuration: SimulatorConfiguration

  public let commandCache: TargetCommandCache

  public let logger: any ControlCoreLogger
  public let auxillaryDirectory: String

  /// How much of each HID event this simulator's HID connection logs.
  public let hidEventLogging: SimulatorHIDEventLogging

  /// How long this simulator's accessibility reads may take, unless a read asks for its own.
  public let accessibilityTiming: SimulatorAccessibilityTiming

  private let temporaryDirectoryLock = NSLock()
  private var _temporaryDirectory: TemporaryDirectory?

  // MARK: - Initializers

  /// The `Simulator` for `device`, without going through a `SimulatorSet`.
  ///
  /// There is at most one live `Simulator` per device in the process, whether it is obtained here
  /// or from a `SimulatorSet`: if one is already held anywhere, it is returned and `logger` and
  /// `hidEventLogging` and `accessibilityTiming` are ignored. Once nothing holds it, the next request builds a fresh instance,
  /// without the memoized commands or connections of the previous one.
  public static func fromSimDevice(
    _ device: SimDevice,
    logger: (any ControlCoreLogger)? = nil,
    hidEventLogging: SimulatorHIDEventLogging = .redacted,
    accessibilityTiming: SimulatorAccessibilityTiming = .default
  ) -> Simulator {
    SimulatorRegistry.shared.simulator(for: device) { device in
      Simulator(device: device, logger: logger, hidEventLogging: hidEventLogging, accessibilityTiming: accessibilityTiming)
    }
  }

  private convenience init(
    device: SimDevice, logger: (any ControlCoreLogger)?, hidEventLogging: SimulatorHIDEventLogging,
    accessibilityTiming: SimulatorAccessibilityTiming
  ) {
    self.init(
      device: device,
      configuration: SimulatorConfiguration(simDevice: device),
      auxillaryDirectory: Self.auxillaryDirectory(fromSimDevice: device),
      logger: logger,
      hidEventLogging: hidEventLogging,
      accessibilityTiming: accessibilityTiming)
  }

  /// Bypasses `SimulatorRegistry`, so nothing guarantees this is the only live instance for
  /// `device`. Only the registry's factories and tests construct through it.
  init(
    device: SimDevice,
    configuration: SimulatorConfiguration,
    auxillaryDirectory: String,
    logger: (any ControlCoreLogger)?,
    hidEventLogging: SimulatorHIDEventLogging = .redacted,
    accessibilityTiming: SimulatorAccessibilityTiming = .default
  ) {
    self.device = device
    self.configuration = configuration
    self.auxillaryDirectory = auxillaryDirectory
    self.hidEventLogging = hidEventLogging
    self.accessibilityTiming = accessibilityTiming
    self.logger = (logger ?? ControlCoreGlobalConfiguration.defaultLogger).withName(device.udid.uuidString)
    self.commandCache = TargetCommandCache()
  }

  // MARK: - TargetInfo

  public var uniqueIdentifier: String { udid }

  public var udid: String { device.udid.uuidString }

  public var name: String { device.name }

  public var state: TargetState { TargetState(rawValue: UInt(device.state)) ?? .unknown }

  public var targetType: TargetType { .simulator }

  public var architectures: [Architecture] { Array(ArchitectureProcessAdapter.hostMachineSupportedArchitectures()) }

  public var deviceType: DeviceType { configuration.device }

  public var osVersion: OSVersion { configuration.os }

  public var extendedInformation: [String: Any] { [:] }

  // MARK: - Target

  public var runtimeRootDirectory: String { get async { device.runtime.root } }

  public var platformRootDirectory: String {
    get async {
      (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/iPhoneSimulator.platform")
    }
  }

  public var screenInfo: TargetScreenInfo? {
    guard let deviceType = device.deviceType else {
      return nil
    }
    return TargetScreenInfo(
      widthPixels: UInt(deviceType.mainScreenSize.width),
      heightPixels: UInt(deviceType.mainScreenSize.height),
      scale: deviceType.mainScreenScale)
  }

  public var temporaryDirectory: TemporaryDirectory {
    temporaryDirectoryLock.withLock {
      if let _temporaryDirectory {
        return _temporaryDirectory
      }
      let directory = TemporaryDirectory(logger: logger)
      _temporaryDirectory = directory
      return directory
    }
  }

  public var workQueue: DispatchQueue { .main }

  public var asyncQueue: DispatchQueue { .global(qos: .userInitiated) }

  public func replacementMapping() -> [String: String] {
    ["%%SIM_ROOT%%": dataDirectory ?? ""]
  }

  public func environmentAdditions() -> [String: String] { [:] }

  public func requiresBundlesToBeSigned() -> Bool { true }

  // MARK: - Simulator Properties

  /// The Product Family of the Simulator.
  package var productFamily: ProductFamily {
    switch device.deviceType?.productFamilyID {
    case .some(1):
      return .iPhone
    case .some(2):
      return .iPad
    case .some(3):
      return .appleTV
    case .some(4):
      return .appleWatch
    default:
      return .unknown
    }
  }

  /// A string representation of the Simulator State.
  public var stateString: TargetStateString {
    state.stateString
  }

  /// The Directory that Contains the Simulator's Data.
  package var dataDirectory: String? { device.dataPath() }

  public var customDeviceSetPath: String? {
    let setPath = device.deviceSet?.setPath
    return setPath == (DefaultDeviceSet as NSString).expandingTildeInPath ? nil : setPath
  }

  /// The directory path of the expected location of the CoreSimulator logs directory.
  var coreSimulatorLogsDirectory: String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/CoreSimulator/\(udid)")
  }

  // MARK: - Hashable

  public func hash(into hasher: inout Hasher) {
    hasher.combine(device.hash)
  }

  public static func == (lhs: Simulator, rhs: Simulator) -> Bool {
    lhs.device.isEqual(rhs.device)
  }

  public var description: String {
    self.targetDescription
  }

  private static func auxillaryDirectory(fromSimDevice device: SimDevice) -> String {
    ((device.dataPath() ?? "") as NSString).appendingPathComponent("fbsimulatorcontrol")
  }
}

// Commands that own something outliving a single call — a notifier, an in-flight video, a task —
// are memoized through `commandCache` (`TargetCommandCache`), whose lock also stops two callers
// racing the first construction. Commands that only wrap the simulator are built per call: a slot
// for one would hold a box around a pointer back to the object owning the cache, closing a retain
// cycle.
extension Simulator {

  // MARK: - Shared accessors

  public var application: SimulatorApplicationCommands {
    SimulatorApplicationCommands(simulator: self)
  }

  public var crashLog: SimulatorCrashLogCommands {
    commandCache.resolve { SimulatorCrashLogCommands(simulator: self) }
  }

  public var screenshot: SimulatorScreenshotCommands {
    commandCache.resolve { SimulatorScreenshotCommands(simulator: self) }
  }

  public var location: SimulatorLocationCommands {
    SimulatorLocationCommands(simulator: self)
  }

  public var debugServer: SimulatorDebugServerCommands {
    SimulatorDebugServerCommands(simulator: self)
  }

  public var file: SimulatorFileCommands {
    SimulatorFileCommands(simulator: self)
  }

  public var log: SimulatorLogCommands {
    SimulatorLogCommands(simulator: self)
  }

  public var launchCtl: SimulatorLaunchCtlCommands {
    SimulatorLaunchCtlCommands(simulator: self)
  }

  public var xctraceRecord: TargetXCTraceRecordCommands {
    TargetXCTraceRecordCommands(target: self)
  }

  // MARK: - Sim-only accessors

  public var lifecycle: SimulatorLifecycleCommands {
    SimulatorLifecycleCommands(simulator: self)
  }

  public var framebuffer: SimulatorFramebufferCommands {
    SimulatorFramebufferCommands(simulator: self)
  }

  public var hid: SimulatorHIDCommands {
    commandCache.resolve { SimulatorHIDCommands(simulator: self) }
  }

  /// The simulator's CoreDevice features. One client per simulator, so the installed CoreDevice
  /// version is read once.
  var coreDevice: SimulatorCoreDeviceClient {
    commandCache.resolve { SimulatorCoreDeviceClient(deviceID: udid, connector: xpc) }
  }

  /// Host connections to the simulator's guest services.
  var xpc: SimulatorXPCConnector {
    .simulator(self)
  }

  /// GSEvents over the PurpleWorkspacePort: lock, and rotation on a runtime without device motion. One
  /// per simulator, so concurrent sends to the port queue behind one another.
  var purpleHID: SimulatorPurpleHIDTransport {
    commandCache.resolve { SimulatorPurpleHIDTransport(simulator: self) }
  }

  public var displays: SimulatorDisplayCommands {
    commandCache.resolve { SimulatorDisplayCommands(simulator: self) }
  }

  public var hinge: SimulatorHingeCommands {
    SimulatorHingeCommands(simulator: self)
  }

  public var keyboard: SimulatorKeyboardCommands {
    SimulatorKeyboardCommands(simulator: self)
  }

  public var hardware: SimulatorHardwareCommands {
    SimulatorHardwareCommands(simulator: self)
  }

  public var power: SimulatorPowerCommands {
    SimulatorPowerCommands(simulator: self)
  }

  public var media: SimulatorMediaCommands {
    SimulatorMediaCommands(simulator: self)
  }

  public var keychain: SimulatorKeychainCommands {
    SimulatorKeychainCommands(simulator: self)
  }

  public var statusBar: SimulatorStatusBarCommands {
    SimulatorStatusBarCommands(simulator: self)
  }

  public var dapServer: SimulatorDapServerCommand {
    SimulatorDapServerCommand(simulator: self)
  }

  public var memory: SimulatorMemoryCommands {
    SimulatorMemoryCommands(simulator: self)
  }

  public var audio: SimulatorAudioCommands {
    SimulatorAudioCommands(simulator: self)
  }

  public var runtimeTools: SimulatorRuntimeToolCommands {
    SimulatorRuntimeToolCommands(simulator: self)
  }

  public var bootstrapPorts: SimulatorBootstrapPortCommands {
    SimulatorBootstrapPortCommands(simulator: self)
  }

  // MARK: - Command verbs

  public func erase() async throws {
    try await power.shutdown()
    let logger = self.logger
    let description = "\(self)"
    logger.log("Erasing \(description)")
    try await awaitCoreSimulatorCompletion {
      device.eraseContentsAndSettingsAsync(withCompletionQueue: workQueue, completionHandler: $0)
    }
    logger.log("Erased \(description)")
  }

  public func details(_ keys: Set<TargetDetailKey>) async throws -> TargetDetails {
    var details = TargetDetails(unsupported: keys)
    if keys.contains(.displays) {
      details.displays = state == .booted ? try await displays.describedDisplays() : .read([])
    }
    return details
  }
}

/// Vends at most one live `Simulator` per simulator UDID in the process.
///
/// State hangs off a `Simulator` — its `commandCache`, HID connection and temporary directory — so
/// two instances wrapping the same device would split it. Entries are held weakly: while anything
/// holds a `Simulator`, every request for its device returns it; once nothing does, the next
/// request builds a fresh one. UDIDs are unique across device sets, so the key holds even when
/// the same device is reached through different `SimDeviceSet` instances.
final class SimulatorRegistry: @unchecked Sendable {

  static let shared = SimulatorRegistry()

  // Guards `simulators`, so that two callers racing for the same device build only one instance.
  private let lock = NSLock()
  private let simulators = NSMapTable<NSString, Simulator>.strongToWeakObjects()

  /// Returns the live `Simulator` for `device`, calling `make` to build one only when none is live.
  func simulator(for device: SimDevice, make: (SimDevice) -> Simulator) -> Simulator {
    let key = device.udid.uuidString as NSString
    lock.lock()
    defer { lock.unlock() }
    if let existing = simulators.object(forKey: key) {
      return existing
    }
    let simulator = make(device)
    simulators.setObject(simulator, forKey: key)
    return simulator
  }
}
