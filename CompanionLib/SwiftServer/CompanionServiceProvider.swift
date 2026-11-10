/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import IDBTelemetry
import SwiftProtobuf

final class CompanionServiceProvider: Idb_CompanionService.SimpleServiceProtocol, @unchecked Sendable {

  private let target: CompanionTarget
  private let commandExecutor: IDBCommandExecutor
  private let reporter: EventReporter
  private let logger: IDBLogger
  private let telemetry: CompanionTelemetry
  /// Tracks in-flight calls so the companion can shut down when idle.
  private let idleMonitor: IdleMonitor?
  private let allowedForwardPorts: Set<UInt16>
  /// Owns the single in-progress REPL screen recording. Held here, at target scope,
  /// because a recording can outlive the `repl` stream that started it (the app
  /// context keeps the app -- and the recording -- alive across reconnects).
  private let replRecordingCoordinator: ReplRecordingCoordinator

  init(
    target: CompanionTarget,
    commandExecutor: IDBCommandExecutor,
    reporter: EventReporter,
    logger: IDBLogger,
    idleMonitor: IdleMonitor? = nil,
    allowedForwardPorts: Set<UInt16> = []
  ) {
    self.target = target
    self.commandExecutor = commandExecutor
    self.reporter = reporter
    self.logger = logger
    self.telemetry = CompanionTelemetry(logger: logger, reporter: reporter)
    self.idleMonitor = idleMonitor
    self.allowedForwardPorts = allowedForwardPorts
    self.replRecordingCoordinator = ReplRecordingCoordinator(
      auxillaryDirectory: commandExecutor.auxillaryDirectory, logger: target.logger)
  }

  /// Also counts the call as in-flight for `idleMonitor` (a no-op when idle shutdown is disabled),
  /// and maps whatever the handler throws to the status the client sees.
  ///
  /// The generated service runs a streaming handler inside the response producer, after the
  /// interceptor chain has already returned, so an interceptor cannot map its errors; the
  /// mapping has to happen here, around the handler itself.
  private func tracked<R>(_ body: () async throws -> R) async throws -> R {
    do {
      guard let idleMonitor else {
        return try await body()
      }
      return try await idleMonitor.tracking(body)
    } catch {
      throw ErrorMapping.rpcError(from: error)
    }
  }

  /// The teardown scope every handler runs in. Sits inside the telemetry span rather than around
  /// it, so a call's reported duration continues to include the time its cleanups take.
  ///
  /// The code-location defaults belong to the `tracked*` caller, which forwards its own, so a
  /// context reports the RPC method that opened it rather than a helper in this file.
  private func scoped<R>(function: String, file: String, line: Int, column: Int, _ body: () async throws -> R) async throws -> R {
    try await TeardownContext.withAutocleanup(
      function: function, file: file, line: line, column: column, operation: body)
  }

  private func trackedUnaryCall<Request, Response>(_ context: ServerContext, request: Request, summarize: ((Response) -> String)? = nil, function: String = #function, file: String = #file, line: Int = #line, column: Int = #column, body: () async throws -> Response) async throws -> Response {
    try await tracked {
      try await telemetry.unaryCall(context.descriptor.method, request: request, summarize: summarize) {
        try await scoped(function: function, file: file, line: line, column: column, body)
      }
    }
  }

  private func trackedClientStreaming<Response>(_ context: ServerContext, function: String = #function, file: String = #file, line: Int = #line, column: Int = #column, body: () async throws -> Response) async throws -> Response {
    try await tracked {
      try await telemetry.clientStreaming(context.descriptor.method) {
        try await scoped(function: function, file: file, line: line, column: column, body)
      }
    }
  }

  private func trackedServerStreaming<Request>(_ context: ServerContext, request: Request, function: String = #function, file: String = #file, line: Int = #line, column: Int = #column, body: () async throws -> Void) async throws {
    try await tracked {
      try await telemetry.serverStreaming(context.descriptor.method, request: request) {
        try await scoped(function: function, file: file, line: line, column: column, body)
      }
    }
  }

  private func trackedBidiStreaming(_ context: ServerContext, function: String = #function, file: String = #file, line: Int = #line, column: Int = #column, body: () async throws -> Void) async throws {
    try await tracked {
      try await telemetry.bidiStreaming(context.descriptor.method) {
        try await scoped(function: function, file: file, line: line, column: column, body)
      }
    }
  }

