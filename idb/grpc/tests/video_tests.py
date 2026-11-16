#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
from collections.abc import AsyncIterator
from unittest.mock import MagicMock, patch

from grpclib.const import Status
from grpclib.exceptions import GRPCError
from idb.common.types import (
    CompanionInfo,
    DomainSocketAddress,
    IdbException,
    RecordedAudio,
    RecordedAudioProcess,
    VideoFormat,
)
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import (
    Payload,
    RecordRequest,
    RecordResponse,
    VideoStreamRequest,
    VideoStreamResponse,
)
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.grpc.video import generate_video_bytes
from idb.utils.testing import TestCase


async def _stream(*responses: RecordResponse) -> AsyncIterator[RecordResponse]:
    for response in responses:
        yield response


def _payload(data: bytes) -> RecordResponse:
    return RecordResponse(payload=Payload(data=data))


def _echo(**kwargs: float) -> RecordResponse:
    # pyre-ignore[6]: the proto constructor is not typed per-field here.
    return RecordResponse(applied=RecordResponse.Applied(**kwargs))


def _audio() -> RecordResponse:
    return RecordResponse(
        audio=RecordResponse.Audio(
            offset=-0.25,
            frames=96_000,
            sample_rate=48_000,
            wav_file_path="out.wav",
            processes=[
                RecordResponse.AudioProcess(
                    pid=41, name="Player", frames=96_000, realignments=2
                ),
                RecordResponse.AudioProcess(
                    pid=42,
                    name="Crashed",
                    frames=480,
                    dropped_frames=-1,
                    unmixed_frames=64,
                ),
            ],
            failures=["Recorder: no space left"],
        )
    )


_DESCRIBED_AUDIO = RecordedAudio(
    offset=-0.25,
    frames=96_000,
    sample_rate=48_000,
    wav_file_path="out.wav",
    processes=[
        RecordedAudioProcess(
            pid=41,
            name="Player",
            frames=96_000,
            dropped_frames=0,
            unmixed_frames=0,
            realignments=2,
        ),
        # The companion's -1 is a process that exited before saying what it dropped.
        RecordedAudioProcess(
            pid=42,
            name="Crashed",
            frames=480,
            dropped_frames=None,
            unmixed_frames=64,
            realignments=0,
        ),
    ],
    failures=["Recorder: no space left"],
)


class _FakeStream:
    """Enough of a grpclib stream for `record_video`: it keeps what was sent and replays a fixed
    list of responses, then end-of-stream."""

    def __init__(self, *responses: RecordResponse) -> None:
        self.sent: list[RecordRequest] = []
        self._responses = list(responses)

    async def __aenter__(self) -> "_FakeStream":
        return self

    async def __aexit__(self, *_args: object) -> None:
        return None

    async def send_message(self, message: RecordRequest) -> None:
        self.sent.append(message)

    async def end(self) -> None:
        return None

    async def recv_message(self) -> RecordResponse | None:
        return self._responses.pop(0) if self._responses else None


