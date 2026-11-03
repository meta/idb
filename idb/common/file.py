#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from collections.abc import AsyncIterator

import aiofiles


def get_last_n_lines(file_path: str, n: int) -> str:
    with open(file_path) as f:
        return "".join(f.readlines()[-n:])


async def generate_file_chunks(file_path: str) -> AsyncIterator[bytes]:
    async with aiofiles.open(file_path, "rb") as f:
        while chunk := await f.read(4 * 1024 * 1024):
            yield chunk


async def drain_to_file(stream: AsyncIterator[bytes], file_path: str) -> None:
    async with aiofiles.open(file_path, "w+b") as f:
        async for data in stream:
            await f.write(data)
