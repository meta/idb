/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

private let CrashLogAppeared = NSNotification.Name("CrashLogAppeared")

public final class CrashLogStore {

  private let directories: [String]
  private let logger: any ControlCoreLogger
  private let lock = NSLock()
  // Guarded by `lock`, keyed by crash log name.
  private var ingestedCrashLogs: [String: CrashLogInfo] = [:]

  public init(directories: [String], logger: any ControlCoreLogger) {
    self.directories = directories
    self.logger = logger
  }

  // MARK: - Ingestion

  @discardableResult public func ingestAllExistingInDirectory() -> [CrashLogInfo] {
    var ingested: [CrashLogInfo] = []
    for directory in directories {
      let crashLogs = ingestCrashLogInDirectory(directory)
      ingested.append(contentsOf: crashLogs)
    }
    return ingested
  }

  func ingestCrashLog(atPath path: String) -> CrashLogInfo? {
    if hasIngestedCrashLog(withName: (path as NSString).lastPathComponent) {
      return nil
    }
    guard let crashLog = try? CrashLogInfo.fromCrashLog(atPath: path) else {
      logger.log("Could not obtain crash info for \(path)")
      return nil
    }
    return ingestCrashLog(crashLog)
  }

  public func ingestCrashLogData(_ data: Data, name: String) -> CrashLogInfo? {
    if hasIngestedCrashLog(withName: name) {
      return nil
    }
    if !CrashLogInfo.isParsableCrashLog(data) {
      return nil
    }
    for directory in directories {
      let destination = (directory as NSString).appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: directory) {
        if (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)) == nil {
          continue
        }
      }
      if !(data as NSData).write(toFile: destination, atomically: true) {
        continue
      }
      return ingestCrashLog(atPath: destination)
    }
    return nil
  }

  // MARK: - Fetching

  public func ingestedCrashLog(withName name: String) -> CrashLogInfo? {
    lock.withLock { ingestedCrashLogs[name] }
  }

  func allIngestedCrashLogs() -> [CrashLogInfo] {
    lock.withLock { Array(ingestedCrashLogs.values) }
  }

  /// Starts listening for the next crash log matching `predicate` before returning, so one ingested
  /// before `CrashLogListener.next()` is awaited is still delivered.
  public func listenForNextCrashLog(matching predicate: CrashLogPredicate) -> CrashLogListener {
    CrashLogListener(predicate: predicate)
  }

  public func nextCrashLog(forMatchingPredicate predicate: CrashLogPredicate) async throws -> CrashLogInfo {
    try await listenForNextCrashLog(matching: predicate).next()
  }

  public func ingestedCrashLogs(matchingPredicate predicate: CrashLogPredicate) -> [CrashLogInfo] {
    return allIngestedCrashLogs().filter(predicate.matches)
  }

  public func pruneCrashLogs(matchingPredicate predicate: CrashLogPredicate) -> [CrashLogInfo] {
    lock.withLock {
      let pruned = ingestedCrashLogs.values.filter(predicate.matches)
      for crashLog in pruned {
        ingestedCrashLogs.removeValue(forKey: crashLog.name)
      }
      return pruned
    }
  }

  private func hasIngestedCrashLog(withName key: String) -> Bool {
    lock.withLock { ingestedCrashLogs[key] != nil }
  }

  private func ingestCrashLog(_ crashLog: CrashLogInfo) -> CrashLogInfo {
    logger.log("Ingesting Crash Log \(crashLog)")
    lock.withLock { ingestedCrashLogs[crashLog.name] = crashLog }
    NotificationCenter.default.post(name: CrashLogAppeared, object: crashLog)
    return crashLog
  }

  private func ingestCrashLogInDirectory(_ directory: String) -> [CrashLogInfo] {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
      return []
    }
    var ingested: [CrashLogInfo] = []
    for path in contents {
      if let crash = ingestCrashLog(atPath: (directory as NSString).appendingPathComponent(path)) {
        ingested.append(crash)
      }
    }
    return ingested
  }
}

/// Holds the first crash log matching its predicate from the moment it is created, and hands it to
/// every caller of `next()`.
// SAFETY: `observer` is only touched under `lock`.
// patternlint-disable-next-line unchecked-sendable
public final class CrashLogListener: @unchecked Sendable {
  private let appeared = AsyncEvent<CrashLogInfo>()
  private let lock = NSLock()
  private var observer: (any NSObjectProtocol)?

  init(predicate: CrashLogPredicate) {
    lock.lock()
    defer { lock.unlock() }
    observer = NotificationCenter.default.addObserver(forName: CrashLogAppeared, object: nil, queue: nil) { [weak self] notification in
      guard let crashLog = notification.object as? CrashLogInfo, predicate.matches(crashLog) else { return }
      self?.resolve(.success(crashLog))
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Returns the first matching crash log, waiting for one if none has appeared yet. Cancellation,
  /// including before the call, throws `CancellationError` and stops the listener, unless a crash log
  /// has already appeared.
  public func next() async throws -> CrashLogInfo {
    try await withTaskCancellationHandler {
      try await appeared.wait()
    } onCancel: {
      resolve(.failure(CancellationError()))
    }
  }

  private func resolve(_ result: Result<CrashLogInfo, any Error>) {
    let observer: (any NSObjectProtocol)? = lock.withLock {
      defer { self.observer = nil }
      return self.observer
    }
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    switch result {
    case let .success(crashLog):
      appeared.happen(crashLog)
    case let .failure(error):
      appeared.fail(error)
    }
  }
}