class RecordVideoTests(TestCase):
    """`record_video` against a fake companion. `is_local` is true so the recording goes to a file
    on the companion's side and the response stream carries only the encode option echo."""

    def setUp(self) -> None:
        super().setUp()
        self.logger = MagicMock()
        self.stop = asyncio.Event()
        # The recording runs until this is set, and these tests are about the request that was sent
        # and the responses that came back, not about the duration.
        self.stop.set()

    def _client(self, stream: _FakeStream) -> Client:
        client = Client.__new__(Client)
        client.stub = MagicMock(record=MagicMock(open=MagicMock(return_value=stream)))
        client.companion = CompanionInfo(
            udid="udid",
            is_local=True,
            pid=None,
            address=DomainSocketAddress(path="/tmp/idb.sock"),
        )
        client.logger = self.logger
        return client

    async def _record(
        self, stream: _FakeStream, **options: float
    ) -> RecordRequest.Start:
        client = self._client(stream)
        # pyre-ignore[6]: the options are the encode options, each int | float | None.
        await client.record_video(stop=self.stop, output_file="out.mp4", **options)
        return stream.sent[0].start

    async def test_audio_is_asked_for_and_described(self) -> None:
        stream = _FakeStream(_echo(fps=30, audio=True), _audio(), _payload(b"out.mp4"))

        audio = await self._client(stream).record_video(
            stop=self.stop, output_file="out.mp4", audio=True
        )

        self.assertEqual(
            stream.sent[0].start, RecordRequest.Start(file_path="out.mp4", audio=True)
        )
        self.assertEqual(audio, _DESCRIBED_AUDIO)

    async def test_a_recording_without_audio_describes_none(self) -> None:
        audio = await self._client(_FakeStream()).record_video(
            stop=self.stop, output_file="out.mp4"
        )
        self.assertIsNone(audio)

    async def test_a_companion_that_records_no_audio_is_refused(self) -> None:
        # An old companion ignores the field and records video alone: it either echoes nothing or
        # echoes the encode options without audio, and describes no audio afterwards.
        for responses in ((), (_echo(fps=30),)):
            with self.subTest(responses=responses):
                with self.assertRaisesRegex(IdbException, "recorded no audio"):
                    await self._client(_FakeStream(*responses)).record_video(
                        stop=self.stop, output_file="out.mp4", audio=True
                    )

    async def test_a_request_without_options_is_what_idb_always_sent(self) -> None:
        # This is what the zero default buys: a caller who asks for nothing produces a request
        # indistinguishable from one sent before RecordRequest.Start had these fields.
        start = await self._record(_FakeStream())
        self.assertEqual(start, RecordRequest.Start(file_path="out.mp4"))

    async def test_the_options_reach_the_companion(self) -> None:
        start = await self._record(
            _FakeStream(_echo(fps=15)),
            fps=15,
            scale_factor=0.5,
            bitrate=1000000,
            key_frame_rate=2,
        )
        self.assertEqual(
            start,
            RecordRequest.Start(
                file_path="out.mp4",
                fps=15,
                scale_factor=0.5,
                avg_bitrate=1000000,
                key_frame_rate=2,
            ),
        )

    async def test_a_companion_that_ignored_the_options_is_reported(self) -> None:
        # An old companion drops the unknown fields and records at its own defaults. The missing
        # echo is the only thing that distinguishes that from having honoured them.
        await self._record(_FakeStream(), fps=15)
        self.logger.warning.assert_called_once()

    async def test_an_echoed_option_is_not_reported(self) -> None:
        await self._record(_FakeStream(_echo(fps=15)), fps=15)
        self.logger.warning.assert_not_called()

    async def test_a_default_recording_is_never_reported(self) -> None:
        # Nothing echoes a request that set no options, so warning on one would fire every time.
        await self._record(_FakeStream())
        self.logger.warning.assert_not_called()

    async def test_local_and_remote_stop_and_publication_transcript(self) -> None:
        applied = _echo(
            fps=15,
            scale_factor=0.5,
            avg_bitrate=1_000_000,
            key_frame_rate=2,
        )
        first = _payload(b"first")
        second = _payload(b"second")

        for name, is_local, output_file in (
            ("local_path", True, "out.mp4"),
            ("local_dash", True, "-"),
            ("remote_path", False, "out.mp4"),
            ("remote_dash", False, "-"),
        ):
            with self.subTest(name=name):
                terminal = RecordResponse(log_output=output_file.encode())
                responses = (
                    (applied, terminal) if is_local else (applied, first, second)
                )
                stream = ScriptedStream[RecordResponse](*responses)
                client, open_rpc = make_client(
                    "record",
                    stream,
                    is_local=is_local,
                )
                publications: list[tuple[str, list[bytes]]] = []

                async def publish(
                    stream: AsyncIterator[bytes],
                    output_path: str,
                    publication_log: list[tuple[str, list[bytes]]] = publications,
                ) -> None:
                    publication_log.append(
                        (output_path, [chunk async for chunk in stream])
                    )

                with patch("idb.grpc.client.drain_gzip_decompress", new=publish):
                    await client.record_video(
                        stop=self.stop,
                        output_file=output_file,
                        fps=15,
                        scale_factor=0.5,
                        bitrate=1_000_000,
                        key_frame_rate=2,
                    )

                start = RecordRequest(
                    start=RecordRequest.Start(
                        file_path=output_file if is_local else "",
                        fps=15,
                        scale_factor=0.5,
                        avg_bitrate=1_000_000,
                        key_frame_rate=2,
                    )
                )
                prefix = [
                    ("send", start),
                    ("send", RecordRequest(stop=RecordRequest.Stop())),
                    ("end", None),
                ]
                expected_transcript = (
                    prefix + [("recv", applied), ("recv", terminal)]
                    if is_local
                    else prefix
                    + [
                        ("recv", applied),
                        ("recv", first),
                        ("recv", second),
                        ("recv", None),
                    ]
                )
                self.assertEqual(stream.transcript, expected_transcript)
                self.assertEqual(
                    publications,
                    [] if is_local else [(output_file, [b"first", b"second"])],
                )
                open_rpc.assert_called_once_with()
                client.logger.warning.assert_not_called()

        # A companion refuses a start it cannot serve, here a second audio capture of one
        # simulator, by ending the call: after its headers, or in a trailers-only response. That is
        # reported then, without waiting for a stop that never comes, rather than once stopped as a
        # recording without a file.
        refusal = "Another audio capture is already running on simulator udid"
        for name, is_local, trailers_only in (
            ("refused_local", True, False),
            ("refused_remote", False, False),
            ("refused_local_trailers_only", True, True),
            ("refused_remote_trailers_only", False, True),
        ):
            with self.subTest(name=name):
                error = GRPCError(Status.FAILED_PRECONDITION, refusal)
                stream = ScriptedStream[RecordResponse](
                    **(
                        {"recv_error": error}
                        if trailers_only
                        else {"trailing_error": error}
                    )
                )
                client, _ = make_client("record", stream, is_local=is_local)
                publish = MagicMock()
                with patch("idb.grpc.client.drain_gzip_decompress", new=publish):
                    with self.assertRaisesRegex(IdbException, refusal):
                        # Nothing stops this recording, so it can only end by reporting the refusal.
                        await asyncio.wait_for(
                            client.record_video(
                                stop=asyncio.Event(), output_file="out.mp4"
                            ),
                            timeout=10,
                        )
                self.assertEqual(
                    stream.transcript,
                    [
                        (
                            "send",
                            RecordRequest(
                                start=RecordRequest.Start(
                                    file_path="out.mp4" if is_local else ""
                                )
                            ),
                        ),
                        *(
                            [("recv_error", None)]
                            if trailers_only
                            else [("recv", None), ("end", None), ("trailers", None)]
                        ),
                    ],
                )
                publish.assert_not_called()

        # A companion that fails once stopped sends no file, and gunzip fails on nothing. The
        # companion's error is the one reported.
        failure = "The recording could not be finalized"
        stream = ScriptedStream[RecordResponse](
            trailing_error=GRPCError(Status.INTERNAL, failure)
        )
        client, _ = make_client("record", stream, is_local=False)

        async def gunzip_nothing(
            stream: AsyncIterator[bytes], output_path: str
        ) -> None:
            self.assertEqual([chunk async for chunk in stream], [])
            raise IdbException(f"gunzip exited with 1 decompressing to {output_path}")

        with patch("idb.grpc.client.drain_gzip_decompress", new=gunzip_nothing):
            with self.assertRaisesRegex(IdbException, failure):
                await client.record_video(stop=self.stop, output_file="out.mp4")
        self.assertEqual(stream.transcript[-1], ("trailers", None))

        # gunzip that stops reading partway leaves responses unread, and a companion sends its
        # trailers only after them, so waiting for the trailers would never end. gunzip's error is
        # the one reported.
        stream = ScriptedStream[RecordResponse](_payload(b"first"), _payload(b"second"))
        client, _ = make_client("record", stream, is_local=False)

        async def gunzip_first_chunk(
            stream: AsyncIterator[bytes], output_path: str
        ) -> None:
            await anext(aiter(stream))
            raise IdbException(f"gunzip exited with 1 decompressing to {output_path}")

        with patch("idb.grpc.client.drain_gzip_decompress", new=gunzip_first_chunk):
            with self.assertRaisesRegex(IdbException, "gunzip exited with 1"):
                await client.record_video(stop=self.stop, output_file="out.mp4")
        self.assertNotIn(("trailers", None), stream.transcript)


