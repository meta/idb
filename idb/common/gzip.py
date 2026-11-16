#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import sys
from collections.abc import AsyncGenerator, AsyncIterator

from idb.common.types import IdbException
from idb.utils.contextlib import asynccontextmanager
from idb.utils.typing import none_throws


READ_CHUNK_SIZE: int = 1024 * 1024 * 4  # 4Mb, the default max read for gRPC


@asynccontextmanager
async def _create_gzip_decompress_command(
    extract_path: str,
) -> AsyncGenerator[asyncio.subprocess.Process, None]:
    process = await asyncio.create_subprocess_shell(
        f"gunzip -v > '{extract_path}'",
        stdin=asyncio.subprocess.PIPE,
        stderr=sys.stderr,
        stdout=sys.stdout,
    )
    yield process


@asynccontextmanager
async def _create_gzip_compress_command(
    path: str,
) -> AsyncGenerator[asyncio.subprocess.Process, None]:
    process = await asyncio.create_subprocess_shell(
        f"gzip -v '{path}' --to-stdout",
        stdin=asyncio.subprocess.PIPE,
        stderr=sys.stderr,
        stdout=asyncio.subprocess.PIPE,
    )
    yield process


async def drain_gzip_decompress(stream: AsyncIterator[bytes], output_path: str) -> None:
    async with _create_gzip_decompress_command(extract_path=output_path) as process:
        writer = none_throws(process.stdin)
        stopped_reading = False
        try:
            async for data in stream:
                writer.write(data)
                await writer.drain()
            writer.write_eof()
            await writer.drain()
        except (BrokenPipeError, ConnectionResetError):
            # gunzip exits on input it cannot decompress without reading the rest.
            stopped_reading = True
        # gunzip is still writing output_path after its stdin closes, and the last bytes it was
        # sent only reach it if the event loop outlives the pipe transport's buffer.
        returncode = await process.wait()
    # Not an OSError: the client reads one of those as a companion it can no longer reach.
    if returncode != 0 or stopped_reading:
        raise IdbException(
            f"gunzip exited with {returncode} decompressing to {output_path}"
        )


async def generate_gzip(path: str) -> AsyncIterator[bytes]:
    async with _create_gzip_compress_command(path=path) as process:
        reader = none_throws(process.stdout)
        while not reader.at_eof():
            data = await reader.read(READ_CHUNK_SIZE)
            if not data:
                return
            yield data


async def _stream_from_data(data: bytes) -> AsyncIterator[bytes]:
    yield data


async def gunzip(data: bytes, output_path: str) -> None:
    await drain_gzip_decompress(
        stream=_stream_from_data(data=data),
        output_path=output_path,
    )
