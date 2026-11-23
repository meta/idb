/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import os

struct InstallMethodHandler {

  let commandExecutor: IDBCommandExecutor
  let targetLogger: any ControlCoreLogger

  func handle(requestStream: RequestStreamReader<Idb_InstallRequest>, responseStream: RPCWriter<Idb_InstallResponse>, context: ServerContext) async throws {

    let artifact = try await Self.mapSimulatorInstallErrors {
      let request = try await InstallRequest.read(requestStream)
      let isCancelled = { context.cancellation.isCancelled }
      // Clients print every response to any other install as an installed artifact, so only an application reports its progress.
      guard request.header.destination == .app else {
        return try await install(request, isCancelled: isCancelled)
      }
      return try await InstallPercentages.reporting(to: { progress in
        try await responseStream.send(Idb_InstallResponse.with { $0.progress = progress })
      }) { progressObserver in
        try await install(request, isCancelled: isCancelled, progressObserver: progressObserver)
      }
    }

    let response = Idb_InstallResponse.with {
      $0.name = artifact.name
      $0.uuid = artifact.uuid?.uuidString ?? ""
    }
    try await responseStream.send(response)
  }

  static func mapSimulatorInstallErrors<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch let error as SimulatorApplicationInstallError {
      switch error {
      case .processSuspended,
        .processDebuggerAttached,
        .targetNotBooted,
        .targetUnavailable:
        throw RPCError(code: .failedPrecondition, message: error.localizedDescription)
      default:
        throw error
      }
    }
  }

  func install(
    _ request: InstallRequest,
    isCancelled: () -> Bool = { false },
    progressObserver: (any InstallProgressObserving)? = nil
  ) async throws -> InstalledArtifact {
    let header = request.header
    let telemetry = InstallTelemetry(payloadKind: request.payload.kind)
    defer {
      if let call = CallTelemetry.current {
        telemetry.record(into: call)
      }
    }
    do {
      return try await install(
        request.payload,
        to: header.destination,
        name: header.nameHint ?? UUID().uuidString,
        makeDebuggable: header.makeDebuggable,
        linkToBundle: header.linkDsymToBundle.map { readLinkBundleToDsym(from: $0) },
        overrideModificationTime: header.overrideModificationTime,
        skipSigningBundles: header.skipSigningBundles,
        telemetry: telemetry,
        progressObserver: progressObserver)
    } catch {
      telemetry.failed(error, rpcCancelled: isCancelled())
      throw error
    }
  }

  private func install(
    _ payload: InstallPayload,
    to destination: Idb_InstallRequest.Destination,
    name: String,
    makeDebuggable: Bool,
    linkToBundle: DsymInstallLinkToBundle?,
    overrideModificationTime: Bool,
    skipSigningBundles: Bool,
    telemetry: InstallTelemetry,
    progressObserver: (any InstallProgressObserving)?
  ) async throws -> InstalledArtifact {

    let installDestination: InstallDestination
    switch destination {
    case .app:
      installDestination = .application(makeDebuggable: makeDebuggable)
    case .xctest:
      installDestination = .xctest(skipSigningBundles: skipSigningBundles)
    case .dsym:
      installDestination = .dsym(linkTo: linkToBundle)
    case .dylib:
      installDestination = .dylib(name: name)
    case .framework:
      installDestination = .framework
    case .UNRECOGNIZED:
      throw RPCError(code: .invalidArgument, message: "Unrecognized destination")
    }

    func install(from source: InstallSource) async throws -> InstalledArtifact {
      let options = InstallOptions(overrideModificationTime: overrideModificationTime)
      return try await commandExecutor.install(
        installDestination, from: source, options: options,
        observer: InstallObserver(telemetry: telemetry, progressObserver: progressObserver))
    }

    switch payload {
    case let .data(head, rest):
      let source = ChunkSource()
      async let pumped: Void = telemetry.receive { receive in
        try await source.pump(rest, after: head) { receive.count($0) }
      }
      let artifact: InstalledArtifact
      do {
        artifact = try await install(from: .stream(source))
      } catch {
        source.abandon()
        // A client stream that fails truncates the archive, so extraction fails too; the client's failure is the cause.
        // A pump stopped only because the extraction had stopped reading is the extraction's failure.
        do {
          try await pumped
        } catch let clientFailure where !(clientFailure is ChunkSource.ReaderClosed) {
          throw clientFailure
        } catch {}
        throw error
      }
      // The extractor may stop before the stream does -- `bsdtar` exits at the end of the archive -- and a client still
      // sending would otherwise wait for room forever. What it sends past a finished install doesn't matter.
      source.abandon()
      do {
        try await pumped
      } catch is ChunkSource.ReaderClosed {}
      return artifact

    case let .url(url, connectionOverride):
      return try await install(from: .remoteURL(url, connectingTo: connectionOverride))

    case let .filePath(filePath):
      return try await install(from: .localPath(filePath))
    }
  }

  private func readLinkBundleToDsym(from link: Idb_InstallRequest.LinkDsymToBundle) -> DsymInstallLinkToBundle {
    return .init(
      bundleID: link.bundleID,
      bundleType: readDsymBundleType(from: link.bundleType))
  }

  private func readDsymBundleType(from bundleType: Idb_InstallRequest.LinkDsymToBundle.BundleType) -> DsymBundleType {
    switch bundleType {
    case .app:
      return .app
    case .xctest:
      return .xcTest
    case .UNRECOGNIZED:
      return .app
    }
  }
}

/// The whole percentages of a download an install has received, each reported once.
final class InstallPercentages: Sendable {

  let percentages: AsyncStream<Double>
  private let continuation: AsyncStream<Double>.Continuation
  private let reported = OSAllocatedUnfairLock<Int>(initialState: 0)

  /// Only a rise is reported, so at most 100 values are ever buffered.
  init() {
    (percentages, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .unbounded)
  }

  func observe(_ event: InstallProgressEvent) {
    guard let percent = Self.percent(of: event) else {
      return
    }
    reported.withLock { reported in
      guard percent > reported else {
        return
      }
      reported = percent
      continuation.yield(Double(percent))
    }
  }

  func finish() {
    continuation.finish()
  }

  /// Reported only while a download is in progress; a download of unknown length has no percentage.
  static func percent(of event: InstallProgressEvent) -> Int? {
    guard case .downloadProgress = event else {
      return nil
    }
    return event.downloadPercent
  }
}

// MARK: - Observing

/// Records each install event in the call's telemetry, and passes its download progress on.
private struct InstallObserver: InstallEventObserving {
  let telemetry: InstallTelemetry
  let progressObserver: (any InstallProgressObserving)?

  func observe(_ event: InstallEvent) {
    telemetry.observe(event)
    if case .progress(let progress) = event {
      progressObserver?.observe(progress)
    }
  }
}

// MARK: - Reporting

/// Receives an install's download progress as it arrives.
protocol InstallProgressObserving: Sendable {
  func observe(_ event: InstallProgressEvent)
}

extension InstallPercentages: InstallProgressObserving {}

extension InstallPercentages {

  /// Runs `install`, sending each percentage of its download as it arrives and all of them before returning.
  static func reporting<T>(
    to send: @escaping @Sendable (Double) async throws -> Void,
    _ install: (any InstallProgressObserving) async throws -> T
  ) async throws -> T {
    let percentages = InstallPercentages()
    async let sent: Void = {
      for await percent in percentages.percentages {
        try await send(percent)
      }
    }()
    let result: T
    do {
      result = try await install(percentages)
    } catch {
      percentages.finish()
      try? await sent
      throw error
    }
    percentages.finish()
    try await sent
    return result
  }
}
