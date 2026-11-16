#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import asyncio
from collections import deque
from collections.abc import AsyncIterator
from typing import Generic, TypeVar
from unittest.mock import MagicMock

from idb.common.types import CompanionInfo, DomainSocketAddress
from idb.grpc.client import Client


_Response = TypeVar("_Response")


class ScriptedStream(Generic[_Response], AsyncIterator[_Response]):
    def __init__(
        self,
        *responses: _Response,
        block_after_responses: bool = False,
        trailing_error: Exception | None = None,
        recv_error: Exception | None = None,
    ) -> None:
        self._responses = deque(responses)
        self._block_after_responses = block_after_responses
        self._trailing_error = trailing_error
        self._recv_error = recv_error
        self.sent: list[tuple[object, bool]] = []
        self.transcript: list[tuple[str, object | None]] = []
        self.read_cancellations = 0
        self.entered = False
        self.exited = False

    async def __aenter__(self) -> ScriptedStream[_Response]:
        self.entered = True
        return self

    async def __aexit__(self, *_args: object) -> None:
        self.exited = True

    def __aiter__(self) -> AsyncIterator[_Response]:
        return self

    async def __anext__(self) -> _Response:
        response = await self.recv_message()
        if response is None:
            raise StopAsyncIteration
        return response

    async def send_message(self, message: object, *, end: bool = False) -> None:
        self.sent.append((message, end))
        self.transcript.append(("send", message))

    async def recv_message(self) -> _Response | None:
        if self._responses:
            response = self._responses.popleft()
            self.transcript.append(("recv", response))
            return response
        if self._recv_error is not None:
            self.transcript.append(("recv_error", None))
            raise self._recv_error
        if not self._block_after_responses:
            self.transcript.append(("recv", None))
            return None

        blocker: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        try:
            await blocker
        except asyncio.CancelledError:
            self.read_cancellations += 1
            raise
        return None

    async def cancel(self) -> None:
        self.transcript.append(("cancel", None))
        await asyncio.sleep(0)

    async def end(self) -> None:
        self.transcript.append(("end", None))

    async def recv_trailing_metadata(self) -> None:
        self.transcript.append(("trailers", None))
        if self._trailing_error is not None:
            raise self._trailing_error


def make_client(
    rpc_name: str,
    stream: object,
    *,
    is_local: bool | None = None,
) -> tuple[Client, MagicMock]:
    open_rpc = MagicMock(return_value=stream)
    stub = MagicMock()
    setattr(stub, rpc_name, MagicMock(open=open_rpc))

    client = Client.__new__(Client)
    client.stub = stub
    client.logger = MagicMock()
    if is_local is not None:
        client.companion = CompanionInfo(
            udid="udid",
            is_local=is_local,
            pid=None,
            address=DomainSocketAddress(path="idb.sock"),
        )
    return client, open_rpc
