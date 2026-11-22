/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore
import XCTest
import os

final class DataConsumerTests: XCTestCase {
  func testLineBufferAccumulation() {
    let consumer = AccumulatingBuffer()
    consumer.consumeData("FOO".data(using: .utf8)!)
    consumer.consumeData("BAR".data(using: .utf8)!)

    XCTAssertEqual(consumer.data(), "FOOBAR".data(using: .utf8)!)
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    XCTAssertEqual(consumer.data(), "FOOBAR".data(using: .utf8)!)
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
  }

  func testLineBufferAccumulationWithCapacity() {
    let consumer = AccumulatingBuffer(capacity: 3)
    consumer.consumeData("F".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["F"])
    consumer.consumeData("O".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["FO"])
    consumer.consumeData("O".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["FOO"])

    consumer.consumeData("B".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["OOB"])

    consumer.consumeData("AR".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["BAR"])

    consumer.consumeData("ALONGSTRINGBUTIWANTAHIT".data(using: .utf8)!)
    XCTAssertEqual(consumer.lines(), ["HIT"])
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    XCTAssertEqual(consumer.lines(), ["HIT"])
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
  }

  func testLineBufferedConsumer() {
    var lines: [String] = []
    let consumer = LineConsumer(delivery: .synchronous) { line in
      lines.append(line)
    }

    consumer.consumeData("FOO\n".data(using: .utf8)!)
    consumer.consumeData("BAR\n".data(using: .utf8)!)
    XCTAssertEqual(lines, ["FOO", "BAR"])
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    XCTAssertEqual(lines, ["FOO", "BAR"])
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("NOPE".data(using: .utf8)!)
    consumer.consumeData("NOPE".data(using: .utf8)!)
    XCTAssertEqual(lines, ["FOO", "BAR"])
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
  }

  func testLineBufferedConsumerAsync() {
    let queue = DispatchQueue(label: "testLineBufferedConsumerAsync")
    var lines: [String] = []
    let bothLines = expectation(description: "both lines delivered to the consumer")
    let consumer = LineConsumer { line in
      queue.sync {
        lines.append(line)
        if lines.count == 2 { bothLines.fulfill() }
      }
    }

    consumer.consumeData("FOO\n".data(using: .utf8)!)
    consumer.consumeData("BAR\n".data(using: .utf8)!)
    wait(for: [bothLines], timeout: ControlCoreGlobalConfiguration.fastTimeout)
    queue.sync { XCTAssertEqual(lines, ["FOO", "BAR"]) }
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    let finished = expectation(for: NSPredicate { _, _ in consumer.finishedConsuming.hasHappened }, evaluatedWith: nil)
    wait(for: [finished], timeout: ControlCoreGlobalConfiguration.fastTimeout)
    queue.sync { XCTAssertEqual(lines, ["FOO", "BAR"]) }

    consumer.consumeData("NOPE".data(using: .utf8)!)
    consumer.consumeData("NOPE".data(using: .utf8)!)
    queue.sync { XCTAssertEqual(lines, ["FOO", "BAR"]) }
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
  }

  func testLineBufferedConsumerTrailingLine() {
    var lines: [String] = []
    let consumer = LineConsumer(delivery: .synchronous) { line in
      lines.append(line)
    }

    consumer.consumeData("FOO\nBAR".data(using: .utf8)!)
    consumer.consumeEndOfFile()
    XCTAssertEqual(lines, ["FOO", "BAR"])
  }

  func testLineBufferedConsumerAsyncFinishesAfterQueuedLines() {
    let queue = DispatchQueue(label: "testLineBufferedConsumerAsyncFinishesAfterQueuedLines")
    let releaseQueue = DispatchSemaphore(value: 0)
    queue.async { releaseQueue.wait() }
    var lines: [String] = []
    let consumer = LineConsumer(delivery: .queue(queue)) { line in
      lines.append(line)
    }

    consumer.consumeData("FOO\n".data(using: .utf8)!)
    consumer.consumeEndOfFile()
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    releaseQueue.signal()
    queue.sync { XCTAssertEqual(lines, ["FOO"]) }
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
  }

  func testUnbufferedConsumer() {
    let expected = "FOOBARBAZ".data(using: .utf8)!
    let actual = NSMutableData()
    let consumer = SynchronousDataConsumer { incremental in
      actual.append(incremental)
    }

    XCTAssertFalse(consumer.finishedConsuming.hasHappened)
    consumer.consumeData("FOO".data(using: .utf8)!)
    consumer.consumeData("BAR".data(using: .utf8)!)
    consumer.consumeData("BAZ".data(using: .utf8)!)
    usleep(1000)
    XCTAssertEqual(expected, actual as Data)
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    XCTAssertEqual(expected, actual as Data)
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("NOPE".data(using: .utf8)!)
    consumer.consumeData("NOPE".data(using: .utf8)!)
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
    XCTAssertEqual(expected, actual as Data)
  }

