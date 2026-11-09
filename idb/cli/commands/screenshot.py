#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
import sys
from argparse import ArgumentParser, ArgumentTypeError, Namespace
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict
from typing import IO

from idb.cli import ClientCommand
from idb.common import plugin
from idb.common.types import (
    Client,
    CompanionInfo,
    IdbException,
    Screenshot,
    ScreenshotCrop,
    ScreenshotFormat,
    ScreenshotOptions,
    ScreenshotUnit,
)


def _crop(value: str) -> ScreenshotCrop:
    fields = value.split(",")
    if len(fields) != 4:
        raise ArgumentTypeError(f"expected X,Y,WIDTH,HEIGHT, got {value!r}")
    try:
        x, y, width, height = (float(field) for field in fields)
    except ValueError:
        raise ArgumentTypeError(f"expected four numbers, got {value!r}")
    return ScreenshotCrop(x=x, y=y, width=width, height=height)


class ScreenshotCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Take a Screenshot of the Target"

    @property
    def name(self) -> str:
        return "screenshot"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "dest_path",
            help="The destination file path to write to or - (dash) to write to stdout",
            type=str,
        )
        parser.add_argument(
            "--app-bundle-id",
            type=str,
            default=None,
            help="Capture this application's window instead of the whole target; requires a capture provider and default PNG options",
        )
        parser.add_argument(
            "--format",
            choices=[format.value for format in ScreenshotFormat],
            default=ScreenshotFormat.PNG.value,
            help="The encoding of the image (default: png)",
        )
        parser.add_argument(
            "--compression-quality",
            type=float,
            default=None,
            help=(
                "Quality of a lossy encoding, in (0, 1] (default: 0.8). Only "
                "meaningful with --format jpeg; setting it on a lossless format "
                "is an error rather than a no-op."
            ),
        )
        parser.add_argument(
            "--crop",
            type=_crop,
            default=None,
            help=(
                "Capture only X,Y,WIDTH,HEIGHT, from a top-left origin, in the "
                "units given by --units. A rect that partially overhangs the "
                "screen is clamped to it."
            ),
        )
        parser.add_argument(
            "--scale-factor",
            type=float,
            default=None,
            help=(
                "Scale the image by this factor, in (0, 1]. Cannot be combined "
                "with --max-width or --max-height."
            ),
        )
        parser.add_argument(
            "--max-width",
            type=int,
            default=None,
            help=(
                "Scale the image down to fit within this width, in the units "
                "given by --units. One factor is applied to both axes and the "
                "image is never scaled up, so the aspect ratio is preserved to "
                "within the rounding of each side to a whole pixel."
            ),
        )
        parser.add_argument(
            "--max-height",
            type=int,
            default=None,
            help="As --max-width, for the height. The two can be combined.",
        )
        parser.add_argument(
            "--units",
            choices=[unit.value for unit in ScreenshotUnit],
            default=ScreenshotUnit.PIXELS.value,
            help=(
                "The units --crop, --max-width and --max-height are expressed "
                "in (default: pixels). points is the coordinate space tap, "
                "swipe and describe use; it needs a target that reports a "
                "screen scale, which simulators do and devices do not."
            ),
        )
        super().add_parser_arguments(parser)

    def prepare_capture(self, args: Namespace) -> tuple[ScreenshotOptions, str | None]:
        """Resolve the pre-I/O capture intent used by all screenshot frontends."""
        if args.json and args.dest_path == "-":
            raise IdbException(
                "The image and the --json metadata cannot both go to stdout; "
                "write the image to a file"
            )
        options = self._options(args)
        bundle_id = getattr(args, "app_bundle_id", None)
        if bundle_id is not None:
            plugin.validate_app_screenshot_options(bundle_id, options)
        return options, bundle_id

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        options, bundle_id = self.prepare_capture(args)
        if bundle_id is None:
            screenshot = await client.screenshot(options=options)
        else:
            requested_udid = getattr(args, "udid", None)
            companion = getattr(client, "companion", None)
            if requested_udid is not None and (
                not isinstance(companion, CompanionInfo)
                or requested_udid != companion.udid
            ):
                raise IdbException(
                    "The connected companion does not match the requested target"
                )
            screenshot = await plugin.capture_app_screenshot(client, bundle_id, options)
        with screenshot_file(args.dest_path) as f:
            f.write(screenshot)
        if args.json:
            print(json.dumps(_metadata(screenshot)))

    def _options(self, args: Namespace) -> ScreenshotOptions:
        try:
            return ScreenshotOptions(
                format=ScreenshotFormat(args.format),
                compression_quality=args.compression_quality,
                crop=args.crop,
                scale_factor=args.scale_factor,
                max_width=args.max_width,
                max_height=args.max_height,
                unit=ScreenshotUnit(args.units),
            )
        except ValueError as e:
            # The options type owns the rules about which requests can be
            # expressed, so argparse is not asked to restate them: a mutually
            # exclusive group cannot say "a factor, or one or both bounds".
            raise IdbException(str(e)) from e


def _metadata(screenshot: Screenshot) -> dict[str, object]:
    # None for anything a companion older than these fields did not report.
    metadata: dict[str, object] = {
        "format": screenshot.format.value,
        "byte_count": len(screenshot),
        "width": screenshot.width,
        "height": screenshot.height,
        "source_width": screenshot.source_width,
        "source_height": screenshot.source_height,
        "screen_scale": screenshot.screen_scale,
    }
    if screenshot.app_capture is not None:
        metadata["app_capture"] = asdict(screenshot.app_capture)
    return metadata


@contextmanager
def screenshot_file(path: str) -> Iterator[IO[bytes]]:
    if path == "-":
        yield sys.stdout.buffer
        return

    with open(path, "wb") as f:
        yield f
