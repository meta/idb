/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IDBTelemetry

/// Per-RPC telemetry, applied in `CompanionServiceProvider` around each handler dispatch: logs
/// `<method> called with: [<args>]` and `<method> succeeded in <duration>` / `<method> failed after
/// <duration>: <message>`, all at info so a failing call stays visible under `-log-level info`, and reports
/// one success or failure `EventReporterSubject` per call. Unary calls may pass `summarize` to append a
/// result summary to the success line (e.g. `ls succeeded in 12ms (5 entries)`). Columns a handler set
/// through `CallTelemetry` end either completion line (e.g. `install succeeded in 2.10s {size=4096}`). Arguments are rendered
/// from the request via `Mirror`, each value middle-truncated to 100 characters (container GUIDs and temp
/// paths differ at the tail); empty protobuf `unknownFields` are omitted. A handler adds `size`, ints and
/// normals to its call's subject through `CallTelemetry.current`.
struct CompanionTelemetry {

  let logger: IDBLogger
  let reporter: any EventReporter

  private static let argumentValueLimit = 100

  // MARK: - RPC shapes

  @discardableResult
  func unaryCall<Request, Response>(
    _ method: String,
    request: Request,
    summarize: ((Response) -> String)? = nil,
    body: () async throws -> Response
  ) async throws -> Response {
    return try await report(
      method: method,
      arguments: describeArguments(request),
      summarize: summarize,
      body: body)
  }

  @discardableResult
  func clientStreaming<Response>(
    _ method: String,
    body: () async throws -> Response
  ) async throws -> Response {
    return try await report(method: method, arguments: [], body: body)
  }

  func serverStreaming<Request>(
    _ method: String,
    request: Request,
    body: () async throws -> Void
  ) async throws {
    try await report(method: method, arguments: describeArguments(request), body: body)
  }

  func bidiStreaming(
    _ method: String,
    body: () async throws -> Void
  ) async throws {
    try await report(method: method, arguments: [], body: body)
  }

  // MARK: - Core reporting

  @discardableResult
  private func report<R>(
    method: String,
    arguments: [String],
    summarize: ((R) -> String)? = nil,
    body: () async throws -> R
  ) async throws -> R {
    // Monotonic on purpose: a wall clock can step backwards (NTP) across the
    // await, producing negative durations.
    let start = DispatchTime.now()
    let call = CallTelemetry()
    logger.info().log("\(method) called with: \(oneLineDescription(arguments))")
    do {
      let result = try await CallTelemetry.$current.withValue(call) {
        try await body()
      }
      let duration = Self.secondsSince(start)
      let summary = summarize.map { " (\($0(result)))" } ?? ""
      logger.info().log("\(method) succeeded in \(Self.formatDuration(duration))\(summary)\(Self.columnSuffix(call))")
      reporter.report(
        EventReporterSubject(
          forSuccessfulCall: method,
          duration: duration,
          size: call.size,
          arguments: arguments,
          normals: call.normals,
          ints: call.ints))
      return result
    } catch {
      let duration = Self.secondsSince(start)
      let message = (error as NSError).localizedDescription
      logger.info().log("\(method) failed after \(Self.formatDuration(duration)): \(message)\(Self.columnSuffix(call))")
      reporter.report(
        EventReporterSubject(
          forFailingCall: method,
          duration: duration,
          message: message,
          size: call.size,
          arguments: arguments,
          normals: call.normals,
          ints: call.ints))
      throw error
    }
  }

  private static func columnSuffix(_ call: CallTelemetry) -> String {
    let columns = call.columnDescriptions
    return columns.isEmpty ? "" : " {" + columns.joined(separator: ", ") + "}"
  }

  private static func secondsSince(_ start: DispatchTime) -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
  }

  /// Renders a call duration for the completion line: whole milliseconds
  /// below one second, two-decimal seconds above it.
  static func formatDuration(_ duration: TimeInterval) -> String {
    if duration < 1 {
      return unsafe String(format: "%.0fms", duration * 1000)
    }
    return unsafe String(format: "%.2fs", duration)
  }

  /// Truncates over-long values to exactly `limit` characters, keeping the
  /// head and the tail around an ellipsis. Values at or under the limit
  /// pass through verbatim.
  static func truncateMiddle(_ value: String, limit: Int) -> String {
    guard value.count > limit else {
      return value
    }
    let ellipsis = "..."
    let headCount = (limit - ellipsis.count) / 2
    let tailCount = limit - ellipsis.count - headCount
    return String(value.prefix(headCount)) + ellipsis + String(value.suffix(tailCount))
  }

  // MARK: - Argument description

  private func describeArguments(_ request: Any) -> [String] {
    let mirror = Mirror(reflecting: request)
    var args: [String] = []
    for child in mirror.children {
      guard var label = child.label else { continue }
      // SwiftProtobuf prefixes backing-storage fields with "_"; surface the user-facing name.
      if label.hasPrefix("_") {
        label = String(label.dropFirst())
      }
      let raw = "\(child.value)"
      // Every protobuf request carries unknownFields; skip the storage when
      // it is empty so the log line only names fields that say something.
      // Non-empty storage is kept verbatim for forward-compat debugging.
      if label == "unknownFields" && raw == "UnknownStorage(data: 0 bytes)" {
        continue
      }
      // Protobuf messages render across lines (e.g. a file container dumps
      // as `...Container:\nkind: ROOT\n)]`); flatten so one argument stays
      // on one log line and line-oriented tools keep working.
      let singleLine =
        raw
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      args.append("\(label)=\(Self.truncateMiddle(singleLine, limit: Self.argumentValueLimit))")
    }
    return args
  }

  private func oneLineDescription(_ arguments: [String]) -> String {
    "[" + arguments.joined(separator: ", ") + "]"
  }
}
