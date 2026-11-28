/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
@testable import FBSimulatorVideo
import FBVideoCore
import XCTest

final class FramePusherPoolTests: XCTestCase {
  private let size = VideoFrameSource(width: 1398, height: 2034, pixelFormat: kCVPixelFormatType_32BGRA)

  func testAKeptPusherIsTakenOnce() {
    var pool = FramePusherPool()
    let pusher = BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil)
    XCTAssertNil(pool.keep(pusher, for: size))
    XCTAssertTrue(pool.contains(size))
    XCTAssertTrue(pool.take(size) === pusher)
    XCTAssertNil(pool.take(size))
  }

  func testKeepingASecondPusherForASourceReturnsTheFirst() {
    var pool = FramePusherPool()
    let first = BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil)
    let second = BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil)
    _ = pool.keep(first, for: size)
    XCTAssertTrue(pool.keep(second, for: size) === first)
    XCTAssertTrue(pool.take(size) === second)
  }

  func testRemovingAllEmptiesThePool() {
    var pool = FramePusherPool()
    _ = pool.keep(BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil), for: size)
    _ = pool.keep(BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil), for: VideoFrameSource(width: 2007, height: 2853, pixelFormat: kCVPixelFormatType_32BGRA))
    XCTAssertEqual(pool.removeAll().count, 2)
    XCTAssertFalse(pool.contains(size))
  }

  func testASourceIsAPositiveWholeNumberOfPixels() {
    let bgra = kCVPixelFormatType_32BGRA
    XCTAssertEqual(VideoFrameSource(CGSize(width: 2007, height: 2853), pixelFormat: bgra), VideoFrameSource(width: 2007, height: 2853, pixelFormat: bgra))
    XCTAssertNil(VideoFrameSource(CGSize(width: 2007.5, height: 2853), pixelFormat: bgra))
    XCTAssertNil(VideoFrameSource(CGSize(width: 0, height: 2853), pixelFormat: bgra))
  }

  func testAPusherIsTakenOnlyForItsPixelFormat() {
    var pool = FramePusherPool()
    _ = pool.keep(BitmapFramePusher(consumer: AccumulatingBuffer(), scaleFactor: nil), for: size)
    XCTAssertNil(pool.take(VideoFrameSource(width: size.width, height: size.height, pixelFormat: kCVPixelFormatType_32RGBA)))
    XCTAssertNotNil(pool.take(size))
  }

}
