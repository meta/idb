#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import base64

from idb.common.types import (
    IdbException,
    ScreenshotCrop,
    ScreenshotFormat,
    ScreenshotOptions,
    ScreenshotUnit,
)
from idb.grpc.idb_pb2 import ScreenshotRequest, ScreenshotResponse
from idb.grpc.screenshot import screenshot_from_grpc, screenshot_to_grpc
from idb.utils.testing import TestCase


def _size(width: int, height: int) -> ScreenshotResponse.Size:
    return ScreenshotResponse.Size(width=width, height=height)


def _response(**kwargs: object) -> ScreenshotResponse:
    defaults: dict[str, object] = {
        "image_data": b"image",
        "image_format": "png",
        "destination": _size(100, 200),
        "source": _size(100, 200),
        "screen_scale": 2,
    }
    # pyre-ignore[6]: the proto constructor is not typed per-field here.
    return ScreenshotResponse(**{**defaults, **kwargs})


class ScreenshotTests(TestCase):
    def test_absent_context_is_backward_compatible(self) -> None:
        screenshot = screenshot_from_grpc(ScreenshotOptions(), _response())
        self.assertIsNone(screenshot.app_context)
        self.assertEqual(b"image", bytes(screenshot))

    def test_application_context_is_transported_without_certifying_source(self) -> None:
        response = _response()
        context = response.app_context
        context.version = 1
        context.state = 1
        context.target_udid = "target-1"
        context.display_id = "display-1"
        context.capture_started_at_ms = 2
        context.capture_finished_at_ms = 3
        for observation, timestamp in ((context.before, 1), (context.after, 4)):
            observation.app_name = "App"
            observation.bundle_id = "com.example"
            observation.installed_build_uuid = "build-1"
            observation.process_id = 123
            observation.observed_at_ms = timestamp
        screenshot = screenshot_from_grpc(ScreenshotOptions(), response)
        self.assertIsNotNone(screenshot.app_context)
        self.assertEqual("build-1", screenshot.app_context.before.installed_build_uuid)
        self.assertEqual(b"image", bytes(screenshot))
        context.version = 999
        self.assertIsNone(
            screenshot_from_grpc(ScreenshotOptions(), response).app_context
        )
        context.version = 1
        context.state = 999
        self.assertIsNone(
            screenshot_from_grpc(ScreenshotOptions(), response).app_context
        )

    # Request

    def test_default_options_are_an_empty_request(self) -> None:
        # Every field defaults to 0 on the wire, so a caller who asks for
        # nothing sends exactly what idb sent before the request had fields.
        self.assertEqual(screenshot_to_grpc(ScreenshotOptions()), ScreenshotRequest())

    def test_every_format_maps(self) -> None:
        for format, expected in [
            (ScreenshotFormat.PNG, ScreenshotRequest.PNG),
            (ScreenshotFormat.JPEG, ScreenshotRequest.JPEG),
            (ScreenshotFormat.TIFF, ScreenshotRequest.TIFF),
        ]:
            request = screenshot_to_grpc(ScreenshotOptions(format=format))
            self.assertEqual(request.format, expected)

    def test_every_unit_maps(self) -> None:
        for unit, expected in [
            (ScreenshotUnit.PIXELS, ScreenshotRequest.PIXELS),
            (ScreenshotUnit.POINTS, ScreenshotRequest.POINTS),
        ]:
            request = screenshot_to_grpc(ScreenshotOptions(unit=unit))
            self.assertEqual(request.unit, expected)

    def test_compression_quality_is_carried(self) -> None:
        request = screenshot_to_grpc(
            ScreenshotOptions(format=ScreenshotFormat.JPEG, compression_quality=0.35)
        )
        self.assertEqual(request.compression_quality, 0.35)

    def test_an_unset_compression_quality_asks_for_the_default(self) -> None:
        # 0 is not a legal quality, so it is unambiguously "unset" on the wire.
        self.assertEqual(
            screenshot_to_grpc(
                ScreenshotOptions(format=ScreenshotFormat.JPEG)
            ).compression_quality,
            0,
        )

    def test_a_crop_is_carried(self) -> None:
        request = screenshot_to_grpc(
            ScreenshotOptions(crop=ScreenshotCrop(x=10, y=20, width=30, height=40))
        )
        self.assertTrue(request.HasField("crop"))
        self.assertEqual(
            request.crop, ScreenshotRequest.Rect(x=10, y=20, width=30, height=40)
        )

    def test_no_crop_captures_the_full_screen(self) -> None:
        self.assertFalse(screenshot_to_grpc(ScreenshotOptions()).HasField("crop"))

    def test_a_scale_factor_is_carried(self) -> None:
        request = screenshot_to_grpc(ScreenshotOptions(scale_factor=0.5))
        self.assertEqual(request.WhichOneof("scale"), "scale_factor")
        self.assertEqual(request.scale_factor, 0.5)

    def test_fit_bounds_are_carried_with_zero_meaning_unbounded(self) -> None:
        for options, expected in [
            (
                ScreenshotOptions(max_width=100, max_height=200),
                ScreenshotRequest.Fit(max_width=100, max_height=200),
            ),
            (
                ScreenshotOptions(max_width=100),
                ScreenshotRequest.Fit(max_width=100, max_height=0),
            ),
            (
                ScreenshotOptions(max_height=200),
                ScreenshotRequest.Fit(max_width=0, max_height=200),
            ),
        ]:
            request = screenshot_to_grpc(options)
            self.assertEqual(request.WhichOneof("scale"), "fit")
            self.assertEqual(request.fit, expected)

    def test_no_scale_is_a_native_capture(self) -> None:
        self.assertIsNone(screenshot_to_grpc(ScreenshotOptions()).WhichOneof("scale"))

    def test_a_factor_and_a_bounding_box_together_are_rejected(self) -> None:
        # The wire carries one or the other, so sending both is impossible and
        # silently dropping one would be a screenshot of the wrong size.
        with self.assertRaises(ValueError):
            ScreenshotOptions(scale_factor=0.5, max_width=100)
        with self.assertRaises(ValueError):
            ScreenshotOptions(scale_factor=0.5, max_height=100)

    def test_a_compression_quality_outside_the_range_is_rejected(self) -> None:
        # 0 is "unset" on the wire, so a companion cannot tell a deliberate 0
        # from an absent field: it would hand back a JPEG at its own default and
        # report success. This is the one range check that has to be local.
        for quality in [0, -0.5, 1.5]:
            with self.subTest(compression_quality=quality):
                with self.assertRaises(ValueError):
                    ScreenshotOptions(compression_quality=quality)
        self.assertEqual(
            screenshot_to_grpc(
                ScreenshotOptions(compression_quality=1)
            ).compression_quality,
            1,
        )

    def test_a_fit_bound_below_one_is_rejected(self) -> None:
        # The wire field is a uint32, so a negative bound raises out of protobuf
        # before any validation runs, and 0 already means "unbounded".
        for bound in [0, -1]:
            with self.subTest(bound=bound):
                with self.assertRaises(ValueError):
                    ScreenshotOptions(max_width=bound)
                with self.assertRaises(ValueError):
                    ScreenshotOptions(max_height=bound)

    # Response

    def test_the_screenshot_carries_every_measurement(self) -> None:
        screenshot = screenshot_from_grpc(
            ScreenshotOptions(format=ScreenshotFormat.JPEG),
            _response(
                image_data=b"jpeg bytes",
                image_format="jpeg",
                destination=_size(200, 100),
                source=_size(828, 1792),
                screen_scale=3,
            ),
        )
        self.assertEqual(screenshot, b"jpeg bytes")
        self.assertEqual(screenshot.format, ScreenshotFormat.JPEG)
        self.assertEqual(screenshot.width, 200)
        self.assertEqual(screenshot.height, 100)
        self.assertEqual(screenshot.source_width, 828)
        self.assertEqual(screenshot.source_height, 1792)
        self.assertEqual(screenshot.screen_scale, 3)

    def test_a_screenshot_is_still_bytes(self) -> None:
        # Callers written against the old return type write it to files, base64
        # it and isinstance-check it. All of that has to keep working.
        screenshot = screenshot_from_grpc(ScreenshotOptions(), _response())
        self.assertIsInstance(screenshot, bytes)
        self.assertEqual(base64.b64encode(screenshot), base64.b64encode(b"image"))
        self.assertEqual(len(screenshot), len(b"image"))

    def test_an_unreported_measurement_is_none(self) -> None:
        # 0 is never a real measurement, so it is the companion saying it does
        # not have one rather than a screen of zero height.
        screenshot = screenshot_from_grpc(
            ScreenshotOptions(), _response(screen_scale=0, source=_size(0, 1792))
        )
        self.assertIsNone(screenshot.screen_scale)
        self.assertIsNone(screenshot.source_width)

    def test_the_repr_says_when_a_measurement_is_missing(self) -> None:
        # "NonexNone" reads as a measurement rather than the absence of one, and
        # this repr exists to be read in a traceback.
        self.assertIn(
            "size=200x100",
            repr(
                screenshot_from_grpc(
                    ScreenshotOptions(), _response(destination=_size(200, 100))
                )
            ),
        )
        self.assertIn(
            "size=unreported",
            repr(
                screenshot_from_grpc(
                    ScreenshotOptions(), ScreenshotResponse(image_data=b"png")
                )
            ),
        )

    def test_an_old_companion_still_serves_a_default_screenshot(self) -> None:
        # An empty image_format means a companion from before the request had
        # fields. It ignored the request, which for a default request is the
        # same thing as honouring it.
        screenshot = screenshot_from_grpc(
            ScreenshotOptions(), ScreenshotResponse(image_data=b"png bytes")
        )
        self.assertEqual(screenshot, b"png bytes")
        self.assertEqual(screenshot.format, ScreenshotFormat.PNG)
        self.assertIsNone(screenshot.width)

    def test_an_old_companion_cannot_serve_a_configured_screenshot(self) -> None:
        # It would return a full-screen PNG and nothing would say so.
        for options in [
            ScreenshotOptions(format=ScreenshotFormat.JPEG),
            ScreenshotOptions(scale_factor=0.5),
            ScreenshotOptions(crop=ScreenshotCrop(x=0, y=0, width=1, height=1)),
            ScreenshotOptions(unit=ScreenshotUnit.POINTS),
        ]:
            with self.assertRaises(IdbException):
                screenshot_from_grpc(options, ScreenshotResponse(image_data=b"png"))

    def test_a_format_the_companion_did_not_encode_is_rejected(self) -> None:
        # The companion never picks the format, so a mismatch means the bytes
        # are not what was asked for.
        with self.assertRaises(IdbException):
            screenshot_from_grpc(
                ScreenshotOptions(format=ScreenshotFormat.JPEG),
                _response(image_format="png"),
            )
