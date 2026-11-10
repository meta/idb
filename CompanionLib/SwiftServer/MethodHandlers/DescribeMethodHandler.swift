/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry

struct DescribeMethodHandler {

  let reporter: EventReporter
  let logger: IDBLogger
  let target: any Target

  func handle(request: Idb_TargetDescriptionRequest, context: ServerContext) async throws -> Idb_TargetDescriptionResponse {
    let details = try await target.details(request.fetchDiagnostics ? [.displays, .diagnostics] : [.displays])
    var response = Idb_TargetDescriptionResponse.with {
      $0.targetDescription = .with {
        $0.udid = target.udid
        $0.name = target.name
        $0.state = target.state.stateString.rawValue
        $0.targetType = target.targetType.stringRepresentation.lowercased()
        $0.osVersion = target.osVersion.name.rawValue
        if let screenInfo = target.screenInfo {
          $0.screenDimensions = .with {
            $0.width = UInt64(screenInfo.widthPixels)
            $0.widthPoints = $0.width / UInt64(screenInfo.scale)
            $0.height = UInt64(screenInfo.heightPixels)
            $0.heightPoints = $0.height / UInt64(screenInfo.scale)
            $0.density = Double(screenInfo.scale)
          }
        }
        if let extData = try? JSONSerialization.data(withJSONObject: target.extendedInformation) {
          $0.extended = extData
        }
        $0.displays = displays(details.displays).map(Self.display)
      }
      $0.companion = Idb_CompanionInfo.with {
        $0.udid = target.udid
        $0.setStreamCapabilities()
        $0.screenshotAppContext = true
        if let metadata = try? JSONSerialization.data(withJSONObject: reporter.metadata) {
          $0.metadata = metadata
        }
      }
    }

    guard let diagnostics = details.diagnostics else {
      return response
    }

    response.targetDescription.diagnostics = try JSONSerialization.data(withJSONObject: Self.diagnostics(diagnostics))

    return response
  }

  static func display(_ display: TargetDisplayDescription) -> Idb_Display {
    .with {
      $0.uniqueID = display.uniqueID
      $0.name = display.name
      $0.active = display.isActive
      $0.integrated = display.isIntegrated
      $0.width = UInt64(display.widthPixels)
      $0.height = UInt64(display.heightPixels)
      $0.density = display.scale
    }
  }

  // A target with no diagnostics of its own is described with empty ones.
  static func diagnostics(_ detail: TargetDetail<[String: Any]>) throws -> [String: Any] {
    switch detail {
    case let .read(diagnostics): diagnostics
    case .unsupported: [:]
    case let .failed(error): throw error
    }
  }

  // A description is still useful without displays, so a failed read leaves them out.
  private func displays(_ detail: TargetDetail<[TargetDisplayDescription]>?) -> [TargetDisplayDescription] {
    switch detail {
    case let .read(displays):
      return displays
    case let .failed(error):
      logger.info().log("Describing \(target.udid) without displays: \(error)")
      return []
    case .unsupported, nil:
      return []
    }
  }
}
