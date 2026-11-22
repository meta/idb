/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !os(tvOS)
import Darwin
import FBSimulatorBridgeProtocol
import Foundation
#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

private struct DeliveredNotification {
  let bundleID: String
  let identifier: String
  let title: String
  let subtitle: String
  let body: String
  let threadIdentifier: String
  let date: Double?

  var answer: BridgeDeliveredNotification {
    BridgeDeliveredNotification(
      bundleID: bundleID, identifier: identifier, title: title, subtitle: subtitle, body: body, threadIdentifier: threadIdentifier, date: date)
  }

  var jsonObject: [String: Any] {
    var object: [String: Any] = [
      "bundleID": bundleID,
      "identifier": identifier,
      "title": title,
      "subtitle": subtitle,
      "body": body,
      "threadIdentifier": threadIdentifier,
    ]
    if let date {
      object["date"] = date
    }
    return object
  }

  init(values: FBDeliveredNotificationValues, bundleID: String) {
    self.bundleID = bundleID
    identifier = values.identifier ?? ""
    title = values.title ?? ""
    subtitle = values.subtitle ?? ""
    body = values.body ?? ""
    threadIdentifier = values.threadIdentifier ?? ""
    date = values.date?.doubleValue
  }

  enum DecodeError: Error {
    case missingIdentifier
    case retypedField
  }

  init(fields: [String: Any], bundleID: String) throws {
    guard let identifier = fields["AppNotificationIdentifier"] as? String, identifier != "$null" else {
      throw DecodeError.missingIdentifier
    }
    func string(_ key: String) -> String? {
      guard let value = fields[key], !NotificationArchive.isNull(value) else { return "" }
      return value as? String
    }
    guard let title = string("AppNotificationTitle"),
      let subtitle = string("AppNotificationSubtitle"),
      let body = string("AppNotificationMessage"),
      let threadIdentifier = string("SBSPushStoreNotificationThreadKey")
    else {
      throw DecodeError.retypedField
    }
    var date: Double?
    if let value = fields["AppNotificationCreationDate"], !NotificationArchive.isNull(value) {
      guard let archivedDate = value as? [String: Any], let interval = archivedDate["NS.time"] as? NSNumber else {
        throw DecodeError.retypedField
      }
      date = Date(timeIntervalSinceReferenceDate: interval.doubleValue).timeIntervalSince1970
    }
    self.bundleID = bundleID
    self.identifier = identifier
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.threadIdentifier = threadIdentifier
    self.date = date
  }
}

private struct NotificationArchive {
  let objects: [Any]
  let rootIndex: Int

  enum ReadResult {
    case absent
    case invalid
    case archive(NotificationArchive)
  }

  struct DictionaryResult {
    let fields: [String: Any]
    let lossy: Bool
  }

  var root: Any? {
    objects.indices.contains(rootIndex) ? objects[rootIndex] : nil
  }

  static func isNull(_ value: Any?) -> Bool {
    value as? String == "$null"
  }

  func resolve(_ object: Any) -> Any? {
    guard let index = FBKeyedArchiveReference.index(of: object)?.intValue else { return object }
    return objects.indices.contains(index) ? objects[index] : nil
  }

  func dictionary(_ candidate: Any?) -> DictionaryResult? {
    guard let encoded = candidate as? [String: Any],
      let keys = encoded["NS.keys"] as? [Any],
      let values = encoded["NS.objects"] as? [Any]
    else {
      return nil
    }
    var fields: [String: Any] = [:]
    var lossy = keys.count != values.count
    for (keyReference, valueReference) in zip(keys, values) {
      guard let key = resolve(keyReference) as? String, let value = resolve(valueReference) else {
        lossy = true
        continue
      }
      fields[key] = value
    }
    return DictionaryResult(fields: fields, lossy: lossy)
  }

  static func read(_ path: String) -> ReadResult {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      let failure = error as NSError
      if isMissingFile(failure) {
        return .absent
      }
      NSLog("[DeliveredNotifications] %@ could not be read: %@", (path as NSString).lastPathComponent, failure)
      return .invalid
    }
    let plist: Any
    do {
      plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      NSLog("[DeliveredNotifications] %@ is not a property list: %@", (path as NSString).lastPathComponent, error as NSError)
      return .invalid
    }
    guard let dictionary = plist as? [String: Any] else {
      NSLog("[DeliveredNotifications] %@ is not a property list: (null)", (path as NSString).lastPathComponent)
      return .invalid
    }
    guard let objects = dictionary["$objects"] as? [Any],
      let top = dictionary["$top"] as? [String: Any],
      let rootIndex = FBKeyedArchiveReference.index(of: top["root"])?.intValue
    else {
      return .invalid
    }
    return .archive(NotificationArchive(objects: objects, rootIndex: rootIndex))
  }
}

