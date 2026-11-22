/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation
import XPC

/// What one `displayinfo` read says about the simulator's displays, before anything is selected from it.
package enum SimulatorDisplayReport: Equatable, Sendable {
  /// Every display, identified, with its activity.
  case displays([SimulatorDisplay])
  /// A runtime that reports no display activity. The geometry of each integrated display, which may not be
  /// identified.
  case legacy(integrated: [SimulatorDisplayGeometry])
  /// Layout has moved to a display whose backlight has not caught up, as after a hinge change. `incoming` is the
  /// integrated display the layout has moved to, when exactly one is named.
  case transitioning(incoming: SimulatorDisplay?)
  case failed(SimulatorCoreDeviceError)
}

/// The `displayinfo` feature: what the provider reports about each display.
enum SimulatorDisplayProtocol {
  static let service = "com.apple.coredevice.feature.getdisplayinfo"
  static let action = "com.apple.coredevice.action.displayinfo"

  /// The output as the provider sends it. Activity and stable identity are optional only because
  /// older providers omit activity from every display or report every backlight as `unknown`, and
  /// some of those omit identity too; see `report`.
  struct Report: Decodable {
    struct Record: Decodable {
      let uniqueId: String?
      let name: String
      let active: Bool?
      let backlightState: String?
      let primary: Bool
      let bounds: [[Double]]
      let pointScale: Int64
      let currentOrientation: SimulatorDisplayRotation
      let type: [String: XPCValue]
    }

    let current: Bool
    let displays: [Record]
  }

  private static let maximumDisplays = 32
  private static let maximumStringLength = 1024

  /// A report with activity yields displays; one that carries no activity evidence on any display is
  /// legacy, whether or not it sends identity (Xcode 27.0 sends identity without activity). An `unknown`
  /// backlight is not evidence: Xcode 27.1 driving an iOS 26 runtime reports it on every display and sends
  /// no identity. A report with activity on some displays but not others is malformed.
  static func report(_ reply: xpc_object_t) -> SimulatorDisplayReport {
    reading { try CoreDeviceReply.decode(Report.self, from: reply) }
  }

  /// A report pushed by `displayinfoupdates`, which arrives already decoded.
  static func report(of report: Report) -> SimulatorDisplayReport {
    reading { report }
  }

  private static func reading(_ decode: () throws -> Report) -> SimulatorDisplayReport {
    do {
      return try interpreted(validated(decode()))
    } catch let error as SimulatorCoreDeviceError {
      return .failed(error)
    } catch {
      return .failed(.malformed("\(error)"))
    }
  }

  private static func interpreted(_ report: Report) throws -> SimulatorDisplayReport {
    let legacy = report.displays.allSatisfy { $0.active == nil && [nil, "unknown"].contains($0.backlightState) }
    guard legacy, !report.displays.isEmpty else {
      return try displays(in: report)
    }
    var integrated: [SimulatorDisplayGeometry] = []
    for record in report.displays {
      let validated = try validated(record)
      guard validated.integrated else { continue }
      guard !validated.bounds.isEmpty else { throw SimulatorCoreDeviceError.malformed("Invalid integrated display geometry") }
      integrated.append(
        SimulatorDisplayGeometry(bounds: validated.bounds, scale: Double(record.pointScale), rotation: record.currentOrientation))
    }
    return .legacy(integrated: integrated)
  }

  private static func validated(_ report: Report) throws -> Report {
    guard report.current else { throw SimulatorCoreDeviceError.malformed("Report is not current") }
    guard report.displays.count <= maximumDisplays else { throw SimulatorCoreDeviceError.malformed("Too many displays") }
    return report
  }

