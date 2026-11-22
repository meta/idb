/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import CoreGraphics
@preconcurrency import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import XCTest

/// Pins the `screenshot` request → configuration translation, the capture → response shape, and the
/// status code each geometry rejection is reported as. These are the wire contract: a field that
/// stops being honored, or a rejection that changes class, is a client-visible break.
final class ScreenshotRequestTranslationTests: XCTestCase {

  // MARK: - Helpers

  private func request(_ mutate: (inout Idb_ScreenshotRequest) -> Void = { _ in }) -> Idb_ScreenshotRequest {
    var request = Idb_ScreenshotRequest()
    mutate(&request)
    return request
  }

  private func configuration(
    _ mutate: (inout Idb_ScreenshotRequest) -> Void = { _ in }
  ) throws -> ScreenshotConfiguration {
    try ScreenshotRequestTranslation.configuration(from: request(mutate))
  }

  private func assertRejected(
    _ mutate: (inout Idb_ScreenshotRequest) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try configuration(mutate), file: file, line: line) { error in
      guard let status = error as? RPCError else {
        return XCTFail("expected a RPCError, got \(error)", file: file, line: line)
      }
      XCTAssertEqual(status.code, .invalidArgument, file: file, line: line)
      XCTAssertFalse(status.message.isEmpty, "a rejection must say why", file: file, line: line)
    }
  }

  func testAnEmptyRequestIsTheHistoricalBehaviour() throws {
    // Every field defaults to 0 on the wire, so an old client that only ever set `format` must
    // still get exactly what it got before the request gained fields: a full-screen native PNG.
    XCTAssertEqual(try configuration(), ScreenshotConfiguration())
  }

  // MARK: - Format and quality

  func testEveryWireFormatMaps() throws {
    XCTAssertEqual(try configuration { $0.format = .png }.encoding, .png)
    XCTAssertEqual(try configuration { $0.format = .tiff }.encoding, .tiff)
    XCTAssertEqual(
      try configuration { $0.format = .jpeg }.encoding,
      .jpeg(quality: ScreenshotEncoding.defaultJPEGQuality)
    )
  }

  func testJPEGCarriesItsQuality() throws {
    XCTAssertEqual(
      try configuration {
        $0.format = .jpeg
        $0.compressionQuality = 0.35
      }.encoding,
      .jpeg(quality: 0.35)
    )
  }

  func testFullQualityJPEGIsAccepted() throws {
    XCTAssertEqual(
      try configuration {
        $0.format = .jpeg
        $0.compressionQuality = 1
      }.encoding,
      .jpeg(quality: 1)
    )
  }

  func testQualityOutsideTheRangeIsRejected() {
    for quality in [-0.5, 1.0001, 2] {
      assertRejected {
        $0.format = .jpeg
        $0.compressionQuality = quality
      }
    }
  }

  func testQualityOnALosslessFormatIsRejected() {
    // Rather than silently ignored: a caller who set this believes they are getting a smaller image.
    assertRejected {
      $0.format = .png
      $0.compressionQuality = 0.5
    }
    assertRejected {
      $0.format = .tiff
      $0.compressionQuality = 0.5
    }
  }

  func testAnUnrecognizedFormatIsRejected() {
    // Unlike the accessibility formats, there is no historical default to degrade to that would not
    // be a lie about what the bytes are.
    assertRejected { $0.format = .UNRECOGNIZED(99) }
  }

  // MARK: - Crop

  func testAnUnsetCropCapturesTheFullScreen() throws {
    XCTAssertNil(try configuration().cropRect)
  }

  func testACropCarriesItsRect() throws {
    XCTAssertEqual(
      try configuration {
        $0.crop = .with {
          $0.x = 10
          $0.y = 20
          $0.width = 30
          $0.height = 40
        }
      }.cropRect,
      CGRect(x: 10, y: 20, width: 30, height: 40)
    )
  }

  func testAnAllZeroCropIsPresentRatherThanAbsent() throws {
    // Presence comes from the message, not from its contents, so an explicit empty rect reaches the
    // geometry and is rejected there instead of quietly becoming a full-screen capture.
    XCTAssertEqual(try configuration { $0.crop = Idb_ScreenshotRequest.Rect() }.cropRect, .zero)
  }

  // MARK: - Scale

  func testAnUnsetScaleIsNative() throws {
    XCTAssertEqual(try configuration().scale, .native)
  }

  func testAScaleFactorCarriesThrough() throws {
    XCTAssertEqual(try configuration { $0.scaleFactor = 0.5 }.scale, .factor(0.5))
  }

  func testFitBoundsMapWithZeroMeaningUnbounded() throws {
    XCTAssertEqual(
      try configuration {
        $0.fit = .with {
          $0.maxWidth = 100
          $0.maxHeight = 200
        }
      }.scale,
      .fit(maxWidth: 100, maxHeight: 200)
    )
    XCTAssertEqual(
      try configuration { $0.fit = .with { $0.maxWidth = 100 } }.scale,
      .fit(maxWidth: 100, maxHeight: nil)
    )
    XCTAssertEqual(
      try configuration { $0.fit = .with { $0.maxHeight = 200 } }.scale,
      .fit(maxWidth: nil, maxHeight: 200)
    )
  }

  func testAFitWithNoBoundsIsNotSilentlyNative() throws {
    // A caller who sent a `fit` at all meant to bound something. The geometry refuses this; turning
    // it into a native capture here would hide the mistake behind a plausible image.
    XCTAssertEqual(try configuration { $0.fit = Idb_ScreenshotRequest.Fit() }.scale, .fit(maxWidth: nil, maxHeight: nil))
  }

  // MARK: - Unit

  func testEveryWireUnitMaps() throws {
    XCTAssertEqual(try configuration { $0.unit = .pixels }.unit, .pixels)
    XCTAssertEqual(try configuration { $0.unit = .points }.unit, .points)
  }

  func testAnUnrecognizedUnitIsRejected() {
    // Guessing between pixels and points silently mis-crops by the screen scale.
    assertRejected { $0.unit = .UNRECOGNIZED(7) }
  }

  // MARK: - Response

  func testTheResponseCarriesEveryMeasurement() {
    let response = ScreenshotRequestTranslation.response(
      from: ScreenshotResult(
        imageData: Data([1, 2, 3]),
        format: .jpeg,
        size: CGSize(width: 200, height: 100),
        sourceSize: CGSize(width: 828, height: 1792),
        screenScale: 3
      )
    )
    XCTAssertEqual(response.imageData, Data([1, 2, 3]))
    XCTAssertEqual(response.imageFormat, "jpeg")
    XCTAssertEqual(response.destination.width, 200)
    XCTAssertEqual(response.destination.height, 100)
    XCTAssertEqual(response.source.width, 828)
    XCTAssertEqual(response.source.height, 1792)
    XCTAssertEqual(response.screenScale, 3)
  }

  func testAnUnknownScreenScaleIsReportedAsZero() {
    let response = ScreenshotRequestTranslation.response(
      from: ScreenshotResult(
        imageData: Data(),
        format: .png,
        size: CGSize(width: 1, height: 1),
        sourceSize: CGSize(width: 1, height: 1),
        screenScale: nil
      )
    )
    XCTAssertEqual(response.screenScale, 0, "0 is the documented 'this target does not report one' value")
  }

  func testTheReportedFormatNamesAreTheDocumentedOnes() {
    // These strings are on the wire, so they are not free to change with the Swift case names.
    XCTAssertEqual(
      ScreenshotImageFormat.allCases.map(\.rawValue).sorted(),
      ["jpeg", "png", "tiff"]
    )
  }

  /// `UInt32(_: CGFloat)` traps rather than saturating. A dimension that is negative, not a number
  /// or past the range of the field is a bug upstream, but reporting it as unknown keeps the image
  /// -- which is fine -- and the process, which the trap would not.
  func testAnUnreportableMeasurementIsZeroRatherThanACrash() {
    let expected: [(CGFloat, UInt32)] = [
      (.nan, 0),
      (.infinity, 0),
      (-1, 0),
      (0, 0),
      // Past the field, so it saturates rather than wrapping to something small and plausible.
      (CGFloat(UInt32.max) * 2, UInt32.max),
      (200.6, 201),
    ]
    for (width, reported) in expected {
      let response = ScreenshotRequestTranslation.response(
        from: ScreenshotResult(
          imageData: Data(),
          format: .png,
          size: CGSize(width: width, height: 1),
          sourceSize: CGSize(width: 1, height: 1),
          screenScale: nil
        )
      )
      XCTAssertEqual(response.destination.width, reported, "\(width)")
      XCTAssertEqual(response.destination.height, 1, "\(width)")
    }
  }

  // MARK: - Geometry rejections

  func testEveryGeometryRejectionHasAStatus() {
    // Not exhaustive by construction -- the error has associated values, so it is not CaseIterable.
    // A case added to ScreenshotGeometryError must be added here.
    let expected: [(ScreenshotGeometryError, RPCError.Code)] = [
      (.scaleFactorOutOfRange(2), .invalidArgument),
      (.fitBoundsEmpty, .invalidArgument),
      (.fitBoundNotPositive(0), .invalidArgument),
      (.cropExtentNotPositive(.zero), .invalidArgument),
      (
        .cropOutsideBounds(
          cropRect: CGRect(x: 900, y: 0, width: 10, height: 10),
          sourceSize: CGSize(width: 828, height: 1792)), .invalidArgument
      ),
      // Well formed, and the identical request succeeds on a simulator, so not invalidArgument.
      (.screenScaleUnknown, .failedPrecondition),
      (.sourceSizeNotPositive(.zero), .internalError),
    ]
    for (error, code) in expected {
      let status = ScreenshotRequestTranslation.status(for: error)
      XCTAssertEqual(status.code, code, "\(error)")
      XCTAssertFalse(status.message.isEmpty, "\(error) must say why")
    }
  }

  // MARK: - Render failures

  func testEveryRenderFailureHasAStatus() {
    // Not exhaustive by construction -- the error has associated values, so it is not CaseIterable.
    // A case added to ScreenshotRenderError must be added here.
    let expected: [(ScreenshotRenderError, RPCError.Code)] = [
      (.croppingFailed(cropRect: .zero, sourceSize: .zero), .internalError),
      (.contextCreationFailed(size: .zero), .internalError),
      (.scalingFailed(size: .zero), .internalError),
      (.destinationCreationFailed(format: .png), .internalError),
      (.encodingFailed(format: .png), .internalError),
      (.unreadableImageData, .internalError),
      (.unknownImageDimensions, .internalError),
      (.decodingFailed, .internalError),
      (.compressionQualityOutOfRange(2), .invalidArgument),
    ]
    for (error, code) in expected {
      let status = ScreenshotRequestTranslation.status(for: error)
      XCTAssertEqual(status.code, code, "\(error)")
      XCTAssertFalse(status.message.isEmpty, "\(error) must say why")
    }
  }

  // MARK: - End to end through the geometry

  func testARejectedRequestSurvivesTranslationAndIsCaughtByTheGeometry() throws {
    // The translation deliberately does not restate the geometry's rules, so a scale factor it
    // cannot honor has to pass through here and be refused there.
    let unhonorable = try configuration { $0.scaleFactor = 2 }
    XCTAssertThrowsError(
      try ScreenshotGeometry.plan(
        for: unhonorable,
        sourceSize: CGSize(width: 828, height: 1792),
        screenScale: 3
      )
    ) { error in
      guard let error = error as? ScreenshotGeometryError else {
        return XCTFail("expected a geometry error, got \(error)")
      }
      XCTAssertEqual(ScreenshotRequestTranslation.status(for: error).code, .invalidArgument)
    }
  }
}