private func isMissingFile(_ error: NSError) -> Bool {
  (error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError))
    || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
}

private enum DeliveredNotificationOutput {
  static func write(_ notification: DeliveredNotification, output: BridgeOutput?) -> Bool {
    if let output { return output.write(.deliveredNotification(notification.answer)) }
    let object = notification.jsonObject
    guard JSONSerialization.isValidJSONObject(object) else {
      NSLog("[DeliveredNotifications] Notification %@ holds a value JSON cannot represent, such as a non-finite date", notification.identifier)
      return false
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: object)
    } catch {
      NSLog("[DeliveredNotifications] Could not serialise notification %@: %@", notification.identifier, error as NSError)
      return false
    }
    let written = data.withUnsafeBytes { bytes in
      fwrite(bytes.baseAddress, 1, bytes.count, stdout)
    }
    guard written == data.count, fputc(10, stdout) != EOF else {
      NSLog("[DeliveredNotifications] Could not write notification %@ to stdout: %@", notification.identifier, String(cString: strerror(errno)))
      return false
    }
    return true
  }

  static func flush(output: BridgeOutput?) -> Int32 {
    if let output { return output.failed ? 1 : 0 }
    guard fflush(stdout) == 0 else {
      NSLog("[DeliveredNotifications] Could not flush stdout: %@", String(cString: strerror(errno)))
      return 1
    }
    return 0
  }
}

private struct DeliveredNotificationStore {
  let directory: String?

  private enum Location {
    case absent
    case unreadable
    case directory(String)
  }

  private func location(bundleID: String) -> Location {
    guard let directory else {
      NSLog("[DeliveredNotifications] No Library directory, so no notification store")
      return .unreadable
    }
    let path = (directory as NSString).appendingPathComponent("Library.plist")
    let archive: NotificationArchive
    switch NotificationArchive.read(path) {
    case .absent: return .absent
    case .invalid:
      NSLog("[DeliveredNotifications] %@ could not be read as a keyed archive", path)
      return .unreadable
    case .archive(let value): archive = value
    }
    if NotificationArchive.isNull(archive.root) {
      NSLog("[DeliveredNotifications] %@ names no store for any bundle", path)
      return .absent
    }
    guard let mapping = archive.dictionary(archive.root) else {
      NSLog("[DeliveredNotifications] %@ holds no archived mapping", path)
      return .unreadable
    }
    guard !mapping.lossy else {
      NSLog("[DeliveredNotifications] %@ did not reconstruct in full", path)
      return .unreadable
    }
    if let name = mapping.fields[bundleID] as? String {
      return .directory((directory as NSString).appendingPathComponent(name))
    }
    if mapping.fields[bundleID] != nil {
      NSLog("[DeliveredNotifications] Library.plist names a non-string store directory for %@", bundleID)
      return .unreadable
    }
    NSLog("[DeliveredNotifications] Library.plist names no store directory for %@", bundleID)
    return .absent
  }

