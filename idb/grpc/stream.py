#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
from collections.abc import AsyncIterator
from logging import Logger
from typing import Generic, TypeVar

from idb.utils.typing import none_throws


_TSend = TypeVar("_TSend")
_TRecv = TypeVar("_TRecv")


class Stream(Generic[_TSend, _TRecv], AsyncIterator[_TRecv]):
    metadata: dict[str, str] = {}

    async def recv_message(self) -> _TRecv | None: ...

    async def send_message(self, message: _TSend) -> None: ...

    async def end(self) -> None: ...

    async def cancel(self) -> None: ...


async def drain_to_stream(
    stream: Stream[_TSend, _TRecv], generator: AsyncIterator[_TSend], logger: Logger
) -> _TRecv:
    while True:
        async for message in generator:
            await stream.send_message(message)
        await stream.end()
        logger.debug("Streamed all chunks to companion, waiting for completion")
        response = none_throws(await stream.recv_message())
        logger.debug("Companion completed")
        return response


async def generate_bytes(
    stream: AsyncIterator[object], logger: Logger | None = None
) -> AsyncIterator[bytes]:
    async for item in stream:
        log_output = getattr(item, "log_output", None)
        if log_output is not None and len(log_output) and logger:
            logger.info(log_output)
            continue
        payload = getattr(item, "payload", None)
        if payload is None:
            continue
        data = getattr(payload, "data", None)
        if data is None:
            continue
        if not len(data):
            continue
        yield data


async def stop_wrapper(
    stream: Stream[_TSend, _TRecv], stop: asyncio.Event
) -> AsyncIterator[_TRecv]:
    stop_future = asyncio.ensure_future(stop.wait())
    try:
        while True:
            read = asyncio.ensure_future(stream.recv_message())
            done, pending = await asyncio.wait(
                [stop_future, read], return_when=asyncio.FIRST_COMPLETED
            )
            if stop_future in done:
                read.cancel()
                return
            result = read.result()
            if result is None:
                # Reached the end of the stream
                return
            yield result
    finally:
        # The CLI waits for every pending task before it exits, and stop may
        # never be set once the stream has ended on its own.
        stop_future.cancel()
        await asyncio.wait([stop_future])


async def cancel_wrapper(
    stream: Stream[_TSend, _TRecv], stop: asyncio.Event
) -> AsyncIterator[_TRecv]:
    async for event in stop_wrapper(stream, stop):
        yield event
    if stop.is_set():
        await stream.cancel()
