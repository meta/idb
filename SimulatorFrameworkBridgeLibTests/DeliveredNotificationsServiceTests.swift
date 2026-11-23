/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import UserNotifications
import XCTest

// The other half of the guest's `notifications` service. It has no test file of its own, and
// the two are reached through the same verb.
final class DeliveredNotificationsServiceTests: XCTestCase {
  private var notificationsDirectory = ""
  private var storeDirectory = ""
  private var timeout: TimeInterval = 0

  /// The mapping from bundle identifier to store directory, as BulletinBoard writes it.
  private var libraryPath: String {
    (notificationsDirectory as NSString).appendingPathComponent("Library.plist")
  }

  override func setUp() {
    super.setUp()
    // A directory of this suite's own. The simulator's own mapping and stores are shared by
    // every app on it, so writing them here would leave them changed for anything that ran
    // afterwards if this run did not reach its teardown.
    notificationsDirectory = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent(UUID().uuidString)
    storeDirectory = UUID().uuidString
    XCTAssertNoThrow(
      try FileManager.default.createDirectory(
        atPath: notificationsDirectory,
        withIntermediateDirectories: true
      )
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: notificationsDirectory)
    super.tearDown()
  }

  private func handleDeliveredNotificationsAction(_ action: String?, _ bundleID: String?) -> Int32 {
    DeliveredNotificationsService.handleAction(action, bundleID: bundleID, directory: notificationsDirectory, timeout: timeout)
  }

  private func handleDeliveredNotificationsActionWithCenter(_ action: String?, _ bundleID: String?, _ center: Any?) -> Int32 {
    DeliveredNotificationsService.handleActionWithCenter(
      action, bundleID: bundleID, center: center, directory: notificationsDirectory, timeout: timeout)
  }

  private func clearDeliveredNotificationsWithRemover(_ bundleID: String?, _ remover: Any?) -> Int32 {
    DeliveredNotificationsService.clear(bundleID: bundleID, remover: remover, directory: notificationsDirectory, timeout: timeout)
  }

  private func writeArchive(of root: Any, toPath path: String) {
    let data = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
    XCTAssertNotNil(data)
    XCTAssertNoThrow(try data?.write(to: URL(fileURLWithPath: path), options: .atomic))
  }

  /// Lays down the store in the form BulletinBoard writes it: a `Library.plist` mapping the
  /// bundle to its directory, and the records in that directory, both as keyed archives.
  private func writeStore(forBundleID bundleID: String, records: [Any]) {
    let directory = (notificationsDirectory as NSString).appendingPathComponent(storeDirectory)
    XCTAssertNoThrow(
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    )
    writeArchive(of: [bundleID: storeDirectory], toPath: libraryPath)
    writeArchive(
      of: records,
      toPath: (directory as NSString).appendingPathComponent("DeliveredNotifications.plist")
    )
  }

  func testNilActionIsRefusedWithoutOutputOrAskingTheCenter() {
    let center = FBFakeDeliveredNotificationsCenter()
    let output = FBStdoutWhileRunning {
      XCTAssertEqual(handleDeliveredNotificationsAction(nil, "com.example.test"), 1)
      XCTAssertEqual(handleDeliveredNotificationsAction("unknown", "com.example.test"), 1)
      XCTAssertEqual(handleDeliveredNotificationsActionWithCenter(nil, "com.example.test", center), 1)
    }
    XCTAssertEqual(output, "")
    XCTAssertFalse(center.wasAsked)
  }

  func testNonemptyCenterPreservesFieldsOrderAndDuplicatesWithoutReadingStore() throws {
    try "unreadable store".write(toFile: libraryPath, atomically: true, encoding: .utf8)
    let content = UNMutableNotificationContent()
    content.title = "Title"
    content.subtitle = "Subtitle"
    content.body = "Body"
    content.threadIdentifier = "thread"
    let request = UNNotificationRequest(identifier: "duplicate", content: content, trigger: nil)
    let first = DeliveredNotificationFixture(request: request, date: Date(timeIntervalSince1970: 1_700_000_000))
    let second = FBFakeDeliveredNotification()
    second.identifier = "duplicate"
    let center = FBFakeDeliveredNotificationsCenter()
    center.notifications = [first, second]
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", "com.example.test", center)
    }

