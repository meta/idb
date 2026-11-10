/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBControlCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite
struct ScreenshotRendererTests {

  /// The fixture is a 988x388 PNG, standing in for a capture that arrives already encoded.
  private let fixtureSize = CGSize(width: 988, height: 388)

  private func fixtureData() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: TestFixtures.photo0Path))
  }

  private func fixtureImage() throws -> CGImage {
    let data = try fixtureData()
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  /// Reads back what was actually encoded, rather than trusting the reported dimensions.
  private func decode(_ data: Data) throws -> (type: UTType, size: CGSize) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let identifier = try #require(CGImageSourceGetType(source) as String?)
    let type = try #require(UTType(identifier))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (type, CGSize(width: image.width, height: image.height))
  }

  private func render(_ configuration: ScreenshotConfiguration, screenScale: Double? = 2) throws -> ScreenshotResult {
    try ScreenshotRenderer.render(encoded: try fixtureData(), configuration: configuration, screenScale: screenScale)
  }

  // MARK: - Passthrough

  @Test
  func wholeScreenAsPNGReturnsTheCapturedBytesUntouched() throws {
    let data = try fixtureData()
    let result = try render(ScreenshotConfiguration())
    #expect(result.imageData == data)
    #expect(result.format == .png)
    #expect(result.size == fixtureSize)
    #expect(result.sourceSize == fixtureSize)
    #expect(result.screenScale == 2)
    #expect(result.displayID == nil, "encoded input does not identify a display")
  }

  @Test
  func anIdentifiedCaptureKeepsItsDisplayThroughEncoding() throws {
    let result = try ScreenshotRenderer.render(
      transformed: try fixtureImage(), sourceSize: fixtureSize, encoding: .jpeg(quality: 0.8),
      screenScale: 2, displayID: "captured-screen")
    #expect(result.displayID == "captured-screen")
    #expect(try decode(result.imageData).type == .jpeg)
    #expect(try decode(result.imageData).size == fixtureSize)
  }

  @Test
  func capturesWithoutADisplayIdentityRemainUnidentifiedThroughEncoding() throws {
    let image = try fixtureImage()
    let unidentified = try ScreenshotRenderer.render(
      transformed: image, sourceSize: fixtureSize, encoding: .png,
      screenScale: 2, displayID: nil)
    let emptyIdentity = try ScreenshotRenderer.render(
      transformed: image, sourceSize: fixtureSize, encoding: .png,
      screenScale: 2, displayID: "")
    #expect(unidentified.displayID == nil)
    #expect(emptyIdentity.displayID == nil)
    #expect(emptyIdentity.imageData == unidentified.imageData)
    #expect(try decode(emptyIdentity.imageData).size == fixtureSize)
  }

  @Test
  func wholeScreenInAnotherFormatIsReEncoded() throws {
    let data = try fixtureData()
    for encoding in [ScreenshotEncoding.jpeg(quality: 0.8), .tiff] {
      let result = try render(ScreenshotConfiguration(encoding: encoding))
      #expect(result.imageData != data)
      #expect(result.format == encoding.format)
      #expect(result.size == fixtureSize)
      let decoded = try decode(result.imageData)
      #expect(decoded.type == encoding.format.contentType)
      #expect(decoded.size == fixtureSize)
    }
  }

  // MARK: - Crop and scale on encoded input

  @Test
  func cropOnEncodedInput() throws {
    let result = try render(ScreenshotConfiguration(cropRect: CGRect(x: 100, y: 50, width: 200, height: 100)))
    #expect(result.size == CGSize(width: 200, height: 100))
    #expect(result.sourceSize == fixtureSize)
    #expect(try decode(result.imageData).size == CGSize(width: 200, height: 100))
  }

  @Test
  func scaleOnEncodedInput() throws {
    let result = try render(ScreenshotConfiguration(scale: .factor(0.5)))
    #expect(result.size == CGSize(width: 494, height: 194))
    #expect(try decode(result.imageData).size == CGSize(width: 494, height: 194))
  }

  @Test
  func fitOnEncodedInput() throws {
    let result = try render(ScreenshotConfiguration(scale: .fit(maxWidth: 247, maxHeight: nil)))
    #expect(result.size == CGSize(width: 247, height: 97))
    #expect(try decode(result.imageData).size == CGSize(width: 247, height: 97))
  }

  @Test
  func cropThenScaleOnEncodedInput() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 0, y: 0, width: 400, height: 200),
      scale: .factor(0.5)
    )
    let result = try render(configuration)
    #expect(result.size == CGSize(width: 200, height: 100))
    #expect(try decode(result.imageData).size == CGSize(width: 200, height: 100))
  }

  /// The crop is in points, so a 2x scale doubles it before it reaches the pixels.
  @Test
  func cropInPointsOnEncodedInput() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 0, y: 0, width: 100, height: 50),
      unit: .points
    )
    let result = try render(configuration, screenScale: 2)
    #expect(result.size == CGSize(width: 200, height: 100))
  }

  @Test
  func pointsWithoutAScreenScaleIsRejectedOnEncodedInput() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 0, y: 0, width: 100, height: 50),
      unit: .points
    )
    let error = #expect(throws: (any Error).self) { try render(configuration, screenScale: nil) }
    #expect(error.map { String(reflecting: $0) } == String(reflecting: ScreenshotGeometryError.screenScaleUnknown))
    #expect(throws: Never.self) { try render(ScreenshotConfiguration(), screenScale: nil) }
    // Points with nothing measured in them converts nothing, so it needs no scale either.
    #expect(throws: Never.self) { try render(ScreenshotConfiguration(unit: .points), screenScale: nil) }
  }

  @Test
  func unreadableInputIsRejected() {
    let data = Data("not an image".utf8)
    let error = #expect(throws: (any Error).self) {
      try ScreenshotRenderer.render(encoded: data, configuration: ScreenshotConfiguration(), screenScale: nil)
    }
    #expect(error.map { String(reflecting: $0) } == String(reflecting: ScreenshotRenderError.unreadableImageData))
  }

  // MARK: - Transform

  @Test
  func transformIsAnIdentityWhenThePlanIs() throws {
    let image = try fixtureImage()
    let plan = ScreenshotPlan(cropRect: nil, scaleFactor: 1, outputSize: fixtureSize)
    let transformed = try ScreenshotRenderer.transform(image, plan: plan)
    #expect(transformed === image)
  }

  @Test
  func transformCropsAndScales() throws {
    let image = try fixtureImage()
    let plan = ScreenshotPlan(
      cropRect: CGRect(x: 10, y: 20, width: 400, height: 200),
      scaleFactor: 0.25,
      outputSize: CGSize(width: 100, height: 50)
    )
    let transformed = try ScreenshotRenderer.transform(image, plan: plan)
    #expect(transformed.width == 100)
    #expect(transformed.height == 50)
  }

  @Test
  func transformSkipsAResampleThatWouldChangeNothing() throws {
    let image = try fixtureImage()
    let plan = ScreenshotPlan(cropRect: nil, scaleFactor: 0.9999, outputSize: fixtureSize)
    let transformed = try ScreenshotRenderer.transform(image, plan: plan)
    #expect(transformed === image)
  }

  /// `ScreenshotPlan` has a public memberwise initializer, so `transform` can receive an output size
  /// the geometry would never produce; it must fail with a named error, not a zero-sized CG context.
  @Test
  func transformRejectsAPlanWithNoOutput() throws {
    let image = try fixtureImage()
    for outputSize in [CGSize(width: 0, height: 10), CGSize(width: 10, height: 0), .zero] {
      let plan = ScreenshotPlan(cropRect: nil, scaleFactor: 1, outputSize: outputSize)
      let error = #expect(throws: (any Error).self, "\(outputSize)") { try ScreenshotRenderer.transform(image, plan: plan) }
      #expect(error.map { String(reflecting: $0) } == String(reflecting: ScreenshotRenderError.contextCreationFailed(size: outputSize)), "\(outputSize)")
    }
  }

  // MARK: - Encode

  @Test
  func encodeProducesTheRequestedContainer() throws {
    let image = try fixtureImage()
    for encoding in [ScreenshotEncoding.png, .tiff, .jpeg(quality: 0.8)] {
      let data = try ScreenshotRenderer.encode(image, encoding: encoding)
      let decoded = try decode(data)
      #expect(decoded.type == encoding.format.contentType, "\(encoding)")
      #expect(decoded.size == fixtureSize, "\(encoding)")
    }
  }

  @Test
  func jpegQualityChangesTheEncodedSize() throws {
    let image = try fixtureImage()
    let low = try ScreenshotRenderer.encode(image, encoding: .jpeg(quality: 0.1))
    let high = try ScreenshotRenderer.encode(image, encoding: .jpeg(quality: 0.95))
    #expect(low.count < high.count)
  }

  /// ImageIO silently clamps a quality outside (0, 1] and encodes anyway, so the encoder must reject
  /// it itself.
  @Test
  func encodeRejectsAQualityOutsideTheRange() throws {
    let image = try fixtureImage()
    for quality in [0.0, -0.5, 1.5] {
      let encoding = ScreenshotEncoding.jpeg(quality: quality)
      let error = #expect(throws: (any Error).self, "\(quality)") { try ScreenshotRenderer.encode(image, encoding: encoding) }
      #expect(error.map { String(reflecting: $0) } == String(reflecting: ScreenshotRenderError.compressionQualityOutOfRange(quality)), "\(quality)")
    }
    // NaN compares false against every bound, so it has to be rejected by the shape of the check
    // rather than by a comparison that happens to be true.
    #expect(throws: (any Error).self) { try ScreenshotRenderer.encode(image, encoding: .jpeg(quality: .nan)) }
    #expect(throws: Never.self) { try ScreenshotRenderer.encode(image, encoding: .jpeg(quality: 1)) }
  }

  @Test
  func tiffIsUncompressed() throws {
    let image = try fixtureImage()
    let tiff = try ScreenshotRenderer.encode(image, encoding: .tiff)
    let png = try ScreenshotRenderer.encode(image, encoding: .png)
    #expect(tiff.count > png.count)
    // At least three bytes per pixel, whether or not the encoder keeps an alpha channel. Anything
    // compressed comes in well under this for a photograph.
    #expect(tiff.count > Int(fixtureSize.width * fixtureSize.height) * 3)
  }
}
