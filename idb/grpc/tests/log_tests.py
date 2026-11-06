#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
from collections.abc import AsyncIterator
from unittest import IsolatedAsyncioTestCase
from unittest.mock import AsyncMock, MagicMock, patch

from idb.grpc.client import Client
from idb.grpc.idb_pb2 import LogRequest, LogResponse
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.utils.testing import TestCase


class MockMessage:
    """Mock gRPC message with output bytes."""

    __slots__ = ["output"]

    def __init__(self, output: bytes) -> None:
        self.output = output


class LogDecodingTest(IsolatedAsyncioTestCase):
    """Tests for UTF-8 decoding in log streaming.

    These tests validate that the incremental UTF-8 decoder properly handles
    multi-byte characters that may be split across message boundaries, which
    can occur when streaming logs over gRPC with 64KB buffer boundaries.
    """

    async def test_tail_specific_logs_handles_split_multibyte_at_boundary(
        self,
    ) -> None:
        """Test that _tail_specific_logs properly handles split multi-byte UTF-8 chars.

        This test simulates the real-world scenario where a multi-byte UTF-8 character
        (like "…" which is 0xe2 0x80 0xa6) gets split at a 64KB buffer boundary.
        Without the incremental decoder fix, this would raise UnicodeDecodeError.
        """
        # Create mock messages that simulate a split multi-byte character
        # "Hello…world" where "…" (ellipsis = 0xe2 0x80 0xa6) is split across messages
        chunk1 = b"Hello\xe2"  # First byte of ellipsis at end
        chunk2 = b"\x80\xa6world"  # Remaining bytes of ellipsis at start

        messages = [MockMessage(chunk1), MockMessage(chunk2)]

        # Create a mock client with mocked stub
        mock_stub = MagicMock()
        mock_stream = AsyncMock()
        mock_stream.send_message = AsyncMock()

        # Create an async iterator for the messages
        async def mock_message_iterator() -> AsyncIterator[MockMessage]:
            for msg in messages:
                yield msg

        mock_stream.__aenter__ = AsyncMock(return_value=mock_stream)
        mock_stream.__aexit__ = AsyncMock(return_value=None)
        mock_stub.log.open = MagicMock(return_value=mock_stream)

        # Mock cancel_wrapper to just iterate over the stream
        with patch("idb.grpc.client.cancel_wrapper") as mock_cancel_wrapper:
            mock_cancel_wrapper.return_value = mock_message_iterator()

            # Create client instance
            client = Client.__new__(Client)
            client.stub = mock_stub

            # Call _tail_specific_logs and collect results
            stop_event = asyncio.Event()
            results = []
            async for decoded_str in client._tail_specific_logs(
                source=LogRequest.TARGET,
                stop=stop_event,
                arguments=None,
            ):
                results.append(decoded_str)

        # Verify the multi-byte character was properly decoded across chunks
        combined = "".join(results)
        self.assertEqual(
            combined,
            "Hello…world",
            "The split multi-byte character should be properly decoded. "
            "If this fails with UnicodeDecodeError or shows replacement characters, "
            "the incremental decoder fix is not working correctly.",
        )

    async def test_tail_specific_logs_handles_invalid_utf8_gracefully(self) -> None:
        """Test that truly invalid UTF-8 sequences are replaced, not crashed on."""
        # 0xff is never valid in UTF-8
        chunk = b"Hello \xff world"

        messages = [MockMessage(chunk)]

        mock_stub = MagicMock()
        mock_stream = AsyncMock()
        mock_stream.send_message = AsyncMock()

        async def mock_message_iterator() -> AsyncIterator[MockMessage]:
            for msg in messages:
                yield msg

        mock_stream.__aenter__ = AsyncMock(return_value=mock_stream)
        mock_stream.__aexit__ = AsyncMock(return_value=None)
        mock_stub.log.open = MagicMock(return_value=mock_stream)

        with patch("idb.grpc.client.cancel_wrapper") as mock_cancel_wrapper:
            mock_cancel_wrapper.return_value = mock_message_iterator()

            client = Client.__new__(Client)
            client.stub = mock_stub

            stop_event = asyncio.Event()
            results = []
            # This should NOT raise an exception
            async for decoded_str in client._tail_specific_logs(
                source=LogRequest.TARGET,
                stop=stop_event,
                arguments=None,
            ):
                results.append(decoded_str)

        combined = "".join(results)
        # The invalid byte should be replaced with the Unicode replacement character
        self.assertEqual(combined, "Hello \ufffd world")


class LogStreamTests(TestCase):
    async def test_target_and_companion_requests_cancel_and_eof(self) -> None:
        target_arguments: tuple[tuple[str, list[str] | None], ...] = (
            ("implicit", None),
            ("empty", []),
            ("collect", ["collect"]),
            ("config", ["config"]),
            ("erase", ["erase"]),
            ("show", ["show"]),
            ("stream", ["stream", "--style", "json"]),
            ("stats", ["stats"]),
            ("native", ["unrecognized", "--native-flag"]),
        )
        cases = (
            (
                "companion",
                True,
                None,
                LogRequest(source=LogRequest.COMPANION),
            ),
            *(
                (
                    name,
                    False,
                    arguments,
                    LogRequest(arguments=arguments, source=LogRequest.TARGET),
                )
                for name, arguments in target_arguments
            ),
        )

        for name, companion, arguments, expected_request in cases:
            for termination in ("cancel", "eof"):
                with self.subTest(name=name, termination=termination):
                    stream = ScriptedStream(
                        LogResponse(output=b"log"),
                        block_after_responses=termination == "cancel",
                    )
                    client, open_rpc = make_client("log", stream)
                    stop = asyncio.Event()
                    iterator = (
                        client.tail_companion_logs(stop=stop)
                        if companion
                        else client.tail_logs(stop=stop, arguments=arguments)
                    )

                    self.assertEqual(await anext(iterator), "log")
                    if termination == "cancel":
                        stop.set()
                    with self.assertRaises(StopAsyncIteration):
                        await anext(iterator)

                    self.assertEqual(stream.sent, [(expected_request, True)])
                    self.assertEqual(
                        sum(action == "cancel" for action, _ in stream.transcript),
                        1 if termination == "cancel" else 0,
                    )
                    self.assertEqual(
                        stream.read_cancellations,
                        1 if termination == "cancel" else 0,
                    )
                    self.assertNotIn(("end", None), stream.transcript)
                    open_rpc.assert_called_once_with()
                    self.assertTrue(stream.entered)
                    self.assertTrue(stream.exited)
