/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public enum SpringboardIconEntryType: Sendable {
  case app
  case folder
  case widget
  case appLibrary
}

/// A property-list value from the SpringBoard icon-state wire format.
enum SpringboardPropertyListValue: Encodable, Sendable {
  case string(String)
  case bool(Bool)
  case integer(Int)
  case double(Double)
  case data(Data)
  case date(Date)
  case array([SpringboardPropertyListValue])
  case dictionary([String: SpringboardPropertyListValue])

  init(rawValue: Any) throws {
    if let value = rawValue as? String {
      self = .string(value)
    } else if let value = rawValue as? Bool {
      self = .bool(value)
    } else if let value = rawValue as? Int {
      self = .integer(value)
    } else if let value = rawValue as? Double {
      self = .double(value)
    } else if let value = rawValue as? Data {
      self = .data(value)
    } else if let value = rawValue as? Date {
      self = .date(value)
    } else if let value = rawValue as? NSNumber {
      self = value.isFloatingPointNumber ? .double(value.doubleValue) : .integer(value.intValue)
    } else if let value = rawValue as? [Any] {
      self = .array(try value.map { try SpringboardPropertyListValue(rawValue: $0) })
    } else if let value = rawValue as? NSArray {
      self = .array(try value.map { try SpringboardPropertyListValue(rawValue: $0) })
    } else if let value = rawValue as? [String: Any] {
      self = .dictionary(try SpringboardPropertyListValue.dictionary(from: value))
    } else if let value = rawValue as? NSDictionary {
      self = .dictionary(try SpringboardPropertyListValue.dictionary(from: value))
    } else {
      throw SpringboardServicesError.unexpectedResponse(
        command: "getIconState",
        expected: "a property-list value",
        actual: String(describing: rawValue))
    }
  }

