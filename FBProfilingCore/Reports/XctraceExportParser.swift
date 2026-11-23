/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public struct TraceReport: Codable, Equatable, Sendable {
  public let runs: [TraceRun]
  /// The exported tables of the last run.
  public let tables: [TraceTable]
}

/// One recording in a trace, from `xctrace export --toc`.
public struct TraceRun: Codable, Equatable, Sendable {
  public let number: Int
  public let templateName: String?
  public let durationSeconds: Double?
  public let endReason: String?
  public let processes: [TraceProcess]
  /// The schema of every table the run recorded, in the order xctrace lists them. A schema can recur with different parameters.
  public let schemas: [String]
}

public struct TraceProcess: Codable, Equatable, Sendable {
  public let name: String
  public let pid: Int32
  public let path: String?
}

public struct TraceColumn: Codable, Equatable, Sendable {
  public let mnemonic: String
  public let name: String
  public let engineeringType: String
}

/// One table of a trace, from `xctrace export --xpath`.
public struct TraceTable: Codable, Equatable, Sendable {
  public let schema: String
  public let columns: [TraceColumn]
  /// Every row in the table, including any beyond the row limit.
  public let rowCount: Int
  /// One value per column.
  public let rows: [[TraceValue]]
}

public enum TraceValue: Equatable, Sendable {
  /// xctrace's `sentinel`: the column has no value in this row.
  case empty
  /// The value as Instruments displays it.
  case text(String)
  /// Innermost first, as xctrace reports it.
  case backtrace([ProfileFrame])
}

extension TraceValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .empty
    } else if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      self = .backtrace(try container.decode([ProfileFrame].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .empty:
      try container.encodeNil()
    case let .text(text):
      try container.encode(text)
    case let .backtrace(frames):
      try container.encode(frames)
    }
  }
}

/// Parses the XML that `xctrace export` writes.
public enum XctraceExportParser {

  public static func runs(fromTableOfContents data: Data) throws -> [TraceRun] {
    let document = try XMLDocument(data: data)
    let runs = try document.nodes(forXPath: "/trace-toc/run").compactMap { $0 as? XMLElement }
    guard !runs.isEmpty else {
      throw ProfileReportParseError.missingSection(tool: "xctrace", section: "run")
    }
    return runs.map { run in
      let summary = run.child("info")?.child("summary")
      return TraceRun(
        number: run.attribute("number").flatMap { Int($0) } ?? 0,
        templateName: summary?.child("template-name")?.stringValue,
        durationSeconds: summary?.child("duration")?.stringValue.flatMap { Double($0) },
        endReason: summary?.child("end-reason")?.stringValue,
        processes: run.child("processes")?.children("process").compactMap { process in
          guard let name = process.attribute("name"), let pid = process.attribute("pid").flatMap({ Int32($0) }) else { return nil }
          return TraceProcess(name: name, pid: pid, path: process.attribute("path"))
        } ?? [],
        schemas: run.child("data")?.children("table").compactMap { $0.attribute("schema") } ?? [])
    }
  }

  /// Parses the first table in an export. Rows past `rowLimit` are counted but not returned.
  public static func table(from data: Data, rowLimit: Int? = nil) throws -> TraceTable {
    let document = try XMLDocument(data: data)
    guard let node = try document.nodes(forXPath: "/trace-query-result/node").first as? XMLElement,
      let schema = node.child("schema"),
      let schemaName = schema.attribute("name")
    else {
      throw ProfileReportParseError.missingSection(tool: "xctrace", section: "table schema")
    }
    let columns = schema.children("col").map { column in
      TraceColumn(
        mnemonic: column.child("mnemonic")?.stringValue ?? "",
        name: column.child("name")?.stringValue ?? "",
        engineeringType: column.child("engineering-type")?.stringValue ?? "")
    }
    let rows = node.children("row")
    let interner = Interner()
    // A ref only ever points to an earlier element, so the rows past the limit can go unread.
    var parsed: [[TraceValue]] = []
    for row in rows.prefix(rowLimit ?? rows.count) {
      parsed.append(row.childElements.map { interner.value(of: $0) })
    }
    return TraceTable(schema: schemaName, columns: columns, rowCount: rows.count, rows: parsed)
  }

  /// xctrace writes each distinct value once with an `id`, and every later occurrence as a `ref` to it.
  private final class Interner {
    var values: [String: TraceValue] = [:]
    var frames: [String: ProfileFrame] = [:]
    var binaries: [String: String] = [:]

    func value(of element: XMLElement) -> TraceValue {
      if let ref = element.attribute("ref") {
        return values[ref] ?? .empty
      }
      let value: TraceValue
      if element.name == "sentinel" {
        value = .empty
      } else if element.name?.hasSuffix("backtrace") == true {
        value = .backtrace(element.children("frame").map(frame(of:)))
      } else {
        // Children such as a thread's process carry their own ids, which later cells refer to.
        for child in element.childElements {
          _ = self.value(of: child)
        }
        value = .text(element.attribute("fmt") ?? element.stringValue ?? "")
      }
      if let id = element.attribute("id") {
        values[id] = value
      }
      return value
    }

    private func frame(of element: XMLElement) -> ProfileFrame {
      if let ref = element.attribute("ref") {
        return frames[ref] ?? ProfileFrame(symbol: "", binary: nil)
      }
      let frame = ProfileFrame(
        symbol: element.attribute("name") ?? element.attribute("addr") ?? "",
        binary: element.child("binary").flatMap(binary(of:)))
      if let id = element.attribute("id") {
        frames[id] = frame
      }
      return frame
    }

    private func binary(of element: XMLElement) -> String? {
      if let ref = element.attribute("ref") {
        return binaries[ref]
      }
      let name = element.attribute("name")
      if let id = element.attribute("id"), let name {
        binaries[id] = name
      }
      return name
    }
  }
}

extension XMLElement {
  fileprivate var childElements: [XMLElement] {
    children?.compactMap { $0 as? XMLElement } ?? []
  }

  fileprivate func children(_ name: String) -> [XMLElement] {
    elements(forName: name)
  }

  fileprivate func child(_ name: String) -> XMLElement? {
    elements(forName: name).first
  }

  fileprivate func attribute(_ name: String) -> String? {
    attribute(forName: name)?.stringValue
  }
}