  func testUnbufferedConsumerBlockCanReenterTheConsumer() {
    let actual = NSMutableData()
    let box = ConsumerBox<SynchronousDataConsumer>()
    box.consumer = SynchronousDataConsumer { incremental in
      actual.append(incremental)
      guard incremental == "FOO".data(using: .utf8)! else { return }
      box.consumer?.consumeData("BAR".data(using: .utf8)!)
      box.consumer?.consumeEndOfFile()
    }

    let returned = expectation(description: "the re-entrant delivery returned")
    DispatchQueue.global().async {
      box.consumer?.consumeData("FOO".data(using: .utf8)!)
      returned.fulfill()
    }
    wait(for: [returned], timeout: ControlCoreGlobalConfiguration.fastTimeout)
    XCTAssertEqual("FOOBAR".data(using: .utf8)!, actual as Data)
    XCTAssertTrue(box.consumer?.finishedConsuming.hasHappened ?? false)
  }

  func testUnbufferedConsumerAsync() {
    let expected = "FOOBARBAZ".data(using: .utf8)!
    let actual = DeliveredData()
    let allChunks = expectation(description: "all three chunks delivered to the consumer")
    let consumer = AsynchronousDataConsumer { incremental in
      actual.append(incremental)
      if actual.data.count == expected.count { allChunks.fulfill() }
    }

    XCTAssertFalse(consumer.finishedConsuming.hasHappened)
    consumer.consumeData("FOO".data(using: .utf8)!)
    consumer.consumeData("BAR".data(using: .utf8)!)
    consumer.consumeData("BAZ".data(using: .utf8)!)
    wait(for: [allChunks], timeout: ControlCoreGlobalConfiguration.fastTimeout)
    XCTAssertEqual(expected, actual.data)
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()
    XCTAssertEqual(expected, actual.data)
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("NOPE".data(using: .utf8)!)
    consumer.consumeData("NOPE".data(using: .utf8)!)
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
    XCTAssertEqual(expected, actual.data)
  }

  func testConsumerAsync() {
    let expected = "FOO".data(using: .utf8)!
    let actual = DeliveredData()
    let consumeStarted = DispatchSemaphore(value: 0)
    let continueConsume = DispatchSemaphore(value: 0)
    let consumer = AsynchronousDataConsumer { incremental in
      consumeStarted.signal()
      continueConsume.wait()
      actual.append(incremental)
    }

    XCTAssertEqual(0, consumer.unprocessedDataCount())
    consumer.consumeData("FOO".data(using: .utf8)!)
    consumeStarted.wait()
    XCTAssertEqual(1, consumer.unprocessedDataCount())
    continueConsume.signal()
    consumer.consumeEndOfFile()
    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
    XCTAssertEqual(0, consumer.unprocessedDataCount())
    XCTAssertEqual(expected, actual.data)
  }

  func testConsumerAsyncEndOfFileWithReentrantDelivery() {
    let actual = DeliveredData()
    let endOfFileStarted = DispatchSemaphore(value: 0)
    let box = ConsumerBox<AsynchronousDataConsumer>()
    box.consumer = AsynchronousDataConsumer { incremental in
      actual.append(incremental)
      guard incremental == "FOO".data(using: .utf8)! else { return }
      endOfFileStarted.wait()
      box.consumer?.consumeData("BAR".data(using: .utf8)!)
    }

    box.consumer?.consumeData("FOO".data(using: .utf8)!)
    let returned = expectation(description: "end-of-file returned")
    DispatchQueue.global().async {
      box.consumer?.consumeEndOfFile()
      returned.fulfill()
    }
    // Nothing signals that end-of-file is under way, so give it time to start waiting.
    Thread.sleep(forTimeInterval: 0.1)
    endOfFileStarted.signal()

    wait(for: [returned], timeout: ControlCoreGlobalConfiguration.fastTimeout)
    XCTAssertEqual("FOO".data(using: .utf8)!, actual.data)
    XCTAssertTrue(box.consumer?.finishedConsuming.hasHappened ?? false)
  }

