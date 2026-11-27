#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import replace
from unittest import mock

from idb.common.companion import (
    Companion,
    CompanionReport,
    CompanionServerConfig,
    CompanionSpawnerException,
)
from idb.common.types import TargetType
from idb.utils.testing import AsyncMock, ignoreTaskLeaks, TestCase


@ignoreTaskLeaks
class CompanionTests(TestCase):
    def setUp(self) -> None:
        self.udid = "someUdid"
        self.spawner = Companion(
            companion_path="idb_path", device_set_path=None, logger=mock.Mock()
        )
        self.spawner._log_file_path = mock.Mock()
        self.companion_server_config = CompanionServerConfig(
            udid=self.udid,
            only=TargetType.SIMULATOR,
            log_file_path=None,
            cwd=None,
            tmp_path=None,
            reparent=True,
        )
        self.exec_mock_common_args = {
            "stdout": mock.ANY,
            "stderr": mock.ANY,
            "stdin": mock.ANY,
            "cwd": None,
            "preexec_fn": os.setpgrp,
        }

    @asynccontextmanager
    async def _mock_all_the_things(
        self, report: CompanionReport
    ) -> AsyncIterator[AsyncMock]:
        with (
            mock.patch(
                "idb.common.companion.asyncio.create_subprocess_exec",
                new=AsyncMock(),
            ) as exec_mock,
            mock.patch("idb.common.companion.open"),
            mock.patch("idb.common.companion.get_last_n_lines"),
        ):
            process_mock = mock.Mock()
            process_mock.stdout.readline = AsyncMock(
                return_value=json.dumps(report).encode("utf-8")
            )
            exec_mock.return_value = process_mock
            yield exec_mock

    async def test_spawn_tcp_server(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234}
        ) as exec_mock:
            (_, port, swift_port) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=1234,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env=os.environ,
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)
            self.assertIsNone(swift_port)

    async def test_spawn_tcp_server_with_tmp_path(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234}
        ) as exec_mock:
            await self.spawner.spawn_tcp_server(
                config=replace(self.companion_server_config, tmp_path="/some/tmp"),
                port=1234,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env={
                    **os.environ,
                    "IDB_COMPANION_TMPDIR": "/some/tmp",
                    "TMPDIR": "/some/tmp",
                },
                **self.exec_mock_common_args,
            )

    async def test_spawn_tcp_server_auto_bind(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234}
        ) as exec_mock:
            (_, port, swift_port) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=None,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "0",
                "--only",
                "simulator",
                env=os.environ,
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)
            self.assertIsNone(swift_port)

    async def test_spawn_tcp_server_broken_report(self) -> None:
        async with self._mock_all_the_things({"hostname": "myHost"}) as exec_mock:
            with self.assertRaisesRegex(
                CompanionSpawnerException, r".*couldn\'t read.*"
            ):
                await self.spawner.spawn_tcp_server(
                    config=self.companion_server_config,
                    port=1234,
                )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env=os.environ,
                **self.exec_mock_common_args,
            )

    async def test_spawn_tcp_server_port_mismatch(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 0}
        ) as exec_mock:
            with self.assertRaisesRegex(
                CompanionSpawnerException, r".*zero is invalid.*"
            ):
                await self.spawner.spawn_tcp_server(
                    config=self.companion_server_config,
                    port=1234,
                )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env=os.environ,
                **self.exec_mock_common_args,
            )

    async def test_spawn_tcp_server_with_debug_port(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234}
        ) as exec_mock:
            (_, port, _) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=1234,
                debug_port=1233,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--debug-port",
                "1233",
                "--only",
                "simulator",
                env=os.environ,
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)

    async def test_spawn_tcp_server_with_swift(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234, "grpc_swift_port": 1235}
        ) as exec_mock:
            (_, port, swift_port) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=1234,
                swift_port=1235,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env={**os.environ, "IDB_SWIFT_COMPANION_PORT": "1235"},
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)
            self.assertEqual(swift_port, 1235)

    async def test_spawn_tcp_server_with_swift_missing_from_report(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234}
        ) as exec_mock:
            (_, port, swift_port) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=1234,
                swift_port=1235,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env={**os.environ, "IDB_SWIFT_COMPANION_PORT": "1235"},
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)
            self.assertIsNone(swift_port)

    async def test_spawn_tcp_server_with_swift_port_mismatch(self) -> None:
        async with self._mock_all_the_things(
            {"hostname": "myHost", "grpc_port": 1234, "grpc_swift_port": 42}
        ) as exec_mock:
            (_, port, swift_port) = await self.spawner.spawn_tcp_server(
                config=self.companion_server_config,
                port=1234,
                swift_port=1235,
            )
            exec_mock.assert_called_once_with(
                "idb_path",
                "--udid",
                self.udid,
                "--grpc-port",
                "1234",
                "--only",
                "simulator",
                env={**os.environ, "IDB_SWIFT_COMPANION_PORT": "1235"},
                **self.exec_mock_common_args,
            )
            self.assertEqual(port, 1234)
            self.assertIsNone(swift_port)
