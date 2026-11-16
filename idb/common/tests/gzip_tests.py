#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import gzip
import os
import tempfile
from collections.abc import AsyncIterator

from idb.common.gzip import drain_gzip_decompress, generate_gzip
from idb.utils.testing import TestCase


async def _chunks(data: bytes, size: int) -> AsyncIterator[bytes]:
    for offset in range(0, len(data), size):
        yield data[offset : offset + size]


class GzipTests(TestCase):
    async def test_decompress_to_path_with_apostrophe(self) -> None:
        payload = b"video bytes"
        with tempfile.TemporaryDirectory() as tmp:
            output = os.path.join(tmp, "Bob's capture.mp4")
            await drain_gzip_decompress(
                _chunks(gzip.compress(payload), 1024), output_path=output
            )
            with open(output, "rb") as f:
                self.assertEqual(f.read(), payload)

    async def test_compress_path_with_apostrophe(self) -> None:
        payload = b"dylib bytes"
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "Bob's library.dylib")
            with open(path, "wb") as f:
                f.write(payload)
            compressed = b"".join([chunk async for chunk in generate_gzip(path)])
            self.assertEqual(gzip.decompress(compressed), payload)

    async def test_decompressed_file_is_complete_when_drain_returns(self) -> None:
        # Large enough that gunzip is still writing when the last byte reaches its stdin.
        payload = os.urandom(1024 * 1024) * 64
        with tempfile.TemporaryDirectory() as tmp:
            output = os.path.join(tmp, "out.bin")
            await drain_gzip_decompress(
                _chunks(gzip.compress(payload, compresslevel=1), 1024 * 1024),
                output_path=output,
            )
            self.assertEqual(os.path.getsize(output), len(payload))
            with open(output, "rb") as f:
                self.assertEqual(f.read(), payload)

    async def test_truncated_stream_raises(self) -> None:
        compressed = gzip.compress(os.urandom(1024 * 1024))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError):
                await drain_gzip_decompress(
                    _chunks(compressed[: len(compressed) // 2], 64 * 1024),
                    output_path=os.path.join(tmp, "out.bin"),
                )