class VideoStreamTests(TestCase):
    async def test_start_payload_stop_and_output_destination(self) -> None:
        first = VideoStreamResponse(payload=Payload(data=b"first"))
        second = VideoStreamResponse(payload=Payload(data=b"second"))

        for name, is_local, output_file in (
            ("local_stdout", True, None),
            ("local_file", True, "out.h264"),
            ("local_dash", True, "-"),
            ("remote_stdout", False, None),
            ("remote_file", False, "out.h264"),
            ("remote_dash", False, "-"),
        ):
            with self.subTest(name=name):
                responses = (
                    () if is_local and output_file is not None else (first, second)
                )
                stream = ScriptedStream[VideoStreamResponse](*responses)
                client, open_rpc = make_client(
                    "video_stream",
                    stream,
                    is_local=is_local,
                )
                publications: list[tuple[str, list[bytes]]] = []

                async def publish(
                    stream: AsyncIterator[bytes],
                    file_path: str,
                    publication_log: list[tuple[str, list[bytes]]] = publications,
                ) -> None:
                    publication_log.append(
                        (file_path, [chunk async for chunk in stream])
                    )

                with patch("idb.grpc.client.drain_to_file", new=publish):
                    output = [
                        chunk
                        async for chunk in client.stream_video(
                            output_file=output_file,
                            fps=15,
                            format=VideoFormat.H264,
                            compression_quality=0.2,
                            scale_factor=0.5,
                        )
                    ]

                start = VideoStreamRequest(
                    start=VideoStreamRequest.Start(
                        file_path=(
                            output_file if is_local and output_file is not None else ""
                        ),
                        fps=15,
                        format=VideoStreamRequest.H264,
                        compression_quality=0.2,
                        scale_factor=0.5,
                    )
                )
                self.assertEqual(
                    stream.transcript,
                    [
                        ("send", start),
                        *[("recv", response) for response in responses],
                        ("recv", None),
                        ("send", VideoStreamRequest(stop=VideoStreamRequest.Stop())),
                        ("end", None),
                    ],
                )
                self.assertEqual(
                    output,
                    [b"first", b"second"] if output_file is None else [],
                )
                self.assertEqual(
                    publications,
                    (
                        [(output_file, [b"first", b"second"])]
                        if not is_local and output_file is not None
                        else []
                    ),
                )
                open_rpc.assert_called_once_with()


