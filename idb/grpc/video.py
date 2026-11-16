#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
from collections.abc import AsyncIterator
from typing import Protocol

from idb.common.types import IdbException, RecordedAudio, RecordedAudioProcess
from idb.grpc.idb_pb2 import RecordResponse


class RecordStream(Protocol):
    """The parts of a `record` call that waiting for its stop uses."""

    async def recv_message(self) -> RecordResponse | None: ...

    async def end(self) -> None: ...

    async def recv_trailing_metadata(self) -> None: ...


async def wait_for_stop(stream: RecordStream, stop: asyncio.Event) -> "RecordResponses":
    """Waits for `stop` while reading what the companion sends, then returns every response of the
    call: those read while waiting, followed by the rest as they arrive.

    The companion refuses a start it cannot serve, for example a second audio capture of one
    simulator, by ending the call with an error. Reading while waiting raises that error when it
    happens, instead of after the stop as a recording without a file.
    """
    early: list[RecordResponse] = []
    received = asyncio.ensure_future(stream.recv_message())
    try:
        if not stop.is_set():
            stopped = asyncio.ensure_future(stop.wait())
            try:
                while not stopped.done():
                    await asyncio.wait(
                        {received, stopped}, return_when=asyncio.FIRST_COMPLETED
                    )
                    if not received.done():
                        break
                    response = received.result()
                    if response is None:
                        await stream.end()
                        # Raises the companion's error, which is what ended the call.
                        await stream.recv_trailing_metadata()
                        raise IdbException(
                            "The companion ended the recording before it was stopped"
                        )
                    early.append(response)
                    received = asyncio.ensure_future(stream.recv_message())
            finally:
                await _cancel(stopped)
    except BaseException:
        await _cancel(received)
        raise
    return RecordResponses(early, received, stream)


async def _cancel(task: "asyncio.Future[object]") -> None:
    """Cancels `task`, waits for it to end and retrieves what it failed with, so that it is neither
    left running nor reported as an unretrieved error. Waiting, rather than awaiting, leaves a
    cancellation of the caller to the caller."""
    task.cancel()
    await asyncio.wait({task})
    if not task.cancelled():
        task.exception()


class RecordResponses:
    """The responses of a `record` call once its stop is due. `aclose` ends the read that was in
    flight when the stop came, if nothing consumed it, and must be called once the call is done."""

    def __init__(
        self,
        early: list[RecordResponse],
        received: "asyncio.Future[RecordResponse | None]",
        stream: RecordStream,
    ) -> None:
        self._early = early
        self._received = received
        self._stream = stream
        # Whether every response was read, so the call's trailers have arrived.
        self.exhausted = False

    def __aiter__(self) -> AsyncIterator[RecordResponse]:
        return self._responses()

    async def _responses(self) -> AsyncIterator[RecordResponse]:
        for response in self._early:
            yield response
        response = await self._received
        while response is not None:
            yield response
            response = await self._stream.recv_message()
        self.exhausted = True

    async def aclose(self) -> None:
        await _cancel(self._received)


async def generate_video_bytes(
    stream: AsyncIterator[RecordResponse],
    applied: list[RecordResponse.Applied] | None = None,
    audio: list[RecordResponse.Audio] | None = None,
) -> AsyncIterator[bytes]:
    """Yields the recorded bytes. The companion precedes them with the encode options it resolved
    when the request asked for any, and with a description of the audio when it recorded some;
    those frames carry no video, so they are collected into `applied` and `audio` rather than
    yielded as empty chunks."""
    async for response in stream:
        output = response.WhichOneof("output")
        if output == "applied":
            if applied is not None:
                applied.append(response.applied)
        elif output == "audio":
            if audio is not None:
                audio.append(response.audio)
        elif output == "payload":
            yield response.payload.data


def recorded_audio_from_grpc(audio: RecordResponse.Audio) -> RecordedAudio:
    return RecordedAudio(
        offset=audio.offset,
        frames=audio.frames,
        sample_rate=audio.sample_rate,
        wav_file_path=audio.wav_file_path or None,
        processes=[
            RecordedAudioProcess(
                pid=process.pid,
                name=process.name,
                frames=process.frames,
                dropped_frames=(
                    process.dropped_frames if process.dropped_frames >= 0 else None
                ),
                unmixed_frames=process.unmixed_frames,
                realignments=process.realignments,
            )
            for process in audio.processes
        ],
        failures=list(audio.failures),
    )
