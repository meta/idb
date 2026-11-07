#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import asyncio
import tempfile
import threading
from collections import deque
from pathlib import Path
from unittest.mock import call, patch

from grpclib.exceptions import ProtocolError
from idb.common.types import IdbException
from idb.grpc.idb_pb2 import (
    DebuggerInfo as GrpcDebuggerInfo,
    LaunchRequest,
    LaunchResponse,
    ProcessOutput,
)
from idb.grpc.launch import drain_launch_stream, MAX_BUFFERED_OUTPUT_BYTES
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.utils.testing import TestCase


class LaunchStreamTests(TestCase):
    async def test_response_eof_completes_without_stop(self) -> None:
        last_output = LaunchResponse(
            output=ProcessOutput(interface=ProcessOutput.STDOUT, data=b"last output")
        )
        stream = ScriptedStream(last_output)
        client, _ = make_client("launch", stream)
        stop = asyncio.Event()
        tasks = asyncio.all_tasks()

        with patch("idb.grpc.launch.sys") as stdio:
            await asyncio.wait_for(
                client.launch(bundle_id="com.example.app", stop=stop), timeout=1
            )

        self.assertFalse(stop.is_set())
        self.assertEqual(
            stream.transcript,
            [
                (
                    "send",
                    LaunchRequest(
                        start=LaunchRequest.Start(
                            bundle_id="com.example.app", wait_for=True
                        )
                    ),
                ),
                ("recv", last_output),
                ("recv", None),
                # grpclib raises if a call exits before its requests are ended
                ("end", None),
            ],
        )
        self.assertEqual(
            stdio.mock_calls,
            [call.stdout.buffer.write(b"last output"), call.stdout.buffer.flush()],
        )
        self.assertEqual(asyncio.all_tasks(), tasks)
        self.assertTrue(stream.exited)

    async def test_stop_preserves_final_output(self) -> None:
        final_response = LaunchResponse(
            output=ProcessOutput(interface=ProcessOutput.STDOUT, data=b"final output")
        )
        stream = _StopDrivenLaunchStream(final_response)
        client, _ = make_client("launch", stream)
        stop = asyncio.Event()

        with patch("idb.grpc.launch.sys") as stdio:
            async with asyncio.timeout(1):
                launch = asyncio.create_task(
                    client.launch(bundle_id="com.example.app", stop=stop)
                )
                try:
                    await stream.read_started.wait()
                    self.assertFalse(launch.done())
                    self.assertFalse(stream.requests_ended.is_set())
                    stop.set()
                    await launch
                finally:
                    launch.cancel()
                    await asyncio.gather(launch, return_exceptions=True)

        self.assertEqual(
            stream.sent[1:], [(LaunchRequest(stop=LaunchRequest.Stop()), False)]
        )
        self.assertEqual(
            stream.transcript[1:],
            [
                ("send", LaunchRequest(stop=LaunchRequest.Stop())),
                ("end", None),
                ("recv", final_response),
                ("recv", None),
            ],
        )
        self.assertEqual(
            stdio.mock_calls,
            [call.stdout.buffer.write(b"final output"), call.stdout.buffer.flush()],
        )
        self.assertEqual(stream.read_cancellations, 0)
        self.assertTrue(stream.exited)

    async def test_response_error_settles_pending_stop(self) -> None:
        stream = ScriptedStream[LaunchResponse]()
        client, _ = make_client("launch", stream)
        stop = asyncio.Event()
        failure = ProtocolError("launch response failed")
        tasks = asyncio.all_tasks()

        with patch.object(stream, "recv_message", side_effect=failure):
            with self.assertRaises(IdbException) as raised:
                await client.launch(bundle_id="com.example.app", stop=stop)

        self.assertIs(raised.exception.__cause__, failure)
        self.assertFalse(stop.is_set())
        self.assertEqual(asyncio.all_tasks(), tasks)
        self.assertTrue(stream.exited)

    async def test_stop_error_settles_pending_read(self) -> None:
        stream = _StopDrivenLaunchStream()
        client, _ = make_client("launch", stream)
        stop = asyncio.Event()
        stop.set()
        failure = ProtocolError("launch Stop failed")
        tasks = asyncio.all_tasks()
        send_message = stream.send_message

        async def send_request(message: LaunchRequest) -> None:
            if message.HasField("stop"):
                raise failure
            await send_message(message)

        with patch.object(stream, "send_message", side_effect=send_request):
            with self.assertRaises(IdbException) as raised:
                await client.launch(bundle_id="com.example.app", stop=stop)

        self.assertIs(raised.exception.__cause__, failure)
        self.assertEqual(stream.read_cancellations, 1)
        self.assertEqual(asyncio.all_tasks(), tasks)
        self.assertTrue(stream.exited)

    async def test_parent_cancellation_settles_read_and_stop(self) -> None:
        stream = _StopDrivenLaunchStream()
        client, _ = make_client("launch", stream)
        stop = asyncio.Event()
        tasks = asyncio.all_tasks()

        async with asyncio.timeout(1):
            launch = asyncio.create_task(
                client.launch(bundle_id="com.example.app", stop=stop)
            )
            try:
                await stream.read_started.wait()
                launch.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await launch
            finally:
                launch.cancel()
                await asyncio.gather(launch, return_exceptions=True)

        self.assertFalse(stop.is_set())
        self.assertEqual(stream.read_cancellations, 1)
        self.assertEqual(asyncio.all_tasks(), tasks)
        self.assertTrue(stream.exited)

    async def test_start_output_debugger_stop_and_half_close(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for waits_for_stop in (False, True):
                with self.subTest(waits_for_stop=waits_for_stop):
                    stream_type = (
                        _StopDrivenLaunchStream if waits_for_stop else ScriptedStream
                    )
                    stream = stream_type(
                        LaunchResponse(
                            output=ProcessOutput(
                                interface=ProcessOutput.STDOUT,
                                data=b"stdout",
                            )
                        ),
                        LaunchResponse(
                            output=ProcessOutput(
                                interface=ProcessOutput.STDERR,
                                data=b"stderr",
                            )
                        ),
                        LaunchResponse(debugger=GrpcDebuggerInfo(pid=42)),
                    )
                    client, open_rpc = make_client("launch", stream)
                    stop = asyncio.Event() if waits_for_stop else None
                    if stop is not None:
                        stop.set()
                    pid_file = (
                        str(Path(directory) / "debugger.json")
                        if waits_for_stop
                        else None
                    )

                    with patch("idb.grpc.launch.sys") as stdio:
                        await client.launch(
                            bundle_id="com.example.app",
                            args=["first", "second"],
                            env={"IDB_TOKEN": "value"},
                            foreground_if_running=True,
                            wait_for_debugger=True,
                            stop=stop,
                            pid_file=pid_file,
                            enable_repl=True,
                        )

                    start = LaunchRequest(
                        start=LaunchRequest.Start(
                            bundle_id="com.example.app",
                            env={"IDB_TOKEN": "value"},
                            app_args=["first", "second"],
                            foreground_if_running=True,
                            wait_for_debugger=True,
                            wait_for=waits_for_stop,
                            enable_repl=True,
                        )
                    )
                    stop_request = LaunchRequest(stop=LaunchRequest.Stop())
                    expected_sent = [(start, False)]
                    responses = [
                        (
                            "recv",
                            LaunchResponse(
                                output=ProcessOutput(
                                    interface=ProcessOutput.STDOUT,
                                    data=b"stdout",
                                )
                            ),
                        ),
                        (
                            "recv",
                            LaunchResponse(
                                output=ProcessOutput(
                                    interface=ProcessOutput.STDERR,
                                    data=b"stderr",
                                )
                            ),
                        ),
                        (
                            "recv",
                            LaunchResponse(debugger=GrpcDebuggerInfo(pid=42)),
                        ),
                        ("recv", None),
                    ]
                    if waits_for_stop:
                        expected_sent.append((stop_request, False))
                        expected_transcript = [
                            ("send", start),
                            ("send", stop_request),
                            ("end", None),
                            *responses,
                        ]
                    else:
                        expected_transcript = [
                            ("send", start),
                            ("end", None),
                            *responses,
                        ]
                    self.assertEqual(stream.sent, expected_sent)
                    self.assertEqual(stream.transcript, expected_transcript)
                    self.assertEqual(
                        stdio.mock_calls[:4],
                        [
                            call.stdout.buffer.write(b"stdout"),
                            call.stdout.buffer.flush(),
                            call.stderr.buffer.write(b"stderr"),
                            call.stderr.buffer.flush(),
                        ],
                    )
                    if pid_file is None:
                        self.assertEqual(
                            stdio.mock_calls[4:],
                            [
                                call.stdout.buffer.write(b'{"pid": 42}\n'),
                                call.stdout.buffer.flush(),
                            ],
                        )
                    else:
                        self.assertEqual(stdio.mock_calls[4:], [])
                        self.assertEqual(Path(pid_file).read_bytes(), b'{"pid": 42}')
                    open_rpc.assert_called_once_with()
                    self.assertTrue(stream.entered)
                    self.assertTrue(stream.exited)


class LaunchOutputBufferingTests(TestCase):
    async def test_blocked_output_reader_does_not_stop_stream_reads(self) -> None:
        chunks = [b"first", b"second", b"third"]
        stream, written, reads_when_released = await self._drain_with_blocked_stdout(
            chunks, max_buffered_output_bytes=None
        )

        self.assertEqual(reads_when_released, [len(chunks) + 1])
        self.assertEqual(written, chunks)
        self.assertEqual(stream.transcript[-1], ("recv", None))

    async def test_full_buffer_stops_stream_reads_until_output_is_written(
        self,
    ) -> None:
        chunks = [b"aaaa", b"bbbb", b"cccc"]
        _, written, reads_when_released = await self._drain_with_blocked_stdout(
            chunks, max_buffered_output_bytes=4
        )

        self.assertEqual(reads_when_released, [2])
        self.assertEqual(written, chunks)

    async def test_write_error_surfaces_while_output_keeps_arriving(self) -> None:
        for max_buffered_output_bytes in (MAX_BUFFERED_OUTPUT_BYTES, 4):
            with self.subTest(max_buffered_output_bytes=max_buffered_output_bytes):
                stream = ScriptedStream(
                    *(
                        LaunchResponse(
                            output=ProcessOutput(
                                interface=ProcessOutput.STDOUT, data=b"x" * 4
                            )
                        )
                        for _ in range(50)
                    )
                )
                with patch("idb.grpc.launch.sys") as stdio:
                    stdio.stdout.buffer.write.side_effect = BrokenPipeError()
                    async with asyncio.timeout(5):
                        with self.assertRaises(BrokenPipeError):
                            await drain_launch_stream(
                                stream, None, max_buffered_output_bytes
                            )

    async def test_buffered_output_is_written_when_the_stream_fails(self) -> None:
        chunks = [b"first", b"second", b"third"]
        responses = deque(
            LaunchResponse(
                output=ProcessOutput(interface=ProcessOutput.STDOUT, data=chunk)
            )
            for chunk in chunks
        )
        failure = ProtocolError("launch response failed")
        failed = threading.Event()
        written: list[bytes] = []

        async def recv_message() -> LaunchResponse:
            if responses:
                return responses.popleft()
            failed.set()
            raise failure

        def blocking_write(data: bytes) -> None:
            failed.wait(timeout=1)
            written.append(data)

        stream = ScriptedStream[LaunchResponse]()
        with patch.object(stream, "recv_message", side_effect=recv_message):
            with patch("idb.grpc.launch.sys") as stdio:
                stdio.stdout.buffer.write.side_effect = blocking_write
                async with asyncio.timeout(5):
                    with self.assertRaises(ProtocolError) as raised:
                        await drain_launch_stream(stream, None)

        self.assertIs(raised.exception, failure)
        self.assertEqual(written, chunks)

    async def _drain_with_blocked_stdout(
        self, chunks: list[bytes], max_buffered_output_bytes: int | None
    ) -> tuple[ScriptedStream[LaunchResponse], list[bytes], list[int]]:
        stream = ScriptedStream(
            *(
                LaunchResponse(
                    output=ProcessOutput(interface=ProcessOutput.STDOUT, data=chunk)
                )
                for chunk in chunks
            )
        )
        release = threading.Event()
        written: list[bytes] = []
        reads_when_released: list[int] = []

        def reads() -> int:
            return sum(1 for entry in stream.transcript if entry[0] == "recv")

        def blocking_write(data: bytes) -> None:
            if not written:
                release.wait(timeout=1)
                reads_when_released.append(reads())
            written.append(data)

        kwargs = (
            {}
            if max_buffered_output_bytes is None
            else {"max_buffered_output_bytes": max_buffered_output_bytes}
        )
        expected_reads = len(chunks) + 1 if max_buffered_output_bytes is None else 2
        with patch("idb.grpc.launch.sys") as stdio:
            stdio.stdout.buffer.write.side_effect = blocking_write
            async with asyncio.timeout(5):
                drain = asyncio.create_task(drain_launch_stream(stream, None, **kwargs))
                try:
                    while reads() < expected_reads:
                        await asyncio.sleep(0.01)
                    await asyncio.sleep(0.05)
                    release.set()
                    await drain
                finally:
                    release.set()
                    drain.cancel()
                    await asyncio.gather(drain, return_exceptions=True)
        return stream, written, reads_when_released


class _StopDrivenLaunchStream(ScriptedStream[LaunchResponse]):
    """Withholds responses until the client ends its requests, which follows Stop."""

    def __init__(self, *responses: LaunchResponse) -> None:
        super().__init__(*responses)
        self.read_started = asyncio.Event()
        self.requests_ended = asyncio.Event()

    async def recv_message(self) -> LaunchResponse | None:
        self.read_started.set()
        try:
            await self.requests_ended.wait()
        except asyncio.CancelledError:
            self.read_cancellations += 1
            raise
        return await super().recv_message()

    async def end(self) -> None:
        await super().end()
        self.requests_ended.set()
