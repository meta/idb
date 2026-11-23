/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import FBSimulatorControl
import Foundation

/// The attributes and depth a read must fetch, declared before anything is read.
///
/// A reader fetches exactly what the plan names, and the serializer only consumes what it requested,
/// so how a backend satisfies a plan — one round trip per element, or none at all for a tree already in
/// memory — is the reader's business alone.
struct AXReadPlan: Equatable {

  /// An attribute a read can fetch beyond the frame, which every read fetches because the serializer and
  /// the remote-content grid both place elements by it.
  enum Attribute: CaseIterable {
    case role
    case label
    case value
    case identifier
    case title
    case help
    case enabled
    case customActions
    case roleDescription
    case subrole
    case required
    case traits
    case expanded
    case placeholder
    case hidden
    case focused
    /// Whether a touch reaches the element, and what decides it. Fetched as one unit because a backend
    /// that cannot say whether the element is hittable must not fetch the rest.
    case hittability
    /// The element a hit-test at this one's centre found.
    case explainedBy
  }

  /// How far below the root a read descends.
  enum Depth: Equatable {
    case unlimited
    /// `0` reads the root alone.
    case limited(UInt)

    var descendant: Depth? {
      switch self {
      case .unlimited:
        return .unlimited
      case .limited(0):
        return nil
      case let .limited(remaining):
        return .limited(remaining - 1)
      }
    }
  }

  let attributes: Set<Attribute>
  let depth: Depth

  init(attributes: Set<Attribute>, depth: Depth) {
    self.attributes = attributes
    self.depth = depth
  }

  /// The plan a serialization over `keys` consumes.
  init(keys: Set<AXKeys>, depth: Depth) {
    var attributes: Set<Attribute> = []
    if keys.contains(.role) || keys.contains(.type) { attributes.insert(.role) }
    if keys.contains(.label) { attributes.insert(.label) }
    if keys.contains(.value) { attributes.insert(.value) }
    if keys.contains(.uniqueID) { attributes.insert(.identifier) }
    if keys.contains(.title) { attributes.insert(.title) }
    if keys.contains(.help) { attributes.insert(.help) }
    if keys.contains(.enabled) { attributes.insert(.enabled) }
    if keys.contains(.customActions) { attributes.insert(.customActions) }
    if keys.contains(.roleDescription) { attributes.insert(.roleDescription) }
    if keys.contains(.subrole) { attributes.insert(.subrole) }
    if keys.contains(.contentRequired) { attributes.insert(.required) }
    if keys.contains(.traits) { attributes.insert(.traits) }
    if keys.contains(.expanded) { attributes.insert(.expanded) }
    if keys.contains(.placeholder) { attributes.insert(.placeholder) }
    if keys.contains(.hidden) { attributes.insert(.hidden) }
    if keys.contains(.focused) { attributes.insert(.focused) }
    // `occluded_by` enriches `interactable`, so it reads what `interactable` reads.
    if keys.contains(.interactable) || keys.contains(.occludedBy) {
      attributes.insert(.hittability)
      attributes.insert(.explainedBy)
    }
    self.init(attributes: attributes, depth: depth)
  }

  /// The plan a search comparing `key` consumes.
  init(searching key: AXSearchableKey, depth: Depth) {
    let attribute: Attribute =
      switch key {
      case .label: .label
      case .uniqueID: .identifier
      case .value: .value
      case .title: .title
      case .role: .role
      case .roleDescription: .roleDescription
      case .subrole: .subrole
      case .help: .help
      case .placeholder: .placeholder
      }
    self.init(attributes: [attribute], depth: depth)
  }
}

/// Whether a touch reaches an element, and the attributes that decide why not. Only a backend that can
/// answer hittability produces one; the rest are read only once hittability is known.
struct AXHittability: Equatable {
  let isHittable: Bool
  let isHidden: Bool
  let isEnabled: Bool?
  let isUserInteractionEnabled: Bool?
  /// The point the accessibility server believes a touch reaches, sentinel included.
  let hittablePoint: CGPoint?
}

/// One element as read against an `AXReadPlan`: what the plan named, the element's children to the plan's
/// depth, and nothing that needs another read.
///
/// An attribute outside the plan is nil. The serializer requests the same keys it consumes, so it never
/// mistakes an unread attribute for an absent one.
final class AXElementSnapshot {
  let frame: NSRect
  let pid: pid_t
  /// The element actions go through, when the backend can act on what it read.
  let handle: (any AXTranslationReference)?
  let role: String?
  let label: String?
  let value: AccessibilityAttributeValue?
  /// The value as read, when the platform returned a string: what a search on `.value` compares, which
  /// a described non-string value must not match.
  let stringValue: String?
  let identifier: String?
  let title: String?
  let help: String?
  let isEnabled: Bool?
  let customActionNames: [String]?
  let roleDescription: String?
  let subrole: String?
  let isRequired: Bool?
  let traits: [String]?
  let isExpanded: Bool?
  let placeholder: String?
  let isHidden: Bool?
  let isFocused: Bool?
  let hittability: AXHittability?
  let explainedBy: AXElementSnapshot?
  let children: [AXElementSnapshot]

  init(
    frame: NSRect,
    pid: pid_t,
    handle: (any AXTranslationReference)? = nil,
    role: String? = nil,
    label: String? = nil,
    value: AccessibilityAttributeValue? = nil,
    stringValue: String? = nil,
    identifier: String? = nil,
    title: String? = nil,
    help: String? = nil,
    isEnabled: Bool? = nil,
    customActionNames: [String]? = nil,
    roleDescription: String? = nil,
    subrole: String? = nil,
    isRequired: Bool? = nil,
    traits: [String]? = nil,
    isExpanded: Bool? = nil,
    placeholder: String? = nil,
    isHidden: Bool? = nil,
    isFocused: Bool? = nil,
    hittability: AXHittability? = nil,
    explainedBy: AXElementSnapshot? = nil,
    children: [AXElementSnapshot] = []
  ) {
    self.frame = frame
    self.pid = pid
    self.handle = handle
    self.role = role
    self.label = label
    self.value = value
    self.stringValue = stringValue
    self.identifier = identifier
    self.title = title
    self.help = help
    self.isEnabled = isEnabled
    self.customActionNames = customActionNames
    self.roleDescription = roleDescription
    self.subrole = subrole
    self.isRequired = isRequired
    self.traits = traits
    self.isExpanded = isExpanded
    self.placeholder = placeholder
    self.isHidden = isHidden
    self.isFocused = isFocused
    self.hittability = hittability
    self.explainedBy = explainedBy
    self.children = children
  }
}

// MARK: - Searching

extension AXElementSnapshot {

  /// The value of `key`, as a search compares it. Read only when the snapshot's plan named the key.
  func searchableValue(for key: AXSearchableKey) -> String? {
    switch key {
    case .label: label
    case .uniqueID: identifier
    case .value: stringValue
    case .title: title
    case .role: role
    case .roleDescription: roleDescription
    case .subrole: subrole
    case .help: help
    case .placeholder: placeholder
    }
  }
}
