/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry

/// Logs a one-line summary when a streaming call's client stream closes.
///
/// Call *start* is intentionally not logged here: `CompanionTelemetry` wraps
/// every handler and already logs `<method> called with` at info, so a
/// `Start of` line would duplicate it. Per-frame logging is likewise avoided:
/// a single `hid` stream can carry dozens of frames, so frames are counted
/// and summarized on close instead.
///
/// Call *completion* (success/failure) is intentionally not logged or reported
/// here. `CompanionTelemetry` wraps every handler in a `do`/`catch` and reports
/// completion — and the success/failure `EventReporter` event — reliably on every
/// termination path, so it is the single source for that.
///
/// The frame counter lives inside `intercept`, so one interceptor instance serves
/// every call without shared state.
struct LoggingInterceptor: ServerInterceptor {

  private let logger: IDBLogger

  init(logger: IDBLogger) {
    self.logger = logger
  }

  func intercept<Input: Sendable, Output: Sendable>(
    request: StreamingServerRequest<Input>,
    context: ServerContext,
    next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
  ) async throws -> StreamingServerResponse<Output> {
    guard Self.isClientStreaming(context.descriptor) else {
      return try await next(request, context)
    }

    let logger = self.logger
    let method = context.descriptor.method
    let counted = RPCAsyncSequence<Input, any Error>(
      wrapping: CountingSequence(base: request.messages) { frameCount in
        logger.debug().log("Closed client stream of \(method) after \(frameCount) frames")
      })
    return try await next(StreamingServerRequest(metadata: request.metadata, messages: counted), context)
  }

  /// The context's descriptor comes from the transport and carries no call type; the
  /// generated service metadata does, so the method is looked up there.
  private static func isClientStreaming(_ descriptor: MethodDescriptor) -> Bool {
    switch clientStreamingTypes[descriptor.fullyQualifiedMethod] {
    case .clientStreaming, .bidirectionalStreaming:
      return true
    case .unary, .serverStreaming, .none:
      return false
    }
  }

  private static let clientStreamingTypes: [String: MethodDescriptor.RPCType] = Idb_CompanionService.Method.descriptors
    .reduce(into: [:]) { $0[$1.fullyQualifiedMethod] = $1.type }
}

/// Passes `base` through unchanged, reporting how many elements were produced once it ends.
private struct CountingSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element: Sendable {
  typealias Element = Base.Element

  let base: Base
  let onEnd: @Sendable (Int) -> Void

  func makeAsyncIterator() -> Iterator {
    Iterator(base: base.makeAsyncIterator(), onEnd: onEnd)
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: Base.AsyncIterator
    let onEnd: @Sendable (Int) -> Void
    var count = 0
    var ended = false

    mutating func next() async throws -> Element? {
      if let element = try await base.next() {
        count += 1
        return element
      }
      if !ended {
        ended = true
        onEnd(count)
      }
      return nil
    }
  }
}
