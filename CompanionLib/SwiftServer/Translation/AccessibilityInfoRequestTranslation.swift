/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorAX
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Translates an `accessibility_info` request to the framework's query and option types, and a read's
/// response to the legacy output bytes.
enum AccessibilityInfoRequestTranslation {

  /// The marker query a request selects, or nil when the request targets a point or the whole frontmost
  /// app. An unset `ignore_case` (older clients) is the historical case-sensitive match.
  static func markerQuery(from request: Idb_AccessibilityInfoRequest) -> AccessibilityElementQuery? {
    guard !request.marker.isEmpty else {
      return nil
    }
    return .marker(
      value: request.marker,
      key: searchableKey(from: request.matchKey),
      depth: UInt(request.depth),
      ignoresCase: request.ignoreCase)
  }

  /// The substring narrowing a request asks for, or nil when it asks for none.
  static func match(from request: Idb_AccessibilityInfoRequest) -> AccessibilityMatch? {
    AccessibilityMatch(
      value: request.match,
      key: searchableKey(from: request.matchKey),
      ignoresCase: request.ignoreCase)
  }

  /// `FILTER_ALL` and an unrecognized value both mean the unfiltered read.
  static func filter(from wire: Idb_AccessibilityInfoRequest.Filter) -> AccessibilityElementFilter {
    switch wire {
    case .all:
      return .all
    case .interactable:
      return .interactable
    case .UNRECOGNIZED:
      return .all
    }
  }

  /// The point a request targets, or nil for the whole frontmost app.
  static func point(from request: Idb_AccessibilityInfoRequest) -> NSValue? {
    guard request.hasPoint else {
      return nil
    }
    return NSValue(point: .init(x: request.point.x, y: request.point.y))
  }

  /// The request options for a point / frontmost read. Rejects an all-invalid `--key` list rather
  /// than silently falling back to the default set and masking the caller's typo; an empty list means
  /// "defaults", and unrecognized keys in a partially-valid list are dropped. `--key all` expands to
  /// every key the reader can answer.
  static func options(from request: Idb_AccessibilityInfoRequest, format: AccessibilityOutputFormat) throws -> AccessibilityRequestOptions {
    let mappedKeys = AXKeys.requested(request.keys)
    if !request.keys.isEmpty && mappedKeys.isEmpty {
      throw RPCError(
        code: .invalidArgument,
        message: "no recognized accessibility keys in \(request.keys)")
    }
    let keys = mappedKeys.isEmpty ? AXKeys.defaultSet : mappedKeys
    return AccessibilityRequestOptions(
      format: format,
      keys: keys,
      enableProfiling: request.profile,
      collectFrameCoverage: request.collectFrameCoverage,
      filter: filter(from: request.filter),
      match: match(from: request),
      clientType: try clientType(from: request.clientType))
  }

  /// `UNSPECIFIED` names no client, the historical read. An unrecognized value is refused rather than
  /// dropped: a read that silently claimed no client would answer with a different tree than asked for.
  static func clientType(from wire: Idb_AccessibilityInfoRequest.ClientType) throws -> AXClientType? {
    switch wire {
    case .unspecified: nil
    case .noClient: .noClient
    case .unidentified: .unidentified
    case .application: .application
    case .xcodeHelper: .xcodeHelper
    case .xctest: .xctest
    case .scripter: .scripter
    case .systemEvents: .systemEvents
    case .voiceOver: .voiceOver
    case .switchControl: .switchControl
    case .fullKeyboardAccess: .fullKeyboardAccess
    case .voiceControl: .voiceControl
    case .accessibilityInspector: .accessibilityInspector
    case let .UNRECOGNIZED(value):
      throw RPCError(code: .invalidArgument, message: "unrecognized accessibility client type \(value)")
    }
  }

  /// `marker` selects one element; `match` narrows a list. Setting both is rejected rather than given a
  /// precedence.
  static func validate(_ request: Idb_AccessibilityInfoRequest) throws {
    guard request.marker.isEmpty || request.match.isEmpty else {
      throw RPCError(code: .invalidArgument, message: "set either marker or match, not both")
    }
  }

  /// `UNSPECIFIED` and an unrecognized value both fall back to the CoreSimulator backend.
  static func backend(from wire: Idb_AccessibilityInfoRequest.Backend) -> UIAutomationBackend {
    switch wire {
    case .unspecified:
      return .accessibility
    case .ax:
      return UIAutomationBackend(resolvedName: .ax)
    case .axCoresimulator:
      return UIAutomationBackend(resolvedName: .axCoreSimulator)
    case .axbridge, .axbridgePersistent:
      // The companion owns its simulator for its whole run, so it holds a bridge. Holding the shared
      // one would make every other process on this machine wait and then spawn a duplicate.
      return UIAutomationBackend(resolvedName: .axBridgeExclusive)
    case .UNRECOGNIZED:
      return .accessibility
    }
  }

  /// An unrecognized value falls back to `LEGACY`, the flat array the gRPC surface has always returned.
  static func outputFormat(from format: Idb_AccessibilityInfoRequest.Format) -> AccessibilityOutputFormat {
    switch format {
    case .legacy:
      return .default
    case .nested:
      return .nested
    case .complete:
      return .complete
    case .UNRECOGNIZED:
      return .default
    }
  }

  /// Reads have always treated an unrecognized key as `.label`.
  static func searchableKey(from key: Idb_AccessibilityActionRequest.SearchableKey) -> AXSearchableKey {
    AXSearchableKey(key) ?? .label
  }

  /// The historical byte shape of a point / frontmost read: the bare element array, serialized without
  /// sorted keys — distinct from the marker path's `{"elements": …}` envelope.
  static func legacyJSON(from response: AccessibilityElementsResponse) throws -> Data {
    try JSONSerialization.data(withJSONObject: response.elements.legacyFoundationObject)
  }

  /// The response bytes for a point / frontmost read: the historical bare shape for the legacy
  /// formats, byte-untouched, and the consolidated document for `complete`.
  static func responseJSON(from response: AccessibilityElementsResponse, format: AccessibilityOutputFormat) throws -> Data {
    switch format {
    case .default, .nested:
      return try legacyJSON(from: response)
    case .complete:
      return try response.formattedOutputJSON(format: format)
    }
  }
}