  func testLineBufferConsumption() {
    let consumer = ConsumableBuffer()
    consumer.consumeData("FOO".data(using: .utf8)!)

    XCTAssertNil(consumer.consumeLineData())
    XCTAssertNil(consumer.consumeLineString())
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("BAR\n".data(using: .utf8)!)

    XCTAssertEqual(consumer.consumeLineString(), "FOOBAR")
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("BANG\nBAZ".data(using: .utf8)!)
    consumer.consumeData("\nHELLO\nHERE".data(using: .utf8)!)

    XCTAssertEqual(consumer.consumeCurrentString(), "BANG\nBAZ\nHELLO\nHERE")
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("GOODBYE".data(using: .utf8)!)
    consumer.consumeData("\nFOR\nNOW".data(using: .utf8)!)

    XCTAssertEqual(consumer.consumeCurrentData(), "GOODBYE\nFOR\nNOW".data(using: .utf8)!)
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("ILIED".data(using: .utf8)!)
    consumer.consumeData("$$SOZ\n".data(using: .utf8)!)

    XCTAssertEqual(consumer.consume(until: "$$".data(using: .utf8)!), "ILIED".data(using: .utf8)!)
    XCTAssertEqual(consumer.consumeLineString(), "SOZ")
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeData("BACKAGAIN".data(using: .utf8)!)
    consumer.consumeData("\nTHIS\nIS\nTHE\nTAIL".data(using: .utf8)!)

    XCTAssertEqual(consumer.consumeLineData(), "BACKAGAIN".data(using: .utf8)!)
    XCTAssertFalse(consumer.finishedConsuming.hasHappened)

    consumer.consumeEndOfFile()

    XCTAssertTrue(consumer.finishedConsuming.hasHappened)
    XCTAssertEqual(consumer.consumeLineString(), "THIS")
    XCTAssertEqual(consumer.consumeLineData(), "IS".data(using: .utf8)!)
    XCTAssertEqual(consumer.consumeLineString(), "THE")
    XCTAssertNil(consumer.consumeLineString())
    XCTAssertEqual(consumer.consumeCurrentString(), "TAIL")
  }

  func testCompositeWithCompletion() {
    let accumulating = ConsumableBuffer()
    let consumable = ConsumableBuffer()
    let composite = CompositeDataConsumer(consumers: [
      accumulating,
      consumable,
    ])

    composite.consumeData("FOO".data(using: .utf8)!)

    XCTAssertNil(consumable.consumeLineString())
    XCTAssertFalse(composite.finishedConsuming.hasHappened)

    composite.consumeData("BAR\n".data(using: .utf8)!)

    XCTAssertEqual(consumable.consumeLineString(), "FOOBAR")
    XCTAssertNil(consumable.consumeLineString())
    XCTAssertFalse(consumable.finishedConsuming.hasHappened)
    XCTAssertFalse(accumulating.finishedConsuming.hasHappened)
    XCTAssertFalse(composite.finishedConsuming.hasHappened)

    composite.consumeEndOfFile()
    XCTAssertTrue(consumable.finishedConsuming.hasHappened)
    XCTAssertTrue(accumulating.finishedConsuming.hasHappened)
    XCTAssertTrue(composite.finishedConsuming.hasHappened)
  }

  func testLengthBasedConsumption() {
    let consumer = ConsumableBuffer()

    consumer.consumeData("FOOBARRBAZZZ".data(using: .utf8)!)
    consumer.consumeEndOfFile()

    XCTAssertEqual(consumer.consumeLength(3), "FOO".data(using: .utf8)!)
    XCTAssertEqual(consumer.consumeLength(4), "BARR".data(using: .utf8)!)
    XCTAssertEqual(consumer.consumeLength(5), "BAZZZ".data(using: .utf8)!)
    XCTAssertNil(consumer.consumeLength(4))
    XCTAssertEqual(consumer.consumeCurrentData(), Data())
  }

  func testLoggingConsumerLogsEachChunkTrimmedOfNewlines() {
    let logger = RecordingLogger()
    let consumer = LoggingDataConsumer(logger: logger)

    consumer.consumeData("FOO\n".data(using: .utf8)!)
    consumer.consumeData("\nBAR BAZ\r\n".data(using: .utf8)!)
    consumer.consumeEndOfFile()

    XCTAssertEqual(logger.messages, ["FOO", "BAR BAZ"])
  }

  func testLoggingConsumerDropsEmptyAndNonUTF8Chunks() {
    let logger = RecordingLogger()
    let consumer = LoggingDataConsumer(logger: logger)

    consumer.consumeData("\n\n".data(using: .utf8)!)
    consumer.consumeData(Data([0xFF, 0xFE]))
    consumer.consumeData(Data())

    XCTAssertEqual(logger.messages, [])
  }
}

// SAFETY: the tests only log from the test thread.
private final class RecordingLogger: ControlCoreLogger, @unchecked Sendable {
  var messages: [String] = []
  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }

  func log(_ message: String) -> any ControlCoreLogger {
    messages.append(message)
    return self
  }
  func info() -> any ControlCoreLogger { self }
  func debug() -> any ControlCoreLogger { self }
  func error() -> any ControlCoreLogger { self }
  func withName(_ name: String) -> any ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger { self }
}

/// The bytes a consumer has delivered so far: appended on its queue, read by the test.
private final class DeliveredData: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: Data())

  var data: Data { storage.withLock { $0 } }

  func append(_ data: Data) {
    storage.withLock { $0.append(data) }
  }
}

private final class ConsumerBox<Consumer>: @unchecked Sendable {
  var consumer: Consumer?
}
