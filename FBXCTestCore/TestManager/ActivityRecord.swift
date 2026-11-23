/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// An XCTest activity, copied out of XCTest's own `XCActivityRecord`.
public final class ActivityRecord: CustomStringConvertible {

  public let title: String
  public let activityType: String
  public let uuid: UUID
  public let start: Date
  /// Equal to `start` for an activity that has not finished, consistent with its zero `duration`.
  public let finish: Date
  public let attachments: [Attachment]
  public let duration: Double
  public let name: String
  /// Starts empty; reporters nest records into it themselves.
  public var subactivities: [ActivityRecord] = []

  /// `XCActivityRecord` is read through KVC because the XCTest private headers are not importable from Swift.
  public init(_ record: NSObject) {
    let start = record.value(forKey: "start") as? Date ?? Date()
    self.title = record.value(forKey: "title") as? String ?? ""
    self.activityType = record.value(forKey: "activityType") as? String ?? ""
    self.uuid = record.value(forKey: "uuid") as? UUID ?? UUID()
    self.start = start
    self.finish = record.value(forKey: "finish") as? Date ?? start
    let attachments = record.value(forKey: "attachments") as? [NSObject] ?? []
    self.attachments = attachments.map(Attachment.init)
    self.duration = record.value(forKey: "duration") as? Double ?? 0
    self.name = record.value(forKey: "name") as? String ?? ""
  }

  public var description: String {
    unsafe String(format: "Title %@ | Duration %f | Start %@ | Finish %@ | Uuid %@", title, duration, start as NSDate, finish as NSDate, uuid as NSUUID)
  }
}

/// An attachment recorded by an XCTest activity, copied out of XCTest's own `XCTAttachment`.
public struct Attachment {

  public let payload: Data?
  public let timestamp: Date?
  public let name: String
  public let uniformTypeIdentifier: String
  public let userInfo: [String: Any]?

  /// `XCTAttachment` is read through KVC because the XCTest private headers are not importable from Swift.
  public init(_ attachment: NSObject) {
    let hasPayload = attachment.value(forKey: "hasPayload") as? Bool ?? false
    self.payload = hasPayload ? attachment.value(forKey: "payload") as? Data : nil
    self.timestamp = attachment.value(forKey: "timestamp") as? Date
    self.name = attachment.value(forKey: "name") as? String ?? ""
    self.uniformTypeIdentifier = attachment.value(forKey: "uniformTypeIdentifier") as? String ?? ""
    self.userInfo = attachment.value(forKey: "userInfo") as? [String: Any]
  }
}