  private var targetLogger: ControlCoreLogger {
    target.logger
  }

  func connect(request: Idb_ConnectRequest, context: ServerContext) async throws -> Idb_ConnectResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ConnectMethodHandler(reporter: reporter, logger: logger, target: target)
        .handle(request: request, context: context)
    }
  }

  func debugserver(request: RPCAsyncSequence<Idb_DebugServerRequest, any Error>, response: RPCWriter<Idb_DebugServerResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await DebugserverMethodHandler(commandExecutor: commandExecutor)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func dap(request: RPCAsyncSequence<Idb_DapRequest, any Error>, response: RPCWriter<Idb_DapResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await DapMethodHandler(commandExecutor: commandExecutor, targetLogger: targetLogger)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func describe(request: Idb_TargetDescriptionRequest, context: ServerContext) async throws -> Idb_TargetDescriptionResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await DescribeMethodHandler(reporter: reporter, logger: logger, target: target)
        .handle(request: request, context: context)
    }
  }

  func forward_port(request: RPCAsyncSequence<Idb_ForwardPortRequest, any Error>, response: RPCWriter<Idb_ForwardPortResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await ForwardPortMethodHandler(target: target, allowedPorts: allowedForwardPorts)
        .handle(requestStream: reader, responseStream: response)
    }
  }

  func install(request: RPCAsyncSequence<Idb_InstallRequest, any Error>, response: RPCWriter<Idb_InstallResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await InstallMethodHandler(commandExecutor: commandExecutor, targetLogger: targetLogger)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func log(request: Idb_LogRequest, response: RPCWriter<Idb_LogResponse>, context: ServerContext) async throws {
    try await trackedServerStreaming(context, request: request) {
      try await LogMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(request: request, responseStream: response, context: context)
    }
  }

  func xctrace_record(request: RPCAsyncSequence<Idb_XctraceRecordRequest, any Error>, response: RPCWriter<Idb_XctraceRecordResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await XctraceRecordMethodHandler(logger: logger, targetLogger: targetLogger, target: target)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func profile(request: RPCAsyncSequence<Idb_ProfileRequest, any Error>, response: RPCWriter<Idb_ProfileResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await ProfileMethodHandler(logger: logger, target: target)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func accessibility_info(request: Idb_AccessibilityInfoRequest, context: ServerContext) async throws -> Idb_AccessibilityInfoResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await AccessibilityInfoMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func accessibility_quiescence(request: Idb_AccessibilityQuiescenceRequest, response: RPCWriter<Idb_AccessibilityQuiescenceResponse>, context: ServerContext) async throws {
    try await trackedServerStreaming(context, request: request) {
      try await AccessibilityQuiescenceMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, responseStream: response, context: context)
    }
  }

  func accessibility_action(request: Idb_AccessibilityActionRequest, context: ServerContext) async throws -> Idb_AccessibilityActionResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await AccessibilityActionMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func focus(request: Idb_FocusRequest, context: ServerContext) async throws -> Idb_FocusResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await FocusMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func get_orientation(request: Idb_GetOrientationRequest, context: ServerContext) async throws -> Idb_GetOrientationResponse {
    try await trackedUnaryCall(context, request: request) {
      try await OrientationMethodHandler(target: target).get()
    }
  }

  func set_orientation(request: Idb_SetOrientationRequest, context: ServerContext) async throws -> Idb_SetOrientationResponse {
    try await trackedUnaryCall(context, request: request) {
      try await OrientationMethodHandler(target: target).set(request: request)
    }
  }

  func hinge_angle(request: Idb_HingeAngleRequest, context: ServerContext) async throws -> Idb_HingeAngleResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await HingeAngleMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func hid(request: RPCAsyncSequence<Idb_HIDEvent, any Error>, context: ServerContext) async throws -> Idb_HIDResponse {
    let reader = RequestStreamReader(request)
    return try await trackedClientStreaming(context) {
      try await HidMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(requestStream: reader, context: context)
    }
  }

  func open_url(request: Idb_OpenUrlRequest, context: ServerContext) async throws -> Idb_OpenUrlRequest {
    return try await trackedUnaryCall(context, request: request) {
      try await OpenUrlMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func set_location(request: Idb_SetLocationRequest, context: ServerContext) async throws -> Idb_SetLocationResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await SetLocationMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func delivered_notifications(request: Idb_DeliveredNotificationsRequest, context: ServerContext) async throws -> Idb_DeliveredNotificationsResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await DeliveredNotificationsMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func clear_delivered_notifications(request: Idb_ClearDeliveredNotificationsRequest, context: ServerContext) async throws -> Idb_ClearDeliveredNotificationsResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ClearDeliveredNotificationsMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func send_notification(request: Idb_SendNotificationRequest, context: ServerContext) async throws -> Idb_SendNotificationResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await SendNotificationMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func simulate_memory_warning(request: Idb_SimulateMemoryWarningRequest, context: ServerContext) async throws -> Idb_SimulateMemoryWarningResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await SimulateMemoryWarningMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func approve(request: Idb_ApproveRequest, context: ServerContext) async throws -> Idb_ApproveResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ApproveMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func revoke(request: Idb_RevokeRequest, context: ServerContext) async throws -> Idb_RevokeResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await RevokeMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func clear_keychain(request: Idb_ClearKeychainRequest, context: ServerContext) async throws -> Idb_ClearKeychainResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ClearKeychainMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func contacts_update(request: Idb_ContactsUpdateRequest, context: ServerContext) async throws -> Idb_ContactsUpdateResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ContactsUpdateMethodHandler(target: target, temporaryDirectory: commandExecutor.temporaryDirectory)
        .handle(request: request, context: context)
    }
  }

  func contacts_clear(request: Idb_ContactsClearRequest, context: ServerContext) async throws -> Idb_ContactsClearResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await target.simulator().contacts.clear()
      return Idb_ContactsClearResponse()
    }
  }

  func photos_clear(request: Idb_PhotosClearRequest, context: ServerContext) async throws -> Idb_PhotosClearResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await target.simulator().photos.clear()
      return Idb_PhotosClearResponse()
    }
  }

  func lock_screen(request: Idb_LockScreenRequest, context: ServerContext) async throws -> Idb_LockScreenResponse {
    return try await trackedUnaryCall(context, request: request) {
      let lockScreen = try target.simulator().lockScreen
      let state =
        switch request.action {
        case .state: try await lockScreen.state()
        case .lock: try await lockScreen.lock()
        case .unlock: try await lockScreen.unlock()
        case .UNRECOGNIZED: throw RPCError(code: .invalidArgument, message: "Unrecognized lock screen action")
        }
      return Idb_LockScreenResponse.with { $0.locked = state.locked }
    }
  }

  func setting(request: Idb_SettingRequest, context: ServerContext) async throws -> Idb_SettingResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await SettingMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func get_setting(request: Idb_GetSettingRequest, context: ServerContext) async throws -> Idb_GetSettingResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await GetSettingMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func list_settings(request: Idb_ListSettingRequest, context: ServerContext) async throws -> Idb_ListSettingResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ListSettingsMethodHandler()
        .handle(request: request, context: context)
    }
  }

  func launch(request: RPCAsyncSequence<Idb_LaunchRequest, any Error>, response: RPCWriter<Idb_LaunchResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await LaunchMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func list_apps(request: Idb_ListAppsRequest, context: ServerContext) async throws -> Idb_ListAppsResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ListAppsMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func terminate(request: Idb_TerminateRequest, context: ServerContext) async throws -> Idb_TerminateResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await TerminateMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func uninstall(request: Idb_UninstallRequest, context: ServerContext) async throws -> Idb_UninstallResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await UninstallMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func add_media(request: RPCAsyncSequence<Idb_AddMediaRequest, any Error>, context: ServerContext) async throws -> Idb_AddMediaResponse {
    let reader = RequestStreamReader(request)
    return try await trackedClientStreaming(context) {
      try await AddMediaMethodHandler(target: target, temporaryDirectory: commandExecutor.temporaryDirectory)
        .handle(requestStream: reader, context: context)
    }
  }

  func inject_audio(request: RPCAsyncSequence<Idb_InjectAudioRequest, any Error>, context: ServerContext) async throws -> Idb_InjectAudioResponse {
    let reader = RequestStreamReader(request)
    return try await trackedClientStreaming(context) {
      try await InjectAudioMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(requestStream: reader, context: context)
    }
  }

  func inject_video(request: RPCAsyncSequence<Idb_InjectVideoRequest, any Error>, response: RPCWriter<Idb_InjectVideoResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await InjectVideoMethodHandler(target: target)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func record(request: RPCAsyncSequence<Idb_RecordRequest, any Error>, response: RPCWriter<Idb_RecordResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await RecordMethodHandler(target: target, targetLogger: targetLogger)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func screenshot(request: Idb_ScreenshotRequest, context: ServerContext) async throws -> Idb_ScreenshotResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await ScreenshotMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func video_stream(request: RPCAsyncSequence<Idb_VideoStreamRequest, any Error>, response: RPCWriter<Idb_VideoStreamResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await VideoStreamMethodHandler(target: target, targetLogger: targetLogger, commandExecutor: commandExecutor)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func crash_delete(request: Idb_CrashLogQuery, context: ServerContext) async throws -> Idb_CrashLogResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await CrashDeleteMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func crash_list(request: Idb_CrashLogQuery, context: ServerContext) async throws -> Idb_CrashLogResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await CrashListMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func crash_show(request: Idb_CrashShowRequest, context: ServerContext) async throws -> Idb_CrashShowResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await CrashShowMethodHandler(target: target)
        .handle(request: request, context: context)
    }
  }

  func xctest_list_bundles(request: Idb_XctestListBundlesRequest, context: ServerContext) async throws -> Idb_XctestListBundlesResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await XCTestListBundlesMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func xctest_list_tests(request: Idb_XctestListTestsRequest, context: ServerContext) async throws -> Idb_XctestListTestsResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await XCTestListTestsMethodHandler(target: target, storageManager: commandExecutor.storageManager)
        .handle(request: request, context: context)
    }
  }

  func xctest_run(request: Idb_XctestRunRequest, response: RPCWriter<Idb_XctestRunResponse>, context: ServerContext) async throws {
    try await trackedServerStreaming(context, request: request) {
      try await XCTestRunMethodHandler(target: target, commandExecutor: commandExecutor, reporter: reporter, targetLogger: targetLogger, logger: logger)
        .handle(request: request, responseStream: response, context: context)
    }
  }

  func repl(request: RPCAsyncSequence<Idb_ReplRequest, any Error>, response: RPCWriter<Idb_ReplResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await ReplMethodHandler(commandExecutor: commandExecutor, targetLogger: targetLogger, recordingCoordinator: replRecordingCoordinator)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }

  func ls(request: Idb_LsRequest, context: ServerContext) async throws -> Idb_LsResponse {
    return try await trackedUnaryCall(context, request: request, summarize: LsMethodHandler.summarize) {
      try await LsMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func mkdir(request: Idb_MkdirRequest, context: ServerContext) async throws -> Idb_MkdirResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await MkdirMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func mv(request: Idb_MvRequest, context: ServerContext) async throws -> Idb_MvResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await MvMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func rm(request: Idb_RmRequest, context: ServerContext) async throws -> Idb_RmResponse {
    return try await trackedUnaryCall(context, request: request) {
      try await RmMethodHandler(commandExecutor: commandExecutor)
        .handle(request: request, context: context)
    }
  }

  func pull(request: Idb_PullRequest, response: RPCWriter<Idb_PullResponse>, context: ServerContext) async throws {
    try await trackedServerStreaming(context, request: request) {
      try await PullMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(request: request, responseStream: response, context: context)
    }
  }

  func push(request: RPCAsyncSequence<Idb_PushRequest, any Error>, context: ServerContext) async throws -> Idb_PushResponse {
    let reader = RequestStreamReader(request)
    return try await trackedClientStreaming(context) {
      try await PushMethodHandler(target: target, commandExecutor: commandExecutor)
        .handle(requestStream: reader, context: context)
    }
  }

  func tail(request: RPCAsyncSequence<Idb_TailRequest, any Error>, response: RPCWriter<Idb_TailResponse>, context: ServerContext) async throws {
    let reader = RequestStreamReader(request)
    try await trackedBidiStreaming(context) {
      try await TailMethodHandler(commandExecutor: commandExecutor)
        .handle(requestStream: reader, responseStream: response, context: context)
    }
  }
}
