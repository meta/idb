/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBControlCoreObjC
import Foundation
import ObjectiveC

/// Told what the test bundle and testmanagerd do over the connection. Called on the work queue.
// DTXConnectionServices' classes and the XCTest categories on them, messaged through their selectors:
// naming them as types would link against the private frameworks that vend them.

@objc private protocol DTXSocketTransportMessaging {
  @objc(initWithConnectedSocket:disconnectAction:) func initialize(connectedSocket: Int32, disconnectAction: @escaping () -> Void) -> AnyObject?
}

@objc private protocol DTXConnectionMessaging {
  @objc(initWithTransport:) func initialize(transport: AnyObject) -> AnyObject?
  @objc(registerDisconnectHandler:) func registerDisconnectHandler(_ handler: @escaping () -> Void)
  @objc(resume) func resume()
  @objc(suspend) func suspend()
  @objc(cancel) func cancel()
  @objc(xct_handleProxyRequestForInterface:peerInterface:handler:) func handleProxyRequest(interface: Protocol, peerInterface: Protocol, handler: @escaping (AnyObject) -> Void)
  @objc(xct_makeProxyChannelWithRemoteInterface:exportedInterface:) func makeProxyChannel(remoteInterface: Protocol, exportedInterface: Protocol) -> AnyObject
}

@objc private protocol DTXProxyChannelMessaging {
  @objc(setExportedObject:queue:) func setExportedObject(_ object: AnyObject, queue: DispatchQueue)
  @objc(remoteObjectProxy) func remoteObjectProxy() -> AnyObject
  @objc(cancel) func cancel()
  @objc(xct_setAllowedClassesForTestingProtocols) func setAllowedClassesForTestingProtocols()
}

@objc private protocol XCTestDriverMessaging {
  @objc(_IDE_startExecutingTestPlanWithProtocolVersion:) func startExecutingTestPlan(protocolVersion: NSNumber) -> AnyObject?
}

@objc private protocol XCTestManagerDaemonConnectionMessaging {
  @objc(_IDE_initiateSessionWithIdentifier:forClient:atPath:protocolVersion:) func initiateSession(identifier: NSUUID, client: NSString, path: NSString, protocolVersion: NSNumber) -> AnyObject
  @objc(_IDE_initiateSessionWithIdentifier:capabilities:) func initiateSession(identifier: NSUUID, capabilities: AnyObject) -> AnyObject
}

@objc private protocol DTXRemoteInvocationReceiptCompletion {
  @objc(handleCompletion:) func handleCompletion(_ completion: @escaping (AnyObject?, (any Error)?) -> Void)
}

private let protocolVersion = 36
private let protocolMinimumVersion = 0x8

/// A test-bundle connection: it owns the DTX transport and the proxy channels to the test bundle and
/// testmanagerd. It is the object exported over those channels, answering the session callbacks
/// itself and handing every other callback to the IDE interface.
@objc(FBTestBundleDTXConnection)
final class TestBundleDTXConnection: NSObject {

  private let context: TestManagerContext
  private let workQueue: DispatchQueue
  private let testManagerdSocket: Int32
  private let interface: NSObject
  private let delegate: TestBundleEvents
  private let requestQueue: DispatchQueue
  private let logger: any TestManagerLogSink

  private var testManagerdConnection: (any DTXConnectionMessaging)?
  // Set from the proxy handler's queue and read once the delegate has been told the bundle is ready.
  private let testBundleProxyLock = NSLock()
  private var testBundleProxy: (any XCTestDriverMessaging)?

  private static let clientProcessUniqueIdentifier = ProcessInfo.processInfo.globallyUniqueString

  private static let clientProcessDisplayPath: String = {
    let path = Bundle.main.bundlePath
    if (path as NSString).pathExtension == "app" {
      return path
    }
    return Bundle.main.executablePath ?? path
  }()

  /// - Parameter interface: the `XCTestManager_IDEInterface` / `XCTMessagingChannel_RunnerToIDE`
  ///   implementation the callbacks this connection does not answer go to.
  init(
    context: TestManagerContext,
    work workQueue: DispatchQueue,
    socket: Int32,
    interface: NSObject,
    delegate: TestBundleEvents,
    request requestQueue: DispatchQueue,
    logger: any TestManagerLogSink
  ) {
    self.context = context
    self.workQueue = workQueue
    self.testManagerdSocket = socket
    self.interface = interface
    self.delegate = delegate
    self.requestQueue = requestQueue
    self.logger = logger
    super.init()
  }

  // MARK: Message Forwarding

  override func responds(to selector: Selector?) -> Bool {
    super.responds(to: selector) || interface.responds(to: selector)
  }

  override func forwardingTarget(for selector: Selector?) -> Any? {
    interface.responds(to: selector) ? interface : super.forwardingTarget(for: selector)
  }

  // MARK: Connection lifecycle