  func printNotifications(bundleID: String, output: BridgeOutput?) -> Int32 {
    let directory: String
    switch location(bundleID: bundleID) {
    case .absent: return 0
    case .unreadable: return Int32(output?.failure("Could not locate the delivered notification store for \(bundleID)") ?? 1)
    case .directory(let value): directory = value
    }
    let path = (directory as NSString).appendingPathComponent("DeliveredNotifications.plist")
    let archive: NotificationArchive
    switch NotificationArchive.read(path) {
    case .absent: return 0
    case .invalid:
      NSLog("[DeliveredNotifications] %@ could not be read as a keyed archive", path)
      return Int32(output?.failure("Could not read a keyed archive from \(path)") ?? 1)
    case .archive(let value): archive = value
    }
    if NotificationArchive.isNull(archive.root) {
      return DeliveredNotificationOutput.flush(output: output)
    }
    guard let root = archive.root as? [String: Any] else {
      NSLog("[DeliveredNotifications] %@ holds no archived root dictionary", path)
      return Int32(output?.failure("No archived root dictionary in \(path)") ?? 1)
    }
    guard let references = root["NS.objects"] as? [Any] else {
      NSLog("[DeliveredNotifications] Archived root in %@ has no NS.objects array", path)
      return Int32(output?.failure("Archived root has no NS.objects array in \(path)") ?? 1)
    }
    var unreported = 0
    for reference in references {
      let record = archive.resolve(reference)
      let dictionary = archive.dictionary(record)
      guard let dictionary, !dictionary.fields.isEmpty else {
        if NotificationArchive.isNull(record) { continue }
        let recordType = record.map { NSStringFromClass(type(of: $0 as AnyObject)) } ?? "a reference to nothing"
        NSLog("[DeliveredNotifications] Could not decode a record in %@: %@", path, recordType)
        unreported += 1
        continue
      }
      guard !dictionary.lossy else {
        NSLog("[DeliveredNotifications] A record in %@ did not reconstruct in full", path)
        unreported += 1
        continue
      }
      do {
        let notification = try DeliveredNotification(fields: dictionary.fields, bundleID: bundleID)
        if !DeliveredNotificationOutput.write(notification, output: output) { unreported += 1 }
      } catch DeliveredNotification.DecodeError.missingIdentifier {
        NSLog("[DeliveredNotifications] A record in %@ carries no notification identifier", path)
        unreported += 1
      } catch {
        NSLog("[DeliveredNotifications] A record in %@ carries a field this reader does not recognise", path)
        unreported += 1
      }
    }
    guard unreported == 0 else {
      NSLog("[DeliveredNotifications] %lu of %lu records in %@ could not be reported; failing rather than returning a short list", unreported, references.count, path)
      return Int32(output?.failure("Could not report all delivered notification records from \(path)") ?? 1)
    }
    return DeliveredNotificationOutput.flush(output: output)
  }

  // A mapping that could not be read is a failure rather than nothing to clear: the store it would have
  // named may hold records, and answering 0 would report them as cleared.
  func clearNotifications(bundleID: String, output: BridgeOutput?) -> Int32 {
    let directory: String
    switch location(bundleID: bundleID) {
    case .absent: return 0
    case .unreadable: return Int32(output?.failure("Could not locate the delivered notification store for \(bundleID)") ?? 1)
    case .directory(let value): directory = value
    }
    let path = (directory as NSString).appendingPathComponent("DeliveredNotifications.plist")
    do {
      try FileManager.default.removeItem(atPath: path)
      return 0
    } catch {
      let failure = error as NSError
      if isMissingFile(failure) {
        return 0
      }
      NSLog("[DeliveredNotifications] %@ could not be removed: %@", path, failure)
      return Int32(output?.failure("Could not remove \(path)") ?? 1)
    }
  }
}

public enum DeliveredNotificationsService {
  /// Used whenever a caller passes a non-positive timeout.
  static let defaultTimeout: TimeInterval = 30

  private static func store(directory override: String?) -> DeliveredNotificationStore {
    let directory =
      override
      ?? NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first
      .map { ($0 as NSString).appendingPathComponent("UserNotifications") }
    return DeliveredNotificationStore(directory: directory)
  }

  public static func handleAction(_ action: String?, bundleID: String?, directory: String?, timeout: TimeInterval) -> Int32 {
    handleAction(action, bundleID: bundleID, directory: directory, timeout: timeout, output: nil)
  }

  static func handleAction(_ action: String?, bundleID: String?, directory: String?, timeout: TimeInterval, output: BridgeOutput?) -> Int32 {
    guard let bundleID, !bundleID.isEmpty else {
      NSLog("[DeliveredNotifications] bundleID required for %@", action ?? "(null)")
      return Int32(output?.failure("Delivered notifications require a bundle identifier") ?? 1)
    }
    if action == "clear-delivered" {
      return clear(client: FBDeliveredNotificationsRemovalClient.live(), bundleID: bundleID, directory: directory, timeout: timeout, output: output)
    }
    guard action == "delivered" else {
      NSLog("[DeliveredNotifications] Unknown action: %@. Use delivered or clear-delivered.", action ?? "(null)")
      return Int32(output?.failure("Unknown delivered notification action") ?? 1)
    }
    guard let client = FBDeliveredNotificationsClient.live(bundleID: bundleID) else {
      NSLog("[DeliveredNotifications] No center for %@; reading the store", bundleID)
      return store(directory: directory).printNotifications(bundleID: bundleID, output: output)
    }
    return handle(client: client, bundleID: bundleID, directory: directory, timeout: timeout, output: output)
  }