  private static func displays(in report: Report) throws -> SimulatorDisplayReport {
    let hasLayoutActivity = report.displays.contains { $0.active != nil }
    var identifiers: Set<String> = []
    var displays: [SimulatorDisplay] = []
    for record in report.displays {
      let validated = try validated(record)
      guard let id = record.uniqueId, !id.isEmpty, id.utf8.count <= maximumStringLength, identifiers.insert(id).inserted else {
        throw SimulatorCoreDeviceError.malformed("Duplicate or empty display identity")
      }
      guard let activity = try activity(of: record, hasLayoutActivity: hasLayoutActivity) else {
        return .transitioning(incoming: incomingDisplay(in: report))
      }
      guard activity != .active || !validated.bounds.isEmpty else { throw SimulatorCoreDeviceError.malformed("Active display has empty bounds") }
      displays.append(
        SimulatorDisplay(
          uniqueID: id, name: record.name, activity: activity, isPrimary: record.primary, isIntegrated: validated.integrated,
          bounds: validated.bounds, scale: Double(record.pointScale), rotation: record.currentOrientation))
    }
    return .displays(displays.sorted { $0.uniqueID < $1.uniqueID })
  }

  /// The sole integrated display whose layout is active. Read without failing, so a transitioning report is
  /// recognised whatever the other records hold, as it is when no display is incoming.
  private static func incomingDisplay(in report: Report) -> SimulatorDisplay? {
    let laidOut = report.displays.filter { $0.active == true }
    guard laidOut.count == 1, let record = laidOut.first, let id = record.uniqueId, !id.isEmpty, id.utf8.count <= maximumStringLength,
      let validated = try? validated(record), validated.integrated, !validated.bounds.isEmpty
    else {
      return nil
    }
    return SimulatorDisplay(
      uniqueID: id, name: record.name, activity: .active, isPrimary: record.primary, isIntegrated: true, bounds: validated.bounds,
      scale: Double(record.pointScale), rotation: record.currentOrientation)
  }

  /// Layout activity is authoritative when the report carries it; otherwise backlight state identifies
  /// the illuminated display. Nil when an inactive layout is still lit, as mid-transition.
  private static func activity(of record: Report.Record, hasLayoutActivity: Bool) throws -> SimulatorDisplayActivity? {
    if hasLayoutActivity {
      guard let active = record.active else { throw SimulatorCoreDeviceError.malformed("Display has no activity") }
      if !active, let state = record.backlightState, ["activeOn", "activeDimmed"].contains(state) {
        return nil
      }
      return active ? .active : .inactive
    }
    switch record.backlightState {
    case "activeOn", "activeDimmed": return .active
    case "off", "inactiveOn": return .inactive
    case "unknown": return .unknown
    case nil: throw SimulatorCoreDeviceError.malformed("Display has no activity")
    default: throw SimulatorCoreDeviceError.malformed("Unknown backlight state")
    }
  }

  /// The fields every record has to satisfy, legacy or not.
  private static func validated(_ record: Report.Record) throws -> (bounds: CGRect, integrated: Bool) {
    guard record.name.utf8.count <= maximumStringLength else { throw SimulatorCoreDeviceError.malformed("name") }
    guard record.pointScale > 0 else { throw SimulatorCoreDeviceError.malformed("Invalid display scale") }
    guard record.type.count == 1 else { throw SimulatorCoreDeviceError.malformed("Invalid display type") }
    return (try rectangle(record.bounds), record.type["integrated"] != nil)
  }

  /// Bounds arrive as `[[x, y], [width, height]]`.
  private static func rectangle(_ value: [[Double]]) throws -> CGRect {
    guard value.count == 2, value[0].count == 2, value[1].count == 2 else {
      throw SimulatorCoreDeviceError.malformed("Invalid bounds")
    }
    let (x, y, width, height) = (value[0][0], value[0][1], value[1][0], value[1][1])
    guard [x, y, width, height].allSatisfy(\.isFinite) else { throw SimulatorCoreDeviceError.malformed("Non-finite coordinate") }
    guard width >= 0, height >= 0 else { throw SimulatorCoreDeviceError.malformed("Negative size") }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