  /// Wraps the testmanagerd socket in a DTX transport and connection.
  func connect() throws {
    let socket = testManagerdSocket
    let logger = self.logger
    logger.log("Wrapping testmanagerd socket (\(socket)) in DTXTransport and DTXConnection")
    let connection: any DTXConnectionMessaging
    do {
      // DTX asserts internally on a dead socket; the raise would otherwise cross Swift frames, where
      // it cannot be caught, and abort the process.
      connection = try FBObjCExceptionGuard.guarded {
        guard
          let allocatedTransport = RuntimeClassAllocation.alloc("DTXSocketTransport"),
          let transport = unsafe unsafeBitCast(allocatedTransport, to: (any DTXSocketTransportMessaging).self)
            .initialize(connectedSocket: socket, disconnectAction: { logger.log("Notified that daemon socket disconnected") }),
          let allocatedConnection = RuntimeClassAllocation.alloc("DTXConnection"),
          let connection = unsafe unsafeBitCast(allocatedConnection, to: (any DTXConnectionMessaging).self).initialize(transport: transport)
        else {
          throw XCTestBootstrapErrors.testFailure("DTXConnectionServices is not loaded")
        }
        return unsafe unsafeBitCast(connection, to: (any DTXConnectionMessaging).self)
      }
    } catch {
      throw XCTestBootstrapErrors.testFailure("Failed to wrap testmanagerd socket \(socket) in DTXConnection: \(error)")
    }
    connection.registerDisconnectHandler { [self] in
      logger.log("Notified that testmanagerd connection disconnected")
      delegate.testBundleConnectionDidDisconnect()
    }
    testManagerdConnection = connection
    logger.log("testmanagerd socket \(socket) wrapped in \(connection)")
  }

  /// Ends the testmanagerd connection, before returning so it is down by the time the caller's scope
  /// has exited.
  func disconnect() {
    guard let connection = testManagerdConnection else {
      return
    }
    requestQueue.sync {
      logger.log("Ending the testmanagerd connection. \(connection)")
      connection.suspend()
      connection.cancel()
    }
  }

  func setupAndStartSession() {
    guard let connection = testManagerdConnection else {
      return
    }
    Self.addExportedInterfaceConformances
    setupTestBundleConnection(connection)
    sendStartSessionRequest(connection)
  }

  func startExecutingTestPlan() {
    logger.log("Starting Execution of the test plan w/ version \(protocolVersion)")
    let proxy = testBundleProxyLock.withLock { testBundleProxy }
    _ = proxy?.startExecutingTestPlan(protocolVersion: NSNumber(value: protocolVersion))
  }

  private func setupTestBundleConnection(_ connection: any DTXConnectionMessaging) {
    logger.log("Listening for proxy connection request from the test bundle (all platforms)")
    connection.handleProxyRequest(
      interface: Self.protocolNamed("XCTMessagingChannel_RunnerToIDE"),
      peerInterface: Self.protocolNamed("XCTMessagingChannel_IDEToRunner")
    ) { [self] channel in
      logger.log("Got proxy channel request from test bundle")
      let channel = unsafe unsafeBitCast(channel, to: (any DTXProxyChannelMessaging).self)
      channel.setExportedObject(self, queue: workQueue)
      let proxy = unsafe unsafeBitCast(channel.remoteObjectProxy(), to: (any XCTestDriverMessaging).self)
      testBundleProxyLock.withLock { testBundleProxy = proxy }
      delegate.testBundleConnectionDidOpenProxyChannel()
    }
    logger.log("Resuming the test bundle connection.")
    connection.resume()
  }

  private func sendStartSessionRequest(_ connection: any DTXConnectionMessaging) {
    logger.log("Checking test manager availability...")
    let proxyChannel = unsafe unsafeBitCast(
      connection.makeProxyChannel(
        remoteInterface: Self.protocolNamed("XCTMessagingChannel_IDEToDaemon"),
        exportedInterface: Self.protocolNamed("XCTMessagingChannel_DaemonToIDE")),
      to: (any DTXProxyChannelMessaging).self)
    proxyChannel.setAllowedClassesForTestingProtocols()
    proxyChannel.setExportedObject(self, queue: workQueue)
    let remoteProxy = unsafe unsafeBitCast(proxyChannel.remoteObjectProxy(), to: (any XCTestManagerDaemonConnectionMessaging).self)

    logger.log("Starting test session with ID \(context.sessionIdentifier.uuidString)")
    let sessionStartMethod: String
    let request: AnyObject
    // iOS 27 runtimes, which need Xcode 27, only start a test session requested with capabilities.
    if XcodeConfiguration.xcodeVersion.majorVersion >= 27 {
      let capabilities: AnyObject
      do {
        capabilities = try TestConfiguration.ideCapabilities()
      } catch {
        proxyChannel.cancel()
        delegate.testBundleConnectionDidStartSessionWithError(error)
        return
      }
      sessionStartMethod = "_IDE_initiateSessionWithIdentifier:capabilities:"
      request = remoteProxy.initiateSession(identifier: context.sessionIdentifier as NSUUID, capabilities: capabilities)
    } else {
      sessionStartMethod = "_IDE_initiateSessionWithIdentifier:forClient:atPath:protocolVersion:"
      request = remoteProxy.initiateSession(
        identifier: context.sessionIdentifier as NSUUID,
        client: Self.clientProcessUniqueIdentifier as NSString,
        path: Self.clientProcessDisplayPath as NSString,
        protocolVersion: NSNumber(value: protocolVersion))
    }
    let receipt = unsafe unsafeBitCast(request, to: (any DTXRemoteInvocationReceiptCompletion).self)
    receipt.handleCompletion { [self] result, error in
      proxyChannel.cancel()
      if let error {
        logger.log("testmanagerd did \(sessionStartMethod) failed: \(error)")
        delegate.testBundleConnectionDidStartSessionWithError(error)
        return
      }
      logger.log("testmanagerd handled \(sessionStartMethod) with \(result.map { String(describing: $0) } ?? "nil")")
      delegate.testBundleConnectionDidStartSessionWithError(nil)
    }
  }

