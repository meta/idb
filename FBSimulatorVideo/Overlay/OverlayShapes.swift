/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBSimulatorControl
import Foundation

// MARK: - Shape Model

/// A command containing overlay shapes to render.
public struct OverlayCommand: Decodable {
  public let overlays: [OverlayShape]

  public init(overlays: [OverlayShape]) {
    self.overlays = overlays
  }
}

/// A tagged union of overlay shapes, decoded from the overlay JSON protocol (`{"circle": {...}}` etc.).
public enum OverlayShape: Decodable {
  case circle(Circle)
  case rectangle(Rectangle)
  case label(Label)

  public struct Circle: Decodable {
    public let x: CGFloat
    public let y: CGFloat
    public let radius: CGFloat
    public let rgba: [CGFloat]
    public let effect: Effect?

    public init(x: CGFloat, y: CGFloat, radius: CGFloat, rgba: [CGFloat], effect: Effect?) {
      self.x = x
      self.y = y
      self.radius = radius
      self.rgba = rgba
      self.effect = effect
    }
  }

  public struct Rectangle: Decodable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let rgba: [CGFloat]
    public let effect: Effect?

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rgba: [CGFloat], effect: Effect?) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
      self.rgba = rgba
      self.effect = effect
    }
  }

  public struct Label: Decodable {
    public let text: String
    public let padding: CGFloat
    public let font: String

    public init(text: String, padding: CGFloat, font: String) {
      self.text = text
      self.padding = padding
      self.font = font
    }
  }

  public enum Effect: Decodable {
    case fadeout(FadeEffect)
    case fadein(FadeEffect)
    case translate(TranslateEffect)

    public struct FadeEffect: Decodable {
      public let durationMs: CGFloat

      public init(durationMs: CGFloat) {
        self.durationMs = durationMs
      }
    }

    public struct TranslateEffect: Decodable {
      public let x: CGFloat
      public let y: CGFloat
      public let durationMs: CGFloat

      public init(x: CGFloat, y: CGFloat, durationMs: CGFloat) {
        self.x = x
        self.y = y
        self.durationMs = durationMs
      }
    }

    private enum CodingKeys: String, CodingKey {
      case fadeout, fadein, translate
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let fade = try container.decodeIfPresent(FadeEffect.self, forKey: .fadeout) {
        self = .fadeout(fade)
      } else if let fade = try container.decodeIfPresent(FadeEffect.self, forKey: .fadein) {
        self = .fadein(fade)
      } else if let translate = try container.decodeIfPresent(TranslateEffect.self, forKey: .translate) {
        self = .translate(translate)
      } else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown effect type"))
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case circle, rectangle, label
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let circle = try container.decodeIfPresent(Circle.self, forKey: .circle) {
      self = .circle(circle)
    } else if let rect = try container.decodeIfPresent(Rectangle.self, forKey: .rectangle) {
      self = .rectangle(rect)
    } else if let label = try container.decodeIfPresent(Label.self, forKey: .label) {
      self = .label(label)
    } else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown shape type"))
    }
  }
}
