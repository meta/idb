/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import CoreText
import CoreVideo
import FBControlCore
import FBSimulatorControl
import Foundation
import QuartzCore

/// The content mode for a status bar slot.
public enum BarContent: Equatable {
  /// Display the given text in the bar.
  case text(String)
  /// Display live stats from the internal 1Hz writer.
  case stats
  /// Bar is hidden — no background, no text.
  case hidden
}

/// Layout mode for a status bar — determines how the bar interacts with the simulator screen.
public enum BarMode: String {
  /// Bar lives in canvas space reserved via edgeInsets. Nothing renders behind it, so the
  /// background is fully opaque. The simulator screen is pushed away from the reserved edge.
  case pad
  /// Bar is drawn on top of the simulator screen at the requested edge. The canvas size matches
  /// the simulator screen; the bar covers screen pixels with a semi-transparent background so
  /// the underlying content peeks through.
  case overlay
}

/// Renders overlay shapes into a CVPixelBuffer for compositing over video frames.
///
/// The renderer owns a single IOSurface-backed BGRA+alpha CVPixelBuffer that is
/// reused across renders. Call `render(overlays:)` to draw shapes, then pass `buffer`
/// to `SimulatorVideoStream.updateOverlayBuffer()` to trigger a frame push.
///
/// For animated effects (fadeout, fadein, translate), call `startEffectTimer(onTick:)`
/// after rendering. The timer re-renders at ~30fps until all effects complete.
// SAFETY: every mutable field, the buffer and its layout included, is guarded by `stateLock`.
// patternlint-disable-next-line unchecked-sendable
public final class OverlayRenderer: @unchecked Sendable {
  public var buffer: CVPixelBuffer {
    stateLock.lock()
    defer { stateLock.unlock() }
    return storage
  }
  public var transform: OverlayCoordinateTransform {
    stateLock.lock()
    defer { stateLock.unlock() }
    return layout
  }
  private var storage: CVPixelBuffer
  private var width: Int
  private var height: Int
  private var layout: OverlayCoordinateTransform

  /// Injectable time source for monotonic time (seconds). Defaults to `CACurrentMediaTime()`.
  /// Override in tests to control animation progress deterministically.
  var currentTime: () -> CFTimeInterval = { CACurrentMediaTime() }

  /// A shape with its start time, classified as persistent or animating.
  ///
  /// - `persistent`: No effect — replaced wholesale on each `render(overlays:)` call.
  /// - `animating`: Has an active effect (fadeout, fadein, translate) — survives across
  ///   subsequent `render(overlays:)` calls until the effect expires.
  private enum TimedShape {
    case persistent(OverlayShape, startTime: CFTimeInterval)
    case animating(OverlayShape, startTime: CFTimeInterval)

    var shape: OverlayShape {
      switch self {
      case .persistent(let s, _), .animating(let s, _): return s
      }
    }

    var startTime: CFTimeInterval {
      switch self {
      case .persistent(_, let t), .animating(_, let t): return t
      }
    }

    var isAnimating: Bool {
      switch self {
      case .animating: return true
      case .persistent: return false
      }
    }
  }

  private var shapes: [TimedShape] = []
  private var effectTimer: (any DispatchSourceTimer)?
  private let effectQueue = DispatchQueue(label: "com.facebook.FBSimulatorControl.overlay-effects")

  /// Serializes access to the renderer's mutable state (`shapes`, the bar dictionaries, `statsText`,
  /// `effectTimer`) and the buffer render. The renderer is driven from several threads — the
  /// `@MainActor` stdin handler, the background 1Hz stats writer, and the effect timer's own queue —
  /// so without this every mutation would race (a concurrent `statsText` write/read corrupts the
  /// dictionary and crashes). Recursive so a locked method can call `renderToBuffer()` while held.
  private let stateLock = NSRecursiveLock()

  /// Logger for diagnostic output.
  public var logger: (any ControlCoreLogger)?

  /// Current content mode for each bar position.
  public private(set) var barContent: [String: BarContent] = [:]

  /// Live stats text written by the internal 1Hz timer. Only displayed when the bar's content
  /// mode is `.stats`. The renderer never reads this unless the bar is in stats mode.
  private(set) var statsText: [String: String] = [:]

  /// Layout mode for each bar position. Defaults to `.pad` for any position not explicitly set.
  /// `pad` mode draws an opaque background; `overlay` mode draws a partially-transparent
  /// background so the simulator content beneath shows through.
  public private(set) var barMode: [String: BarMode] = [:]