  public static func handleActionWithCenter(
    _ action: String?, bundleID: String?, center: Any?, directory: String?, timeout: TimeInterval, output: BridgeOutput? = nil
  ) -> Int32 {
    guard action == "delivered" else {
      NSLog("[DeliveredNotifications] Unknown action: %@. Use delivered.", action ?? "(null)")
      return 1
    }
    return handle(client: FBDeliveredNotificationsClient(center: center), bundleID: bundleID ?? "", directory: directory, timeout: timeout, output: output)
  }

  public static func clear(bundleID: String?, remover: Any?, directory: String?, timeout: TimeInterval) -> Int32 {
    clear(client: remover.map { FBDeliveredNotificationsRemovalClient(remover: $0) }, bundleID: bundleID ?? "", directory: directory, timeout: timeout, output: nil)
  }

  private static func clear(client: FBDeliveredNotificationsRemovalClient?, bundleID: String, directory: String?, timeout: TimeInterval, output: BridgeOutput?) -> Int32 {
    // Deleting the file leaves later reads agreeing that the app holds nothing, but the daemon still does,
    // so anything already on screen stays there. That is the outcome for a guest the daemon does not see
    // as the app, which is why it is logged rather than taken silently.
    func clearStoreInstead(_ reason: String) -> Int32 {
      NSLog("[DeliveredNotifications] %@ for %@; clearing the store instead, which withdraws nothing already on screen", reason, bundleID)
      return store(directory: directory).clearNotifications(bundleID: bundleID, output: output)
    }
    guard let client else {
      return clearStoreInstead("No connection to usernotificationsd")
    }
    let result = client.removeAll(bundleID: bundleID, timeout: timeout > 0 ? timeout : defaultTimeout)
    switch result.status {
    case .raised:
      return clearStoreInstead("removeAllDeliveredNotificationsForBundleIdentifier: raised \(result.exceptionDescription ?? "(null)")")
    case .timedOut:
      return clearStoreInstead("usernotificationsd did not answer the removal")
    case .refused:
      return clearStoreInstead("usernotificationsd refused the removal")
    // The daemon rewrites the store itself as it withdraws, so it is the daemon's to update.
    case .removed: return 0
    @unknown default: return Int32(output?.failure("Unknown delivered notification removal status") ?? 1)
    }
  }

  private static func handle(client: FBDeliveredNotificationsClient, bundleID: String, directory: String?, timeout: TimeInterval, output: BridgeOutput?) -> Int32 {
    let result = client.read(timeout: timeout > 0 ? timeout : defaultTimeout)
    switch result.status {
    case .raised:
      NSLog("[DeliveredNotifications] getDeliveredNotificationsWithCompletionHandler: raised for %@: %@; reading the store", bundleID, result.exceptionDescription ?? "(null)")
      return store(directory: directory).printNotifications(bundleID: bundleID, output: output)
    case .timedOut:
      NSLog("[DeliveredNotifications] Timed out reading notifications for %@; reading the store", bundleID)
      return store(directory: directory).printNotifications(bundleID: bundleID, output: output)
    case .received: break
    @unknown default: return Int32(output?.failure("Unknown delivered notification read status") ?? 1)
    }
    guard !result.notifications.isEmpty else {
      NSLog("[DeliveredNotifications] Center reported none for %@; reading the store", bundleID)
      return store(directory: directory).printNotifications(bundleID: bundleID, output: output)
    }
    var unreported = 0
    for values in result.notifications {
      if let error = values.readError {
        NSLog("[DeliveredNotifications] Could not read notification for %@: %@", bundleID, error)
        output?.failure("Could not read delivered notification: \(error)")
        unreported += 1
        continue
      }
      if !DeliveredNotificationOutput.write(DeliveredNotification(values: values, bundleID: bundleID), output: output) {
        unreported += 1
      }
    }
    guard unreported == 0 else {
      NSLog("[DeliveredNotifications] %lu of %lu notifications for %@ could not be reported; failing rather than returning a short list", unreported, result.notifications.count, bundleID)
      return 1
    }
    return DeliveredNotificationOutput.flush(output: output)
  }
}
#endif
