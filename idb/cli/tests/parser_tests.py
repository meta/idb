#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import json
import logging
import os
import sys
import tempfile
from argparse import ArgumentParser, Namespace
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, redirect_stderr, redirect_stdout
from io import BytesIO, StringIO, TextIOWrapper
from types import ModuleType
from typing import Any, TypeVar
from unittest.mock import ANY, MagicMock, patch

from idb.cli import print_upload_progress
from idb.cli.commands.xctest import NO_SPECIFIED_PATH
from idb.cli.main import gen_main as cli_main, get_default_companion_path
from idb.common import plugin
from idb.common.command import Command, CommandGroup
from idb.common.types import (
    AccessibilityBackend,
    AccessibilityClientType,
    AccessibilityDragOptions,
    AccessibilityElementFilter,
    AccessibilityInfo,
    AccessibilityInfoOptions,
    AccessibilityMarker,
    AccessibilityOutputFormat,
    AccessibilityPoint,
    AccessibilityScrollDirection,
    AccessibilitySearchableKey,
    AccessibilitySearchDiagnostics,
    AccessibilityWaitResult,
    AppScreenshotCapture,
    CompanionInfo,
    Compression,
    CrashLogQuery,
    DeliveredNotification,
    DeviceOrientation,
    DomainSocketAddress,
    FileContainerType,
    HIDButtonType,
    HIDDelay,
    HIDDirection,
    HIDOrientationType,
    IdbException,
    InstalledArtifact,
    LockState,
    LoggingMetadata,
    Permission,
    ProfileAllProcesses,
    ProfileBundleID,
    ProfileLaunch,
    ProfilePid,
    ProfileResult,
    QuiescenceBackend,
    QuiescenceEvent,
    QuiescenceState,
    QuiescenceStateChanged,
    QuiescenceTargetChanged,
    QuiescenceTargetExited,
    QuiescenceTouchesCompleted,
    RetryVerdict,
    Screenshot,
    ScreenshotCrop,
    ScreenshotFormat,
    ScreenshotOptions,
    ScreenshotUnit,
    TargetType,
    TCPAddress,
    TraceProfile,
)
from idb.grpc.idb_pb2 import AccessibilityInfoRequest
from idb.utils.testing import AsyncContextManagerMock, AsyncMock, TestCase


T = TypeVar("T")
COMPANION_PATH: str | None = get_default_companion_path()
DELIVERED_NOTIFICATION = DeliveredNotification(
    bundle_id="com.foo.bar",
    identifier="identifier-1",
    title="Title",
    subtitle="Subtitle",
    body="Body",
    thread_identifier="thread-1",
    date=1700000000.0,
)
AWKWARD_DELIVERED_NOTIFICATION = DeliveredNotification(
    bundle_id="com.foo.bar",
    identifier="",
    title="Line one\nLine two \u0085\u2028\u2029🚀",
    subtitle="",
    body='Body with a | separator, a "quote" and 日本語',
    thread_identifier="",
    date=None,
)
UNREADABLE_DATE_DELIVERED_NOTIFICATION = DeliveredNotification(
    bundle_id="com.foo.bar",
    identifier="identifier-3",
    title="Title",
    subtitle="Subtitle",
    body="Body",
    thread_identifier="thread-3",
    # Past what `time_t` can hold, which a device with a bad clock can report.
    date=1e20,
)
NAN_DATE_DELIVERED_NOTIFICATION = DeliveredNotification(
    bundle_id="com.foo.bar",
    identifier="identifier-4",
    title="Title",
    subtitle="Subtitle",
    body="Body",
    thread_identifier="thread-4",
    date=float("nan"),
)
INFINITE_DATE_DELIVERED_NOTIFICATION = DeliveredNotification(
    bundle_id="com.foo.bar",
    identifier="identifier-5",
    title="Title",
    subtitle="Subtitle",
    body="Body",
    thread_identifier="thread-5",
    date=float("inf"),
)


def _strict_json_loads(line: str) -> Any:
    """Parses a line the way a reader that is not Python's would.

    `json.loads` accepts the bare `Infinity` and `NaN` that `json.dumps` writes for
    a non-finite double, and readers in other languages do not, so asserting with it
    alone would pass on output nothing else could take. `parse_constant` is the hook
    those tokens go through, and raising from it is what makes this reject them.
    """

    def reject(token: str) -> Any:
        raise AssertionError(f"`{token}` is not a value a strict JSON reader accepts")

    return json.loads(line, parse_constant=reject)


class AsyncGeneratorMock(AsyncMock):
    def __call__(self) -> None:
        super()

    def __init__(self, iter_list: tuple[T, ...] = ()) -> None:
        super().__init__()
        # pyrefly: ignore [invalid-type-var]
        self.iter_list = iter_list
        self.iter_pos: int = -1

    def __aiter__(self) -> AsyncMock:
        self.iter_pos = -1
        return self

    async def __anext__(self) -> MagicMock:
        try:
            self.iter_pos += 1
            return self.iter_list[self.iter_pos]
        except IndexError:
            raise StopAsyncIteration()


class _AppCapturePlugin(ModuleType):
    def __init__(self, image: object, error: Exception | None = None) -> None:
        super().__init__("app_capture")
        self.image = image
        self.error = error
        self.capture = AsyncMock(side_effect=error, return_value=image)

    async def capture_app_screenshot(
        self, client: object, bundle_id: str, options: ScreenshotOptions
    ) -> object:
        return await self.capture(client, bundle_id, options)