class VideoTests(TestCase):
    async def test_the_payloads_are_the_video(self) -> None:
        chunks = [
            chunk
            async for chunk in generate_video_bytes(
                _stream(_payload(b"first"), _payload(b"second"))
            )
        ]
        self.assertEqual(chunks, [b"first", b"second"])

    async def test_the_encode_option_echo_is_not_video(self) -> None:
        # It leads the stream, so yielding it would prepend an empty chunk to the mp4.
        applied: list[RecordResponse.Applied] = []
        chunks = [
            chunk
            async for chunk in generate_video_bytes(
                _stream(_echo(fps=15, scale_factor=0.5), _payload(b"first")), applied
            )
        ]
        self.assertEqual(chunks, [b"first"])
        self.assertEqual([echo.fps for echo in applied], [15])

    async def test_the_echo_is_still_skipped_when_nobody_collects_it(self) -> None:
        chunks = [
            chunk
            async for chunk in generate_video_bytes(
                _stream(_echo(fps=15), _payload(b"first"))
            )
        ]
        self.assertEqual(chunks, [b"first"])

    async def test_the_audio_description_is_not_video(self) -> None:
        # A remote recording's audio is described before its bytes, which it would otherwise corrupt.
        applied: list[RecordResponse.Applied] = []
        audio: list[RecordResponse.Audio] = []
        chunks = [
            chunk
            async for chunk in generate_video_bytes(
                _stream(_echo(audio=True), _audio(), _payload(b"first")), applied, audio
            )
        ]
        self.assertEqual(chunks, [b"first"])
        self.assertEqual([description.frames for description in audio], [96_000])
