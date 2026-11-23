/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import CoreSimulator
import FBControlCore
import FBControlCoreObjC
import Foundation
import UniformTypeIdentifiers

public enum SimulatorMediaError: Error {
  case noMediaProvided
  case unknownMediaPaths(paths: [URL])
  case addMediaFailed(paths: [URL], underlying: any Error)
  case addContactsFailed(paths: [URL], underlying: any Error)
}

extension SimulatorMediaError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noMediaProvided:
      return "Cannot upload media, none was provided"
    case let .unknownMediaPaths(paths):
      return "\(paths) not a known media path"
    case let .addMediaFailed(paths, _):
      return "Failed to add media \(paths)"
    case let .addContactsFailed(paths, _):
      return "Failed to add contacts \(paths)"
    }
  }
}

public struct SimulatorMediaCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  private static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

  private static let photoTypes: [UTType] = [.heic, .image, .jpeg, .png] + [UTType("public.jpeg-2000")].compactMap { $0 }

  private static let contactTypes: [UTType] = [.vCard]

  public func upload(_ mediaFileURLs: [URL]) throws {

    if mediaFileURLs.isEmpty {
      throw SimulatorMediaError.noMediaProvided
    }

    let unknown = mediaFileURLs.filter { !Self.url($0, conformsToAnyOf: Self.videoTypes + Self.photoTypes + Self.contactTypes) }
    if !unknown.isEmpty {
      throw SimulatorMediaError.unknownMediaPaths(paths: unknown)
    }

    if simulator.state != .booted {
      let stateString = (simulator.device.stateString() as String?) ?? "unknown"
      throw SimulatorStateError.notBooted(operation: "upload photos", state: stateString)
    }

    let photosAndVideos = mediaFileURLs.filter { Self.url($0, conformsToAnyOf: Self.photoTypes + Self.videoTypes) }
    if !photosAndVideos.isEmpty {
      do {
        try FBObjCExceptionGuard.guarded {
          try simulator.device.addMedia(photosAndVideos)
        }
      } catch {
        throw SimulatorMediaError.addMediaFailed(paths: photosAndVideos, underlying: error)
      }
    }

    let contacts = mediaFileURLs.filter { Self.url($0, conformsToAnyOf: Self.contactTypes) }
    if !contacts.isEmpty {
      do {
        try FBObjCExceptionGuard.guarded {
          try simulator.device.addMedia(contacts)
        }
      } catch {
        throw SimulatorMediaError.addContactsFailed(paths: contacts, underlying: error)
      }
    }
  }

  private static func url(_ url: URL, conformsToAnyOf types: [UTType]) -> Bool {
    guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
      return false
    }
    return types.contains { contentType.conforms(to: $0) }
  }
}
