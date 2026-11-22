/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBControlCore
import Foundation
import Testing

@Suite
struct ScreenshotConfigurationTests {

  /// A 3x retina phone screen: 828x1792 pixels, 276x597 points.
  private let sourceSize = CGSize(width: 828, height: 1792)
  private let screenScale = 3.0

  /// `.some(nil)` asks for a target that does not report a screen scale; omitting the argument uses
  /// the 3x default.
  private func plan(
    _ configuration: ScreenshotConfiguration,
    sourceSize: CGSize? = nil,
    screenScale: Double?? = nil
  ) throws -> ScreenshotPlan {
    try ScreenshotGeometry.plan(
      for: configuration,
      sourceSize: sourceSize ?? self.sourceSize,
      screenScale: screenScale ?? self.screenScale
    )
  }

  private func assertThrows(
    _ expected: ScreenshotGeometryError,
    _ configuration: ScreenshotConfiguration,
    sourceSize: CGSize? = nil,
    screenScale: Double?? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let error = #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try plan(configuration, sourceSize: sourceSize, screenScale: screenScale) }
    if let error {
      #expect(String(reflecting: error) == String(reflecting: expected), sourceLocation: sourceLocation)
    }
  }

  // MARK: - Defaults

  @Test
  func defaultConfigurationIsAnIdentityTransform() throws {
    let result = try plan(ScreenshotConfiguration())
    #expect(result.isIdentity)
    #expect(result.cropRect == nil)
    #expect(result.scaleFactor == 1)
    #expect(result.outputSize == sourceSize)
  }

  @Test
  func compressionQualityExistsOnlyOnJPEG() {
    #expect(ScreenshotEncoding.png.compressionQuality == nil)
    #expect(ScreenshotEncoding.tiff.compressionQuality == nil)
    #expect(ScreenshotEncoding.jpeg(quality: 0.6).compressionQuality == 0.6)
  }

  // MARK: - Scale factor

  @Test
  func scaleFactorHalvesBothDimensions() throws {
    let result = try plan(ScreenshotConfiguration(scale: .factor(0.5)))
    #expect(result.scaleFactor == 0.5)
    #expect(result.outputSize == CGSize(width: 414, height: 896))
    #expect(!result.isIdentity)
  }

  @Test
  func scaleFactorOfOneIsAnIdentityTransform() throws {
    let result = try plan(ScreenshotConfiguration(scale: .factor(1)))
    #expect(result.isIdentity)
  }

  @Test
  func scaleFactorMustBeInRange() {
    assertThrows(.scaleFactorOutOfRange(0), ScreenshotConfiguration(scale: .factor(0)))
    assertThrows(.scaleFactorOutOfRange(-0.5), ScreenshotConfiguration(scale: .factor(-0.5)))
    assertThrows(.scaleFactorOutOfRange(1.5), ScreenshotConfiguration(scale: .factor(1.5)))
  }

  // MARK: - Fit