class TestParser(TestCase):
    def __init__(self, *args: Any, **kws: Any) -> None:
        super().__init__(*args, **kws)

    def setUp(self) -> None:
        self.client_mock = MagicMock(name="client_mock")
        self.client_mock.build.return_value = AsyncContextManagerMock(
            return_value=self.client_mock
        )
        self.client_manager_mock = MagicMock(name="client_manager_mock")
        self.client_manager_mock().from_udid.return_value = AsyncContextManagerMock(
            return_value=self.client_mock
        )
        self.client_manager_patch = patch(
            "idb.cli.GrpcClientManager", self.client_manager_mock
        )
        self.client_manager_patch.start()
        self.client_patch = patch("idb.cli.GrpcClient", self.client_mock)
        self.client_patch.start()
        self.companion_mock = MagicMock(name="companion_mock")
        self.companion_patch = patch("idb.cli.LocalCompanion", self.companion_mock)
        self.companion_patch.start()

    def tearDown(self) -> None:
        self.client_manager_patch.stop()
        self.client_patch.stop()
        self.companion_patch.stop()

    async def test_launch_with_udid(self) -> None:
        bundle_id = "com.foo.app"
        udid = "my udid"
        self.client_mock.launch = AsyncMock(return_value=bundle_id)
        await cli_main(cmd_input=["launch", "--udid", udid, bundle_id])
        self.client_mock.launch.assert_called_once_with(
            bundle_id=bundle_id,
            env={},
            args=[],
            foreground_if_running=False,
            wait_for_debugger=False,
            stop=None,
            pid_file=None,
            enable_repl=False,
        )

    async def test_launch_with_pid_file(self) -> None:
        bundle_id = "com.foo.app"
        udid = "my udid"
        pid_file = "/tmp/fifo-file"
        self.client_mock.launch = AsyncMock(return_value=bundle_id)
        await cli_main(
            cmd_input=["launch", "--pid-file", pid_file, "--udid", udid, bundle_id]
        )
        self.client_mock.launch.assert_called_once_with(
            bundle_id=bundle_id,
            env={},
            args=[],
            foreground_if_running=False,
            wait_for_debugger=False,
            stop=None,
            pid_file=pid_file,
            enable_repl=False,
        )

    async def test_launch_with_enable_repl(self) -> None:
        bundle_id = "com.foo.app"
        udid = "my udid"
        self.client_mock.launch = AsyncMock(return_value=bundle_id)
        await cli_main(cmd_input=["launch", "--enable-repl", "--udid", udid, bundle_id])
        self.client_mock.launch.assert_called_once_with(
            bundle_id=bundle_id,
            env={},
            args=[],
            foreground_if_running=False,
            wait_for_debugger=False,
            stop=None,
            pid_file=None,
            enable_repl=True,
        )

    async def test_create(self) -> None:
        await cli_main(
            cmd_input=["--companion-path", "idb_companion", "create", "ipone", "os2"]
        )
        self.companion_mock().create.assert_called_once_with(
            device_type="ipone", os_version="os2"
        )

    async def test_boot(self) -> None:
        for command in [
            ["--companion-path", "idb_companion", "boot", "my_udid"],
            ["--companion-path", "idb_companion", "boot", "--udid", "my_udid"],
            [
                "--companion-path",
                "idb_companion",
                "boot",
                "--udid",
                "my_udid_old",
                "my_udid",
            ],
        ]:
            self.companion_mock().boot = AsyncMock()
            await cli_main(cmd_input=command)
            self.companion_mock().boot.assert_called_once_with(udid="my_udid")

    async def test_shutdown(self) -> None:
        udid = "my udid"
        await cli_main(
            cmd_input=["--companion-path", "idb_companion", "shutdown", udid]
        )
        self.companion_mock().shutdown.assert_called_once_with(udid=udid)

    async def test_erase(self) -> None:
        udid = "my udid"
        await cli_main(cmd_input=["--companion-path", "idb_companion", "erase", udid])
        self.companion_mock().erase.assert_called_once_with(udid=udid)

    async def test_clone(self) -> None:
        udid = "my udid"
        await cli_main(cmd_input=["--companion-path", "idb_companion", "clone", udid])
        self.companion_mock().clone.assert_called_once_with(udid=udid)

    async def test_delete(self) -> None:
        udid = "my udid"
        await cli_main(cmd_input=["--companion-path", "idb_companion", "delete", udid])
        self.companion_mock().delete.assert_called_once_with(udid=udid)

    async def test_delete_all(self) -> None:
        self.companion_mock().delete = AsyncMock()
        await cli_main(cmd_input=["--companion-path", "idb_companion", "delete-all"])
        self.companion_mock().delete.assert_called_once_with(udid=None)

    async def test_install(self) -> None:
        app_path = "testApp.app"
        self.client_mock.install = MagicMock(
            return_value=AsyncGeneratorMock(
                (
                    InstalledArtifact(
                        name="first.app", uuid="first-uuid", progress=50.0
                    ),
                    InstalledArtifact(
                        name="com.example.app", uuid="app-uuid", progress=0.0
                    ),
                )
            )
        )
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=["install", app_path]), 0)
        self.assertEqual(output.getvalue(), "Installed: com.example.app app-uuid\n")
        self.client_mock.install.assert_called_once_with(
            bundle=app_path,
            make_debuggable=None,
            compression=None,
            override_modification_time=None,
            connect_to=None,
            on_upload_progress=print_upload_progress,
        )

        self.client_mock.install = MagicMock(return_value=AsyncGeneratorMock())
        output = StringIO()
        with redirect_stdout(output), redirect_stderr(StringIO()):
            self.assertEqual(await cli_main(cmd_input=["install", app_path]), 1)
        self.assertEqual(output.getvalue(), "")
        self.client_mock.install.assert_called_once_with(
            bundle=app_path,
            make_debuggable=None,
            compression=None,
            override_modification_time=None,
            connect_to=None,
            on_upload_progress=print_upload_progress,
        )

    async def test_install_prints_upload_progress_to_stderr(self) -> None:
        async def install(
            **kwargs: Any,
        ) -> AsyncIterator[InstalledArtifact]:
            kwargs["on_upload_progress"]("Uploading: 1.0 MiB sent, 0.5 MiB/s")
            yield InstalledArtifact(
                name="com.example.app", uuid="app-uuid", progress=0.0
            )

        self.client_mock.install = install
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            self.assertEqual(
                await cli_main(cmd_input=["install", "--json", "testApp.ipa"]), 0
            )
        self.assertEqual(
            stdout.getvalue(),
            '{"installedAppBundleId": "com.example.app", "uuid": "app-uuid"}\n',
        )
        self.assertIn("Uploading: 1.0 MiB sent, 0.5 MiB/s\n", stderr.getvalue())

    async def test_install_from_stdin(self) -> None:
        self.client_mock.install = MagicMock(
            return_value=AsyncGeneratorMock(
                (
                    InstalledArtifact(
                        name="com.example.app", uuid="app-uuid", progress=None
                    ),
                )
            )
        )
        with redirect_stdout(StringIO()):
            self.assertEqual(await cli_main(cmd_input=["install", "-"]), 0)
        self.client_mock.install.assert_called_once_with(
            bundle=sys.stdin.buffer,
            make_debuggable=None,
            compression=None,
            override_modification_time=None,
            connect_to=None,
            on_upload_progress=print_upload_progress,
        )

    async def test_install_with_mtime_override(self) -> None:
        self.client_mock.install = MagicMock(
            return_value=AsyncGeneratorMock(
                (
                    InstalledArtifact(
                        name="com.example.app", uuid="app-uuid", progress=0.0
                    ),
                )
            )
        )
        app_path = "testApp.ipa"
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(
                await cli_main(cmd_input=["install", "--override-mtime", app_path]),
                0,
            )
        self.assertEqual(output.getvalue(), "Installed: com.example.app app-uuid\n")
        self.client_mock.install.assert_called_once_with(
            bundle=app_path,
            make_debuggable=None,
            compression=None,
            override_modification_time=True,
            connect_to=None,
            on_upload_progress=print_upload_progress,
        )

    async def test_install_with_connect_to(self) -> None:
        url = "https://cdn.example.com/a.ipa"
        for value, address in [
            ("192.0.2.1:443", TCPAddress(host="192.0.2.1", port=443)),
            ("[2001:db8::1]:8443", TCPAddress(host="2001:db8::1", port=8443)),
            ("lb.example.net:443", TCPAddress(host="lb.example.net", port=443)),
        ]:
            self.client_mock.install = MagicMock(
                return_value=AsyncGeneratorMock(
                    (
                        InstalledArtifact(
                            name="com.example.app", uuid="app-uuid", progress=0.0
                        ),
                    )
                )
            )
            with redirect_stdout(StringIO()):
                self.assertEqual(
                    await cli_main(cmd_input=["install", "--connect-to", value, url]),
                    0,
                )
            self.client_mock.install.assert_called_once_with(
                bundle=url,
                make_debuggable=None,
                compression=None,
                override_modification_time=None,
                connect_to=address,
                on_upload_progress=print_upload_progress,
            )

    async def test_install_with_a_malformed_connect_to(self) -> None:
        self.client_mock.install = MagicMock(return_value=AsyncGeneratorMock())
        for value in [
            "192.0.2.1",
            "2001:db8::1:443",
            "host:0",
            "host:65536",
            ":443",
            "[:443",
            "[host:443",
            "host]:443",
            "[a]b]:443",
        ]:
            with redirect_stderr(StringIO()):
                exit_code = await cli_main(
                    cmd_input=["install", "--connect-to", value, "https://a/b.ipa"]
                )
            self.assertEqual(exit_code, 1, value)
        self.client_mock.install.assert_not_called()

    async def test_install_with_bad_compression(self) -> None:
        self.client_mock.install = MagicMock(return_value=AsyncGeneratorMock())
        app_path = "testApp.app"
        exit_code = await cli_main(
            cmd_input=["--compression", "PZSTD", "install", app_path]
        )
        self.assertEqual(exit_code, 2)
        self.client_mock.install.assert_not_called()

    async def test_install_with_compression(self) -> None:
        self.client_mock.install = MagicMock(
            return_value=AsyncGeneratorMock(
                (
                    InstalledArtifact(
                        name="com.example.app", uuid="app-uuid", progress=0.0
                    ),
                )
            )
        )
        app_path = "testApp.app"
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(
                await cli_main(
                    cmd_input=["--compression", "ZSTD", "install", app_path]
                ),
                0,
            )
        self.assertEqual(output.getvalue(), "Installed: com.example.app app-uuid\n")
        self.client_mock.install.assert_called_once_with(
            bundle=app_path,
            make_debuggable=None,
            compression=Compression.ZSTD,
            override_modification_time=None,
            connect_to=None,
            on_upload_progress=print_upload_progress,
        )

    async def test_dsym_install(self) -> None:
        responses = (
            InstalledArtifact(name="ignored", uuid=None, progress=50.0),
            InstalledArtifact(name="Symbols.dSYM", uuid=None, progress=0.0),
        )
        self.client_mock.install_dsym = MagicMock(
            return_value=AsyncGeneratorMock(responses)
        )
        bundle_id = "com.example.app"
        command = [
            "--compression",
            "GZIP",
            "dsym",
            "install",
            "--bundle-id",
            bundle_id,
            "Symbols.dSYM",
        ]
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(
            output.getvalue(),
            "Installed 50.0%\nInstalled: Symbols.dSYM\n",
        )
        self.client_mock.install_dsym.assert_called_once_with(
            "Symbols.dSYM",
            bundle_id,
            Compression.GZIP,
            FileContainerType.APPLICATION,
            on_upload_progress=print_upload_progress,
        )

        self.client_mock.install_dsym = MagicMock(return_value=AsyncGeneratorMock())
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(output.getvalue(), "")

    async def test_dylib_install(self) -> None:
        responses = (
            InstalledArtifact(name="ignored", uuid=None, progress=50.0),
            InstalledArtifact(name="libExample.dylib", uuid="dylib-uuid", progress=0.0),
        )
        self.client_mock.install_dylib = MagicMock(
            return_value=AsyncGeneratorMock(responses)
        )
        command = ["dylib", "install", "libExample.dylib"]
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(
            output.getvalue(),
            "Installed 50.0%\nInstalled: libExample.dylib dylib-uuid\n",
        )
        self.client_mock.install_dylib.assert_called_once_with(
            "libExample.dylib", on_upload_progress=print_upload_progress
        )

        self.client_mock.install_dylib = MagicMock(return_value=AsyncGeneratorMock())
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(output.getvalue(), "")

    async def test_framework_install(self) -> None:
        responses = (
            InstalledArtifact(name="ignored", uuid=None, progress=50.0),
            InstalledArtifact(
                name="Example.framework", uuid="framework-uuid", progress=0.0
            ),
        )
        self.client_mock.install_framework = MagicMock(
            return_value=AsyncGeneratorMock(responses)
        )
        command = ["framework", "install", "Example.framework"]
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(
            output.getvalue(),
            "Installed 50.0%\nInstalled: Example.framework framework-uuid\n",
        )
        self.client_mock.install_framework.assert_called_once_with(
            "Example.framework", on_upload_progress=print_upload_progress
        )

        self.client_mock.install_framework = MagicMock(
            return_value=AsyncGeneratorMock()
        )
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(output.getvalue(), "")

    async def test_uninstall(self) -> None:
        self.client_mock.uninstall = AsyncMock()
        app_path = "com.dummy.app"
        await cli_main(cmd_input=["uninstall", app_path])
        self.client_mock.uninstall.assert_called_once_with(bundle_id=app_path)

    async def test_list_apps(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        await cli_main(cmd_input=["list-apps"])
        self.client_mock.list_apps.assert_called_once()

    async def test_list_apps_direct_companion_tcp(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=["--companion", "thehost:123", "--companion-tls", "list-apps"]
        )
        self.client_mock.list_apps.assert_called_once()
        self.client_mock.build.assert_called_once_with(
            address=TCPAddress(host="thehost", port=123),
            logger=ANY,
            use_tls=True,
        )

    async def test_list_apps_direct_companion_uxd(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        await cli_main(cmd_input=["--companion", "/foo/sock", "list-apps"])
        self.client_mock.list_apps.assert_called_once()
        self.client_mock.build.assert_called_once_with(
            address=DomainSocketAddress(path="/foo/sock"),
            logger=ANY,
            use_tls=False,
        )

    async def test_connect_with_host_and_port(self) -> None:
        self.client_manager_mock().connect = AsyncMock()
        host = "someHost"
        port = 1234
        await cli_main(cmd_input=["connect", host, str(port)])
        self.client_manager_mock().connect.assert_called_once_with(
            destination=TCPAddress(host=host, port=port),
        )

    async def test_connect_with_udid(self) -> None:
        self.client_manager_mock().connect = AsyncMock()
        udid = "0B3311FA-234C-4665-950F-37544F690B61"
        await cli_main(cmd_input=["connect", udid])
        self.client_manager_mock().connect.assert_called_once_with(
            destination=udid,
        )

    async def test_disconnect_with_host_and_port(self) -> None:
        self.client_manager_mock().disconnect = AsyncMock()
        host = "someHost"
        port = 1234
        await cli_main(cmd_input=["disconnect", host, str(port)])
        self.client_manager_mock().disconnect.assert_called_once_with(
            destination=TCPAddress(host=host, port=port)
        )

    async def test_disconnect_with_udid(self) -> None:
        self.client_manager_mock().disconnect = AsyncMock()
        udid = "0B3311FA-234C-4665-950F-37544F690B61"
        await cli_main(cmd_input=["disconnect", udid])
        self.client_manager_mock().disconnect.assert_called_once_with(destination=udid)

    async def test_mkdir(self) -> None:
        self.client_mock.mkdir = AsyncMock()
        src = "path"
        cmd_input = ["file", "mkdir", src]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.mkdir.assert_called_once_with(container=None, path=src)

    async def test_bundled_file_mkdir(self) -> None:
        self.client_mock.mkdir = AsyncMock()
        src = "path"
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "mkdir", src, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.mkdir.assert_called_once_with(container=bundle_id, path=src)

    async def test_rm(self) -> None:
        self.client_mock.rm = AsyncMock()
        src = "path"
        cmd_input = ["file", "remove", src]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.rm.assert_called_once_with(container=None, paths=[src])

    async def test_bundled_file_rmpath(self) -> None:
        self.client_mock.rm = AsyncMock()
        src = "path"
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "remove", src, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.rm.assert_called_once_with(container=bundle_id, paths=[src])

    async def test_bundled_file_rmpath_multiple(self) -> None:
        self.client_mock.rm = AsyncMock()
        srcs = ["pathA", "pathB"]
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "remove", srcs[0], srcs[1], "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.rm.assert_called_once_with(container=bundle_id, paths=srcs)

    async def test_list(self) -> None:
        self.client_mock.ls_single = AsyncMock(return_value=[])
        src = "path"
        cmd_input = ["file", "list", src]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.ls_single.assert_called_once_with(container=None, path=src)

    async def test_bundled_file_list(self) -> None:
        self.client_mock.ls_single = AsyncMock(return_value=[])
        src = "path"
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "list", src, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.ls_single.assert_called_once_with(
            container=bundle_id, path=src
        )

    async def test_file_move(self) -> None:
        self.client_mock.mv = AsyncMock(return_value=[])
        src = "a"
        dst = "b"
        cmd_input = ["file", "move", src, dst]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.mv.assert_called_once_with(
            container=None, src_paths=[src], dest_path=dst
        )

    async def test_bundled_file_move(self) -> None:
        self.client_mock.mv = AsyncMock(return_value=[])
        src = "a"
        dst = "b"
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "move", src, dst, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.mv.assert_called_once_with(
            container=bundle_id, src_paths=[src], dest_path=dst
        )

    async def test_bundled_file_move_multiple(self) -> None:
        self.client_mock.mv = AsyncMock(return_value=[])
        srcs = ["src1", "src2"]
        dst = "b"
        bundle_id = "com.bundle.id"
        cmd_input = ["file", "move", srcs[0], srcs[1], dst, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.mv.assert_called_once_with(
            container=bundle_id, src_paths=srcs, dest_path=dst
        )

    async def test_file_push(self) -> None:
        self.client_mock.push = AsyncMock()
        src = "Library/myFile.txt"
        dst = "someOutputDir"
        cmd_input = ["file", "push", src, dst]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.push.assert_called_once_with(
            container=None,
            src_paths=[os.path.abspath(src)],
            dest_path=dst,
            compression=None,
        )

    async def test_bundled_file_push_single(self) -> None:
        self.client_mock.push = AsyncMock()
        bundle_id = "com.myapp"
        src = "Library/myFile.txt"
        dst = "someOutputDir"
        cmd_input = ["file", "push", src, dst, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.push.assert_called_once_with(
            container=bundle_id,
            src_paths=[os.path.abspath(src)],
            dest_path=dst,
            compression=None,
        )

    async def test_bundled_file_push_zstd(self) -> None:
        self.client_mock.push = AsyncMock()
        bundle_id = "com.myapp"
        src = "Library/myFile.txt"
        dst = "someOutputDir"
        cmd_input = [
            "--compression",
            "ZSTD",
            "file",
            "push",
            src,
            dst,
            "--bundle-id",
            bundle_id,
        ]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.push.assert_called_once_with(
            container=bundle_id,
            src_paths=[os.path.abspath(src)],
            dest_path=dst,
            compression=Compression.ZSTD,
        )

    async def test_bundled_file_push_multi(self) -> None:
        self.client_mock.push = AsyncMock(return_value=[])
        bundle_id = "com.myapp"
        src1 = "Library/myFile.txt"
        src2 = "Library/myFile2.txt"
        dst = "someOutputDir"
        cmd_input = ["file", "push", src1, src2, dst, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.push.assert_called_once_with(
            container=bundle_id,
            src_paths=[os.path.abspath(path) for path in [src1, src2]],
            dest_path=dst,
            compression=None,
        )

    async def test_file_pull(self) -> None:
        self.client_mock.pull = AsyncMock(return_value=[])
        src = "Library/myFile.txt"
        dst = "someOutputDir"
        cmd_input = ["file", "pull", src, dst]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.pull.assert_called_once_with(
            container=None, src_path=src, dest_path=os.path.abspath(dst)
        )

    async def test_bundled_file_pull(self) -> None:
        self.client_mock.pull = AsyncMock(return_value=[])
        bundle_id = "com.myapp"
        src = "Library/myFile.txt"
        dst = "someOutputDir"
        cmd_input = ["file", "pull", src, dst, "--bundle-id", bundle_id]
        await cli_main(cmd_input=cmd_input)
        self.client_mock.pull.assert_called_once_with(
            container=bundle_id, src_path=src, dest_path=os.path.abspath(dst)
        )

    async def test_file_read_and_show(self) -> None:
        contents = b"exact binary contents\x00\xff"
        src = "Library/example.bin"

        def pull(*, container: object, src_path: str, dest_path: str) -> None:
            self.assertIsNone(container)
            self.assertEqual(src_path, src)
            with open(os.path.join(dest_path, os.path.basename(src_path)), "wb") as f:
                f.write(contents)

        self.client_mock.pull = AsyncMock(side_effect=pull)
        stdout = MagicMock()
        for spelling in ("read", "show"):
            with self.subTest(spelling=spelling):
                self.client_mock.pull.reset_mock()
                stdout.buffer.write.reset_mock()
                with patch("idb.cli.commands.file.sys.stdout", stdout):
                    self.assertEqual(
                        await cli_main(cmd_input=["file", spelling, src]), 0
                    )
                self.client_mock.pull.assert_called_once()
                stdout.buffer.write.assert_called_once_with(contents)

    async def test_file_write(self) -> None:
        contents = b"exact stdin contents\x00\xff"
        dst = "Library/Config/example.bin"

        def push(
            *,
            src_paths: list[str],
            container: object,
            dest_path: str,
            compression: Compression | None,
        ) -> None:
            self.assertIsNone(container)
            self.assertEqual(dest_path, "Library/Config")
            self.assertIsNone(compression)
            self.assertEqual(len(src_paths), 1)
            self.assertEqual(os.path.basename(src_paths[0]), "example.bin")
            with open(src_paths[0], "rb") as f:
                self.assertEqual(f.read(), contents)

        self.client_mock.push = AsyncMock(side_effect=push)
        stdin = MagicMock()
        stdin.buffer.read.return_value = contents
        with patch("idb.cli.commands.file.sys.stdin", stdin):
            self.assertEqual(await cli_main(cmd_input=["file", "write", dst]), 0)
        stdin.buffer.read.assert_called_once_with()
        self.client_mock.push.assert_called_once()

    async def test_list_targets(self) -> None:
        self.client_manager_mock().list_targets = AsyncMock(return_value=[])
        await cli_main(cmd_input=["list-targets"])
        self.client_manager_mock().list_targets.assert_called_once()

    async def test_kill(self) -> None:
        self.client_manager_mock().kill = AsyncMock(return_value=[])
        await cli_main(cmd_input=["kill"])
        self.client_manager_mock().kill.assert_called_once_with()

    async def test_xctest_install(self) -> None:
        responses = (
            InstalledArtifact(name="ignored", uuid=None, progress=50.0),
            InstalledArtifact(
                name="com.example.tests", uuid="xctest-uuid", progress=0.0
            ),
        )
        self.client_mock.install_xctest = MagicMock(
            return_value=AsyncGeneratorMock(responses)
        )
        test_bundle_path = "testBundle.xctest"
        command = [
            "xctest",
            "install",
            "--skip-signing-bundles",
            test_bundle_path,
        ]
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(
            output.getvalue(),
            "Installed 50.0%\nInstalled: com.example.tests xctest-uuid\n",
        )
        self.client_mock.install_xctest.assert_called_once_with(
            test_bundle_path, True, on_upload_progress=print_upload_progress
        )

        self.client_mock.install_xctest = MagicMock(return_value=AsyncGeneratorMock())
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(await cli_main(cmd_input=command), 0)
        self.assertEqual(output.getvalue(), "")

    def xctest_run_namespace(self, command: str, test_bundle_id: str) -> Namespace:
        namespace = Namespace()
        namespace.companion_path = COMPANION_PATH
        namespace.companion = None
        namespace.compression = None
        namespace.prune_dead_companion = True
        namespace.retry_verdict = False
        namespace.log_level = "WARNING"
        namespace.log_level_deprecated = None
        namespace.root_command = "xctest"
        namespace.xctest = "run"
        namespace.udid = None
        namespace.json = False
        namespace.reason = None
        if command in ["app", "ui"]:
            namespace.tests_to_run = None
            namespace.tests_to_skip = None
            namespace.test_arguments = []
        elif command == "logic":
            namespace.test_to_run = None
            namespace.tests_to_run = None
        namespace.run = command
        namespace.test_bundle_id = test_bundle_id
        namespace.result_bundle_path = None
        namespace.report_activities = False
        namespace.report_attachments = False
        namespace.activities_output_path = None
        namespace.coverage_output_path = None
        namespace.enable_continuous_coverage_collection = False
        namespace.coverage_format = "EXPORTED"
        namespace.log_directory_path = None
        namespace.wait_for_debugger = False
        namespace.install = False
        namespace.companion_tls = False
        namespace.install_dsym_test_bundle = None
        namespace.skip_signing_bundles = None
        return namespace

    async def test_xctest_run_app(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.XctestRunAppCommand.run", new=mock, create=True
        ):
            test_bundle_id = "com.me.tests"
            app_under_test_id = "com.me.app"
            await cli_main(
                cmd_input=["xctest", "run", "app", test_bundle_id, app_under_test_id]
            )
            namespace = self.xctest_run_namespace("app", test_bundle_id)
            namespace.app_bundle_id = app_under_test_id
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_xctest_run_ui(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.XctestRunUICommand.run", new=mock, create=True
        ):
            test_bundle_id = "com.me.tests"
            app_under_test_id = "com.me.app"
            test_host_app_bundle_id = "com.host.app"
            await cli_main(
                cmd_input=[
                    "xctest",
                    "run",
                    "ui",
                    test_bundle_id,
                    app_under_test_id,
                    test_host_app_bundle_id,
                ]
            )
            namespace = self.xctest_run_namespace("ui", test_bundle_id)
            namespace.app_bundle_id = app_under_test_id
            namespace.test_host_app_bundle_id = test_host_app_bundle_id
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_xctest_run_logic(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.CommonRunXcTestCommand.run", new=mock, create=True
        ):
            test_bundle_id = "com.me.tests"
            await cli_main(cmd_input=["xctest", "run", "logic", test_bundle_id])
            namespace = self.xctest_run_namespace("logic", test_bundle_id)
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_xctest_list(self) -> None:
        self.client_mock.list_xctests = AsyncMock(return_value=[])
        await cli_main(cmd_input=["xctest", "list"])
        self.client_mock.list_xctests.assert_called_once()

    async def test_xctest_list_bundles(self) -> None:
        self.client_mock.list_test_bundle = AsyncMock(return_value=[])
        bundle_id = "myBundleID"
        await cli_main(cmd_input=["xctest", "list-bundle", bundle_id])
        self.client_mock.list_test_bundle.assert_called_once_with(
            test_bundle_id=bundle_id, app_path=None
        )

    async def test_xctest_run_logic_with_install(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.CommonRunXcTestCommand.run", new=mock, create=True
        ):
            test_bundle_path = "/bundle/path"
            await cli_main(
                cmd_input=["xctest", "run", "logic", "--install", test_bundle_path]
            )
            namespace = self.xctest_run_namespace("logic", test_bundle_path)
            namespace.install = True
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_xctest_run_logic_with_install_dsym_test_bundle(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.CommonRunXcTestCommand.run", new=mock, create=True
        ):
            test_bundle_path = "/bundle/path"
            test_dsym_path = "/dsym/path"
            await cli_main(
                cmd_input=[
                    "xctest",
                    "run",
                    "logic",
                    "--install-dsym",
                    test_dsym_path,
                    "--install",
                    test_bundle_path,
                ]
            )
            namespace = self.xctest_run_namespace("logic", test_bundle_path)
            namespace.install_dsym_test_bundle = test_dsym_path
            namespace.install = True
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_xctest_run_logic_with_install_dsym_no_path(self) -> None:
        mock = AsyncMock()
        mock.return_value = []
        with patch(
            "idb.cli.commands.xctest.CommonRunXcTestCommand.run", new=mock, create=True
        ):
            test_bundle_path = "/bundle/path"
            await cli_main(
                cmd_input=[
                    "xctest",
                    "run",
                    "logic",
                    "--install-dsym",
                    "--install",
                    test_bundle_path,
                ]
            )
            namespace = self.xctest_run_namespace("logic", test_bundle_path)
            namespace.install_dsym_test_bundle = NO_SPECIFIED_PATH
            namespace.install = True
            namespace.timeout = None
            mock.assert_called_once_with(namespace)

    async def test_terminate(self) -> None:
        self.client_mock.terminate = AsyncMock(return_value=[])
        bundle_id = "com.foo.app"
        udid = "my udid"
        await cli_main(cmd_input=["terminate", bundle_id, "--udid", udid])
        self.client_mock.terminate.assert_called_once_with(bundle_id)

    async def test_log(self) -> None:
        mock = AsyncMock()
        with patch("idb.cli.commands.log.LogCommand._run_impl", new=mock, create=True):
            await cli_main(cmd_input=["log", "--udid", "1234"])
            namespace = Namespace()
            namespace.companion_path = COMPANION_PATH
            namespace.companion = None
            namespace.compression = None
            namespace.prune_dead_companion = True
            namespace.retry_verdict = False
            namespace.log_level = "WARNING"
            namespace.log_level_deprecated = None
            namespace.root_command = "log"
            namespace.udid = "1234"
            namespace.json = False
            namespace.reason = None
            namespace.log_arguments = []
            namespace.companion_tls = False
            mock.assert_called_once_with(namespace)

    async def test_log_arguments(self) -> None:
        mock = AsyncMock()
        with patch("idb.cli.commands.log.LogCommand._run_impl", new=mock, create=True):
            await cli_main(cmd_input=["log", "--", "--style", "json"])
            namespace = Namespace()
            namespace.companion_path = COMPANION_PATH
            namespace.companion = None
            namespace.compression = None
            namespace.prune_dead_companion = True
            namespace.retry_verdict = False
            namespace.log_level = "WARNING"
            namespace.log_level_deprecated = None
            namespace.root_command = "log"
            namespace.udid = None
            namespace.json = False
            namespace.reason = None
            namespace.log_arguments = ["--", "--style", "json"]
            namespace.companion_tls = False
            mock.assert_called_once_with(namespace)

    async def test_reason(self) -> None:
        mock = AsyncMock()
        with patch("idb.cli.commands.log.LogCommand._run_impl", new=mock, create=True):
            await cli_main(cmd_input=["log", "--reason", "investigating a test flake"])
            mock.assert_called_once()
            namespace = mock.call_args.args[0]
            self.assertEqual(namespace.reason, "investigating a test flake")

    async def test_reason_added_to_telemetry_metadata(self) -> None:
        reason = "investigating a test flake"
        self.client_mock.list_apps = AsyncMock(return_value=[])
        log_call_mock = MagicMock(
            return_value=AsyncContextManagerMock(return_value=None)
        )
        with patch("idb.cli.log_call", log_call_mock):
            await cli_main(cmd_input=["list-apps", "--reason", reason])
        log_call_mock.assert_called_once()
        metadata = log_call_mock.call_args.kwargs["metadata"]
        self.assertEqual(metadata["reason"], reason)

    async def test_reason_omitted_from_telemetry_metadata_when_absent(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        log_call_mock = MagicMock(
            return_value=AsyncContextManagerMock(return_value=None)
        )
        with patch("idb.cli.log_call", log_call_mock):
            await cli_main(cmd_input=["list-apps"])
        log_call_mock.assert_called_once()
        metadata = log_call_mock.call_args.kwargs["metadata"]
        self.assertNotIn("reason", metadata)

    async def test_reason_logged_to_stderr(self) -> None:
        reason = "investigating a test flake"
        self.client_mock.list_apps = AsyncMock(return_value=[])
        with self.assertLogs(level="INFO") as log_context:
            await cli_main(cmd_input=["--log", "INFO", "list-apps", "--reason", reason])
        self.assertTrue(
            any(reason in message for message in log_context.output),
            f"Expected invocation reason in logs, got: {log_context.output}",
        )

    async def test_reason_truncated_to_200(self) -> None:
        reason = "x" * 250
        self.client_mock.list_apps = AsyncMock(return_value=[])
        log_call_mock = MagicMock(
            return_value=AsyncContextManagerMock(return_value=None)
        )
        with patch("idb.cli.log_call", log_call_mock):
            await cli_main(cmd_input=["list-apps", "--reason", reason])
        log_call_mock.assert_called_once()
        metadata = log_call_mock.call_args.kwargs["metadata"]
        self.assertEqual(metadata["reason"], "x" * 200)
        self.assertEqual(len(metadata["reason"]), 200)

    async def test_clear_keychain(self) -> None:
        self.client_mock.clear_keychain = AsyncMock(return_value=[])
        await cli_main(cmd_input=["clear-keychain"])
        self.client_mock.clear_keychain.assert_called_once()

    async def test_open_url(self) -> None:
        self.client_mock.open_url = AsyncMock(return_value=[])
        url = "http://facebook.com"
        await cli_main(cmd_input=["open", url])
        self.client_mock.open_url.assert_called_once_with(url)

    async def test_set_location(self) -> None:
        self.client_mock.set_location = AsyncMock(return_value=[])
        latitude = 1.0
        longitude = 2.0
        await cli_main(cmd_input=["set-location", str(latitude), str(longitude)])
        self.client_mock.set_location.assert_called_once_with(latitude, longitude)

    async def test_set_preference_forwards_name(self) -> None:
        self.client_mock.set_preference = AsyncMock(return_value=[])
        await cli_main(cmd_input=["set", "appearance", "dark"])
        self.client_mock.set_preference.assert_called_once_with(
            name="appearance", value="dark", value_type="string", domain=None
        )

    async def test_set_preference_with_domain(self) -> None:
        self.client_mock.set_preference = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=["set", "MyKey", "1", "--type", "int", "--domain", "com.example"]
        )
        self.client_mock.set_preference.assert_called_once_with(
            name="MyKey", value="1", value_type="int", domain="com.example"
        )

    async def test_set_autofill_passwords(self) -> None:
        self.client_mock.set_preference = AsyncMock(return_value=[])
        await cli_main(cmd_input=["set", "autofill-passwords", "disable"])
        self.client_mock.set_preference.assert_called_once_with(
            name="autofill-passwords", value="disable", value_type="string", domain=None
        )

    async def test_set_hardware_keyboard_routes_through_generic_preference(
        self,
    ) -> None:
        self.client_mock.set_preference = AsyncMock(return_value=[])
        await cli_main(cmd_input=["set", "hardware-keyboard", "enable"])
        self.client_mock.set_preference.assert_called_once_with(
            name="hardware-keyboard", value="enable", value_type="string", domain=None
        )

    async def test_set_locale_routes_through_generic_preference(self) -> None:
        self.client_mock.set_preference = AsyncMock(return_value=[])
        await cli_main(cmd_input=["set", "locale", "en_US"])
        self.client_mock.set_preference.assert_called_once_with(
            name="locale", value="en_US", value_type="string", domain=None
        )

    async def test_get_locale_routes_through_generic_preference(self) -> None:
        self.client_mock.get_preference = AsyncMock(return_value="en_US")
        await cli_main(cmd_input=["get", "locale"])
        self.client_mock.get_preference.assert_called_once_with(
            name="locale", domain=None
        )

    async def test_approve(self) -> None:
        self.client_mock.approve = AsyncMock(return_value=[])
        bundle_id = "com.fb.myApp"
        await cli_main(cmd_input=["approve", bundle_id, "photos"])
        self.client_mock.approve.assert_called_once_with(
            bundle_id=bundle_id, permissions={Permission.PHOTOS}, scheme=None
        )

    async def test_approve_url(self) -> None:
        self.client_mock.approve = AsyncMock(return_value=[])
        bundle_id = "com.fb.myApp"
        await cli_main(cmd_input=["approve", bundle_id, "url", "--scheme", "fb"])
        self.client_mock.approve.assert_called_once_with(
            bundle_id=bundle_id, permissions={Permission.URL}, scheme="fb"
        )

    async def test_revoke(self) -> None:
        self.client_mock.revoke = AsyncMock(return_value=[])
        bundle_id = "com.fb.myApp"
        await cli_main(cmd_input=["revoke", bundle_id, "photos"])
        self.client_mock.revoke.assert_called_once_with(
            bundle_id=bundle_id, permissions={Permission.PHOTOS}, scheme=None
        )

    async def test_revoke_url(self) -> None:
        self.client_mock.revoke = AsyncMock(return_value=[])
        bundle_id = "com.fb.myApp"
        await cli_main(cmd_input=["revoke", bundle_id, "url", "--scheme", "fb"])
        self.client_mock.revoke.assert_called_once_with(
            bundle_id=bundle_id, permissions={Permission.URL}, scheme="fb"
        )

    async def test_video_record(self) -> None:
        mock = AsyncMock()
        with patch(
            "idb.cli.commands.video.VideoRecordCommand._run_impl", new=mock, create=True
        ):
            output_file = "video.mp4"
            await cli_main(cmd_input=["record-video", output_file])
            namespace = Namespace()
            namespace.companion_path = COMPANION_PATH
            namespace.companion = None
            namespace.compression = None
            namespace.prune_dead_companion = True
            namespace.retry_verdict = False
            namespace.log_level = "WARNING"
            namespace.log_level_deprecated = None
            namespace.root_command = "record-video"
            namespace.udid = None
            namespace.json = False
            namespace.reason = None
            namespace.output_file = output_file
            namespace.companion_tls = False
            # Every encode option defaults to unset, which the companion reads as its own default.
            namespace.fps = None
            namespace.scale_factor = None
            namespace.bitrate = None
            namespace.key_frame_rate = None
            namespace.audio = False
            mock.assert_called_once_with(namespace)

    async def test_video_record_encode_options(self) -> None:
        mock = AsyncMock()
        with patch(
            "idb.cli.commands.video.VideoRecordCommand._run_impl", new=mock, create=True
        ):
            await cli_main(
                cmd_input=[
                    "record-video",
                    "--fps=15",
                    "--scale-factor=0.5",
                    "--bitrate=1000000",
                    "--key-frame-rate=2",
                    "video.mp4",
                ]
            )
            namespace = mock.call_args[0][0]
            self.assertEqual(namespace.fps, 15)
            self.assertEqual(namespace.scale_factor, 0.5)
            self.assertEqual(namespace.bitrate, 1000000)
            self.assertEqual(namespace.key_frame_rate, 2)

    async def test_video_stream(self) -> None:
        mock = AsyncMock()
        with patch(
            "idb.cli.commands.video.VideoStreamCommand._run_impl", new=mock, create=True
        ):
            output_file = "video.mp4"
            await cli_main(cmd_input=["video-stream", output_file])
            mock.assert_called_once_with(
                Namespace(
                    companion=None,
                    companion_path=COMPANION_PATH,
                    compression=None,
                    prune_dead_companion=True,
                    retry_verdict=False,
                    log_level="WARNING",
                    format="h264",
                    fps=None,
                    log_level_deprecated=None,
                    compression_quality=0.2,
                    scale_factor=1,
                    root_command="video-stream",
                    udid=None,
                    json=False,
                    reason=None,
                    output_file=output_file,
                    companion_tls=False,
                )
            )

    async def test_key_sequence(self) -> None:
        self.client_mock.key_sequence = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "key-sequence", "1", "2", "3"])
        self.client_mock.key_sequence.assert_called_once_with(key_sequence=[1, 2, 3])

    async def test_tap(self) -> None:
        self.client_mock.tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "10", "20"])
        self.client_mock.tap.assert_called_once_with(x=10, y=20, duration=None)

    async def test_tap_with_duration(self) -> None:
        self.client_mock.tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "10", "20", "--duration", "0.5"])
        self.client_mock.tap.assert_called_once_with(x=10, y=20, duration=0.5)

    async def test_tap_with_expected_value(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "tap",
                "10",
                "20",
                "--expected-value",
                "Ready",
                "--expected-key",
                "AXValue",
            ]
        )
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            expected_value="Ready",
            expected_key=AccessibilitySearchableKey.VALUE,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_ax_point(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "10", "20", "--api", "ax"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AX,
        )

    async def _failing_tap(self, *argv: str) -> tuple[int, str]:
        self.client_mock.accessibility_tap = AsyncMock(
            side_effect=IdbException(
                "The application did not answer",
                retry=RetryVerdict(verdict="unsafe", reason="outcome_unknown"),
            )
        )
        err = StringIO()
        with redirect_stderr(err):
            exit_code = await cli_main(cmd_input=list(argv))
        return int(exit_code or 0), err.getvalue()

    async def test_a_failure_with_a_verdict_prints_only_its_message_by_default(
        self,
    ) -> None:
        exit_code, stderr = await self._failing_tap("ui", "tap", "Login")
        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr, "The application did not answer\n")

    async def test_a_failure_with_a_verdict_prints_it_after_the_message(
        self,
    ) -> None:
        exit_code, stderr = await self._failing_tap(
            "--retry-verdict", "ui", "tap", "Login"
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(
            stderr, "The application did not answer\nretry: unsafe (outcome_unknown)\n"
        )

    async def test_a_failure_with_a_verdict_prints_it_as_json_with_json(
        self,
    ) -> None:
        exit_code, stderr = await self._failing_tap(
            "--retry-verdict", "ui", "tap", "Login", "--json"
        )
        self.assertEqual(exit_code, 1)
        message, verdict = stderr.splitlines()
        self.assertEqual(message, "The application did not answer")
        self.assertEqual(
            json.loads(verdict), {"retry": "unsafe", "retry_reason": "outcome_unknown"}
        )

    async def test_a_failure_without_a_verdict_prints_only_its_message(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(
            side_effect=IdbException("The application did not answer")
        )
        err = StringIO()
        with redirect_stderr(err):
            exit_code = await cli_main(cmd_input=["ui", "tap", "Login"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(err.getvalue(), "The application did not answer\n")

    async def test_tap_marker(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "Login", "--match-key", "AXUniqueId"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=10,
            ),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_marker_with_ignore_case(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "login", "--ignore-case"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=True,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_marker_expected_value(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "tap",
                "Login",
                "--expected-value",
                "Ready",
                "--expected-key",
                "AXValue",
            ]
        )
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            expected_value="Ready",
            expected_key=AccessibilitySearchableKey.VALUE,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_marker_on_the_guest_backend(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "GETTING STARTED", "--api", "axbridge"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="GETTING STARTED",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_marker_on_the_host_backend(self) -> None:
        # The escape hatch from the guest default, for a caller that wants the
        # backend marker taps used before the default changed.
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "Login", "--api", "ax"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AX,
        )

    async def test_tap_marker_through_coresimulators_client(self) -> None:
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "Login", "--api", "ax-coresimulator"])
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AX_CORESIMULATOR,
        )

    async def test_tap_point_on_the_guest_backend_is_not_a_hid_tap(self) -> None:
        # Naming an accessibility backend moves a coordinate off the HID path, the
        # same way --api ax always has.
        self.client_mock.tap = AsyncMock(return_value=[])
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "tap", "10", "20", "--api", "axbridge"])
        self.client_mock.tap.assert_not_called()
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            expected_value=None,
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_coordinate_with_expected_value_and_api_hid(self) -> None:
        # --expected-value moves even a coordinate onto the accessibility path, so
        # `hid` reaches the backend resolution without naming an accessibility
        # backend. It reads as no choice rather than raising.
        self.client_mock.tap = AsyncMock(return_value=[])
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "tap",
                "10",
                "20",
                "--api",
                "hid",
                "--expected-value",
                "Ready",
            ]
        )
        self.client_mock.tap.assert_not_called()
        self.client_mock.accessibility_tap.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            expected_value="Ready",
            expected_key=AccessibilitySearchableKey.LABEL,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_tap_marker_rejects_api_hid(self) -> None:
        self.client_mock.tap = AsyncMock(return_value=[])
        self.client_mock.accessibility_tap = AsyncMock(return_value=[])
        exit_code = await cli_main(cmd_input=["ui", "tap", "Login", "--api", "hid"])
        self.assertEqual(exit_code, 1)
        self.client_mock.tap.assert_not_called()
        self.client_mock.accessibility_tap.assert_not_called()

    async def test_describe_marker(self) -> None:
        self.client_mock.accessibility_info = AsyncMock(
            return_value=AccessibilityInfo(json="[]")
        )
        await cli_main(
            cmd_input=["ui", "describe", "Login", "--match-key", "AXUniqueId"]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=10,
            ),
            options=AccessibilityInfoOptions(nested=False),
        )

    async def test_wait_for_marker(self) -> None:
        self.client_mock.accessibility_wait_result = AsyncMock(
            return_value=AccessibilityWaitResult(found=True)
        )
        exit_code = await cli_main(
            cmd_input=[
                "ui",
                "wait",
                "General",
                "--match-key",
                "AXUniqueId",
                "--timeout",
                "30",
                "--poll-interval",
                "0.25",
                "--api",
                "ax",
            ]
        )
        self.assertEqual(exit_code, 0)
        self.client_mock.accessibility_wait_result.assert_called_once_with(
            target=AccessibilityMarker(
                "General", AccessibilitySearchableKey.UNIQUE_ID, 10
            ),
            timeout=30.0,
            poll_interval=0.25,
            backend=AccessibilityBackend.AX,
        )

    async def test_wait_timeout_has_a_distinct_json_result(self) -> None:
        self.client_mock.accessibility_wait_result = AsyncMock(
            return_value=AccessibilityWaitResult(found=False)
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "wait", "missing", "--json"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "found": False,
                "error": "Timed out waiting for AXLabel containing 'missing' after 10s",
            },
        )

    async def test_wait_timeout_reports_final_probe_diagnostics(self) -> None:
        self.client_mock.accessibility_wait_result = AsyncMock(
            return_value=AccessibilityWaitResult(
                found=False,
                message="Timed out waiting for AXLabel containing 'missing'",
                diagnostics=AccessibilitySearchDiagnostics(
                    unmatched_values=["Settings", "General"]
                ),
            )
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "wait", "missing", "--json"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "found": False,
                "error": "Timed out waiting for AXLabel containing 'missing'",
                "diagnostics": {
                    "unmatched_values": ["Settings", "General"],
                    "truncated": False,
                    "read_error": None,
                },
            },
        )

    async def test_wait_text_formats_structured_diagnostics(self) -> None:
        message = "Timed out waiting for AXLabel containing 'missing'"
        for diagnostics, detail in [
            (
                AccessibilitySearchDiagnostics(
                    unmatched_values=["Settings", "General"], truncated=True
                ),
                "Last poll's nonmatching AXLabel values (truncated):\n  'Settings'\n  'General'",
            ),
            (
                AccessibilitySearchDiagnostics(),
                "Last poll's nonmatching AXLabel values:\n  (none)",
            ),
            (
                AccessibilitySearchDiagnostics(read_error="application unavailable"),
                "Last poll could not read the tree: application unavailable",
            ),
        ]:
            with self.subTest(diagnostics=diagnostics):
                self.client_mock.accessibility_wait_result = AsyncMock(
                    return_value=AccessibilityWaitResult(
                        found=False, message=message, diagnostics=diagnostics
                    )
                )
                with redirect_stderr(StringIO()) as error:
                    exit_code = await cli_main(cmd_input=["ui", "wait", "missing"])
                self.assertEqual(exit_code, 1)
                self.assertEqual(error.getvalue(), f"{message}\n{detail}\n")

    async def test_wait_success_preserves_json_shape(self) -> None:
        self.client_mock.accessibility_wait_result = AsyncMock(
            return_value=AccessibilityWaitResult(found=True)
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "wait", "ready", "--json"])
        self.assertEqual(exit_code, 0)
        self.assertEqual(json.loads(output.getvalue()), {"found": True})

    async def test_wait_command_error_has_no_timeout_result(self) -> None:
        self.client_mock.accessibility_wait_result = AsyncMock(
            side_effect=IdbException("reader failed")
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "wait", "missing", "--json"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(output.getvalue(), "")

    def _stream_quiescence(
        self, *events: QuiescenceEvent, then_block: bool = False
    ) -> tuple[list[dict[str, Any]], list[bool]]:
        calls: list[dict[str, Any]] = []
        closed: list[bool] = []

        async def stream(**kwargs: Any) -> AsyncIterator[QuiescenceEvent]:
            calls.append(kwargs)
            try:
                for event in events:
                    yield event
                if then_block:
                    await asyncio.Event().wait()
            finally:
                closed.append(True)

        self.client_mock.accessibility_quiescence = stream
        return calls, closed

    async def test_quiet_now_answers_with_the_first_busy_or_quiet_state(
        self,
    ) -> None:
        calls, closed = self._stream_quiescence(
            QuiescenceStateChanged(pid=42, state=QuiescenceState.SETTLING),
            QuiescenceStateChanged(pid=42, state=QuiescenceState.QUIET),
            QuiescenceStateChanged(
                pid=42, state=QuiescenceState.BUSY, busy_signals=("run_loop_idle",)
            ),
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "quiet"])
        self.assertEqual(exit_code, 0)
        self.assertEqual(output.getvalue(), "settling (pid 42)\nquiet (pid 42)\n")
        # Reporting now, the quiet window defaults to zero.
        self.assertEqual(
            calls,
            [
                {
                    "pid": None,
                    "bundle_id": None,
                    "busy_threshold_ms": None,
                    "quiet_window_ms": 0,
                    "backend": QuiescenceBackend.AXBRIDGE,
                }
            ],
        )
        self.assertEqual(closed, [True])

    async def test_quiet_now_exits_1_when_busy(self) -> None:
        calls, _ = self._stream_quiescence(
            QuiescenceStateChanged(
                pid=42,
                state=QuiescenceState.BUSY,
                busy_signals=("run_loop_idle", "animations_inactive"),
            ),
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(
                cmd_input=["ui", "quiet", "--pid", "42", "--quiet-window-ms", "5"]
            )
        self.assertEqual(exit_code, 1)
        self.assertEqual(
            output.getvalue(), "busy (animations_inactive, run_loop_idle) (pid 42)\n"
        )
        self.assertEqual(calls[0]["pid"], 42)
        self.assertEqual(calls[0]["quiet_window_ms"], 5)

    async def test_quiet_with_a_timeout_waits_for_quiet(self) -> None:
        # A timeout of 0 waits for as long as it takes. A watch that ends quiet
        # reports every event and answers the same way.
        for timeout in (["30"], ["0"], ["0.01", "--watch"]):
            with self.subTest(timeout=timeout):
                calls, closed = self._stream_quiescence(
                    QuiescenceStateChanged(
                        pid=42,
                        state=QuiescenceState.BUSY,
                        busy_signals=("run_loop_idle",),
                    ),
                    QuiescenceTouchesCompleted(pid=42),
                    QuiescenceTargetChanged(pid=43),
                    QuiescenceStateChanged(pid=43, state=QuiescenceState.QUIET),
                    then_block=True,
                )
                with redirect_stdout(StringIO()) as output:
                    exit_code = await cli_main(
                        cmd_input=[
                            "ui",
                            "quiet",
                            *timeout,
                            "--bundle-id",
                            "com.example.app",
                            "--busy-threshold-ms",
                            "100",
                            "--json",
                        ]
                    )
                self.assertEqual(exit_code, 0)
                self.assertEqual(
                    [json.loads(line) for line in output.getvalue().splitlines()],
                    [
                        {
                            "event": "state",
                            "state": "busy",
                            "signals": ["run_loop_idle"],
                            "pid": 42,
                        },
                        {"event": "touches_completed", "pid": 42},
                        {"event": "target_changed", "pid": 43},
                        {"event": "state", "state": "quiet", "pid": 43},
                    ],
                )
                self.assertEqual(
                    calls,
                    [
                        {
                            "pid": None,
                            "bundle_id": "com.example.app",
                            "busy_threshold_ms": 100,
                            "quiet_window_ms": None,
                            "backend": QuiescenceBackend.AXBRIDGE,
                        }
                    ],
                )
                self.assertEqual(closed, [True])

    async def test_quiet_exits_1_when_the_timeout_elapses(self) -> None:
        _, closed = self._stream_quiescence(
            QuiescenceStateChanged(pid=42, state=QuiescenceState.SETTLING),
            then_block=True,
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(cmd_input=["ui", "quiet", "0.01"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(
            output.getvalue(), "settling (pid 42)\nnot quiet within 0.01s\n"
        )
        self.assertEqual(closed, [True])

        with self.subTest("a watch keeps reporting past quiet"):
            _, closed = self._stream_quiescence(
                QuiescenceStateChanged(pid=42, state=QuiescenceState.QUIET),
                QuiescenceStateChanged(
                    pid=42, state=QuiescenceState.BUSY, busy_signals=("run_loop_idle",)
                ),
                then_block=True,
            )
            with redirect_stdout(StringIO()) as output:
                exit_code = await cli_main(cmd_input=["ui", "quiet", "0.01", "--watch"])
            self.assertEqual(exit_code, 1)
            self.assertEqual(
                output.getvalue(), "quiet (pid 42)\nbusy (run_loop_idle) (pid 42)\n"
            )
            self.assertEqual(closed, [True])

        with self.subTest("a watch that ends after the target changes is not quiet"):
            self._stream_quiescence(
                QuiescenceStateChanged(pid=42, state=QuiescenceState.QUIET),
                QuiescenceTargetChanged(pid=43),
                then_block=True,
            )
            with redirect_stdout(StringIO()) as output:
                exit_code = await cli_main(cmd_input=["ui", "quiet", "0.01", "--watch"])
            self.assertEqual(exit_code, 1)
            self.assertEqual(
                output.getvalue(), "quiet (pid 42)\nnow following pid 43\n"
            )

    async def test_quiet_api_shimulator_asks_the_app(self) -> None:
        calls, _ = self._stream_quiescence(
            QuiescenceStateChanged(pid=42, state=QuiescenceState.QUIET),
        )
        with redirect_stdout(StringIO()) as output:
            exit_code = await cli_main(
                cmd_input=[
                    "ui",
                    "quiet",
                    "5",
                    "--api",
                    "shimulator",
                    "--pid",
                    "42",
                    "--busy-threshold-ms",
                    "32",
                ]
            )
        self.assertEqual(exit_code, 0)
        self.assertEqual(output.getvalue(), "quiet (pid 42)\n")
        self.assertEqual(
            calls,
            [
                {
                    "pid": 42,
                    "bundle_id": None,
                    "busy_threshold_ms": 32,
                    "quiet_window_ms": None,
                    "backend": QuiescenceBackend.SHIMULATOR,
                }
            ],
        )

    async def test_quiet_target_exit_is_an_error(self) -> None:
        for arguments in [["5"], ["5", "--watch"]]:
            with self.subTest(arguments=arguments):
                self._stream_quiescence(QuiescenceTargetExited(pid=42))
                with (
                    redirect_stdout(StringIO()) as output,
                    redirect_stderr(StringIO()) as error,
                ):
                    exit_code = await cli_main(cmd_input=["ui", "quiet", *arguments])
                self.assertEqual(exit_code, 1)
                self.assertEqual(output.getvalue(), "pid 42 exited\n")
                self.assertIn("The application with pid 42 exited", error.getvalue())

    async def test_quiet_rejects_negative_values(self) -> None:
        for arguments in [["-1"], ["--busy-threshold-ms", "-1"], ["--watch"]]:
            with self.subTest(arguments=arguments):
                calls, _ = self._stream_quiescence()
                with redirect_stderr(StringIO()):
                    exit_code = await cli_main(cmd_input=["ui", "quiet", *arguments])
                self.assertEqual(exit_code, 1)
                self.assertEqual(calls, [])

    async def test_scroll_frontmost(self) -> None:
        # No target is not a reason to fall back: the guest addresses the
        # application by pid rather than by point.
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "scroll", "down"])
        self.client_mock.accessibility_scroll.assert_called_once_with(
            target=None,
            direction=AccessibilityScrollDirection.DOWN,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_scroll_marker(self) -> None:
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "scroll", "up", "List"])
        self.client_mock.accessibility_scroll.assert_called_once_with(
            target=AccessibilityMarker(
                value="List",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            direction=AccessibilityScrollDirection.UP,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_scroll_marker_with_ignore_case(self) -> None:
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "scroll", "up", "list", "--ignore-case"])
        self.client_mock.accessibility_scroll.assert_called_once_with(
            target=AccessibilityMarker(
                value="list",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            direction=AccessibilityScrollDirection.UP,
            ignore_case=True,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_scroll_point(self) -> None:
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "scroll", "down", "100", "200"])
        self.client_mock.accessibility_scroll.assert_called_once_with(
            target=AccessibilityPoint(x=100, y=200),
            direction=AccessibilityScrollDirection.DOWN,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_scroll_on_the_guest_backend(self) -> None:
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "scroll", "down", "--api", "axbridge"])
        self.client_mock.accessibility_scroll.assert_called_once_with(
            target=None,
            direction=AccessibilityScrollDirection.DOWN,
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_scroll_too_many_tokens(self) -> None:
        self.client_mock.accessibility_scroll = AsyncMock(return_value=[])
        exit_code = await cli_main(
            cmd_input=["ui", "scroll", "down", "100", "200", "300"]
        )
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_scroll.assert_not_called()

    async def test_set_value_marker(self) -> None:
        self.client_mock.accessibility_set_value = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "set-value", "Field", "--value", "hello"])
        self.client_mock.accessibility_set_value.assert_called_once_with(
            target=AccessibilityMarker(
                value="Field",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            value="hello",
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_set_value_on_the_guest_backend(self) -> None:
        self.client_mock.accessibility_set_value = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "set-value",
                "Field",
                "--value",
                "hello",
                "--api",
                "axbridge",
            ]
        )
        self.client_mock.accessibility_set_value.assert_called_once_with(
            target=AccessibilityMarker(
                value="Field",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            value="hello",
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_set_value_marker_with_ignore_case(self) -> None:
        self.client_mock.accessibility_set_value = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=["ui", "set-value", "field", "--value", "hello", "--ignore-case"]
        )
        self.client_mock.accessibility_set_value.assert_called_once_with(
            target=AccessibilityMarker(
                value="field",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            value="hello",
            ignore_case=True,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_points(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "drag-and-drop", "10", "20", "30", "40"])
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityPoint(x=10, y=20),
            destination=AccessibilityPoint(x=30, y=40),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_on_the_guest_backend(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "drag-and-drop",
                "10",
                "20",
                "30",
                "40",
                "--api",
                "axbridge",
            ]
        )
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityPoint(x=10, y=20),
            destination=AccessibilityPoint(x=30, y=40),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_markers(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "drag-and-drop",
                "Photo",
                "Album",
                "--match-key",
                "AXUniqueId",
                "--depth",
                "5",
            ]
        )
        # The destination inherits the source's key and depth unless it overrides them.
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityMarker(
                value="Photo",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=5,
            ),
            destination=AccessibilityMarker(
                value="Album",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=5,
            ),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_markers_with_ignore_case(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=["ui", "drag-and-drop", "photo", "album", "--ignore-case"]
        )
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityMarker(
                value="photo",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            destination=AccessibilityMarker(
                value="album",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=True,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_destination_overrides_the_source_key(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "drag-and-drop",
                "Photo",
                "Album",
                "--to-match-key",
                "AXLabel",
                "--to-depth",
                "3",
                "--match-key",
                "AXUniqueId",
            ]
        )
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityMarker(
                value="Photo",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=10,
            ),
            destination=AccessibilityMarker(
                value="Album",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=3,
            ),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_timings(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "drag-and-drop",
                "10",
                "20",
                "30",
                "40",
                "--press-duration",
                "1",
                "--duration",
                "2",
                "--release-duration",
                "0.25",
                "--delta",
                "5",
            ]
        )
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityPoint(x=10, y=20),
            destination=AccessibilityPoint(x=30, y=40),
            options=AccessibilityDragOptions(
                press_duration=1.0, duration=2.0, release_duration=0.25, delta=5.0
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_point_to_marker(self) -> None:
        # Three tokens, the first two integers: the source takes the pair.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "drag-and-drop", "10", "20", "Album"])
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityPoint(x=10, y=20),
            destination=AccessibilityMarker(
                value="Album",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_marker_to_point(self) -> None:
        # Three tokens, the first not an integer: the source is one marker and
        # the destination takes the pair.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "drag-and-drop", "Photo", "30", "40"])
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityMarker(
                value="Photo",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            destination=AccessibilityPoint(x=30, y=40),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_all_numeric_endpoints_read_the_source_greedily(
        self,
    ) -> None:
        # Three integer tokens are the one genuinely ambiguous input: "300 400"
        # could be the source point or the destination point. The source is read
        # greedily, the same way `_parse_target` reads a leading integer pair
        # everywhere else, so this is a point to a numeric marker.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "drag-and-drop", "300", "400", "500"])
        self.client_mock.accessibility_drag.assert_called_once_with(
            source=AccessibilityPoint(x=300, y=400),
            destination=AccessibilityMarker(
                value="500",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityDragOptions(
                press_duration=None, duration=None, release_duration=None, delta=None
            ),
            ignore_case=False,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )

    async def test_drag_and_drop_rejects_a_bare_coordinate_pair(self) -> None:
        # `10 20` is one coordinate pair everywhere else in `idb ui`. Reading it
        # here as two numeric markers would contradict the sibling verbs, and a
        # dropped destination is the far likelier intent, so it is an error.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        exit_code = await cli_main(cmd_input=["ui", "drag-and-drop", "10", "20"])
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_drag.assert_not_called()

    async def test_drag_and_drop_rejects_one_endpoint(self) -> None:
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        exit_code = await cli_main(cmd_input=["ui", "drag-and-drop", "Photo"])
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_drag.assert_not_called()

    async def test_drag_and_drop_rejects_too_many_tokens(self) -> None:
        # Five tokens cannot be two endpoints; an unquoted multi-word marker is
        # the usual cause, so this is rejected rather than split some other way.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        exit_code = await cli_main(
            cmd_input=["ui", "drag-and-drop", "My", "Photo", "My", "Album", "1"]
        )
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_drag.assert_not_called()

    async def test_drag_and_drop_unparseable_destination(self) -> None:
        # Four tokens with a marker source leave three for the destination,
        # which is neither a point nor one marker.
        self.client_mock.accessibility_drag = AsyncMock(return_value=[])
        exit_code = await cli_main(
            cmd_input=["ui", "drag-and-drop", "Photo", "My", "Album", "2"]
        )
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_drag.assert_not_called()

    async def test_multi_tap_default(self) -> None:
        self.client_mock.multi_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "multi-tap", "10", "20"])
        self.client_mock.multi_tap.assert_called_once_with(
            x=10, y=20, count=2, duration=None, pause=0.1
        )

    async def test_multi_tap_triple(self) -> None:
        self.client_mock.multi_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "multi-tap", "10", "20", "--count", "3"])
        self.client_mock.multi_tap.assert_called_once_with(
            x=10, y=20, count=3, duration=None, pause=0.1
        )

    async def test_multi_tap_with_pause(self) -> None:
        self.client_mock.multi_tap = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "multi-tap", "10", "20", "--pause", "0.2"])
        self.client_mock.multi_tap.assert_called_once_with(
            x=10, y=20, count=2, duration=None, pause=0.2
        )

    async def test_pinch_default(self) -> None:
        self.client_mock.pinch = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "pinch", "200", "400", "2.0"])
        self.client_mock.pinch.assert_called_once_with(
            center_x=200.0, center_y=400.0, scale=2.0, duration=0.5, radius=100.0
        )

    async def test_pinch_zoom_out(self) -> None:
        self.client_mock.pinch = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "pinch", "200", "400", "0.5"])
        self.client_mock.pinch.assert_called_once_with(
            center_x=200.0, center_y=400.0, scale=0.5, duration=0.5, radius=100.0
        )

    async def test_pinch_with_options(self) -> None:
        self.client_mock.pinch = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=[
                "ui",
                "pinch",
                "100",
                "300",
                "3.0",
                "--duration",
                "1.0",
                "--radius",
                "50",
            ]
        )
        self.client_mock.pinch.assert_called_once_with(
            center_x=100.0, center_y=300.0, scale=3.0, duration=1.0, radius=50.0
        )

    async def test_button(self) -> None:
        self.client_mock.button = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "button", "SIRI"])
        self.client_mock.button.assert_called_once_with(
            button_type=HIDButtonType.SIRI, duration=None
        )

    async def test_rotate(self) -> None:
        self.client_mock.rotate = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "rotate", "LANDSCAPE_LEFT"])
        self.client_mock.rotate.assert_called_once_with(
            orientation=HIDOrientationType.LANDSCAPE_LEFT
        )

    async def test_rotation_get_plain_and_json(self) -> None:
        self.client_mock.set_orientation = AsyncMock()
        for orientation in DeviceOrientation:
            self.client_mock.get_orientation = AsyncMock(return_value=orientation)
            for options in [[], ["--json"]]:
                with redirect_stdout(StringIO()) as output:
                    self.assertEqual(
                        await cli_main(cmd_input=["rotation"] + options), 0
                    )
                expected = (
                    {"orientation": orientation.name} if options else orientation.name
                )
                actual = (
                    json.loads(output.getvalue())
                    if options
                    else output.getvalue().strip()
                )
                self.assertEqual(actual, expected)

        self.client_mock.set_orientation.assert_not_called()

    async def test_rotation_set_preserves_direction_names(self) -> None:
        self.client_mock.get_orientation = AsyncMock()
        self.client_mock.set_orientation = AsyncMock(return_value=None)
        for orientation in HIDOrientationType:
            self.assertEqual(
                await cli_main(cmd_input=["rotation", orientation.name]), 0
            )
            self.client_mock.set_orientation.assert_called_with(orientation=orientation)

        self.client_mock.get_orientation.assert_not_called()

    async def test_rotation_rejects_read_only_states(self) -> None:
        self.client_mock.set_orientation = AsyncMock(return_value=None)
        for orientation in ["UNKNOWN", "FACE_UP", "FACE_DOWN", "sideways"]:
            self.assertEqual(await cli_main(cmd_input=["rotation", orientation]), 2)
        self.client_mock.set_orientation.assert_not_called()

    async def test_hinge_get(self) -> None:
        self.client_mock.get_hinge_angle = AsyncMock(return_value=130.0)
        with redirect_stdout(StringIO()) as output:
            self.assertEqual(await cli_main(cmd_input=["hinge"]), 0)
        self.assertEqual(output.getvalue().strip(), "130.0")
        self.client_mock.get_hinge_angle.assert_called_once_with()

    async def test_hinge_get_json(self) -> None:
        self.client_mock.get_hinge_angle = AsyncMock(return_value=0.0)
        with redirect_stdout(StringIO()) as output:
            self.assertEqual(await cli_main(cmd_input=["hinge", "--json"]), 0)
        self.assertEqual(json.loads(output.getvalue()), {"angle": 0.0})

    async def test_hinge(self) -> None:
        self.client_mock.get_hinge_angle = AsyncMock()
        self.client_mock.set_hinge_angle = AsyncMock(return_value=None)
        for angle in [0, 90, 135.5, 180]:
            with self.subTest(angle=angle):
                await cli_main(cmd_input=["hinge", str(angle)])
                self.client_mock.set_hinge_angle.assert_called_with(angle=angle)
        self.client_mock.get_hinge_angle.assert_not_called()

    async def test_hinge_rejects_invalid_angles(self) -> None:
        self.client_mock.set_hinge_angle = AsyncMock(return_value=None)
        for angle in ["-1", "181", "nan", "inf", "-inf"]:
            with self.subTest(angle=angle):
                exit_code = await cli_main(cmd_input=["hinge", angle])
                self.assertEqual(exit_code, 2)
        self.client_mock.set_hinge_angle.assert_not_called()

    async def test_shake(self) -> None:
        self.client_mock.shake = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "shake"])
        self.client_mock.shake.assert_called_once_with()

    async def test_key(self) -> None:
        self.client_mock.key = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "key", "12"])
        self.client_mock.key.assert_called_once_with(keycode=12, duration=None)

    async def test_remote(self) -> None:
        self.client_mock.key = AsyncMock(return_value=[])
        # SELECT maps to the Return USB HID keyboard usage (0x28) the tvOS focus engine consumes.
        await cli_main(cmd_input=["ui", "remote", "select"])
        self.client_mock.key.assert_called_once_with(keycode=0x28, duration=None)

    async def test_key_with_shift_modifier(self) -> None:
        self.client_mock.hid = AsyncMock(return_value=[])

        # Shift+P
        await cli_main(cmd_input=["ui", "key", "19", "--shift"])
        self.client_mock.hid.assert_called_once()

        async_iter = self.client_mock.hid.call_args.args[0]
        events = [event async for event in async_iter]
        self.assertEqual(len(events), 4)
        self.assertEqual(events[0].action.keycode, 225)  # Shift down
        self.assertEqual(events[0].direction, HIDDirection.DOWN)
        self.assertEqual(events[1].action.keycode, 19)  # P down
        self.assertEqual(events[1].direction, HIDDirection.DOWN)
        self.assertEqual(events[2].action.keycode, 19)  # P up
        self.assertEqual(events[2].direction, HIDDirection.UP)
        self.assertEqual(events[3].action.keycode, 225)  # Shift up
        self.assertEqual(events[3].direction, HIDDirection.UP)

    async def test_key_with_multiple_modifiers(self) -> None:
        self.client_mock.hid = AsyncMock(return_value=[])

        # Control+Option+Shift+Command+R
        await cli_main(
            cmd_input=[
                "ui",
                "key",
                "19",
                "--control",
                "--option",
                "--shift",
                "--command",
            ]
        )
        self.client_mock.hid.assert_called_once()

        async_iter = self.client_mock.hid.call_args.args[0]
        events = [event async for event in async_iter]

        self.assertEqual(len(events), 10)
        # Modifiers down (in order: control, option, shift, command)
        self.assertEqual(events[0].action.keycode, 224)  # Control down
        self.assertEqual(events[0].direction, HIDDirection.DOWN)
        self.assertEqual(events[1].action.keycode, 226)  # Option down
        self.assertEqual(events[1].direction, HIDDirection.DOWN)
        self.assertEqual(events[2].action.keycode, 225)  # Shift down
        self.assertEqual(events[2].direction, HIDDirection.DOWN)
        self.assertEqual(events[3].action.keycode, 227)  # Command down
        self.assertEqual(events[3].direction, HIDDirection.DOWN)
        # Key press
        self.assertEqual(events[4].action.keycode, 19)  # P down
        self.assertEqual(events[4].direction, HIDDirection.DOWN)
        self.assertEqual(events[5].action.keycode, 19)  # P up
        self.assertEqual(events[5].direction, HIDDirection.UP)
        # Modifiers up (reversed: command, shift, option, control)
        self.assertEqual(events[6].action.keycode, 227)  # Command up
        self.assertEqual(events[6].direction, HIDDirection.UP)
        self.assertEqual(events[7].action.keycode, 225)  # Shift up
        self.assertEqual(events[7].direction, HIDDirection.UP)
        self.assertEqual(events[8].action.keycode, 226)  # Option up
        self.assertEqual(events[8].direction, HIDDirection.UP)
        self.assertEqual(events[9].action.keycode, 224)  # Control up
        self.assertEqual(events[9].direction, HIDDirection.UP)

    async def test_key_with_tab_modifier(self) -> None:
        self.client_mock.hid = AsyncMock(return_value=[])

        # Tab+H
        await cli_main(cmd_input=["ui", "key", "11", "--tab"])
        self.client_mock.hid.assert_called_once()

        async_iter = self.client_mock.hid.call_args.args[0]
        events = [event async for event in async_iter]

        self.assertEqual(len(events), 4)
        self.assertEqual(events[0].action.keycode, 43)  # Tab down
        self.assertEqual(events[0].direction, HIDDirection.DOWN)
        self.assertEqual(events[1].action.keycode, 11)  # H down
        self.assertEqual(events[1].direction, HIDDirection.DOWN)
        self.assertEqual(events[2].action.keycode, 11)  # H up
        self.assertEqual(events[2].direction, HIDDirection.UP)
        self.assertEqual(events[3].action.keycode, 43)  # Tab up
        self.assertEqual(events[3].direction, HIDDirection.UP)

    async def test_key_with_duration_and_modifiers(self) -> None:
        self.client_mock.hid = AsyncMock(return_value=[])

        # Shift+P with duration=0.5
        await cli_main(cmd_input=["ui", "key", "19", "--shift", "--duration", "0.5"])
        self.client_mock.hid.assert_called_once()

        async_iter = self.client_mock.hid.call_args.args[0]
        events = [event async for event in async_iter]

        # Expected: Shift down, P down, HIDDelay(0.5), P up, Shift up
        self.assertEqual(len(events), 5)
        self.assertEqual(events[0].action.keycode, 225)  # Shift down
        self.assertEqual(events[0].direction, HIDDirection.DOWN)
        self.assertEqual(events[1].action.keycode, 19)  # P down
        self.assertEqual(events[1].direction, HIDDirection.DOWN)
        # Verify HIDDelay is inserted between key press and release
        self.assertIsInstance(events[2], HIDDelay)
        self.assertEqual(events[2].duration, 0.5)
        self.assertEqual(events[3].action.keycode, 19)  # P up
        self.assertEqual(events[3].direction, HIDDirection.UP)
        self.assertEqual(events[4].action.keycode, 225)  # Shift up
        self.assertEqual(events[4].direction, HIDDirection.UP)

    async def test_text_input(self) -> None:
        self.client_mock.text = AsyncMock(return_value=[])
        text = "Some Text"
        await cli_main(cmd_input=["ui", "text", text])
        self.client_mock.text.assert_called_once_with(text=text, layout=None)

    async def test_text_input_on_a_layout(self) -> None:
        self.client_mock.text = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "text", "azerty", "--layout", "French"])
        self.client_mock.text.assert_called_once_with(text="azerty", layout="French")

    async def test_swipe_with_delta(self) -> None:
        self.client_mock.swipe = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "swipe", "1", "2", "3", "4", "--delta", "5"])
        self.client_mock.swipe.assert_called_once_with(
            p_start=(1, 2), p_end=(3, 4), duration=None, delta=5
        )

    async def test_swipe_with_duration(self) -> None:
        self.client_mock.swipe = AsyncMock(return_value=[])
        await cli_main(
            cmd_input=["ui", "swipe", "1", "2", "3", "4", "--duration", "0.5"]
        )
        self.client_mock.swipe.assert_called_once_with(
            p_start=(1, 2), p_end=(3, 4), duration=0.5, delta=None
        )

    async def test_swipe_without_extra_params(self) -> None:
        self.client_mock.swipe = AsyncMock(return_value=[])
        await cli_main(cmd_input=["ui", "swipe", "1", "2", "3", "4"])
        self.client_mock.swipe.assert_called_once_with(
            p_start=(1, 2), p_end=(3, 4), duration=None, delta=None
        )

    async def test_contacts_update(self) -> None:
        self.client_mock.contacts_update = AsyncMock(return_value=[])
        await cli_main(cmd_input=["contacts", "update", "/dev/null"])
        self.client_mock.contacts_update.assert_called_once_with(
            contacts_path="/dev/null"
        )

    async def test_contacts_clear(self) -> None:
        target_description = MagicMock()
        target_description.target_type = 0
        self.client_mock.describe = AsyncMock(return_value=target_description)
        self.client_mock.contacts_clear = AsyncMock(return_value=None)
        await cli_main(cmd_input=["contacts", "clear"])
        self.client_mock.contacts_clear.assert_called_once()

    async def test_photos_clear(self) -> None:
        target_description = MagicMock()
        target_description.target_type = 0
        self.client_mock.describe = AsyncMock(return_value=target_description)
        self.client_mock.photos_clear = AsyncMock(return_value=None)
        await cli_main(cmd_input=["photos", "clear"])
        self.client_mock.photos_clear.assert_called_once()

    def _describe_as(self, target_type: TargetType) -> None:
        target_description = MagicMock()
        target_description.target_type = target_type
        self.client_mock.describe = AsyncMock(return_value=target_description)

    async def test_lock_prints_the_state_springboard_reports(self) -> None:
        self._describe_as(TargetType.SIMULATOR)
        self.client_mock.lock = AsyncMock(return_value=LockState(locked=True))
        with redirect_stdout(StringIO()) as output:
            self.assertEqual(await cli_main(cmd_input=["ui", "lock"]), 0)
        self.assertEqual(output.getvalue().strip(), "locked")
        self.client_mock.lock.assert_called_once_with()

    async def test_unlock_json(self) -> None:
        self._describe_as(TargetType.SIMULATOR)
        self.client_mock.unlock = AsyncMock(return_value=LockState(locked=False))
        with redirect_stdout(StringIO()) as output:
            self.assertEqual(await cli_main(cmd_input=["ui", "unlock", "--json"]), 0)
        self.assertEqual(
            json.loads(output.getvalue()),
            {"locked": False},
        )
        self.client_mock.unlock.assert_called_once_with()

    async def test_lock_state_does_not_change_the_state(self) -> None:
        self._describe_as(TargetType.SIMULATOR)
        self.client_mock.lock_state = AsyncMock(return_value=LockState(locked=False))
        self.client_mock.lock = AsyncMock()
        self.client_mock.unlock = AsyncMock()
        with redirect_stdout(StringIO()) as output:
            self.assertEqual(await cli_main(cmd_input=["ui", "lock", "--status"]), 0)
        self.assertEqual(output.getvalue().strip(), "unlocked")
        self.client_mock.lock.assert_not_called()
        self.client_mock.unlock.assert_not_called()

    async def test_lock_commands_refuse_non_simulator_targets(self) -> None:
        for target_type in [TargetType.DEVICE, TargetType.MAC]:
            for command in [
                ["ui", "lock"],
                ["ui", "unlock"],
                ["ui", "lock", "--status"],
            ]:
                with self.subTest(target_type=target_type, command=command):
                    self._describe_as(target_type)
                    self.client_mock.lock = AsyncMock()
                    self.client_mock.unlock = AsyncMock()
                    self.client_mock.lock_state = AsyncMock()
                    self.assertNotEqual(await cli_main(cmd_input=command), 0)
                    self.client_mock.lock.assert_not_called()
                    self.client_mock.unlock.assert_not_called()
                    self.client_mock.lock_state.assert_not_called()

    async def test_screenshot_defaults_to_the_historical_capture(self) -> None:
        # No flags has to keep meaning what it meant before the command had
        # any: a full-screen, unscaled PNG written to the destination.
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png bytes"))
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "out.png")
            self.assertEqual(await cli_main(cmd_input=["screenshot", path]), 0)
            with open(path, "rb") as f:
                self.assertEqual(f.read(), b"png bytes")
        self.client_mock.screenshot.assert_called_once_with(options=ScreenshotOptions())

    async def test_app_screenshot_uses_the_connected_target_and_reports_only_capture_attribution(
        self,
    ) -> None:
        self.client_mock.companion = CompanionInfo(
            "target-1", True, None, TCPAddress("localhost", 1)
        )
        marker = AppScreenshotCapture("nonce-1", "target-1", "com.example.app")
        image = Screenshot(b"\x89PNG\r\n\x1a\nimage", app_capture=marker)
        provider = _AppCapturePlugin(image)
        output = StringIO()
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(plugin, "PLUGINS", [provider]),
            patch.object(plugin, "load_cli_plugins"),
            redirect_stdout(output),
        ):
            path = os.path.join(directory, "out.png")
            self.assertEqual(
                await cli_main(
                    cmd_input=[
                        "screenshot",
                        path,
                        "--app-bundle-id",
                        marker.bundle_id,
                        "--udid",
                        "target-1",
                        "--json",
                    ]
                ),
                0,
            )
            with open(path, "rb") as file:
                self.assertEqual(file.read(), bytes(image))
        provider.capture.assert_called_once_with(
            self.client_mock, marker.bundle_id, ScreenshotOptions()
        )
        self.client_mock.screenshot.assert_not_called()
        metadata = json.loads(output.getvalue())
        self.assertEqual(
            metadata["app_capture"],
            {
                "capture_nonce": "nonce-1",
                "target_udid": "target-1",
                "bundle_id": marker.bundle_id,
            },
        )
        self.assertEqual(
            set(metadata),
            {
                "format",
                "byte_count",
                "width",
                "height",
                "source_width",
                "source_height",
                "screen_scale",
                "app_capture",
            },
        )

    async def test_app_screenshot_rejects_wrong_target_and_every_transform_before_capture_or_file_write(
        self,
    ) -> None:
        self.client_mock.companion = CompanionInfo(
            "target-1", True, None, TCPAddress("localhost", 1)
        )
        provider = _AppCapturePlugin(
            Screenshot(
                b"\x89PNG\r\n\x1a\nimage",
                app_capture=AppScreenshotCapture(
                    "nonce", "target-1", "com.example.app"
                ),
            )
        )
        for flags in (
            ["--udid", "other"],
            ["--format", "jpeg"],
            ["--format", "tiff"],
            ["--crop", "0,0,1,1"],
            ["--compression-quality", "1"],
            ["--scale-factor", "1"],
            ["--max-width", "100"],
            ["--max-height", "100"],
            ["--units", "points"],
            ["--app-bundle-id", "com.app/path"],
        ):
            with (
                self.subTest(flags=flags),
                tempfile.TemporaryDirectory() as directory,
                patch.object(plugin, "PLUGINS", [provider]),
                patch.object(plugin, "load_cli_plugins"),
            ):
                path = os.path.join(directory, "out.png")
                with open(path, "wb") as file:
                    file.write(b"existing")
                self.assertEqual(
                    await cli_main(
                        cmd_input=[
                            "screenshot",
                            path,
                            "--app-bundle-id",
                            "com.example.app",
                            *flags,
                        ]
                    ),
                    1,
                )
                with open(path, "rb") as file:
                    self.assertEqual(file.read(), b"existing")
        provider.capture.assert_not_called()
        self.client_mock.screenshot.assert_not_called()

    async def test_app_screenshot_provider_failure_or_unbound_result_never_creates_a_file(
        self,
    ) -> None:
        self.client_mock.companion = CompanionInfo(
            "target-1", True, None, TCPAddress("localhost", 1)
        )
        for provider in (
            None,
            _AppCapturePlugin(None),
            _AppCapturePlugin(Screenshot(b"\x89PNG\r\n\x1a\nimage")),
            _AppCapturePlugin(None, IdbException("refused")),
        ):
            with (
                tempfile.TemporaryDirectory() as directory,
                patch.object(plugin, "PLUGINS", [] if provider is None else [provider]),
                patch.object(plugin, "load_cli_plugins"),
            ):
                path = os.path.join(directory, "out.png")
                self.assertEqual(
                    await cli_main(
                        cmd_input=[
                            "screenshot",
                            path,
                            "--app-bundle-id",
                            "com.example.app",
                        ]
                    ),
                    1,
                )
                self.assertFalse(os.path.exists(path))
        self.client_mock.screenshot.assert_not_called()

    async def test_screenshot_every_flag_reaches_the_options(self) -> None:
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"jpeg"))
        with tempfile.TemporaryDirectory() as directory:
            await cli_main(
                cmd_input=[
                    "screenshot",
                    os.path.join(directory, "out.jpeg"),
                    "--format",
                    "jpeg",
                    "--compression-quality",
                    "0.35",
                    "--crop",
                    "10,20,30,40",
                    "--max-width",
                    "100",
                    "--max-height",
                    "200",
                    "--units",
                    "points",
                ]
            )
        self.client_mock.screenshot.assert_called_once_with(
            options=ScreenshotOptions(
                format=ScreenshotFormat.JPEG,
                compression_quality=0.35,
                crop=ScreenshotCrop(x=10, y=20, width=30, height=40),
                max_width=100,
                max_height=200,
                unit=ScreenshotUnit.POINTS,
            )
        )

    async def test_screenshot_scale_factor_reaches_the_options(self) -> None:
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png"))
        with tempfile.TemporaryDirectory() as directory:
            await cli_main(
                cmd_input=[
                    "screenshot",
                    os.path.join(directory, "out.png"),
                    "--scale-factor",
                    "0.5",
                ]
            )
        self.client_mock.screenshot.assert_called_once_with(
            options=ScreenshotOptions(scale_factor=0.5)
        )

    async def test_screenshot_rejects_a_factor_and_a_bounding_box(self) -> None:
        # argparse cannot express "a factor, or one or both bounds", so the
        # options type refuses it and the command reports that as an error
        # rather than a traceback.
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png"))
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                await cli_main(
                    cmd_input=[
                        "screenshot",
                        os.path.join(directory, "out.png"),
                        "--scale-factor",
                        "0.5",
                        "--max-width",
                        "100",
                    ]
                ),
                1,
            )
        self.client_mock.screenshot.assert_not_called()

    async def test_screenshot_rejects_a_malformed_crop(self) -> None:
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png"))
        with tempfile.TemporaryDirectory() as directory:
            for crop in ["10,20", "10,20,30,40,50", "10,20,30,wide"]:
                with self.subTest(crop=crop):
                    self.assertEqual(
                        await cli_main(
                            cmd_input=[
                                "screenshot",
                                os.path.join(directory, "out.png"),
                                "--crop",
                                crop,
                            ]
                        ),
                        2,
                    )
        self.client_mock.screenshot.assert_not_called()

    async def test_screenshot_reports_a_value_the_wire_cannot_carry(self) -> None:
        # These three never reach the companion: 0 is a proto scalar's "unset",
        # so a quality of 0 would come back as a default-quality JPEG reported
        # as a success, and a negative fit bound raises out of protobuf as a
        # traceback. They have to be an error message from here instead.
        for flags in [
            ["--compression-quality", "0"],
            ["--format", "png", "--compression-quality", "0"],
            ["--compression-quality", "1.5"],
            ["--max-width", "-1"],
            ["--max-height", "0"],
        ]:
            with self.subTest(flags=flags):
                self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png"))
                with tempfile.TemporaryDirectory() as directory:
                    self.assertEqual(
                        await cli_main(
                            cmd_input=[
                                "screenshot",
                                os.path.join(directory, "out.png"),
                                *flags,
                            ]
                        ),
                        1,
                    )
                self.client_mock.screenshot.assert_not_called()

    async def test_screenshot_json_reports_every_measurement(self) -> None:
        self.client_mock.screenshot = AsyncMock(
            return_value=Screenshot(
                b"jpeg",
                format=ScreenshotFormat.JPEG,
                width=200,
                height=100,
                source_width=828,
                source_height=1792,
                screen_scale=3,
            )
        )
        output = StringIO()
        with tempfile.TemporaryDirectory() as directory:
            with redirect_stdout(output):
                await cli_main(
                    cmd_input=[
                        "screenshot",
                        os.path.join(directory, "out.jpeg"),
                        "--format",
                        "jpeg",
                        "--json",
                    ]
                )
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "format": "jpeg",
                "byte_count": 4,
                "width": 200,
                "height": 100,
                "source_width": 828,
                "source_height": 1792,
                "screen_scale": 3,
            },
        )

    async def test_screenshot_will_not_put_json_and_an_image_on_stdout(self) -> None:
        self.client_mock.screenshot = AsyncMock(return_value=Screenshot(b"png"))
        self.assertEqual(
            await cli_main(cmd_input=["screenshot", "-", "--json"]),
            1,
        )
        self.client_mock.screenshot.assert_not_called()

    async def test_accessibility_info_all(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(nested=False),
        )

    async def test_accessibility_info_all_nested(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--nested"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(nested=True),
        )

    async def test_accessibility_info_at_point(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-point", "10", "20"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            options=AccessibilityInfoOptions(nested=False),
        )

    async def test_accessibility_info_at_point_nested(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-point", "--nested", "10", "20"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            options=AccessibilityInfoOptions(nested=True),
        )

    async def test_accessibility_info_all_api(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--api", "axbridge"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False, backend=AccessibilityBackend.AXBRIDGE_PERSISTENT
            ),
        )

    async def test_accessibility_info_at_point_api(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(
            cmd_input=["ui", "describe-point", "10", "20", "--api", "axbridge"]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            options=AccessibilityInfoOptions(
                nested=False, backend=AccessibilityBackend.AXBRIDGE_PERSISTENT
            ),
        )

    async def test_accessibility_info_all_api_ax_coresimulator(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--api", "ax-coresimulator"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False, backend=AccessibilityBackend.AX_CORESIMULATOR
            ),
        )

    async def test_accessibility_info_all_format_complete(self) -> None:
        self.client_mock.accessibility_info = AsyncMock(
            return_value=AccessibilityInfo(json='{"backend": "ax", "elements": []}')
        )
        await cli_main(cmd_input=["ui", "describe-all", "--format", "complete"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False, format=AccessibilityOutputFormat.COMPLETE
            ),
        )

    async def test_accessibility_info_at_point_format_nested(self) -> None:
        self.client_mock.accessibility_info = AsyncMock(
            return_value=AccessibilityInfo(json="[]")
        )
        await cli_main(
            cmd_input=["ui", "describe-point", "10", "20", "--format", "nested"]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityPoint(x=10, y=20),
            options=AccessibilityInfoOptions(
                nested=False, format=AccessibilityOutputFormat.NESTED
            ),
        )

    async def test_accessibility_info_rejects_nested_with_format(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        exit_code = await cli_main(
            cmd_input=["ui", "describe-all", "--nested", "--format", "complete"]
        )
        self.assertEqual(exit_code, 1)
        self.client_mock.accessibility_info.assert_not_called()

    async def test_accessibility_info_all_enrichers(self) -> None:
        self.client_mock.accessibility_info = AsyncMock(
            return_value=AccessibilityInfo(json='{"backend": "ax", "elements": []}')
        )
        await cli_main(
            cmd_input=[
                "ui",
                "describe-all",
                "--profile",
                "--collect-frame-coverage",
                "--format",
                "complete",
            ]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False,
                format=AccessibilityOutputFormat.COMPLETE,
                profile=True,
                collect_frame_coverage=True,
            ),
        )

    async def test_format_enum_matches_wire_values(self) -> None:
        # --format nested must put the exact value on the wire that the
        # deprecated --nested boolean always has, so an older companion —
        # which knows nothing of this enum — serves both identically.
        for fmt in AccessibilityOutputFormat:
            self.assertEqual(
                fmt.value,
                getattr(AccessibilityInfoRequest, fmt.name),
            )

    async def test_describe_marker_api(self) -> None:
        self.client_mock.accessibility_info = AsyncMock(
            return_value=AccessibilityInfo(json="[]")
        )
        await cli_main(cmd_input=["ui", "describe", "Login", "--api", "ax"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityInfoOptions(
                nested=False, backend=AccessibilityBackend.AX
            ),
        )

    async def test_describe_marker_keys_and_enrichers(self) -> None:
        # describe took --format and --api but not --key, so a caller asking a
        # marker read for two attributes got the whole default set instead.
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(
            cmd_input=[
                "ui",
                "describe",
                "Login",
                "--key",
                "AXLabel",
                "--key",
                "frame",
                "--profile",
                "--collect-frame-coverage",
            ]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityInfoOptions(
                nested=False,
                keys=["AXLabel", "frame"],
                profile=True,
                collect_frame_coverage=True,
            ),
        )

    async def test_describe_marker_ignore_case(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe", "ok", "--ignore-case"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=AccessibilityMarker(
                value="ok",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            options=AccessibilityInfoOptions(nested=False, ignore_case=True),
        )

    async def test_describe_marker_is_case_sensitive_by_default(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe", "ok"])
        _, kwargs = self.client_mock.accessibility_info.call_args
        self.assertFalse(kwargs["options"].ignore_case)

    async def test_backend_enum_matches_wire_values(self) -> None:
        # The typed backend must emit the exact values the proto declares, by
        # name and by number — an unset backend is BACKEND_UNSPECIFIED, the
        # only thing an older companion understands.
        self.assertEqual(AccessibilityInfoRequest.BACKEND_UNSPECIFIED, 0)
        for backend in AccessibilityBackend:
            self.assertEqual(
                backend.value,
                getattr(AccessibilityInfoRequest, backend.name),
            )

    async def test_accessibility_info_all_keys(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(
            cmd_input=[
                "ui",
                "describe-all",
                "--nested",
                "--key",
                "AXLabel",
                "--key",
                "type",
            ]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(nested=True, keys=["AXLabel", "type"]),
        )

    async def test_accessibility_info_all_match(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--match", "Add to Cart"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(nested=False, match="Add to Cart"),
        )

    async def test_accessibility_info_all_match_key_and_ignore_case(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(
            cmd_input=[
                "ui",
                "describe-all",
                "--match",
                "cart",
                "--match-key",
                "AXUniqueId",
                "--ignore-case",
            ]
        )
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False,
                match="cart",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                ignore_case=True,
            ),
        )

    async def test_accessibility_info_all_filter(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--filter", "interactable"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False, filter=AccessibilityElementFilter.INTERACTABLE
            ),
        )

    async def test_accessibility_info_all_filter_all_is_explicit(self) -> None:
        # --filter all is not the same as omitting it: it sets the field, which
        # is still the historical behaviour, so both must reach the companion
        # as a read over every element.
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all", "--filter", "all"])
        self.client_mock.accessibility_info.assert_called_once_with(
            target=None,
            options=AccessibilityInfoOptions(
                nested=False, filter=AccessibilityElementFilter.ALL
            ),
        )

    async def test_filter_enum_matches_wire_values(self) -> None:
        # The typed filter must emit the values the proto declares, by name and
        # by number — FILTER_ALL is zero, so a request that does not ask, and
        # an older companion that drops the field, both read every element.
        self.assertEqual(AccessibilityInfoRequest.FILTER_ALL, 0)
        for element_filter in AccessibilityElementFilter:
            self.assertEqual(
                element_filter.value,
                getattr(AccessibilityInfoRequest, f"FILTER_{element_filter.name}"),
            )

    async def test_accessibility_info_client_type_reaches_every_describe_verb(
        self,
    ) -> None:
        for argv, target in [
            (["ui", "describe-all"], None),
            (["ui", "describe-point", "10", "20"], AccessibilityPoint(x=10, y=20)),
            (
                ["ui", "describe", "Login"],
                AccessibilityMarker(
                    value="Login",
                    match_key=AccessibilitySearchableKey.LABEL,
                    depth=10,
                ),
            ),
        ]:
            self.client_mock.accessibility_info = AsyncMock()
            await cli_main(cmd_input=argv + ["--client-type", "xctest"])
            self.client_mock.accessibility_info.assert_called_once_with(
                target=target,
                options=AccessibilityInfoOptions(
                    nested=False, client_type=AccessibilityClientType.XCTEST
                ),
            )

    async def test_accessibility_info_without_client_type_names_none(self) -> None:
        self.client_mock.accessibility_info = AsyncMock()
        await cli_main(cmd_input=["ui", "describe-all"])
        options = self.client_mock.accessibility_info.call_args.kwargs["options"]
        self.assertIsNone(options.client_type)

    async def test_client_type_enum_matches_wire_values(self) -> None:
        # By name and by number, and UNSPECIFIED is zero: a request that does
        # not ask, and an older companion that drops the field, claim no client.
        self.assertEqual(AccessibilityInfoRequest.CLIENT_TYPE_UNSPECIFIED, 0)
        for client_type in AccessibilityClientType:
            self.assertEqual(
                client_type.value,
                getattr(AccessibilityInfoRequest, f"CLIENT_TYPE_{client_type.name}"),
            )

    async def test_crash_list_all(self) -> None:
        self.client_mock.crash_list = AsyncMock(return_value=[])
        await cli_main(cmd_input=["crash", "list"])
        self.client_mock.crash_list.assert_called_once_with(query=CrashLogQuery())

    async def test_crash_list_with_predicate(self) -> None:
        self.client_mock.crash_list = AsyncMock(return_value=[])
        await cli_main(cmd_input=["crash", "list", "--since", "20"])
        self.client_mock.crash_list.assert_called_once_with(
            query=CrashLogQuery(since=20)
        )

    async def test_crash_show(self) -> None:
        self.client_mock.crash_show = AsyncMock()
        await cli_main(cmd_input=["crash", "show", "foo"])
        self.client_mock.crash_show.assert_called_once_with(name="foo")

    async def test_crash_delete_all(self) -> None:
        self.client_mock.crash_delete = AsyncMock(return_value=[])
        cases = (
            (["crash", "delete", "--all"], CrashLogQuery()),
            (["crash", "delete", "", "--all"], CrashLogQuery(name="")),
            (
                ["crash", "delete", "--before", "0", "--all"],
                CrashLogQuery(before=0),
            ),
            (
                ["crash", "delete", "--since", "0", "--all"],
                CrashLogQuery(since=0),
            ),
            (
                ["crash", "delete", "--bundle-id", "", "--all"],
                CrashLogQuery(bundle_id=""),
            ),
        )
        for command, query in cases:
            with self.subTest(command=command):
                self.client_mock.crash_delete.reset_mock()

                self.assertEqual(await cli_main(cmd_input=command), 0)

                self.client_mock.crash_delete.assert_called_once_with(query=query)

    async def test_crash_delete_with_predicate(self) -> None:
        self.client_mock.crash_delete = AsyncMock(return_value=[])
        cases = (
            (["crash", "delete", "--since", "20"], CrashLogQuery(since=20)),
            (
                ["crash", "delete", "", "--before", "1"],
                CrashLogQuery(name="", before=1),
            ),
            (
                ["crash", "delete", "", "--since", "1"],
                CrashLogQuery(name="", since=1),
            ),
            (
                ["crash", "delete", "", "--bundle-id", "com.example"],
                CrashLogQuery(name="", bundle_id="com.example"),
            ),
        )
        for command, query in cases:
            with self.subTest(command=command):
                self.client_mock.crash_delete.reset_mock()

                self.assertEqual(await cli_main(cmd_input=command), 0)

                self.client_mock.crash_delete.assert_called_once_with(query=query)

    async def test_crash_delete_with_name(self) -> None:
        self.client_mock.crash_delete = AsyncMock(return_value=[])
        await cli_main(cmd_input=["crash", "delete", "some.foo.bar.crash"])
        self.client_mock.crash_delete.assert_called_once_with(
            query=CrashLogQuery(name="some.foo.bar.crash")
        )

        for command in (
            ["crash", "delete"],
            ["crash", "delete", ""],
            ["crash", "delete", "--before", "0"],
            ["crash", "delete", "--since", "0"],
            ["crash", "delete", "--bundle-id", ""],
            ["--companion", "/tmp/unreached.sock", "crash", "delete"],
        ):
            with self.subTest(command=command):
                self.client_manager_mock.reset_mock()
                self.client_mock.build.reset_mock()
                self.client_mock.crash_delete.reset_mock()

                stderr = StringIO()
                with redirect_stderr(stderr):
                    self.assertEqual(await cli_main(cmd_input=command), 1)

                self.assertEqual(
                    stderr.getvalue(),
                    "Must pass --all if not other arguments specified\n",
                )
                self.assertNotIn("Traceback", stderr.getvalue())
                self.client_manager_mock.assert_not_called()
                self.client_mock.build.assert_not_called()
                self.client_mock.crash_delete.assert_not_called()

    async def test_add_media(self) -> None:
        self.client_mock.add_media = AsyncMock(return_value=["aaa", "bbb"])
        file_paths = ["cat.jpeg", "dog.mov"]
        await cli_main(cmd_input=["add-media"] + file_paths)
        self.client_mock.add_media.assert_called_once_with(file_paths=file_paths)

    async def test_inject_audio(self) -> None:
        self.client_mock.inject_audio = AsyncMock()
        audio_file_path = "sound.wav"
        await cli_main(cmd_input=["audio", "inject", audio_file_path])
        self.client_mock.inject_audio.assert_called_once_with(
            audio_file_path=audio_file_path
        )

    async def test_inject_camera(self) -> None:
        self.client_mock.inject_video = MagicMock(
            side_effect=lambda **_: AsyncGeneratorMock(([], ["Camera", "Recorder"]))
        )
        stop = asyncio.Event()
        output = StringIO()
        with (
            patch("idb.cli.commands.media.signal_handler_event", return_value=stop),
            redirect_stdout(output),
        ):
            await cli_main(cmd_input=["camera", "inject", "back.mp4"])
            await cli_main(
                cmd_input=[
                    "camera",
                    "inject",
                    "back.mp4",
                    "--front",
                    "front.mp4",
                    "--loop",
                    "--json",
                ]
            )
        self.assertEqual(
            [call.kwargs for call in self.client_mock.inject_video.call_args_list],
            [
                {
                    "back_path": "back.mp4",
                    "front_path": None,
                    "loop": False,
                    "stop": stop,
                },
                {
                    "back_path": "back.mp4",
                    "front_path": "front.mp4",
                    "loop": True,
                    "stop": stop,
                },
            ],
        )
        self.assertEqual(
            output.getvalue().splitlines(),
            [
                "No process is showing the video",
                "Showing the video in: Camera, Recorder",
                '{"processes": []}',
                '{"processes": ["Camera", "Recorder"]}',
            ],
        )

    async def test_focus(self) -> None:
        self.client_mock.focus = AsyncMock(return_value=["aaa", "bbb"])
        await cli_main(cmd_input=["focus"])
        self.client_mock.focus.assert_called_once()

    async def test_notification_send_and_legacy_send_notification(self) -> None:
        payload = '{"aps":{"alert":"Hello"}}'
        for command in (
            ["notification", "send", "com.foo.bar", payload],
            ["send-notification", "com.foo.bar", payload],
        ):
            with self.subTest(command=command):
                for requested in (False, True):
                    send_notification = AsyncMock()
                    self.client_mock.send_notification = send_notification
                    await cli_main(
                        cmd_input=command
                        + (["--service-extension"] if requested else [])
                    )
                    send_notification.assert_called_once_with(
                        "com.foo.bar", payload, process_service_extension=requested
                    )

    async def test_notification_list(self) -> None:
        self.client_mock.delivered_notifications = AsyncMock(
            return_value=[
                DELIVERED_NOTIFICATION,
                AWKWARD_DELIVERED_NOTIFICATION,
                UNREADABLE_DATE_DELIVERED_NOTIFICATION,
                NAN_DATE_DELIVERED_NOTIFICATION,
                INFINITE_DATE_DELIVERED_NOTIFICATION,
            ]
        )
        output = StringIO()
        with redirect_stdout(output):
            await cli_main(cmd_input=["notification", "list", "com.foo.bar"])
        self.client_mock.delivered_notifications.assert_called_once_with("com.foo.bar")
        # Split into lines rather than compared whole, so that a newline in a
        # field fails here instead of quietly reading as a further record. A field
        # the app left empty reads as `""` rather than as a stand-in for a field
        # that was not there, and text it wrote outside ASCII reads as itself. The
        # last three dates are ones no platform can render -- out of range, not a
        # number, infinite -- and the whole list is still expected: one bad field
        # does not cost the other notifications.
        self.assertEqual(
            output.getvalue().splitlines(),
            [
                '"com.foo.bar" | "identifier-1" | "Title" | "Subtitle" | "Body"'
                ' | "thread-1" | 2023-11-14T22:13:20+00:00',
                '"com.foo.bar" | "" | "Line one\\nLine two \\u0085\\u2028\\u2029🚀"'
                ' | "" | "Body with a | separator, a \\"quote\\" and 日本語"'
                ' | "" | no date',
                '"com.foo.bar" | "identifier-3" | "Title" | "Subtitle" | "Body"'
                ' | "thread-3" | unreadable date',
                '"com.foo.bar" | "identifier-4" | "Title" | "Subtitle" | "Body"'
                ' | "thread-4" | unreadable date',
                '"com.foo.bar" | "identifier-5" | "Title" | "Subtitle" | "Body"'
                ' | "thread-5" | unreadable date',
            ],
        )

    async def test_notification_list_json(self) -> None:
        self.client_mock.delivered_notifications = AsyncMock(
            return_value=[
                DELIVERED_NOTIFICATION,
                UNREADABLE_DATE_DELIVERED_NOTIFICATION,
                NAN_DATE_DELIVERED_NOTIFICATION,
                INFINITE_DATE_DELIVERED_NOTIFICATION,
            ]
        )
        output = StringIO()
        with redirect_stdout(output):
            await cli_main(cmd_input=["notification", "list", "com.foo.bar", "--json"])
        # Read strictly, so that a line carrying a bare `Infinity` or `NaN` fails
        # here rather than passing on Python's lenient reader while breaking every
        # other one -- `--json` is the form callers are told to parse.
        records = [_strict_json_loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(
            records[0],
            {
                "bundle_id": "com.foo.bar",
                "identifier": "identifier-1",
                "title": "Title",
                "subtitle": "Subtitle",
                "body": "Body",
                "thread_identifier": "thread-1",
                "date": 1700000000.0,
            },
        )
        # The value as it arrived, not the placeholder the human format shows
        # for it: a caller that knows better than this process what the device
        # meant by it can only do so if it is still here.
        self.assertEqual(records[1]["date"], 1e20)
        # A NaN and an infinity have no JSON number between them, so they read as
        # the same `null` an absent date does. Carrying them through as they
        # arrived is the one thing that cannot be done: it is not JSON.
        self.assertIsNone(records[2]["date"])
        self.assertIsNone(records[3]["date"])

    async def test_notification_clear(self) -> None:
        self.client_mock.clear_delivered_notifications = AsyncMock()
        output = StringIO()
        with redirect_stdout(output):
            await cli_main(cmd_input=["notification", "clear", "com.foo.bar"])
        self.client_mock.clear_delivered_notifications.assert_called_once_with(
            "com.foo.bar"
        )
        self.assertEqual(output.getvalue(), "")

    async def test_debugserver_start(self) -> None:
        self.client_mock.debugserver_start = AsyncMock(return_value=["aaa", "bbb"])
        await cli_main(cmd_input=["debugserver", "start", "com.foo.bar"])
        self.client_mock.debugserver_start.assert_called_once_with(
            bundle_id="com.foo.bar"
        )

    async def test_debugserver_stop(self) -> None:
        self.client_mock.debugserver_stop = AsyncMock(return_value=["aaa", "bbb"])
        await cli_main(cmd_input=["debugserver", "stop"])
        self.client_mock.debugserver_stop.assert_called_once()

    async def test_debugserver_status(self) -> None:
        self.client_mock.debugserver_status = AsyncMock(return_value=["aaa", "bbb"])
        await cli_main(cmd_input=["debugserver", "status"])
        self.client_mock.debugserver_status.assert_called_once()

    async def test_profile_trace_prints_the_tables_of_the_trace_report(self) -> None:
        self.client_mock.profile = AsyncMock(
            return_value=ProfileResult(
                report={
                    "trace": {
                        "runs": [],
                        "tables": [
                            {
                                "schema": "time-profile",
                                "columns": [
                                    {"mnemonic": "time", "name": "Sample Time"},
                                    {"mnemonic": "stack", "name": "Backtrace"},
                                ],
                                "rowCount": 2,
                                "rows": [
                                    {
                                        "values": [
                                            {"text": "00:00.001"},
                                            {
                                                "backtrace": {
                                                    "frames": [
                                                        {"symbol": "inner"},
                                                        {"symbol": "outer"},
                                                    ]
                                                }
                                            },
                                        ]
                                    }
                                ],
                            }
                        ],
                    }
                },
                tool_output=b"raw tool output",
                artifact=None,
            )
        )
        output = StringIO()
        with redirect_stdout(output), redirect_stderr(StringIO()):
            self.assertEqual(
                await cli_main(cmd_input=["profile", "trace", "--pid", "1"]), 0
            )
        self.assertEqual(
            output.getvalue(),
            "time-profile (1 of 2 rows)\nSample Time\tBacktrace\n"
            "00:00.001\tinner < outer\n\n",
        )

    async def test_profile_trace_without_a_trace_report_prints_the_tool_output(
        self,
    ) -> None:
        self.client_mock.profile = AsyncMock(
            return_value=ProfileResult(
                report=None, tool_output=b"raw tool output", artifact=None
            )
        )
        output = TextIOWrapper(BytesIO(), encoding="utf-8")
        with redirect_stdout(output), redirect_stderr(StringIO()):
            self.assertEqual(
                await cli_main(cmd_input=["profile", "trace", "--pid", "1"]), 0
            )
        output.flush()
        self.assertEqual(output.buffer.getvalue(), b"raw tool output")

    async def test_xctrace_record_profiles_a_trace(self) -> None:
        self.client_mock.profile = AsyncMock(
            return_value=ProfileResult(
                report=None, tool_output=b"", artifact="trace.trace"
            )
        )
        await cli_main(
            cmd_input=[
                "xctrace",
                "record",
                "--all-processes",
                "--template",
                "Time Profiler",
                "--time-limit",
                "4m",
                "--output",
                "trace.trace",
            ]
        )
        self.client_mock.profile.assert_called_once_with(
            kind=TraceProfile(template="Time Profiler", duration=240.0),
            target=ProfileAllProcesses(),
            stop=ANY,
            artifact_path="trace.trace",
        )

    async def test_xctrace_record_targets(self) -> None:
        for flags, target in [
            (
                ["--launch", "com.facebook.Wilde"],
                ProfileLaunch(bundle_id="com.facebook.Wilde"),
            ),
            (["--attach", "123"], ProfilePid(pid=123)),
            (
                ["--attach", "com.facebook.Wilde"],
                ProfileBundleID(bundle_id="com.facebook.Wilde"),
            ),
        ]:
            with self.subTest(flags=flags):
                self.client_mock.profile = AsyncMock(
                    return_value=ProfileResult(
                        report=None, tool_output=b"", artifact="trace.trace"
                    )
                )
                await cli_main(
                    cmd_input=[
                        "xctrace",
                        "record",
                        *flags,
                        "--template",
                        "Time Profiler",
                        "--output",
                        "trace",
                    ]
                )
                self.client_mock.profile.assert_called_once_with(
                    kind=TraceProfile(template="Time Profiler"),
                    target=target,
                    stop=ANY,
                    artifact_path="trace.trace",
                )

    async def test_xctrace_record_with_ignored_options(self) -> None:
        self.client_mock.profile = AsyncMock(
            return_value=ProfileResult(
                report=None, tool_output=b"", artifact="trace.trace"
            )
        )
        await cli_main(
            cmd_input=[
                "xctrace",
                "record",
                "--all-processes",
                "--template",
                "Time Profiler",
                "--output",
                "trace.trace",
                "--device",
                "9d86342f4761d4c28d99c7ed5df95d2d641fb3c4",
                "--append-run",
                "--stop-timeout",
                "60s",
            ]
        )
        self.client_mock.profile.assert_called_once_with(
            kind=TraceProfile(template="Time Profiler"),
            target=ProfileAllProcesses(),
            stop=ANY,
            artifact_path="trace.trace",
        )

    async def test_xctrace_record_rejects_unsupported_options(self) -> None:
        for flags in [
            ["--all-processes", "--package", "fb_signpost"],
            ["--launch", "com.facebook.Wilde", "foo", "bar"],
            ["--launch", "com.facebook.Wilde", "--env", "foo=bar"],
            ["--all-processes", "--target-stdin", "-"],
            ["--all-processes", "--target-stdout", "-"],
            ["--all-processes", "--post-args", "instrumental", "convert"],
            ["--attach", "Instruments"],
        ]:
            with self.subTest(flags=flags):
                self.client_mock.profile = AsyncMock()
                self.assertEqual(
                    await cli_main(
                        cmd_input=[
                            "xctrace",
                            "record",
                            "--template",
                            "Time Profiler",
                            "--output",
                            "trace.trace",
                            *flags,
                        ]
                    ),
                    1,
                )
                self.client_mock.profile.assert_not_called()

    async def test_xctrace_record_without_target(self) -> None:
        self.assertEqual(
            await cli_main(
                cmd_input=[
                    "xctrace",
                    "record",
                    "--template",
                    "Time Profiler",
                    "--output",
                    "trace.trace",
                ]
            ),
            2,  # error code when the required arguemt is not provided
        )

    async def test_xctrace_record_with_duplicated_targets(self) -> None:
        self.assertEqual(
            await cli_main(
                cmd_input=[
                    "xctrace",
                    "record",
                    "--all-processes",
                    "--launch",
                    "com.facebook.Wilde",
                    "--template",
                    "Time Profiler",
                    "--output",
                    "trace.trace",
                ]
            ),
            2,  # error code when mutually exclusive arguments are provided
        )

    async def test_subcommands_logged_for_top_level_command(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        on_launch_mock = MagicMock()
        with patch("idb.cli.main.plugin.on_launch", on_launch_mock):
            await cli_main(cmd_input=["list-apps"])
        on_launch_mock.assert_called_once_with(ANY, subcommands=["list-apps"])

    async def test_subcommands_logged_for_nested_command(self) -> None:
        self.client_mock.tap = AsyncMock(return_value=[])
        on_launch_mock = MagicMock()
        with patch("idb.cli.main.plugin.on_launch", on_launch_mock):
            await cli_main(cmd_input=["ui", "tap", "10", "20"])
        on_launch_mock.assert_called_once_with(ANY, subcommands=["ui", "tap"])

    async def test_cli_plugins_loaded_before_contributed_commands(self) -> None:
        self.client_mock.list_apps = AsyncMock(return_value=[])
        events: list[str] = []

        def load_cli_plugins() -> None:
            events.append("load")

        def get_commands() -> list[Command]:
            self.assertEqual(events, ["load"])
            events.append("get_commands")
            return []

        with (
            patch("idb.cli.main.plugin.load_cli_plugins", load_cli_plugins),
            patch("idb.cli.main.plugin.get_commands", get_commands),
        ):
            await cli_main(cmd_input=["list-apps"])
        self.assertEqual(events, ["load", "get_commands"])


class _StubCommand(Command):
    def __init__(self, name: str, aliases: list[str] | None = None) -> None:
        self._name = name
        self._aliases = aliases or []

    @property
    def name(self) -> str:
        return self._name

    @property
    def description(self) -> str:
        return ""

    @property
    def aliases(self) -> list[str]:
        return self._aliases

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        pass

    async def run(self, args: Namespace) -> None:
        pass


class TestResolveSubcommandPath(TestCase):
    def _root(self) -> CommandGroup:
        return CommandGroup(
            name="root_command",
            description="",
            commands=[
                _StubCommand(name="list-apps"),
                _StubCommand(name="list", aliases=["ls"]),
                CommandGroup(
                    name="ui",
                    description="",
                    commands=[_StubCommand(name="tap")],
                ),
            ],
        )

    def test_top_level_command(self) -> None:
        args = Namespace(root_command="list-apps")
        self.assertEqual(self._root().resolve_subcommand_path(args), ["list-apps"])

    def test_nested_command(self) -> None:
        args = Namespace(root_command="ui", ui="tap")
        self.assertEqual(self._root().resolve_subcommand_path(args), ["ui", "tap"])

    def test_alias_normalised_to_canonical_name(self) -> None:
        args = Namespace(root_command="ls")
        self.assertEqual(self._root().resolve_subcommand_path(args), ["list"])

    def test_no_subcommand_selected(self) -> None:
        args = Namespace(root_command=None)
        self.assertEqual(self._root().resolve_subcommand_path(args), [])

    def test_unknown_subcommand(self) -> None:
        args = Namespace(root_command="does-not-exist")
        self.assertEqual(self._root().resolve_subcommand_path(args), [])


class _RejectingPlugin(ModuleType):
    def on_command_parsed(
        self, logger: logging.Logger, command: Command, args: Namespace
    ) -> None:
        raise IdbException("rejected by policy")


class TestPluginRejection(TestCase):
    async def test_rejected_command_exits_nonzero_and_still_logs(self) -> None:
        logged: list[tuple[str, LoggingMetadata]] = []

        @asynccontextmanager
        async def capture_log_call(
            name: str, metadata: LoggingMetadata
        ) -> AsyncIterator[None]:
            logged.append((name, metadata))
            yield

        rejecting = _RejectingPlugin("rejecting")
        with (
            patch.object(plugin, "PLUGINS", [rejecting]),
            patch("idb.cli.log_call", capture_log_call),
        ):
            exit_code = await cli_main(cmd_input=["ui", "tap", "10", "20"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(len(logged), 1)
        self.assertEqual(logged[0][0], "TapCommand")