  var rawValue: Any {
    switch self {
    case .string(let value):
      return value
    case .bool(let value):
      return value
    case .integer(let value):
      return value
    case .double(let value):
      return value
    case .data(let value):
      return value
    case .date(let value):
      return value
    case .array(let value):
      return value.map { $0.rawValue }
    case .dictionary(let value):
      return value.mapValues { $0.rawValue }
    }
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .bool(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .integer(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .double(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .data(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .date(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .array(let value):
      var container = encoder.unkeyedContainer()
      for element in value {
        try container.encode(element)
      }
    case .dictionary(let value):
      var container = encoder.container(keyedBy: SpringboardPropertyListCodingKey.self)
      for (key, element) in value {
        try container.encode(element, forKey: SpringboardPropertyListCodingKey(stringValue: key))
      }
    }
  }

  static func dictionary(from dict: [String: Any]) throws -> [String: SpringboardPropertyListValue] {
    var result: [String: SpringboardPropertyListValue] = [:]
    for (key, value) in dict {
      result[key] = try SpringboardPropertyListValue(rawValue: value)
    }
    return result
  }

  static func dictionary(from dict: NSDictionary) throws -> [String: SpringboardPropertyListValue] {
    var result: [String: SpringboardPropertyListValue] = [:]
    for (key, value) in dict {
      guard let key = key as? String else {
        throw SpringboardServicesError.unexpectedResponse(
          command: "getIconState",
          expected: "a property-list dictionary keyed by strings",
          actual: String(describing: dict))
      }
      result[key] = try SpringboardPropertyListValue(rawValue: value)
    }
    return result
  }
}

private struct SpringboardPropertyListCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

private extension NSNumber {

  var isFloatingPointNumber: Bool {
    CFNumberIsFloatType(self)
  }
}

private extension Dictionary where Key == String, Value == SpringboardPropertyListValue {

  var rawValue: [String: Any] {
    mapValues { $0.rawValue }
  }
}

// MARK: - SpringboardIcon

/// A single entry in the SpringBoard icon-state wire format.
///
/// The raw dictionary is preserved so callers can round-trip entries with
/// fields that `FBDeviceControl` does not interpret.
public struct SpringboardIcon: Encodable, Sendable {
  public let bundleID: String
  public let displayIdentifier: String
  public let displayName: String
  public let entryType: SpringboardIconEntryType
  public let gridSize: String?
  public let folderIcons: [[SpringboardIcon]]

  private let propertyList: [String: SpringboardPropertyListValue]

  public var rawDict: [String: Any] {
    propertyList.rawValue
  }

  public var folderIconCount: Int {
    folderIcons.reduce(0) { $0 + $1.count }
  }

  public init(dict: [String: Any]) {
    guard let propertyList = try? SpringboardPropertyListValue.dictionary(from: dict) else {
      preconditionFailure("SpringBoard icon dictionaries must contain property-list values")
    }
    self.init(propertyList: propertyList)
  }

  private init(propertyList: [String: SpringboardPropertyListValue]) {
    self.propertyList = propertyList
    let dict = propertyList.rawValue

    if let listType = dict["listType"] as? String, listType == "folder" {
      self.entryType = .folder
      self.bundleID = ""
      self.displayIdentifier = ""
      self.displayName = (dict["displayName"] as? String) ?? "Folder"
      self.gridSize = nil
      if let iconLists = dict["iconLists"] as? [[[String: Any]]] {
        self.folderIcons = iconLists.compactMap { page in
          let icons = SpringboardIcon.parseIconDicts(page)
          return icons.isEmpty ? nil : icons
        }
      } else {
        self.folderIcons = []
      }
    } else if let elementType = dict["elementType"] as? String, elementType == "appPredictions" {
      self.entryType = .widget
      self.bundleID = ""
      self.displayIdentifier = (dict["displayIdentifier"] as? String) ?? ""
      self.displayName = "[Siri Suggestions]"
      self.gridSize = dict["gridSize"] as? String
      self.folderIcons = []
    } else if let bundleID = dict["bundleIdentifier"] as? String, !bundleID.isEmpty {
      self.entryType = .app
      self.bundleID = bundleID
      self.displayIdentifier = (dict["displayIdentifier"] as? String) ?? ""
      self.gridSize = nil
      if let name = dict["displayName"] as? String, !name.isEmpty {
        self.displayName = name
      } else {
        self.displayName = bundleID.components(separatedBy: ".").last ?? bundleID
      }
      self.folderIcons = []
    } else if let displayIdentifier = dict["displayIdentifier"] as? String, !displayIdentifier.isEmpty {
      self.entryType = .appLibrary
      self.bundleID = displayIdentifier
      self.displayIdentifier = displayIdentifier
      self.gridSize = nil
      if let name = dict["displayName"] as? String, !name.isEmpty {
        self.displayName = name
      } else {
        self.displayName = displayIdentifier.components(separatedBy: ".").last ?? displayIdentifier
      }
      self.folderIcons = []
    } else {
      self.entryType = .app
      self.bundleID = ""
      self.displayIdentifier = ""
      self.displayName = ""
      self.gridSize = nil
      self.folderIcons = []
    }
  }

  public func encode(to encoder: any Encoder) throws {
    try SpringboardPropertyListValue.dictionary(propertyList).encode(to: encoder)
  }

  public var isValid: Bool {
    switch entryType {
    case .app, .appLibrary:
      return !bundleID.isEmpty
    case .folder, .widget:
      return true
    }
  }

  public static func parseIconDicts(_ dicts: [[String: Any]]) -> [SpringboardIcon] {
    dicts.map { SpringboardIcon(dict: $0) }.filter { $0.isValid }
  }

  public func toDict() -> [String: Any] {
    guard entryType == .folder else { return rawDict }
    var dict = propertyList
    dict["displayName"] = .string(displayName)
    dict["iconLists"] = .array(
      folderIcons.map { page in
        .array(page.map { .dictionary($0.propertyList) })
      })
    return dict.rawValue
  }

  public static func folder(name: String, icons: [[SpringboardIcon]]) -> SpringboardIcon {
    SpringboardIcon(
      propertyList: [
        "listType": .string("folder"),
        "displayName": .string(name),
        "iconLists": .array(
          icons.map { page in
            .array(page.map { .dictionary($0.propertyList) })
          }),
      ])
  }

  public static func app(bundleID: String, name: String) -> SpringboardIcon {
    SpringboardIcon(
      propertyList: [
        "bundleIdentifier": .string(bundleID),
        "displayIdentifier": .string(bundleID),
        "displayName": .string(name),
      ])
  }
}

// MARK: - SpringboardIcon Folder Editing

extension SpringboardIcon {

  public func findInFolder(identifier: String) -> (pageIndex: Int, iconIndex: Int)? {
    precondition(entryType == .folder)
    for (pageIndex, page) in folderIcons.enumerated() {
      for (iconIndex, icon) in page.enumerated() {
        if icon.bundleID == identifier || icon.displayIdentifier == identifier || icon.displayName == identifier {
          return (pageIndex: pageIndex, iconIndex: iconIndex)
        }
      }
    }
    return nil
  }

  public func renamingFolder(to newName: String) -> SpringboardIcon {
    precondition(entryType == .folder)
    var dict = propertyList
    dict["displayName"] = .string(newName)
    return SpringboardIcon(propertyList: dict)
  }

  public func addingToFolder(_ icons: [SpringboardIcon]) -> SpringboardIcon {
    precondition(entryType == .folder)
    var newFolderIcons = folderIcons
    if newFolderIcons.isEmpty {
      newFolderIcons.append(icons)
    } else {
      newFolderIcons[newFolderIcons.count - 1].append(contentsOf: icons)
    }
    return SpringboardIcon.folder(name: displayName, icons: newFolderIcons)
  }

  public func removingFromFolder(pageIndex: Int, iconIndex: Int) -> (folder: SpringboardIcon, removed: SpringboardIcon) {
    precondition(entryType == .folder)
    var newFolderIcons = folderIcons
    let removed = newFolderIcons[pageIndex].remove(at: iconIndex)
    newFolderIcons = newFolderIcons.filter { !$0.isEmpty }
    let folder = SpringboardIcon.folder(name: displayName, icons: newFolderIcons)
    return (folder, removed)
  }

  public func movingWithinFolder(page: Int, from sourceIndex: Int, to destIndex: Int) -> SpringboardIcon {
    precondition(entryType == .folder)
    var newFolderIcons = folderIcons
    let icon = newFolderIcons[page].remove(at: sourceIndex)
    let adjusted = destIndex > sourceIndex ? destIndex - 1 : destIndex
    let clamped = min(adjusted, newFolderIcons[page].count)
    newFolderIcons[page].insert(icon, at: clamped)
    return SpringboardIcon.folder(name: displayName, icons: newFolderIcons)
  }
}

// MARK: - SpringboardIconLayout

/// The SpringBoard icon-state wire format.
///
/// Page 0 is the dock. Subsequent pages are home-screen pages. All values are
/// property-list values deserialized from the lockdown service.
public struct SpringboardIconLayout: Encodable, Sendable {
  private let propertyListPages: [[[String: SpringboardPropertyListValue]]]

  public var pages: [[[String: Any]]] {
    propertyListPages.map { page in page.map { $0.rawValue } }
  }

  public var pageCount: Int { propertyListPages.count }
  public var totalEntries: Int { propertyListPages.flatMap { $0 }.count }
  public var rawValue: NSArray { pages as NSArray }

  public init(pages: [[[String: Any]]]) {
    guard let propertyListPages = try? SpringboardIconLayout.propertyListPages(from: pages) else {
      preconditionFailure("SpringBoard icon layout pages must contain property-list values")
    }
    self.propertyListPages = propertyListPages
  }

  public init(rawValue: Any) throws {
    guard let pages = rawValue as? [[[String: Any]]] else {
      throw SpringboardServicesError.unexpectedResponse(
        command: "getIconState",
        expected: "an array of icon pages",
        actual: String(describing: rawValue))
    }
    self.propertyListPages = try SpringboardIconLayout.propertyListPages(from: pages)
  }

  public func encode(to encoder: any Encoder) throws {
    try SpringboardPropertyListValue.array(
      propertyListPages.map { page in
        .array(page.map { .dictionary($0) })
      }
    ).encode(to: encoder)
  }

  var iconsByBundleID: [String: [String: Any]] {
    var iconsByBundleID: [String: [String: Any]] = [:]
    for page in pages {
      for icon in page {
        if let bundleIdentifier = icon["bundleIdentifier"] as? String {
          iconsByBundleID[bundleIdentifier] = icon
        }
      }
    }
    return iconsByBundleID
  }

  func flattenedBundleIdentifierPages() -> [[String]] {
    pages.map { page in
      page.compactMap { $0["bundleIdentifier"] as? String }
    }
  }

  public func validationError(comparedTo actual: SpringboardIconLayout) -> String? {
    if pageCount != actual.pageCount {
      return "page count differs: sent \(pageCount), got \(actual.pageCount) (iOS may add system entries)"
    }
    for (pageIndex, (expectedPage, actualPage)) in zip(pages, actual.pages).enumerated() {
      let expectedIDs = expectedPage.compactMap { $0["displayIdentifier"] as? String }
      let actualIDs = actualPage.compactMap { $0["displayIdentifier"] as? String }
      if expectedIDs != actualIDs {
        let pageName = pageIndex == 0 ? "dock" : "page \(pageIndex)"
        if expectedIDs.count != actualIDs.count {
          return "\(pageName) count differs: sent \(expectedIDs.count) icons, got \(actualIDs.count)"
        }
        let mismatches = zip(expectedIDs, actualIDs)
          .enumerated()
          .filter { _, identifiers in identifiers.0 != identifiers.1 }
        if let firstMismatch = mismatches.first {
          return "\(pageName) identifiers differ at position \(firstMismatch.offset): sent '\(firstMismatch.element.0)', got '\(firstMismatch.element.1)'"
        }
        return "\(pageName) identifiers differ"
      }
    }
    return nil
  }

  private static func propertyListPages(from pages: [[[String: Any]]]) throws -> [[[String: SpringboardPropertyListValue]]] {
    try pages.map { page in
      try page.map { icon in
        try SpringboardPropertyListValue.dictionary(from: icon)
      }
    }
  }
}
