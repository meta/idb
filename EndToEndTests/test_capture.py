# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Check PNG output, record the screen twice at once, and read the simulator log while the command runs."""

from __future__ import annotations

import asyncio
import os
import signal
import struct
import time
from collections.abc import Iterator
from pathlib import Path

from .harness import (
    IdbEndToEndTestCase,
    IdbProcess,
    NotReady,
    ProcessStream,
    wait_until,
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

SETTINGS_BUNDLE_ID = "com.apple.Preferences"

LOG_TIMEOUT_SECONDS = 60.0

RECORDING_START_TIMEOUT_SECONDS = 30.0

RECORDING_LIMIT_REACHED = (
    "Cannot create a new video recording session: the simulator already records 2"
)

# How long the recording that is kept runs after the other stops: long against the time before, so
# a recording that stopped getting frames when the other stopped falls well short of `COVERAGE`.
KEEP_RECORDING_SECONDS = 10.0

# The share of its life a recording that kept getting frames must hold as video: its life is measured
# from when the client saw the first frame written to when its stop returned, which is a little
# longer than the video.
COVERAGE = 0.75

# Boxes whose children hold the sample tables of a plain or a fragmented MP4.
_MP4_CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"moof", b"traf"}


def _mp4_samples(data: bytes, start: int = 0, end: int | None = None) -> int:
    """The samples an MP4's sample tables and movie fragments hold, across every track."""
    end = len(data) if end is None else end
    samples = 0
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start : start + 8])
        header = 8
        if size == 1:
            (size,) = struct.unpack(">Q", data[start + 8 : start + 16])
            header = 16
        elif size == 0:
            size = end - start
        if size < header:
            break
        body = start + header
        if kind in _MP4_CONTAINERS:
            samples += _mp4_samples(data, body, start + size)
        elif kind in (b"stsz", b"trun"):
            # `stsz` keeps its count after the version, flags and default size; `trun` after the
            # version and flags.
            offset = body + (8 if kind == b"stsz" else 4)
            if offset + 4 > start + size:
                raise ValueError(f"the {kind.decode()} box is cut short")
            samples += struct.unpack(">I", data[offset : offset + 4])[0]
        start += size
    return samples


def _mp4_boxes(
    data: bytes, start: int = 0, end: int | None = None
) -> Iterator[tuple[bytes, int, int]]:
    """Every box of an MP4, depth first in file order, as its type, body start and end."""
    end = len(data) if end is None else end
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start : start + 8])
        header = 8
        if size == 1:
            (size,) = struct.unpack(">Q", data[start + 8 : start + 16])
            header = 16
        elif size == 0:
            size = end - start
        if size < header or start + size > end:
            raise ValueError(f"the {kind!r} box at {start} is cut short")
        yield kind, start + header, start + size
        if kind in _MP4_CONTAINERS or kind == b"mvex":
            yield from _mp4_boxes(data, start + header, start + size)
        start += size


def _mp4_seconds(data: bytes) -> float:
    """How long the one video track of an MP4 lasts: the durations of the samples in its sample
    table and its movie fragments, over the track's timescale."""

    def uint32(offset: int) -> int:
        return struct.unpack(">I", data[offset : offset + 4])[0]

    timescale = 0
    total = 0
    default_duration = 0
    fragment_default = 0
    tracks = 0
    for kind, body, _ in _mp4_boxes(data):
        flags = uint32(body) & 0xFFFFFF if kind in (b"tfhd", b"trun") else 0
        if kind == b"trak":
            tracks += 1
        elif kind == b"mdhd":
            # Version 1 has 64-bit creation and modification times ahead of the timescale.
            timescale = uint32(body + (20 if data[body] == 1 else 12))
        elif kind == b"stts":
            for entry in range(uint32(body + 4)):
                count, delta = struct.unpack(
                    ">II", data[body + 8 + entry * 8 : body + 16 + entry * 8]
                )
                total += count * delta
        elif kind == b"trex":
            default_duration = uint32(body + 12)
        elif kind == b"tfhd":
            offset = body + 8 + (8 if flags & 0x01 else 0) + (4 if flags & 0x02 else 0)
            fragment_default = uint32(offset) if flags & 0x08 else default_duration
        elif kind == b"trun":
            count = uint32(body + 4)
            offset = body + 8 + (4 if flags & 0x01 else 0) + (4 if flags & 0x04 else 0)
            stride = 4 * bin(flags & 0xF00).count("1")
            for sample in range(count):
                total += (
                    uint32(offset + sample * stride)
                    if flags & 0x100
                    else fragment_default
                )
    if tracks != 1 or timescale == 0:
        raise ValueError(f"the MP4 has {tracks} tracks and timescale {timescale}")
    return total / timescale