  @Test
  func fitOnWidthAlone() throws {
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: 414, maxHeight: nil)))
    #expect(result.scaleFactor == 0.5)
    #expect(result.outputSize == CGSize(width: 414, height: 896))
  }

  @Test
  func fitOnHeightAlone() throws {
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: nil, maxHeight: 896)))
    #expect(result.scaleFactor == 0.5)
    #expect(result.outputSize == CGSize(width: 414, height: 896))
  }

  /// A tall screen inside a square box is bounded by its height, not its width.
  @Test
  func moreRestrictiveFitBoundWins() throws {
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: 400, maxHeight: 400)))
    #expect(abs(result.scaleFactor - 400.0 / 1792.0) <= 1e-12)
    #expect(result.outputSize == CGSize(width: 185, height: 400))
  }

  @Test
  func fitNeverUpscales() throws {
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: 4000, maxHeight: 4000)))
    #expect(result.scaleFactor == 1)
    #expect(result.outputSize == sourceSize)
    #expect(result.isIdentity)
  }

  @Test
  func fitNeedsABound() {
    assertThrows(.fitBoundsEmpty, ScreenshotConfiguration(scale: .fit(maxWidth: nil, maxHeight: nil)))
  }

  @Test
  func fitBoundsMustBePositive() {
    assertThrows(.fitBoundNotPositive(0), ScreenshotConfiguration(scale: .fit(maxWidth: 0, maxHeight: nil)))
    assertThrows(.fitBoundNotPositive(-100), ScreenshotConfiguration(scale: .fit(maxWidth: nil, maxHeight: -100)))
  }

  /// A tight bound is legal; the one-pixel floor keeps the result from degenerating.
  @Test
  func extremelyTightFitBoundProducesTheSmallestHonestImage() throws {
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: 1, maxHeight: nil)))
    #expect(result.outputSize == CGSize(width: 1, height: 2))
  }

  // MARK: - Units

  @Test
  func fitBoundsInPointsAreResolvedAgainstTheScreenScale() throws {
    // 138 points on a 3x screen is 414 pixels, half of the 828-pixel width.
    let result = try plan(ScreenshotConfiguration(scale: .fit(maxWidth: 138, maxHeight: nil), unit: .points))
    #expect(result.scaleFactor == 0.5)
    #expect(result.outputSize == CGSize(width: 414, height: 896))
  }

  @Test
  func cropInPointsIsResolvedAgainstTheScreenScale() throws {
    let configuration = ScreenshotConfiguration(cropRect: CGRect(x: 10, y: 20, width: 30, height: 40), unit: .points)
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 30, y: 60, width: 90, height: 120))
    #expect(result.outputSize == CGSize(width: 90, height: 120))
  }

  @Test
  func pointsAndPixelsAgreeOnAOnexScreen() throws {
    let configuration = ScreenshotConfiguration(cropRect: CGRect(x: 10, y: 20, width: 30, height: 40), unit: .points)
    let result = try plan(configuration, sourceSize: CGSize(width: 400, height: 600), screenScale: 1)
    #expect(result.cropRect == CGRect(x: 10, y: 20, width: 30, height: 40))
  }

  /// A physical device does not report a screen scale, so points cannot be resolved there.
  @Test
  func pointsAgainstATargetWithNoScreenScaleIsRejected() {
    assertThrows(
      .screenScaleUnknown,
      ScreenshotConfiguration(cropRect: CGRect(x: 0, y: 0, width: 10, height: 10), unit: .points),
      screenScale: .some(nil)
    )
    assertThrows(
      .screenScaleUnknown,
      ScreenshotConfiguration(scale: .fit(maxWidth: 100, maxHeight: nil), unit: .points),
      screenScale: .some(nil)
    )
  }

  /// With no crop and no fit bound there is nothing to convert, so the screen scale is not consulted.
  @Test
  func pointsWithNothingToConvertNeedsNoScreenScale() throws {
    let result = try plan(ScreenshotConfiguration(unit: .points), screenScale: .some(nil))
    #expect(result.cropRect == nil)
    #expect(result.scaleFactor == 1)
    #expect(result.outputSize == sourceSize)
    #expect(result.isIdentity)
  }

  /// A scale factor is a ratio rather than a measurement, so it is the same number in either unit.
  @Test
  func pointsWithOnlyAScaleFactorNeedsNoScreenScale() throws {
    let configuration = ScreenshotConfiguration(scale: .factor(0.5), unit: .points)
    let result = try plan(configuration, screenScale: .some(nil))
    #expect(result.cropRect == nil)
    #expect(result.outputSize == CGSize(width: 414, height: 896))
  }

  @Test
  func onlyMeasurementsInPointsRequireAScreenScale() {
    #expect(!(ScreenshotConfiguration(unit: .points).requiresScreenScale))
    #expect(!(ScreenshotConfiguration(scale: .factor(0.5), unit: .points).requiresScreenScale))
    #expect(!(ScreenshotConfiguration(cropRect: CGRect(x: 0, y: 0, width: 10, height: 10)).requiresScreenScale))
    #expect(!(ScreenshotConfiguration(scale: .fit(maxWidth: 100, maxHeight: nil)).requiresScreenScale))
    #expect(
      ScreenshotConfiguration(cropRect: CGRect(x: 0, y: 0, width: 10, height: 10), unit: .points)
        .requiresScreenScale)
    #expect(ScreenshotConfiguration(scale: .fit(maxWidth: 100, maxHeight: nil), unit: .points).requiresScreenScale)
  }

  @Test
  func pixelsNeedNoScreenScale() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 0, y: 0, width: 400, height: 400),
      scale: .factor(0.5)
    )
    let result = try plan(configuration, screenScale: .some(nil))
    #expect(result.cropRect == CGRect(x: 0, y: 0, width: 400, height: 400))
    #expect(result.outputSize == CGSize(width: 200, height: 200))
  }

  @Test
  func nonPositiveScreenScaleIsTreatedAsUnknown() {
    assertThrows(
      .screenScaleUnknown,
      ScreenshotConfiguration(cropRect: CGRect(x: 0, y: 0, width: 10, height: 10), unit: .points),
      screenScale: 0
    )
  }

  @Test
  func cropInPixelsIgnoresTheScreenScale() throws {
    let configuration = ScreenshotConfiguration(cropRect: CGRect(x: 10, y: 20, width: 30, height: 40))
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 10, y: 20, width: 30, height: 40))
  }

  // MARK: - Crop

  @Test
  func cropIsRoundedOutToWholePixels() throws {
    let configuration = ScreenshotConfiguration(cropRect: CGRect(x: 10.4, y: 20.6, width: 30.2, height: 40.9))
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 10, y: 20, width: 31, height: 42))
  }

  @Test
  func cropOverhangingTheScreenIsClamped() throws {
    let configuration = ScreenshotConfiguration(cropRect: CGRect(x: 800, y: 1700, width: 100, height: 200))
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 800, y: 1700, width: 28, height: 92))
    #expect(result.outputSize == CGSize(width: 28, height: 92))
  }

  @Test
  func cropEntirelyOffTheScreenIsRejected() {
    let cropRect = CGRect(x: 900, y: 0, width: 100, height: 100)
    assertThrows(
      .cropOutsideBounds(cropRect: cropRect, sourceSize: sourceSize),
      ScreenshotConfiguration(cropRect: cropRect)
    )
  }

  @Test
  func cropWithNoExtentIsRejected() {
    let zeroWidth = CGRect(x: 0, y: 0, width: 0, height: 100)
    assertThrows(.cropExtentNotPositive(zeroWidth), ScreenshotConfiguration(cropRect: zeroWidth))
    let negativeHeight = CGRect(x: 0, y: 0, width: 100, height: -10)
    assertThrows(.cropExtentNotPositive(negativeHeight), ScreenshotConfiguration(cropRect: negativeHeight))
  }

  // MARK: - Crop and scale together

  @Test
  func scaleAppliesToTheCroppedRegion() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 0, y: 0, width: 400, height: 400),
      scale: .fit(maxWidth: 200, maxHeight: nil)
    )
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 0, y: 0, width: 400, height: 400))
    #expect(result.scaleFactor == 0.5)
    #expect(result.outputSize == CGSize(width: 200, height: 200))
  }

  @Test
  func scaleAppliesToTheClampedCropNotTheRequestedOne() throws {
    let configuration = ScreenshotConfiguration(
      cropRect: CGRect(x: 428, y: 0, width: 800, height: 400),
      scale: .factor(0.5)
    )
    let result = try plan(configuration)
    #expect(result.cropRect == CGRect(x: 428, y: 0, width: 400, height: 400))
    #expect(result.outputSize == CGSize(width: 200, height: 200))
  }

  // MARK: - Rounding

  /// Half rounds up, not to even, for parity with client-side resizers.
  @Test
  func outputRoundsHalfUp() {
    #expect(ScreenshotGeometry.outputSize(baseSize: CGSize(width: 5, height: 7), factor: 0.5) == CGSize(width: 3, height: 4))
    #expect(ScreenshotGeometry.roundToPixels(2.5) == 3)
    #expect(ScreenshotGeometry.roundToPixels(3.5) == 4)
    #expect(ScreenshotGeometry.roundToPixels(2.49) == 2)
  }

  @Test
  func outputIsFlooredAtOnePixelPerSide() {
    let size = ScreenshotGeometry.outputSize(baseSize: CGSize(width: 100, height: 100), factor: 0.001)
    #expect(size == CGSize(width: 1, height: 1))
  }

  @Test
  func emptySourceIsRejected() {
    assertThrows(.sourceSizeNotPositive(.zero), ScreenshotConfiguration(), sourceSize: .zero)
  }
}