  private func conclude(with error: any Error) {
    logger.log("Test Completed with error: \(error)")
    delegate.testBundleConnectionBundleDidFailWithError(error)
  }

  /// DTX refuses an exported object that does not conform to the channel's exported interface. The
  /// interfaces are XCTest's private protocols, so the conformances are added at runtime, once XCTest
  /// has registered them.
  private static let addExportedInterfaceConformances: Void = {
    for name in ["XCTestManager_IDEInterface", "XCTMessagingChannel_DaemonToIDE", "XCTMessagingChannel_RunnerToIDE"] {
      class_addProtocol(TestBundleDTXConnection.self, protocolNamed(name))
    }
  }()

  /// The protocol XCTest registered under `name`. XCTest's private framework vends the DTX categories
  /// this connection calls, so it is loaded whenever they are.
  private static func protocolNamed(_ name: String) -> Protocol {
    guard let resolved = unsafe objc_getProtocol(name) else {
      preconditionFailure("XCTest has not registered \(name); its private framework is not loaded")
    }
    return resolved
  }
}

// MARK: - XCTestDriverInterface

extension TestBundleDTXConnection {

  @objc(_XCT_didFinishExecutingTestPlan)
  func didFinishExecutingTestPlan() -> Any? {
    delegate.testBundleConnectionDidFinishTestPlan()
    return unsafe interface.perform(NSSelectorFromString("_XCT_didFinishExecutingTestPlan"))?.takeUnretainedValue()
  }

  @objc(_XCT_testBundleReadyWithProtocolVersion:minimumVersion:)
  func testBundleReady(protocolVersion bundleVersion: NSNumber, minimumVersion: NSNumber) -> Any? {
    let bundleVersionInt = bundleVersion.intValue
    let minimumVersionInt = minimumVersion.intValue
    logger.log("Test bundle is ready, running protocol \(bundleVersionInt), requires at least version \(minimumVersionInt). IDE is running \(protocolVersion) and requires at least \(protocolMinimumVersion)")
    if minimumVersionInt > protocolVersion {
      conclude(with: XCTestBootstrapErrors.startupFailure("Protocol mismatch: test process requires at least version \(minimumVersionInt), IDE is running version \(protocolVersion)", underlyingError: nil))
      return nil
    }
    if bundleVersionInt < protocolMinimumVersion {
      conclude(with: XCTestBootstrapErrors.startupFailure("Protocol mismatch: IDE requires at least version \(protocolMinimumVersion), test process is running version \(bundleVersionInt)", underlyingError: nil))
      return nil
    }
    logger.log("Test Bundle is Ready")
    delegate.testBundleConnectionBundleDidBecomeReady()
    return unsafe interface.perform(NSSelectorFromString("_XCT_testBundleReadyWithProtocolVersion:minimumVersion:"), with: bundleVersion, with: minimumVersion)?.takeUnretainedValue()
  }

  @objc(_XCT_initializationForUITestingDidFailWithError:)
  func initializationForUITestingDidFail(error: NSError?) -> Any? {
    conclude(with: XCTestBootstrapErrors.startupFailure("Failed to initialize for UI testing", underlyingError: error))
    return nil
  }

  /// Called once XCTest's runner is loaded into the host app and ready. The answer is the
  /// `XCTestConfiguration` that says which tests to run and how.
  @objc(_XCT_testRunnerReadyWithCapabilities:)
  func testRunnerReady(capabilities: AnyObject?) -> Any? {
    logger.log("Test Bundle is Ready")
    let receipt = makeRemoteInvocationReceipt()
    receipt?.invokeCompletion(returnValue: context.testConfiguration.xcTestConfiguration, error: nil)
    delegate.testBundleConnectionBundleDidBecomeReady()
    return receipt
  }
}