class CaptureTests(IdbEndToEndTestCase):
    async def test_screenshot_writes_a_png_to_a_file_and_to_stdout(self) -> None:
        destination = self.make_temporary_directory() / "screen.png"

        await self.idb("screenshot", str(destination))

        self.assert_png(destination.read_bytes())
        self.assert_png((await self.idb("screenshot", "-")).stdout)

    def assert_png(self, data: bytes) -> None:
        self.assertEqual(data[: len(PNG_SIGNATURE)], PNG_SIGNATURE)
        self.assertGreater(
            len(data), len(PNG_SIGNATURE), "PNG output contains only the signature"
        )

    async def test_two_recordings_of_one_screen_both_hold_video(self) -> None:
        """Record the screen while it is already being recorded, as a test that records its own
        video does while the harness records the whole run. Each recording holds video, and the
        companion still serves the next command. The inner recording is sent back over the
        connection, as one from a client on another host is, rather than written by the companion."""
        directory = self.make_temporary_directory()
        outer_file = directory / "outer.mp4"
        inner_file = directory / "inner.mp4"
        self.addAsyncCleanup(self.setup_terminate_quietly, SETTINGS_BUNDLE_ID)
        await self.setup_terminate_quietly(SETTINGS_BUNDLE_ID)

        async with self.idb_process("record-video", str(outer_file)) as outer:
            await self.wait_for_recording(outer, outer_file)
            async with self.idb_process(
                "record-video",
                str(inner_file),
                env={**os.environ, "IDB_FORCE_REMOTE": "1"},
            ) as inner:
                # A refused recording ends by itself, so one still running once Settings has
                # launched was accepted. Its file arrives only after the stop.
                await self.setup_idb("launch", SETTINGS_BUNDLE_ID)
                self.assertIsNone(
                    inner.returncode,
                    "the inner recording ended before it was stopped: "
                    + inner.spooled_output(ProcessStream.STDERR).decode(
                        errors="replace"
                    ),
                )
                self.assertEqual(await inner.stop(), 0, "the inner recording failed")
            self.assertEqual(await outer.stop(), 0, "the outer recording failed")

        for recording in (outer_file, inner_file):
            self.assertGreater(
                _mp4_samples(recording.read_bytes()),
                0,
                f"{recording.name} holds no video",
            )
        await self.idb("describe")

    async def test_stopping_the_first_recording_leaves_the_second_recording(
        self,
    ) -> None:
        await self.assert_stopping_one_recording_leaves_the_other(stop_first=True)

    async def test_stopping_the_second_recording_leaves_the_first_recording(
        self,
    ) -> None:
        await self.assert_stopping_one_recording_leaves_the_other(stop_first=False)

    async def assert_stopping_one_recording_leaves_the_other(
        self, stop_first: bool
    ) -> None:
        """Two recordings of one screen; one is stopped as soon as both have frames, and the other
        records for a while longer. The one still recording keeps recording after the other
        stopped, so its video covers its whole life, and both files hold video."""
        directory = self.make_temporary_directory()
        first_file = directory / "first.mp4"
        second_file = directory / "second.mp4"

        async with self.idb_process("record-video", str(first_file)) as first:
            first_started = await self.wait_for_recording(first, first_file)
            async with self.idb_process("record-video", str(second_file)) as second:
                second_started = await self.wait_for_recording(second, second_file)
                stopped, kept, kept_started = (
                    (first, second, second_started)
                    if stop_first
                    else (second, first, first_started)
                )
                self.assertEqual(
                    await stopped.stop(), 0, "the stopped recording failed"
                )
                await self.keep_recording(kept)
                kept_stopped = time.monotonic()
                self.assertEqual(await kept.stop(), 0, "the kept recording failed")

        self.assertGreater(
            _mp4_samples(first_file.read_bytes()), 0, "first.mp4 holds no video"
        )
        self.assertGreater(
            _mp4_samples(second_file.read_bytes()), 0, "second.mp4 holds no video"
        )
        kept_file = second_file if stop_first else first_file
        self.assert_covers(kept_file, kept_stopped - kept_started)

    async def test_killing_one_recordings_client_leaves_the_other_recording(
        self,
    ) -> None:
        """Two recordings of one screen, and a third that is refused because two run. The client of
        one is killed: the companion stops its recording, which frees its place for another, and
        the other keeps recording."""
        directory = self.make_temporary_directory()
        kept_file = directory / "kept.mp4"
        killed_file = directory / "killed.mp4"
        third_file = directory / "third.mp4"
        later_file = directory / "later.mp4"

        async with self.idb_process("record-video", str(kept_file)) as kept:
            kept_started = await self.wait_for_recording(kept, kept_file)
            async with self.idb_process("record-video", str(killed_file)) as killed:
                await self.wait_for_recording(killed, killed_file)
                async with self.idb_process("record-video", str(third_file)) as third:
                    self.assertNotEqual(
                        await third.wait(RECORDING_START_TIMEOUT_SECONDS),
                        0,
                        "a third recording was not refused",
                    )
                    self.assertIn(
                        RECORDING_LIMIT_REACHED,
                        third.spooled_output(ProcessStream.STDERR).decode(
                            errors="replace"
                        ),
                    )
                killed.send_signal(signal.SIGKILL)
                await killed.wait(RECORDING_START_TIMEOUT_SECONDS)
            # The companion stops the killed client's recording once it sees the call end, and
            # then another one fits.
            await wait_until(
                "a recording in the killed one's place",
                RECORDING_START_TIMEOUT_SECONDS,
                lambda: self.record_briefly(later_file),
            )
            await self.keep_recording(kept)
            kept_stopped = time.monotonic()
            self.assertEqual(await kept.stop(), 0, "the kept recording failed")

        self.assert_covers(kept_file, kept_stopped - kept_started)
        await self.idb("describe")

    async def test_a_second_recording_into_the_same_file_is_refused(self) -> None:
        """A recording into the file another recording is writing, spelled through a symbolic link
        to its directory, is refused at once, naming the file. The first recording keeps writing
        it: nothing deleted or replaced it."""
        directory = self.make_temporary_directory()
        recorded = directory / "screen.mp4"
        linked = directory / "linked"
        linked.symlink_to(directory, target_is_directory=True)
        same_file = linked / "screen.mp4"

        async with self.idb_process("record-video", str(recorded)) as first:
            first_started = await self.wait_for_recording(first, recorded)
            async with self.idb_process("record-video", str(same_file)) as second:
                self.assertNotEqual(
                    await second.wait(RECORDING_START_TIMEOUT_SECONDS),
                    0,
                    "the recording into the same file was not refused",
                )
                self.assertIn(
                    f"Cannot record to {same_file}: a recording is already writing to it",
                    second.spooled_output(ProcessStream.STDERR).decode(
                        errors="replace"
                    ),
                )
            self.assertIsNone(first.returncode, "the first recording ended")
            await self.keep_recording(first)
            first_stopped = time.monotonic()
            self.assertEqual(await first.stop(), 0, "the first recording failed")

        self.assert_covers(recorded, first_stopped - first_started)

    async def test_a_second_audio_capture_is_refused_without_touching_the_first(
        self,
    ) -> None:
        """A simulator serves one audio capture. A second recording that asks for audio is refused
        at once with the reason, writes nothing, and the first recording, with its audio, carries
        on to a whole file."""
        directory = self.make_temporary_directory()
        first_file = directory / "first.mp4"
        second_file = directory / "second.mp4"

        async with self.idb_process(
            "record-video", "--audio", str(first_file)
        ) as first:
            await self.wait_for_recording(first, first_file)
            async with self.idb_process(
                "record-video", "--audio", str(second_file)
            ) as second:
                self.assertNotEqual(
                    await second.wait(RECORDING_START_TIMEOUT_SECONDS),
                    0,
                    "the second audio capture was not refused",
                )
                self.assertIn(
                    "Another audio capture is already running on simulator",
                    second.spooled_output(ProcessStream.STDERR).decode(
                        errors="replace"
                    ),
                )
            self.assertFalse(
                second_file.exists() and second_file.stat().st_size > 0,
                "the refused recording wrote a file",
            )
            self.assertIsNone(first.returncode, "the first recording ended")
            self.assertEqual(await first.stop(), 0, "the first recording failed")

        self.assertGreater(
            _mp4_samples(first_file.read_bytes()), 0, "first.mp4 holds no video"
        )

    async def record_briefly(self, path: Path) -> None:
        """Records into `path` until its first frame, then stops. Raises `NotReady` if the recording
        is refused because two already run."""
        async with self.idb_process("record-video", str(path)) as recording:

            async def started_or_refused() -> None:
                if recording.returncode is None and not (
                    path.exists() and path.stat().st_size > 0
                ):
                    raise NotReady(f"{path.name} has not been written")

            await wait_until(
                f"the recording into {path.name}",
                RECORDING_START_TIMEOUT_SECONDS,
                started_or_refused,
            )
            if recording.returncode is not None:
                stderr = recording.spooled_output(ProcessStream.STDERR).decode(
                    errors="replace"
                )
                if RECORDING_LIMIT_REACHED in stderr:
                    raise NotReady(stderr.strip())
                self.fail(f"record-video into {path.name} failed: {stderr.strip()}")
            self.assertEqual(await recording.stop(), 0, f"{path.name} failed")

    async def keep_recording(self, recording: IdbProcess) -> None:
        """Lets `recording` run long enough that a video which stopped getting frames shows it.
        What is measured is how long the video lasts, so this has to be wall time."""
        await asyncio.sleep(KEEP_RECORDING_SECONDS)
        self.assertIsNone(
            recording.returncode, "the recording ended before it was stopped"
        )

    def assert_covers(self, path: Path, seconds: float) -> None:
        """`path` holds video for most of the `seconds` it recorded. A recording takes its frame
        times from the clock, so frames an encoder drops leave the duration as it was, and one whose
        encoder or writer stopped partway, when another recording stopped, falls short. Whether
        its framebuffer registration survived is checked in `SimulatorVideoStreamIsolationTests`:
        a recording at a fixed rate keeps encoding the screen without one."""
        recorded = _mp4_seconds(path.read_bytes())
        self.assertGreaterEqual(
            recorded,
            seconds * COVERAGE,
            f"{path.name} holds {recorded:.1f} s of video for {seconds:.1f} s of recording",
        )

    async def wait_for_recording(self, recording: IdbProcess, path: Path) -> float:
        """Waits until a local recording has written its file, which it opens on its first frame,
        and returns when, on the monotonic clock."""

        async def written() -> None:
            if recording.returncode is not None:
                stderr = recording.spooled_output(ProcessStream.STDERR)
                self.fail(
                    f"record-video into {path.name} exited {recording.returncode}: "
                    f"{stderr.decode(errors='replace').strip()}"
                )
            if not path.exists() or path.stat().st_size == 0:
                raise NotReady(f"{path.name} has not been written")

        await wait_until(
            f"the recording into {path.name}", RECORDING_START_TIMEOUT_SECONDS, written
        )
        return time.monotonic()

    async def test_log_streams_simulator_output(self) -> None:
        async with self.idb_process("log") as log:
            # The setup client owns both the stimulus and its cleanup.
            self.addAsyncCleanup(self.setup_terminate_quietly, SETTINGS_BUNDLE_ID)
            await self.setup_terminate_quietly(SETTINGS_BUNDLE_ID)
            await self.setup_idb("launch", SETTINGS_BUNDLE_ID)

            self.assertTrue(
                (await log.read_some(LOG_TIMEOUT_SECONDS)).strip(),
                "log streamed none of the target's own output",
            )
            self.assertIsNone(
                log.returncode, "log stopped streaming before it was read"
            )
