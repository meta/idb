#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

from grpclib.const import Status
from grpclib.exceptions import GRPCError, ProtocolError
from idb.common.types import IdbException
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import InjectVideoRequest, InjectVideoResponse
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.utils.testing import TestCase


class _CompanionStream(ScriptedStream[InjectVideoResponse]):
    """Holds the response stream open until the client ends its side."""

    def __init__(self, *responses: InjectVideoResponse) -> None:
        super().__init__(*responses, block_after_responses=True)

    async def end(self) -> None:
        await super().end()
        self._block_after_responses = False


class _EndedByCompanionStream(ScriptedStream[InjectVideoResponse]):
    """Exits as grpclib's client stream does after the companion ends the RPC:
    it reads the companion's status only if the client has ended its side."""

    def __init__(
        self, *responses: InjectVideoResponse, error: GRPCError | None = None
    ) -> None:
        super().__init__(*responses)
        self._error = error

    async def __aexit__(self, exc_type: object, *_args: object) -> None:
        await super().__aexit__(exc_type, *_args)
        if exc_type is not None:
            return
        if ("end", None) not in self.transcript:
            raise ProtocolError("Outgoing stream was not ended")
        if self._error is not None:
            raise self._error


async def _drain(client: Client, back_path: str, front_path: str | None) -> None:
    async for _ in client.inject_video(
        back_path=back_path, front_path=front_path, loop=False, stop=asyncio.Event()
    ):
        pass


class InjectVideoTest(TestCase):
    async def test_starts_with_canonical_paths_and_yields_each_process_list(
        self,
    ) -> None:
        stream = _EndedByCompanionStream(
            InjectVideoResponse(),
            InjectVideoResponse(processes=["Camera"]),
            InjectVideoResponse(processes=["Camera", "Recorder"]),
        )
        client, open_rpc = make_client("inject_video", stream, is_local=True)
        stop = asyncio.Event()
        with TemporaryDirectory() as directory:
            back = Path(directory) / "back.mp4"
            back.write_bytes(b"back")
            front = Path(directory) / "front.mp4"
            front.write_bytes(b"front")
            link = Path(directory) / "link.mp4"
            link.symlink_to(back)

            seen = [
                processes
                async for processes in client.inject_video(
                    back_path=str(link), front_path=str(front), loop=False, stop=stop
                )
            ]
            expected_start = InjectVideoRequest.Start(
                back_path=str(back.resolve()),
                front_path=str(front.resolve()),
                loop=False,
            )

        self.assertEqual(seen, [[], ["Camera"], ["Camera", "Recorder"]])
        self.assertEqual(
            stream.sent, [(InjectVideoRequest(start=expected_start), False)]
        )
        self.assertEqual(stream.transcript[-2:], [("recv", None), ("end", None)])
        self.assertTrue(stream.exited)
        open_rpc.assert_called_once_with()

    async def test_a_companion_error_reaches_the_caller(self) -> None:
        message = "/tmp/back.mp4 holds no playable video track: Cannot Open"
        stream = _EndedByCompanionStream(
            error=GRPCError(Status.INVALID_ARGUMENT, message)
        )
        client, _ = make_client("inject_video", stream, is_local=True)
        stop = asyncio.Event()
        with TemporaryDirectory() as directory:
            back = Path(directory) / "back.mp4"
            back.write_bytes(b"back")
            with self.assertRaises(IdbException) as raised:
                async for _ in client.inject_video(
                    back_path=str(back), front_path=None, loop=False, stop=stop
                ):
                    pass
        stop.set()
        await asyncio.sleep(0)

        self.assertEqual(str(raised.exception), message)

    async def test_stopping_sends_stop_and_waits_for_the_companion_to_finish(
        self,
    ) -> None:
        stream = _CompanionStream(InjectVideoResponse())
        client, _ = make_client("inject_video", stream, is_local=True)
        stop = asyncio.Event()
        with TemporaryDirectory() as directory:
            back = Path(directory) / "back.mp4"
            back.write_bytes(b"back")
            iterator = client.inject_video(
                back_path=str(back), front_path=None, loop=True, stop=stop
            )

            self.assertEqual(await anext(iterator), [])
            stop.set()
            with self.assertRaises(StopAsyncIteration):
                await anext(iterator)

        # Let the read that stopping abandoned finish cancelling.
        await asyncio.sleep(0)
        [(start, _), (stop_request, _)] = stream.sent
        self.assertEqual(start.start.front_path, "")
        self.assertTrue(start.start.loop)
        self.assertEqual(
            stop_request, InjectVideoRequest(stop=InjectVideoRequest.Stop())
        )
        self.assertEqual(stream.read_cancellations, 1)
        self.assertEqual(
            stream.transcript[-3:],
            [("send", stop_request), ("end", None), ("recv", None)],
        )

    async def test_rejects_a_remote_companion_before_opening_the_rpc(self) -> None:
        client, open_rpc = make_client("inject_video", ScriptedStream(), is_local=False)
        with TemporaryDirectory() as directory:
            back = Path(directory) / "back.mp4"
            back.write_bytes(b"back")
            with self.assertRaisesRegex(IdbException, "companion on this host"):
                await _drain(client, str(back), None)
        open_rpc.assert_not_called()

    async def test_rejects_non_files_before_opening_the_rpc(self) -> None:
        with TemporaryDirectory() as directory:
            back = Path(directory) / "back.mp4"
            back.write_bytes(b"back")
            missing = str(Path(directory) / "missing.mp4")
            for back_path, front_path in [
                (missing, None),
                (directory, None),
                (str(back), missing),
                (str(back), directory),
            ]:
                client, open_rpc = make_client(
                    "inject_video", ScriptedStream(), is_local=True
                )
                with self.assertRaisesRegex(IdbException, "not a regular file"):
                    await _drain(client, back_path, front_path)
                open_rpc.assert_not_called()
