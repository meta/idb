#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from idb.common.types import (
    DEFAULT_SCREENSHOT_OPTIONS,
    IdbException,
    Screenshot,
    ScreenshotAppContext,
    ScreenshotAppObservation,
    ScreenshotFormat,
    ScreenshotOptions,
    ScreenshotUnit,
)
from idb.grpc.idb_pb2 import ScreenshotRequest, ScreenshotResponse


SCREENSHOT_FORMAT_MAP: dict[ScreenshotFormat, "ScreenshotRequest.Format"] = {
    ScreenshotFormat.PNG: ScreenshotRequest.PNG,
    ScreenshotFormat.JPEG: ScreenshotRequest.JPEG,
    ScreenshotFormat.TIFF: ScreenshotRequest.TIFF,
}

SCREENSHOT_UNIT_MAP: dict[ScreenshotUnit, "ScreenshotRequest.Unit"] = {
    ScreenshotUnit.PIXELS: ScreenshotRequest.PIXELS,
    ScreenshotUnit.POINTS: ScreenshotRequest.POINTS,
}


def screenshot_to_grpc(options: ScreenshotOptions) -> ScreenshotRequest:
    request = ScreenshotRequest(
        format=SCREENSHOT_FORMAT_MAP[options.format],
        unit=SCREENSHOT_UNIT_MAP[options.unit],
        # 0 is "unset" on the wire, so it is how the companion is asked for its
        # own default. Spelled out rather than `or 0` because 0 is also a value
        # a caller can pass: it is not a legal quality, but it has to be
        # rejected rather than silently become "your choice".
        compression_quality=(
            0 if options.compression_quality is None else options.compression_quality
        ),
    )
    if options.crop is not None:
        request.crop.CopyFrom(
            ScreenshotRequest.Rect(
                x=options.crop.x,
                y=options.crop.y,
                width=options.crop.width,
                height=options.crop.height,
            )
        )
    if options.scale_factor is not None:
        request.scale_factor = options.scale_factor
    elif options.max_width is not None or options.max_height is not None:
        # 0 is "unbounded on that axis". The options reject asking for a factor
        # and a bounding box together, since the wire can carry only one, and
        # reject a bound below 1, which this `uint32` field cannot carry at all.
        request.fit.CopyFrom(
            ScreenshotRequest.Fit(
                max_width=0 if options.max_width is None else options.max_width,
                max_height=0 if options.max_height is None else options.max_height,
            )
        )
    return request


def screenshot_from_grpc(
    options: ScreenshotOptions, response: ScreenshotResponse
) -> Screenshot:
    if not response.image_format:
        # A companion that predates the request having fields never populated
        # this, and silently ignored everything that was asked of it.
        if options != DEFAULT_SCREENSHOT_OPTIONS:
            raise IdbException(
                "The companion is too old to honor a screenshot format, crop, "
                "scale or unit; it returned a full-screen PNG instead. Update "
                "the companion, or take a screenshot with no options."
            )
        return Screenshot(response.image_data)
    if response.image_format != options.format.value:
        # The companion never picks the format, so this is not a fallback: the
        # bytes are not what was asked for and reporting them as such would be
        # a lie about their contents.
        raise IdbException(
            f"Asked for a {options.format.value} screenshot, but the companion "
            f"reported encoding it as {response.image_format!r}"
        )
    return Screenshot(
        response.image_data,
        format=options.format,
        # A real measurement is never 0, so 0 is "the companion did not report
        # one" and needs no separate presence bit.
        width=response.destination.width or None,
        height=response.destination.height or None,
        source_width=response.source.width or None,
        source_height=response.source.height or None,
        screen_scale=response.screen_scale or None,
        app_context=_app_context(response),
    )


def _app_context(response: ScreenshotResponse) -> ScreenshotAppContext | None:
    if not response.HasField("app_context"):
        return None
    context = response.app_context
    if context.version != 1:
        return None
    states = {1: "matching_observations", 2: "unavailable"}
    state = states.get(context.state)
    if state is None:
        return None

    def observation(which: str) -> ScreenshotAppObservation | None:
        if not context.HasField(which):
            return None
        value = getattr(context, which)
        if (
            value.process_id <= 0
            or value.observed_at_ms <= 0
            or len(value.app_name) > 256
            or len(value.bundle_id) > 256
            or len(value.installed_build_uuid) > 128
        ):
            return None
        return ScreenshotAppObservation(
            value.app_name,
            value.bundle_id,
            value.installed_build_uuid,
            value.process_id,
            value.observed_at_ms,
        )

    if any(
        len(value) > 256
        for value in (context.target_udid, context.display_id, context.reason)
    ):
        return None
    return ScreenshotAppContext(
        context.version,
        state,
        context.reason,
        context.target_udid,
        context.display_id,
        context.capture_started_at_ms,
        context.capture_finished_at_ms,
        observation("before"),
        observation("after"),
    )