  /// Per-position shrink-to-fit flag. When true, the bar's font size is reduced so the rendered
  /// text width fits within the bar (minus padding). Applies to whatever the bar currently
  /// displays — fixed text and stats text alike. Defaults to false (no shrinking; long text
  /// renders past the bar's right edge and is visually clipped).
  public private(set) var barFit: [String: Bool] = [:]

  /// Convenience init for testing — creates a transform from width/height/scale.
  public convenience init(width: Int, height: Int, scaleFactor: CGFloat = 1.0) {
    let transform = OverlayCoordinateTransform(
      screenPixelWidth: width,
      screenPixelHeight: height,
      retinaScale: 1.0,
      videoScale: scaleFactor,
      borderTop: 0,
      scaledBorderTop: 0,
      borderBottom: 0,
      scaledBorderBottom: 0
    )
    self.init(transform: transform)
  }

  public init(transform: OverlayCoordinateTransform) {
    self.storage = Self.makeBuffer(width: transform.bufferWidth, height: transform.bufferHeight)
    self.width = transform.bufferWidth
    self.height = transform.bufferHeight
    self.layout = transform

    clearBuffer()
  }

  private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &pixelBuffer)
    guard let createdBuffer = pixelBuffer else {
      fatalError("CVPixelBufferCreate failed for \(width)x\(height) BGRA buffer")
    }
    return createdBuffer
  }

  /// Lays the overlay out for a screen of this size in a canvas of this size, keeping its shapes and bars, and returns
  /// the buffer they are drawn in: a new one when either size changed.
  public func layOut(screenPixelWidth: Int, screenPixelHeight: Int, canvasPixelWidth: Int, canvasPixelHeight: Int) -> CVPixelBuffer {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard
      screenPixelWidth != layout.screenPixelWidth || screenPixelHeight != layout.screenPixelHeight
        || canvasPixelWidth != layout.canvasPixelWidth || canvasPixelHeight != layout.canvasPixelHeight
    else {
      return storage
    }
    layout = layout.resized(
      screenPixelWidth: screenPixelWidth, screenPixelHeight: screenPixelHeight, canvasPixelWidth: canvasPixelWidth,
      canvasPixelHeight: canvasPixelHeight)
    width = layout.bufferWidth
    height = layout.bufferHeight
    storage = Self.makeBuffer(width: width, height: height)
    renderToBuffer()
    return storage
  }

  /// A one-off buffer with the overlay drawn as it is now, laid out for a canvas that is exactly a screen of this many
  /// pixels. The buffer `layOut` returned is left as it is.
  public func snapshot(screenPixelWidth: Int, screenPixelHeight: Int) -> CVPixelBuffer {
    stateLock.lock()
    defer { stateLock.unlock() }
    let screenLayout = layout.resized(
      screenPixelWidth: screenPixelWidth, screenPixelHeight: screenPixelHeight, canvasPixelWidth: screenPixelWidth,
      canvasPixelHeight: screenPixelHeight)
    let buffer = Self.makeBuffer(width: screenLayout.bufferWidth, height: screenLayout.bufferHeight)
    draw(into: buffer, layout: screenLayout)
    return buffer
  }

  /// The overlay scale factor from the layout.
  var scaleFactor: CGFloat { transform.overlayScale }

  /// Render the given overlays into the buffer.
  ///
  /// Shapes with effects become `.animating` and persist across subsequent renders
  /// until their effect completes. Shapes without effects become `.persistent` and
  /// replace the previous persistent set on each call.
  public func render(overlays: [OverlayShape]) {
    stateLock.lock()
    defer { stateLock.unlock() }
    let now = currentTime()

    // Keep in-flight animating shapes, drop expired ones.
    var kept = shapes.filter { timedShape in
      guard timedShape.isAnimating else { return false }
      let elapsed = now - timedShape.startTime
      return isEffectActive(effectForShape(timedShape.shape), elapsed: elapsed)
    }

    for shape in overlays {
      if effectForShape(shape) != nil {
        kept.append(.animating(shape, startTime: now))
      } else {
        kept.append(.persistent(shape, startTime: now))
      }
    }

    self.shapes = kept
    renderToBuffer()
  }

  /// Clear the overlay buffer to fully transparent.
  public func clear() {
    stateLock.lock()
    defer { stateLock.unlock() }
    stopEffectTimer()
    shapes = []
    clearBuffer()
  }

  /// Returns true if any shape has an active (non-completed) effect.
  func hasActiveEffects() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    let now = currentTime()
    return shapes.contains { timedShape in
      let elapsed = now - timedShape.startTime
      return isEffectActive(effectForShape(timedShape.shape), elapsed: elapsed)
    }
  }

  /// Start a timer that re-renders the overlay at ~30fps for effect animations.
  ///
  /// If a timer is already running, this is a no-op — the existing timer will
  /// continue rendering and self-cancel when all effects expire.
  public func startEffectTimer(onTick: @escaping () -> Void) {
    stateLock.lock()
    defer { stateLock.unlock() }
    if effectTimer != nil { return }
    guard hasActiveEffects() else { return }

    let timer = DispatchSource.makeTimerSource(queue: effectQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(33))
    timer.setEventHandler { [weak self] in
      guard let self else {
        timer.cancel()
        return
      }
      self.renderToBuffer()
      onTick()
      if !self.hasActiveEffects() {
        self.stopEffectTimer()
      }
    }
    effectTimer = timer
    timer.resume()
  }

  /// Set the content mode for a bar at the given position. Re-renders the buffer.
  public func setBarContent(_ content: BarContent, position: String) {
    stateLock.lock()
    defer { stateLock.unlock() }
    barContent[position] = content
    renderToBuffer()
  }

  /// Update the live stats text for a position (called by the 1Hz timer).
  /// Only triggers a re-render if the bar is currently in `.stats` mode.
  public func setStatsText(_ text: String, position: String) {
    stateLock.lock()
    defer { stateLock.unlock() }
    statsText[position] = text
    if barContent[position] == .stats {
      renderToBuffer()
    }
  }

  /// Set the layout mode for a bar position.
  public func setBarMode(_ mode: BarMode, position: String) {
    stateLock.lock()
    defer { stateLock.unlock() }
    barMode[position] = mode
  }

  /// Set the shrink-to-fit flag for a bar position.
  public func setBarFit(_ fit: Bool, position: String) {
    stateLock.lock()
    defer { stateLock.unlock() }
    barFit[position] = fit
  }

  func stopEffectTimer() {
    stateLock.lock()
    defer { stateLock.unlock() }
    effectTimer?.cancel()
    effectTimer = nil
  }

  // MARK: - Private

  private func clearBuffer() {
    CVPixelBufferLockBaseAddress(storage, [])
    defer { CVPixelBufferUnlockBaseAddress(storage, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(storage) else { return }
    let size = CVPixelBufferGetBytesPerRow(storage) * height
    memset(baseAddress, 0, size)
  }

  /// Re-render all shapes into the pixel buffer at the current time.
  public func renderToBuffer() {
    stateLock.lock()
    defer { stateLock.unlock() }
    draw(into: storage, layout: layout)
  }

  /// Draws every shape and bar at the current time into `buffer`, laid out by `layout`, which sizes it.
  private func draw(into buffer: CVPixelBuffer, layout: OverlayCoordinateTransform) {
    let width = layout.bufferWidth
    let height = layout.bufferHeight
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    else { return }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))

    // CoreGraphics has origin at bottom-left; flip to top-left to match screen coordinates.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    let now = currentTime()
    for timedShape in shapes {
      let elapsed = now - timedShape.startTime
      renderShape(timedShape.shape, layout: layout, context: context, elapsed: elapsed)
    }

    renderBarIfActive("bottom", layout: layout, context: context)
    renderBarIfActive("top", layout: layout, context: context)
  }

  private func renderShape(_ shape: OverlayShape, layout: OverlayCoordinateTransform, context: CGContext, elapsed: CFTimeInterval) {
    switch shape {
    case .circle(let c):
      let bp = layout.bufferPoint(x: c.x, y: c.y)
      logger?.log("Overlay circle: input=(\(c.x),\(c.y)) r=\(c.radius) -> buffer=(\(bp.x),\(bp.y)) r=\(layout.bufferSize(width: c.radius, height: 0).width) [scale=\(layout.overlayScale), buffer=\(layout.bufferWidth)x\(layout.bufferHeight)]")
      renderCircle(c, layout: layout, context: context, elapsed: elapsed)
    case .rectangle(let r):
      let br = layout.bufferRect(x: r.x, y: r.y, width: r.width, height: r.height)
      logger?.log("Overlay rect: input=(\(r.x),\(r.y),\(r.width),\(r.height)) -> buffer=(\(br.origin.x),\(br.origin.y),\(br.size.width),\(br.size.height)) [scale=\(layout.overlayScale), buffer=\(layout.bufferWidth)x\(layout.bufferHeight)]")
      renderRectangle(r, layout: layout, context: context, elapsed: elapsed)
    case .label(let l):
      renderLabel(l, layout: layout, context: context)
    }
  }

  // MARK: - Circle

  private func renderCircle(_ circle: OverlayShape.Circle, layout: OverlayCoordinateTransform, context: CGContext, elapsed: CFTimeInterval) {
    let alpha = effectAlpha(circle.effect, baseAlpha: circleAlpha(circle.rgba), elapsed: elapsed)
    guard alpha > 0 else { return }

    var center = layout.bufferPoint(x: circle.x, y: circle.y)
    if let effect = circle.effect {
      center = effectPosition(effect, base: center, layout: layout, elapsed: elapsed)
    }

    let color = CGColor(
      red: circleRed(circle.rgba),
      green: circleGreen(circle.rgba),
      blue: circleBlue(circle.rgba),
      alpha: alpha
    )
    context.setFillColor(color)
    let scaledRadius = layout.bufferSize(width: circle.radius, height: 0).width
    let rect = CGRect(
      x: center.x - scaledRadius,
      y: center.y - scaledRadius,
      width: scaledRadius * 2,
      height: scaledRadius * 2
    )
    context.fillEllipse(in: rect)
  }

  // MARK: - Rectangle

  private func renderRectangle(_ rect: OverlayShape.Rectangle, layout: OverlayCoordinateTransform, context: CGContext, elapsed: CFTimeInterval) {
    let alpha = effectAlpha(rect.effect, baseAlpha: circleAlpha(rect.rgba), elapsed: elapsed)
    guard alpha > 0 else { return }

    let r = layout.bufferRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)

    let color = CGColor(
      red: circleRed(rect.rgba),
      green: circleGreen(rect.rgba),
      blue: circleBlue(rect.rgba),
      alpha: alpha
    )
    context.setFillColor(color)
    context.fill(r)
  }

  // MARK: - Label

  private func renderLabel(_ label: OverlayShape.Label, layout: OverlayCoordinateTransform, context: CGContext) {
    let (fontName, baseFontSize) = parseFontSpec(label.font)
    let fontSize = layout.labelFontSize(baseFontSize)
    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let attributes: [NSAttributedString.Key: Any] = [
      .init(rawValue: kCTFontAttributeName as String): font,
      .init(rawValue: kCTForegroundColorAttributeName as String): white,
    ]
    let attrString = NSAttributedString(string: label.text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attrString)

    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let origin = layout.labelOrigin(padding: label.padding, ascent: ascent, descent: descent)
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }

  // MARK: - Font Parsing

  /// Parse a Pango-style font spec "FontName Size" (e.g. "Monaco 8").
  func parseFontSpec(_ spec: String) -> (String, CGFloat) {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return ("Monaco", 8) }
    if let lastSpace = trimmed.lastIndex(of: " ") {
      let name = String(trimmed[trimmed.startIndex..<lastSpace])
      let sizeStr = String(trimmed[trimmed.index(after: lastSpace)...])
      if let size = Double(sizeStr), size > 0 {
        return (name, CGFloat(size))
      }
    }
    return (trimmed, 8)
  }

  // MARK: - Status Bars

  private func renderBarIfActive(_ position: String, layout: OverlayCoordinateTransform, context: CGContext) {
    let content = barContent[position] ?? .hidden
    let text: String
    switch content {
    case .text(let t):
      text = t
    case .stats:
      text = statsText[position] ?? ""
    case .hidden:
      return
    }
    let mode = barMode[position] ?? .pad
    let fit = barFit[position] ?? false
    drawStatusBar(
      text: text,
      fontSize: layout.barFontSize(),
      barY: layout.barY(position: position),
      barHeight: layout.barHeight(),
      width: CGFloat(layout.bufferWidth),
      mode: mode,
      fit: fit,
      context: context
    )
  }

  private func drawStatusBar(
    text: String,
    fontSize: CGFloat,
    barY: CGFloat,
    barHeight: CGFloat,
    width: CGFloat,
    mode: BarMode,
    fit: Bool,
    context: CGContext
  ) {
    let padding: CGFloat = 4

    let bgAlpha: CGFloat = mode == .overlay ? 0.7 : 1.0
    let bgColor = CGColor(red: 0, green: 0, blue: 0, alpha: bgAlpha)
    context.setFillColor(bgColor)
    context.fill(CGRect(x: 0, y: barY, width: width, height: barHeight))

    let availableWidth = width - padding * 2
    let (font, line) = makeLine(text: text, fontSize: fontSize, availableWidth: availableWidth, fit: fit)

    let ascent = CTFontGetAscent(font)
    let drawY = barY + padding + ascent
    context.saveGState()
    context.translateBy(x: padding, y: drawY)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }

  /// Build the bar's `CTLine` at the requested point size, optionally shrinking to fit.
  /// Returns the final `CTFont` (for ascent measurement) and the laid-out `CTLine`.
  private func makeLine(text: String, fontSize: CGFloat, availableWidth: CGFloat, fit: Bool) -> (CTFont, CTLine) {
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    func buildLine(_ size: CGFloat) -> (CTFont, CTLine) {
      let font = CTFontCreateWithName("Monaco" as CFString, size, nil)
      let attributes: [NSAttributedString.Key: Any] = [
        .init(rawValue: kCTFontAttributeName as String): font,
        .init(rawValue: kCTForegroundColorAttributeName as String): white,
      ]
      let attrString = NSAttributedString(string: text, attributes: attributes)
      return (font, CTLineCreateWithAttributedString(attrString))
    }
    let (font, line) = buildLine(fontSize)
    guard fit else {
      return (font, line)
    }
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    guard textWidth > availableWidth, textWidth > 0 else {
      return (font, line)
    }
    let shrunkSize = fontSize * (availableWidth / textWidth)
    return buildLine(shrunkSize)
  }

  // MARK: - Effect Helpers

  private func effectForShape(_ shape: OverlayShape) -> OverlayShape.Effect? {
    switch shape {
    case .circle(let c): return c.effect
    case .rectangle(let r): return r.effect
    case .label: return nil
    }
  }

  private func circleRed(_ rgba: [CGFloat]) -> CGFloat { rgba.count > 0 ? rgba[0] / 255.0 : 0 }
  private func circleGreen(_ rgba: [CGFloat]) -> CGFloat { rgba.count > 1 ? rgba[1] / 255.0 : 0 }
  private func circleBlue(_ rgba: [CGFloat]) -> CGFloat { rgba.count > 2 ? rgba[2] / 255.0 : 0 }
  private func circleAlpha(_ rgba: [CGFloat]) -> CGFloat { rgba.count > 3 ? rgba[3] : 1 }

  private func effectAlpha(_ effect: OverlayShape.Effect?, baseAlpha: CGFloat, elapsed: CFTimeInterval) -> CGFloat {
    guard let effect else { return baseAlpha }
    switch effect {
    case .fadeout(let fade):
      let progress = min(1.0, elapsed / (Double(fade.durationMs) / 1000.0))
      return baseAlpha * CGFloat(1.0 - progress)
    case .fadein(let fade):
      let progress = min(1.0, elapsed / (Double(fade.durationMs) / 1000.0))
      return baseAlpha * CGFloat(progress)
    case .translate:
      return baseAlpha
    }
  }

  private func effectPosition(_ effect: OverlayShape.Effect, base: CGPoint, layout: OverlayCoordinateTransform, elapsed: CFTimeInterval) -> CGPoint {
    switch effect {
    case .translate(let t):
      let progress = min(1.0, elapsed / (Double(t.durationMs) / 1000.0))
      let target = layout.translateTarget(x: t.x, y: t.y)
      let x = base.x + (target.x - base.x) * CGFloat(progress)
      let y = base.y + (target.y - base.y) * CGFloat(progress)
      return CGPoint(x: x, y: y)
    default:
      return base
    }
  }

  private func isEffectActive(_ effect: OverlayShape.Effect?, elapsed: CFTimeInterval) -> Bool {
    guard let effect else { return false }
    switch effect {
    case .fadeout(let fade): return elapsed < Double(fade.durationMs) / 1000.0
    case .fadein(let fade): return elapsed < Double(fade.durationMs) / 1000.0
    case .translate(let t): return elapsed < Double(t.durationMs) / 1000.0
    }
  }
}
