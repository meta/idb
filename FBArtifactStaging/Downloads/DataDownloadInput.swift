/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import os

/// What a download reports about its own progress, as distinct from the bytes it
/// is delivering.
enum DataDownloadEvent: Sendable {

  /// The server accepted the request. A length of zero or less means it did not
  /// say how much to expect.
  case response(expectedContentLength: Int64)

  /// A chunk of this many bytes arrived.
  case data(byteCount: Int)
}

final class DataDownloadInput: NSObject, @unchecked Sendable {

  /// The downloaded bytes, written as they arrive and ended when the transfer ends.
  let spool: DownloadSpool

  /// Waits for the transfer to finish, throwing if the server rejected the request or the connection
  /// dropped. `spool` alone cannot distinguish a failed download from a short one.
  @discardableResult
  func completed() async throws -> DownloadReport {
    try await finished.wait()
    // The latch opens on the delegate queue after the last write to `report` and `failure`.
    if let failure {
      throw failure
    }
    return report
  }

  private let finished = AsyncEvent<Void>()
  private let task = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)
  private let cancelRequested = OSAllocatedUnfairLock(initialState: false)
  // Written with `failure`.
  private var failedBeforeCancel = false
  // Written only from the session's delegate queue, which is serial.
  private var report = DownloadReport()
  private var failure: Error?
  // The download starts as soon as it is made.
  private let requestStart = Date()
  private let onEvent: (@Sendable (DataDownloadEvent) -> Void)?
  private let logger: ControlCoreLogger

  /// Stops the transfer, which then completes failed and ends `spool`. For a reader that has no use for the rest.
  func cancel() {
    cancelRequested.withLock { $0 = true }
    task.withLock { $0 }?.cancel()
  }

  /// Whether the download failed for a reason of its own, rather than because `cancel` stopped it. Read after
  /// `completed()` throws.
  var failedOnItsOwn: Bool {
    failedBeforeCancel
  }

  /// Downloads over a caller-supplied session configuration, so that timeouts,
  /// caching policy and protocol handling are the caller's to decide.
  ///
  /// `onEvent` reports how many bytes have arrived, while the bytes themselves
  /// still go only to `spool`, so a caller can show progress without getting
  /// between the download and whatever is consuming it. The spool is a file in `spoolDirectory`, unlinked once open.
  init(
    url: URL,
    configuration: URLSessionConfiguration = .default,
    logger: ControlCoreLogger,
    onEvent: (@Sendable (DataDownloadEvent) -> Void)? = nil,
    spoolDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    spool = DownloadSpool(directory: spoolDirectory)
    self.logger = logger
    self.onEvent = onEvent
    super.init()
    startDownload(from: url, configuration: configuration)
  }

  // The session holds both the delegate and the resumed task for the lifetime of the download, so neither needs storing here.
  // It lets go of the delegate only once invalidated, which `finishTasksAndInvalidate` defers until the task completes.
  private func startDownload(from url: URL, configuration: URLSessionConfiguration) {
    if let error = spool.creationFailure {
      // Nothing that arrived could be kept, so nothing is fetched.
      fail(InstallError.transferFailed(url: url, underlying: error))
      return
    }
    let delegateQueue = OperationQueue()
    delegateQueue.name = "FBControlCore.DataDownloadInput.urlSessionDelegate"
    // Callers read the events as an ordered sequence: the response before any
    // chunk, and chunks in arrival order. An `OperationQueue` is concurrent
    // unless told otherwise.
    delegateQueue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    let dataTask = session.dataTask(with: url)
    task.withLock { $0 = dataTask }
    dataTask.resume()
    session.finishTasksAndInvalidate()
  }
}

// MARK: - URLSessionDataDelegate

extension DataDownloadInput: URLSessionDataDelegate {

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    report.timeToFirstByte = Date().timeIntervalSince(requestStart)
    guard let httpResponse = response as? HTTPURLResponse else {
      completionHandler(.allow)
      return
    }
    guard httpResponse.statusCode == 200 else {
      // Without this the body of an error page is piped onward as though it were
      // the payload, and the caller is told it has a malformed archive.
      let error = InstallError.httpStatus(
        url: dataTask.originalRequest?.url ?? httpResponse.url,
        statusCode: httpResponse.statusCode)
      logger.error().log(error.description)
      fail(error)
      completionHandler(.cancel)
      return
    }
    report.freshness = HTTPFreshness { httpResponse.value(forHTTPHeaderField: $0) }
    onEvent?(.response(expectedContentLength: httpResponse.expectedContentLength))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try spool.append(data)
    } catch {
      // The download is the failure, recorded before the spool's reader can see it, rather than the extraction that
      // reads a spool cut short.
      fail(InstallError.transferFailed(url: dataTask.originalRequest?.url, underlying: error, report: report))
      spool.end(failing: error)
      dataTask.cancel()
      return
    }
    report.receivedBytes += Int64(data.count)
    onEvent?(.data(byteCount: data.count))
  }

  // Delivered before the task completes.
  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    report.observe(metrics)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      logger.error().log("Download task \(task) failed with error \(error)")
      report.trust = DownloadReport.Trust(failure: error)
      fail(InstallError.transferFailed(url: task.originalRequest?.url, underlying: error, report: report))
    } else {
      finished.happen()
    }
    spool.end()
  }

  // The first failure wins, so a cancellation triggered by a rejected response
  // does not displace the HTTP status that caused it.
  private func fail(_ error: Error) {
    guard !finished.hasHappened else {
      return
    }
    failure = error
    failedBeforeCancel = !cancelRequested.withLock { $0 }
    finished.happen()
  }
}