    XCTAssertEqual(result, 0)
    XCTAssertTrue(center.wasAsked)
    let lines = output.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2)
    guard lines.count == 2 else { return }
    let firstObject = try XCTUnwrap(FBParsedJSONLine(lines[0]))
    XCTAssertEqual(
      firstObject as NSDictionary,
      [
        "bundleID": "com.example.test", "identifier": "duplicate", "title": "Title",
        "subtitle": "Subtitle", "body": "Body", "threadIdentifier": "thread", "date": 1_700_000_000,
      ] as NSDictionary)
    let secondObject = try XCTUnwrap(FBParsedJSONLine(lines[1]))
    XCTAssertEqual(
      secondObject as NSDictionary,
      [
        "bundleID": "com.example.test", "identifier": "duplicate", "title": "",
        "subtitle": "", "body": "", "threadIdentifier": "",
      ] as NSDictionary)
  }

  func testRecordExceptionPreservesOtherRecordsWithoutFallingBackToStore() {
    let bundleID = "com.example.test.recordexception"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "fallback"]])
    let first = FBFakeDeliveredNotification()
    first.identifier = "first"
    let last = FBFakeDeliveredNotification()
    last.identifier = "last"
    let center = FBFakeDeliveredNotificationsCenter()
    center.notifications = [first, FBRaisingDeliveredNotification(), last]
    var result: Int32 = -1
    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }
    XCTAssertEqual(result, 1)
    XCTAssertTrue(center.wasAsked)
    XCTAssertEqual(output.split(separator: "\n").compactMap { FBParsedJSONLine(String($0))?["identifier"] as? String }, ["first", "last"])
  }

  func testNilCenterFallsBackToStoreAfterTimeout() {
    let bundleID = "com.example.test.nilcenter"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "stored"]])
    timeout = 0.001
    var result: Int32 = -1
    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, nil)
    }
    XCTAssertEqual(result, 0)
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "stored")
  }

  func testMalformedRecordDoesNotPreventReportingLaterRecords() {
    let bundleID = "com.example.test.continue"
    writeStore(forBundleID: bundleID, records: ["malformed", ["AppNotificationIdentifier": "later"]])
    var result: Int32 = -1
    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, FBFakeDeliveredNotificationsCenter())
    }
    XCTAssertEqual(result, 1)
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "later")
  }

  func testMalformedArchiveStructureFailsWithoutOutput() throws {
    let malformed: [[String: Any]] = [
      [:],
      ["$objects": "not an array", "$top": [:]],
      ["$objects": [], "$top": "not a dictionary"],
      ["$objects": [], "$top": ["root": 0]],
    ]
    for plist in malformed {
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
      try data.write(to: URL(fileURLWithPath: libraryPath))
      var result: Int32 = -1
      let output = FBStdoutWhileRunning {
        result = handleDeliveredNotificationsActionWithCenter("delivered", "com.example.test", FBFakeDeliveredNotificationsCenter())
      }
      XCTAssertEqual(result, 1, "\(plist)")
      XCTAssertEqual(output, "")
    }
  }

  func testAnUnknownActionIsRefusedWithoutAskingTheCenter() {
    let center = FBFakeDeliveredNotificationsCenter()

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter("unknown", "com.example.test", center),
      1
    )
    XCTAssertFalse(center.wasAsked)
  }

  func testACenterWithNothingDeliveredAndNoStoreSucceeds() {
    let center = FBFakeDeliveredNotificationsCenter()

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter("delivered", "com.example.test.nostore", center),
      0
    )
    XCTAssertTrue(center.wasAsked)
  }

  func testTheStoreIsReadWhenTheCenterReportsNothing() {
    // Also the one exercise of the keyed-archive reader, which resolves the archive's
    // cross-references through the private CoreFoundation accessors.
    let bundleID = "com.example.test.store"
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let record: [String: Any] = [
      "AppNotificationIdentifier": "identifier-1",
      "AppNotificationTitle": "Title",
      "AppNotificationSubtitle": "Subtitle",
      "AppNotificationMessage": "Body",
      "SBSPushStoreNotificationThreadKey": "thread-1",
      "AppNotificationCreationDate": created,
    ]
    writeStore(forBundleID: bundleID, records: [record])
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 0)
    let printed = FBParsedJSONLine(output)
    XCTAssertEqual(printed?["bundleID"] as? String, bundleID)
    XCTAssertEqual(printed?["identifier"] as? String, "identifier-1")
    XCTAssertEqual(printed?["title"] as? String, "Title")
    XCTAssertEqual(printed?["subtitle"] as? String, "Subtitle")
    XCTAssertEqual(printed?["body"] as? String, "Body")
    XCTAssertEqual(printed?["threadIdentifier"] as? String, "thread-1")
    XCTAssertEqual(printed?["date"] as? Double ?? 0, created.timeIntervalSince1970, accuracy: 0.001)
    // Exactly the keys the client's model reads. A key beyond them is one no reader would be
    // looking at, so the two paths that print these records could come to disagree on it
    // without anything noticing.
    XCTAssertEqual(
      Set(printed?.keys.map { $0 } ?? []),
      ["bundleID", "identifier", "title", "subtitle", "body", "threadIdentifier", "date"]
    )
  }

  /// The path a cleared store is read back through, so a clear is checked by what a later
  /// `delivered` reports rather than by the file it deleted.
  private func deliveredCount(forBundleID bundleID: String) -> Int {
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1
    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }
    XCTAssertEqual(result, 0)
    return output.split(separator: "\n").filter { !$0.isEmpty }.count
  }

  private func storePath(forDirectory directory: String) -> String {
    ((notificationsDirectory as NSString).appendingPathComponent(directory) as NSString)
      .appendingPathComponent("DeliveredNotifications.plist")
  }

  func testClearDeliveredAsksTheDaemonToWithdrawTheAppsNotifications() {
    let bundleID = "com.example.test.clear"
    let remover = FBFakeDeliveredNotificationsRemover()
    remover.succeeds = true

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, remover), 0)

    XCTAssertEqual(remover.removedBundleIDs, [bundleID])
  }

  func testClearDeliveredLeavesTheStoreToTheDaemonWhenItWithdraws() {
    let bundleID = "com.example.test.clear.withdrawn"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])
    let remover = FBFakeDeliveredNotificationsRemover()
    remover.succeeds = true

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, remover), 0)

    // The daemon rewrites the store as it withdraws; this fake does not, so what is left is
    // what the guest itself touched.
    XCTAssertTrue(FileManager.default.fileExists(atPath: storePath(forDirectory: storeDirectory)))
  }

  func testClearDeliveredClearsTheStoreWhenTheDaemonRefuses() {
    let bundleID = "com.example.test.clear.refused"
    writeStore(
      forBundleID: bundleID,
      records: [["AppNotificationIdentifier": "identifier-1"], ["AppNotificationIdentifier": "identifier-2"]]
    )
    XCTAssertEqual(deliveredCount(forBundleID: bundleID), 2)
    let remover = FBFakeDeliveredNotificationsRemover()

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, remover), 0)

    XCTAssertEqual(remover.removedBundleIDs, [bundleID])
    XCTAssertEqual(deliveredCount(forBundleID: bundleID), 0)
  }

  func testClearDeliveredClearsTheStoreWhenTheDaemonDoesNotAnswer() {
    let bundleID = "com.example.test.clear.silent"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])
    timeout = 0.1

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, FBSilentDeliveredNotificationsRemover()), 0)

    XCTAssertEqual(deliveredCount(forBundleID: bundleID), 0)
  }

  func testClearDeliveredClearsTheStoreWhenTheRemovalRaises() {
    let bundleID = "com.example.test.clear.raising"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, FBRaisingDeliveredNotificationsRemover()), 0)

    XCTAssertEqual(deliveredCount(forBundleID: bundleID), 0)
  }

  func testClearDeliveredClearsTheStoreWithNoConnectionToTheDaemon() {
    let bundleID = "com.example.test.clear.disconnected"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])

    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, nil), 0)

    XCTAssertEqual(deliveredCount(forBundleID: bundleID), 0)
  }

  func testClearingTheStoreSucceedsWhenTheStoreFileIsAlreadyGone() {
    let bundleID = "com.example.test.clear.twice"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])
    let remover = FBFakeDeliveredNotificationsRemover()
    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, remover), 0)

    // The mapping still names the directory, so this reaches the removal and finds nothing
    // there. Removing a path with nothing at it reports a different code to reading one, and
    // taking only the read's code left a second clear reporting failure.
    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, remover), 0)
  }

  func testClearingTheStoreSucceedsWhenNothingWasEverDelivered() {
    // A bundle the mapping never named has nothing to clear, which is not a failure.
    XCTAssertEqual(
      clearDeliveredNotificationsWithRemover("com.example.test.clear.absent", FBFakeDeliveredNotificationsRemover()),
      0
    )
  }

  func testClearingTheStoreDoesNotReportSuccessWhenTheMappingCannotBeRead() {
    let bundleID = "com.example.test.clear.unreadable"
    XCTAssertNoThrow(
      try Data("not a property list".utf8).write(to: URL(fileURLWithPath: libraryPath))
    )

    // The store this would have named may hold records, so reporting them cleared is the
    // silent wrong answer the read path refuses for the same reason.
    XCTAssertEqual(clearDeliveredNotificationsWithRemover(bundleID, FBFakeDeliveredNotificationsRemover()), 1)
  }

  func testARecordThatWillNotDecodeFailsRatherThanShorteningTheList() {
    // Reporting only the records that did decode is a wrong answer that looks like a right one:
    // a test asserting an app received three notifications fails, and the reason it failed is
    // nowhere in the output. Both shapes of undecodable record are here - something in the array
    // that is not an archived dictionary at all, and one that is but carries no fields.
    let bundleID = "com.example.test.undecodable"
    let records: [Any] = [
      ["AppNotificationIdentifier": "identifier-good"],
      "not an archived record",
      [String: Any](),
    ]
    writeStore(forBundleID: bundleID, records: records)
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 1)
    // What did decode is still printed, so the failure reports an incomplete answer rather than
    // discarding the part of it that was readable.
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "identifier-good")
  }

  func testARecordCarryingNoNotificationIdentifierFailsRatherThanPrintingABlankOne() {
    // Every delivered record carries an identifier, so a record that decodes without one is
    // carrying keys this reader does not recognise -- what a rename of the private
    // BulletinBoard keys would look like. Substituting empty strings would print a blank
    // notification and answer 0, which reads as an app having received something empty
    // rather than as this reader no longer understanding the format.
    let bundleID = "com.example.test.unrecognised"
    writeStore(forBundleID: bundleID, records: [["SomeRenamedKey": "value"]])
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 1)
    XCTAssertEqual(output, "")
  }

  func testARecordThatDidNotReconstructInFullFailsRatherThanPrintingWhatSurvived() {
    // A key that does not resolve to a string is dropped from the rebuilt dictionary, so the
    // record arrives missing fields with nothing to say so. Printing it would report a
    // notification whose body or thread key merely failed to reconstruct as one that never
    // had them.
    let bundleID = "com.example.test.lossy"
    let record: [AnyHashable: Any] = [
      "AppNotificationIdentifier": "identifier-1",
      1: "a key that is not a string",
    ]
    writeStore(forBundleID: bundleID, records: [record])
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 1)
    XCTAssertEqual(output, "")
  }

  func testARecordWhoseFieldIsNotAStringFailsRatherThanPrintingItBlank() {
    // A field that is present but not a string is drift in the record format -- a runtime
    // archiving the title as an attributed string, say. Answering `""` for it would report
    // every notification as having no title and still succeed.
    let bundleID = "com.example.test.retyped"
    let record: [String: Any] = [
      "AppNotificationIdentifier": "identifier-1",
      "AppNotificationTitle": 42,
    ]
    writeStore(forBundleID: bundleID, records: [record])
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 1)
    XCTAssertEqual(output, "")
  }

  func testARecordWhoseDateIsNotArchivedAsADateFailsRatherThanDroppingIt() {
    // The date is carried, just not in the shape this reader knows. Dropping the key would
    // report a notification that has a date as one that does not, which is the same silent
    // wrong answer in the one field a caller orders by.
    let bundleID = "com.example.test.baddate"
    let record: [String: Any] = [
      "AppNotificationIdentifier": "identifier-1",
      "AppNotificationCreationDate": "not a date",
    ]
    writeStore(forBundleID: bundleID, records: [record])
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 1)
    XCTAssertEqual(output, "")
  }

  func testAStoreThatHasNeverHeldANotificationReportsNothingDelivered() {
    // The bytes a real simulator writes for an app that has been delivered nothing: a
    // well-formed keyed archive whose root reference resolves to the placeholder for
    // nothing, rather than an absent file or an empty dictionary. Every app on a fresh
    // simulator is in that state, so reading it as a root this reader does not understand
    // would fail the common case. Taken verbatim from a booted iOS 26.3 simulator, because
    // `NSKeyedArchiver` does not produce this shape from any root object a test can hand it.
    let pristineStore = """
      YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05T      S2V5ZWRBcmNoaXZlctEICVRyb290gAChC1UkbnVsbAgRGiQpMjdJTFFTVQAAAAAAAAEBAAAAAAAAAAwA      AAAAAAAAAAAAAAAAAABb
      """.replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: " ", with: "")
    let bundleID = "com.example.test.pristine"
    let directory = (notificationsDirectory as NSString).appendingPathComponent(storeDirectory)
    XCTAssertNoThrow(
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    )
    writeArchive(of: [bundleID: storeDirectory], toPath: libraryPath)
    let storePath = (directory as NSString).appendingPathComponent("DeliveredNotifications.plist")
    let data = Data(base64Encoded: pristineStore)
    XCTAssertNotNil(data)
    XCTAssertNoThrow(try data?.write(to: URL(fileURLWithPath: storePath), options: .atomic))
    let center = FBFakeDeliveredNotificationsCenter()
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)
    }

    XCTAssertEqual(result, 0)
    XCTAssertEqual(output, "")
  }

  func testAMappingThatNamesNoStoreAtAllReportsNothingDelivered() {
    // `Library.plist` takes the same empty shape as a per-app store: a well-formed archive
    // whose root is the placeholder for nothing. A mapping that names no store for any
    // bundle is readable and simply silent about this one, so it means nothing was
    // delivered -- not that the mapping could not be read.
    let emptyArchive = """
      YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05T\
      S2V5ZWRBcmNoaXZlctEICVRyb290gAChC1UkbnVsbAgRGiQpMjdJTFFTVQAAAAAAAAEBAAAAAAAAAAwA\
      AAAAAAAAAAAAAAAAAABb
      """.replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: " ", with: "")
    let data = Data(base64Encoded: emptyArchive)
    XCTAssertNotNil(data)
    XCTAssertNoThrow(try data?.write(to: URL(fileURLWithPath: libraryPath), options: .atomic))
    let center = FBFakeDeliveredNotificationsCenter()

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter("delivered", "com.example.test.nomapping", center),
      0
    )
  }

  func testAFailedWriteToStdoutFailsRatherThanReportingAShortList() {
    // The guest runs under `simctl spawn`, so stdout is a block-buffered pipe: bytes that
    // serialised can still fail to reach the caller, and the implicit flush at exit happens
    // where nothing can change the status any more. Pointing stdout at a descriptor that
    // cannot be written is what makes that failure reachable from a test.
    let bundleID = "com.example.test.unwritable"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-1"]])
    let center = FBFakeDeliveredNotificationsCenter()

    fflush(stdout)
    let original = dup(STDOUT_FILENO)
    let readOnly = open("/dev/null", O_RDONLY)
    XCTAssertGreaterThanOrEqual(original, 0)
    XCTAssertGreaterThanOrEqual(readOnly, 0)
    dup2(readOnly, STDOUT_FILENO)

    let result = handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center)

    dup2(original, STDOUT_FILENO)
    close(original)
    close(readOnly)
    // Drop anything the failed write left buffered and clear stdio's error flag: this is the
    // process's own stdout, and bytes left behind would surface in a later test's capture.
    fpurge(stdout)
    clearerr(stdout)

    XCTAssertEqual(result, 1)
  }

  func testAMappingThatDidNotReconstructInFullIsNotReportedAsNothingDelivered() {
    // The same loss in `Library.plist`: the entry that was dropped may be the one naming this
    // bundle's store, so reading the bundle's absence from the rebuilt mapping as "nothing was
    // ever delivered" would be a guess.
    let bundleID = "com.example.test.lossymapping"
    let mapping: [AnyHashable: Any] = [
      "com.example.test.other": "SomeOtherDirectory",
      1: "a key that is not a string",
    ]
    writeArchive(of: mapping, toPath: libraryPath)
    let center = FBFakeDeliveredNotificationsCenter()

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter("delivered", bundleID, center),
      1
    )
  }

  func testARecordThatWillNotSerialiseFailsRatherThanShorteningTheList() {
    // A record can decode and still not be printable: the date is whatever the device supplied,
    // and no JSON number holds a non-finite one, so serialisation refuses the whole record. That
    // is the same short list the undecodable case above refuses to return, and both paths that
    // print records reach it separately, so both are asserted here.
    let unrepresentable = Date(timeIntervalSince1970: .infinity)

    let reportable = FBFakeDeliveredNotification()
    reportable.identifier = "identifier-from-the-center"
    let unserialisable = FBFakeDeliveredNotification()
    unserialisable.identifier = "identifier-unserialisable"
    unserialisable.date = unrepresentable
    let center = FBFakeDeliveredNotificationsCenter()
    center.notifications = [reportable, unserialisable]
    var centerResult: Int32 = -1

    let centerOutput = FBStdoutWhileRunning {
      centerResult = handleDeliveredNotificationsActionWithCenter(
        "delivered",
        "com.example.test.center.unserialisable",
        center
      )
    }

    XCTAssertEqual(centerResult, 1, "the center path reported a short list as a complete one")
    XCTAssertEqual(
      FBParsedJSONLine(centerOutput)?["identifier"] as? String,
      "identifier-from-the-center"
    )

    let bundleID = "com.example.test.store.unserialisable"
    writeStore(
      forBundleID: bundleID,
      records: [
        ["AppNotificationIdentifier": "identifier-from-the-store"],
        [
          "AppNotificationIdentifier": "identifier-unserialisable",
          "AppNotificationCreationDate": unrepresentable,
        ],
      ]
    )
    var storeResult: Int32 = -1

    let storeOutput = FBStdoutWhileRunning {
      storeResult = handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBFakeDeliveredNotificationsCenter()
      )
    }

    XCTAssertEqual(storeResult, 1, "the store path reported a short list as a complete one")
    XCTAssertEqual(
      FBParsedJSONLine(storeOutput)?["identifier"] as? String,
      "identifier-from-the-store"
    )
  }

  func testAStoreThatCannotBeReadFailsRatherThanReportingNothingDelivered() {
    // What unresolved CF UID accessors look like from here: every archive reads as invalid.
    // Answering 0 would report each bundle as having received nothing for as long as that
    // held, so a test asserting a push arrived would fail for the wrong reason.
    XCTAssertNoThrow(
      try "not a keyed archive".write(toFile: libraryPath, atomically: true, encoding: .utf8)
    )
    let center = FBFakeDeliveredNotificationsCenter()

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter(
        "delivered",
        "com.example.test.unreadable",
        center
      ),
      1
    )
    XCTAssertTrue(center.wasAsked)
  }

  func testAStoreThatCannotBeOpenedIsNotReportedAsNothingDelivered() {
    // Distinct from the case above, where the mapping itself would not parse. Here the mapping
    // reads and names a store that is there; only opening it fails, which the read reports the
    // same way as a path with nothing at it. Treating every failed read as absent would answer
    // 0 for an app whose notifications this process could not read at all.
    let bundleID = "com.example.test.store.unopenable"
    let directory = (notificationsDirectory as NSString).appendingPathComponent(storeDirectory)
    XCTAssertNoThrow(
      try FileManager.default.createDirectory(
        atPath: (directory as NSString).appendingPathComponent("DeliveredNotifications.plist"),
        withIntermediateDirectories: true
      )
    )
    writeArchive(of: [bundleID: storeDirectory], toPath: libraryPath)

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBFakeDeliveredNotificationsCenter()
      ),
      1
    )
  }

  func testACenterThatRaisesReadsTheStoreRatherThanEndingTheGuest() {
    // `main` has no top-level handler, so an uncaught raise takes the process down and the
    // store fallback that exists for this exact runtime is never reached.
    let bundleID = "com.example.test.raising"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-raise"]])
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBRaisingDeliveredNotificationsCenter()
      )
    }

    XCTAssertEqual(result, 0)
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "identifier-raise")
  }

  func testACenterAnsweringFromAnotherQueueIsRead() {
    // What the handler fills belongs to the handler, not to the frame that waits for it, so
    // that a handler still running after a timeout has given up writes into something nobody
    // reads rather than into a caller that has returned.
    let bundleID = "com.example.test.async"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-async"]])
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBAsynchronousDeliveredNotificationsCenter()
      )
    }

    XCTAssertEqual(result, 0)
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "identifier-async")
  }

  func testACenterThatNeverAnswersReadsTheStore() {
    // The store holds the same records, so a center that has not come back is the degraded case
    // the others here already answer from disk for rather than failing on.
    let bundleID = "com.example.test.silent"
    writeStore(forBundleID: bundleID, records: [["AppNotificationIdentifier": "identifier-silent"]])
    timeout = 0.05
    var result: Int32 = -1

    let output = FBStdoutWhileRunning {
      result = handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBSilentDeliveredNotificationsCenter()
      )
    }

    XCTAssertEqual(result, 0)
    XCTAssertEqual(FBParsedJSONLine(output)?["identifier"] as? String, "identifier-silent")
  }

  func testAnEmptyBundleIDIsRefusedRatherThanReadAsNothingDelivered() {
    // An unset bundle identifier reaches the service as the empty string rather than as nil, and
    // the mapping names no store for it - which the store read cannot tell from an app that
    // received nothing. Answering 0 would report a malformed request as an empty inbox. The
    // entry point rather than the center-taking half, because that is where the guard has to be
    // to keep a malformed request away from the private initialiser.
    XCTAssertEqual(handleDeliveredNotificationsAction("delivered", ""), 1)
    XCTAssertEqual(handleDeliveredNotificationsAction("delivered", nil), 1)
    // A clear of nothing would be reported as a clear that succeeded.
    XCTAssertEqual(handleDeliveredNotificationsAction("clear-delivered", ""), 1)
  }

  func testAMappingThatNamesThisBundleWithANonStringIsNotReportedAsNothingDelivered() {
    // Present but malformed is corruption, not silence: the mapping does name this bundle, so
    // answering "nothing delivered" would be a guess about a store that could not be located.
    let bundleID = "com.example.test.malformed"
    writeArchive(of: [bundleID: 42], toPath: libraryPath)

    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter(
        "delivered",
        bundleID,
        FBFakeDeliveredNotificationsCenter()
      ),
      1
    )
  }

  func testAMappingWithNothingAtItReportsNothingDeliveredRatherThanFailing() {
    // The other side of the same classification: a simulator nothing has ever been delivered
    // on has no mapping at all, and that is an answer rather than a failure. `setUp` leaves the
    // directory empty, so this is that shape.
    XCTAssertEqual(
      handleDeliveredNotificationsActionWithCenter(
        "delivered",
        "com.example.test.never",
        FBFakeDeliveredNotificationsCenter()
      ),
      0
    )
  }
}

final class DeliveredNotificationFixture: NSObject {
  @objc let request: UNNotificationRequest
  @objc let date: Date?

  init(request: UNNotificationRequest, date: Date?) {
    self.request = request
    self.date = date
    super.init()
  }
}
