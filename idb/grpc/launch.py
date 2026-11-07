#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import contextlib
import sys
from collections.abc import Callable

from idb.common.format import json_format_debugger_info
from idb.common.types import DebuggerInfo
from idb.grpc.idb_pb2 import LaunchRequest, LaunchResponse, ProcessOutput
from idb.grpc.stream import Stream


async def wait_for_launch_stream(
    stream: Stream[LaunchRequest, LaunchResponse],
    stop: asyncio.Event,
    pid_file: str | None,
) -> None:
    drain = asyncio.create_task(drain_launch_stream(stream, pid_file))
    stopped = asyncio.create_task(stop.wait())
    try:
        done, _ = await asyncio.wait(
            (drain, stopped), return_when=asyncio.FIRST_COMPLETED
        )
        if drain in done:
            await drain
        else:
            await stream.send_message(LaunchRequest(stop=LaunchRequest.Stop()))
        # grpclib raises if a call exits before its requests are ended, even after
        # the response ends
        await stream.end()
        # The companion still forwards the app's final output after Stop, until it
        # ends the response
        await drain
    finally:
        drain.cancel()
        stopped.cancel()
        await asyncio.gather(drain, stopped, return_exceptions=True)


# Room to absorb a reader that pauses, without holding unbounded output when it falls behind for good
MAX_BUFFERED_OUTPUT_BYTES: int = 64 * 1024 * 1024


def _write_stdout(data: bytes) -> None:
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _write_stderr(data: bytes) -> None:
    sys.stderr.buffer.write(data)
    sys.stderr.buffer.flush()


class _OutputForwarder:
    """Writes the app's output from a worker thread, so a slow reader of this process's
    stdout or stderr does not stop the launch stream being read. The companion stops
    reading the app's output while the stream is not read, and the app then blocks in
    its own writes."""

    def __init__(self, max_buffered_bytes: int) -> None:
        self._max_buffered_bytes = max_buffered_bytes
        self._buffered_bytes = 0
        self._writer_stopped = False
        self._room = asyncio.Condition()
        self._pending: asyncio.Queue[tuple[Callable[[bytes], None], bytes] | None] = (
            asyncio.Queue()
        )
        self._writer: asyncio.Task[None] = asyncio.create_task(self._write_pending())

    async def put(self, write: Callable[[bytes], None], data: bytes) -> None:
        async with self._room:
            await self._room.wait_for(
                lambda: self._buffered_bytes < self._max_buffered_bytes
                or self._writer_stopped
            )
            writer_stopped = self._writer_stopped
            if not writer_stopped:
                self._buffered_bytes += len(data)
        # The writer's exit takes `_room`, so its failure is awaited outside it
        if writer_stopped:
            await self._writer
            return
        self._pending.put_nowait((write, data))

    async def finish(self) -> None:
        self._pending.put_nowait(None)
        await self._writer

    async def close(self) -> None:
        self._writer.cancel()
        await asyncio.gather(self._writer, return_exceptions=True)

    async def _write_pending(self) -> None:
        loop = asyncio.get_running_loop()
        try:
            while (item := await self._pending.get()) is not None:
                write, data = item
                await loop.run_in_executor(None, write, data)
                async with self._room:
                    self._buffered_bytes -= len(data)
                    self._room.notify_all()
        finally:
            self._writer_stopped = True
            async with self._room:
                self._room.notify_all()


async def drain_launch_stream(
    stream: Stream[LaunchRequest, LaunchResponse],
    pid_file: str | None,
    max_buffered_output_bytes: int = MAX_BUFFERED_OUTPUT_BYTES,
) -> None:
    output = _OutputForwarder(max_buffered_output_bytes)
    try:
        async for message in stream:
            process_output = message.output
            data = process_output.data
            if len(data):
                interface = process_output.interface
                if interface == ProcessOutput.STDOUT:
                    await output.put(_write_stdout, data)
                elif interface == ProcessOutput.STDERR:
                    await output.put(_write_stderr, data)
            debugger_info = message.debugger
            debugger_pid = debugger_info.pid
            if debugger_pid is not None and debugger_pid != 0:
                info = DebuggerInfo(pid=debugger_info.pid)
                if pid_file is None:
                    await output.put(
                        _write_stdout, json_format_debugger_info(info).encode() + b"\n"
                    )
                else:
                    with open(pid_file, "wb") as f:
                        f.write(json_format_debugger_info(info).encode())
                        f.flush()
    except BaseException:
        # Output already received is written even when the stream fails or is
        # cancelled. The stream's failure is the one reported.
        with contextlib.suppress(Exception):
            await output.finish()
        raise
    else:
        await output.finish()
    finally:
        await output.close()
