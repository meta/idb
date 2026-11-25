#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import asyncio
import io
import os
import sys
import tempfile
import time
from argparse import Namespace
from collections.abc import AsyncIterator, Callable, Iterator
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from typing import cast
from unittest.mock import AsyncMock, MagicMock, patch

from idb.cli import ClientCommand
from idb.cli.command_tree import build_command_graph
from idb.cli.commands.dap import StdStreams
from idb.common.types import (
    Client,
    IdbException,
    InstalledArtifact,
    InstalledTestInfo,
    RetryVerdict,
    TestRunFailureInfo,
    TestRunInfo,
)
from idb.grpc.client import Client as GrpcClient
from idb.grpc.dap import read_next_dap_protocol_message
from idb.grpc.idb_grpc import CompanionServiceStub
from idb.utils.testing import TestCase


class _BytesWriter:
    def __init__(self) -> None:
        self.data = bytearray()

    def write(self, data: bytes) -> None:
        self.data.extend(data)


class _CombinedOutput:
    def __init__(self) -> None:
        self.data = bytearray()
        self.buffer = self

    def write(self, value: str | bytes) -> int:
        encoded = value.encode() if isinstance(value, str) else value
        self.data.extend(encoded)
        return len(value)

    def flush(self) -> None:
        pass


class _DebugClient:
    def __init__(self, operation: str, result: list[str] | None) -> None:
        self.operation = operation
        self.result = result
        self.calls: list[tuple[str, object]] = []

    async def debugserver_start(self, bundle_id: str) -> list[str]:
        self.calls.append(("start", bundle_id))
        return cast(list[str], self.result)

    async def debugserver_status(self) -> list[str] | None:
        self.calls.append(("status", None))
        return self.result

    async def debugserver_stop(self) -> None:
        self.calls.append(("stop", None))


class _DapOutputClient:
    def __init__(self) -> None:
        self.call: dict[str, object] | None = None

    async def dap(self, **kwargs: object) -> None:
        self.call = kwargs
        message = await read_next_dap_protocol_message(
            cast(asyncio.StreamReader, kwargs["input_stream"])
        )
        cast(_BytesWriter, kwargs["output_stream"]).write(message)


class _ShellClient:
    def __init__(self) -> None:
        self.urls: list[str] = []

    async def open_url(self, url: str) -> None:
        self.urls.append(url)
        if url == "bad":
            raise IdbException("boom")
        if url == "unsafe":
            raise IdbException(
                "did not answer",
                retry=RetryVerdict(verdict="unsafe", reason="outcome_unknown"),
            )


class _DiscoveryClient:
    def __init__(
        self,
        *,
        installed: list[InstalledTestInfo] | None = None,
        names: list[str] | None = None,
    ) -> None:
        self.installed = installed or []
        self.names = names or []
        self.calls: list[tuple[str, object]] = []

    async def list_xctests(self) -> list[InstalledTestInfo]:
        self.calls.append(("list_xctests", None))
        return self.installed

    async def list_test_bundle(
        self, test_bundle_id: str, app_path: str | None
    ) -> list[str]:
        self.calls.append(("list_test_bundle", (test_bundle_id, app_path)))
        return self.names

    async def install_xctest(
        self,
        xctest: str,
        skip_signing_bundles: bool | None = None,
        *,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        self.calls.append(("install_xctest", (xctest, skip_signing_bundles)))
        yield InstalledArtifact(
            name="InstalledTests",
            uuid="installed-uuid",
            progress=0.0,
        )


class _ObservedLogClient:
    """Streams two log chunks until stopped, recording what reached the file after each."""

    def __init__(
        self, written: io.BytesIO, cancel_error: Exception | None = None
    ) -> None:
        self.written = written
        # Raised when the stream is stopped, as a cancel on a lost connection does.
        self.cancel_error = cancel_error
        self.seen: list[bytes] = []
        self.yielded: list[str] = []

    async def _chunks(self, stop: asyncio.Event) -> AsyncIterator[str]:
        for chunk in ("first\n", "partial"):
            if stop.is_set():
                if self.cancel_error is not None:
                    raise self.cancel_error
                return
            self.yielded.append(chunk)
            yield chunk
            self.seen.append(self.written.getvalue())

    def tail_logs(
        self, stop: asyncio.Event, arguments: list[str] | None = None
    ) -> AsyncIterator[str]:
        return self._chunks(stop)

    def tail_companion_logs(self, stop: asyncio.Event) -> AsyncIterator[str]:
        return self._chunks(stop)


class _OneLineThenQuietLogClient:
    """Streams one log line, then nothing until stopped, as a narrow `--predicate` stream does."""

    async def _chunks(self, stop: asyncio.Event) -> AsyncIterator[str]:
        yield "first\n"
        await stop.wait()

    def tail_logs(
        self, stop: asyncio.Event, arguments: list[str] | None = None
    ) -> AsyncIterator[str]:
        return self._chunks(stop)

    def tail_companion_logs(self, stop: asyncio.Event) -> AsyncIterator[str]:
        return self._chunks(stop)


class _ResultClient:
    def __init__(self, result: TestRunInfo) -> None:
        self.result = result
        self.calls: list[dict[str, object]] = []

    async def run_xctest(self, **kwargs: object) -> AsyncIterator[TestRunInfo]:
        self.calls.append(kwargs)
        yield self.result


class _SingleResponseStream:
    def __init__(self, response: object) -> None:
        self.response = response
        self.sent: list[object] = []
        self.ended = 0
        self.entered = False
        self.exited = False
        self._delivered = False

    async def __aenter__(self) -> _SingleResponseStream:
        self.entered = True
        return self

    async def __aexit__(self, *_args: object) -> None:
        self.exited = True

    async def send_message(self, message: object) -> None:
        self.sent.append(message)

    async def end(self) -> None:
        self.ended += 1

    def __aiter__(self) -> _SingleResponseStream:
        return self

    async def __anext__(self) -> object:
        if self._delivered:
            raise StopAsyncIteration
        self._delivered = True
        return self.response


class InteractiveOutputTests(TestCase):
    def _resolve(self, argv: list[str]) -> tuple[Namespace, ClientCommand]:
        graph = build_command_graph(extension_loader=lambda: [])
        args = graph.parser.parse_args(argv)
        command = graph.root_command.resolve_command_from_args(args)
        self.assertIsInstance(command, ClientCommand)
        return args, cast(ClientCommand, command)

    async def _capture_command(
        self, argv: list[str], client: object
    ) -> tuple[str, str]:
        args, command = self._resolve(argv)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            await command.run_with_client(args, cast(Client, client))
        return stdout.getvalue(), stderr.getvalue()

    async def test_debugserver_start_status_and_stop_output(self) -> None:
        cases = [
            (
                "start",
                ["debugserver", "start", "com.example"],
                ["command one", "command two"],
                "command one\ncommand two\n",
                [("start", "com.example")],
            ),
            (
                "start_empty",
                ["debugserver", "start", "com.example"],
                [],
                "\n",
                [("start", "com.example")],
            ),
            (
                "status_running",
                ["debugserver", "status"],
                ["command one", "command two"],
                "command one\ncommand two\n",
                [("status", None)],
            ),
            (
                "status_stopped",
                ["debugserver", "status"],
                None,
                "Not Running\n",
                [("status", None)],
            ),
            (
                "stop",
                ["debugserver", "stop"],
                None,
                "",
                [("stop", None)],
            ),
        ]
        for name, argv, result, expected_stdout, expected_calls in cases:
            with self.subTest(name=name):
                client = _DebugClient(operation=name, result=result)
                stdout, stderr = await self._capture_command(argv, client)
                self.assertEqual(stdout, expected_stdout)
                self.assertEqual(stderr, "")
                self.assertEqual(client.calls, expected_calls)

    async def test_dap_raw_stdio_and_silent_control_output(self) -> None:
        raw_message = b"Content-Length: 4\r\n\r\n\x00A\nB"
        reader = asyncio.StreamReader()
        reader.feed_data(raw_message)
        reader.feed_eof()
        stdout_writer = _BytesWriter()
        stderr_writer = _BytesWriter()
        streams = StdStreams(
            stdin=reader,
            stdout=cast(asyncio.StreamWriter, stdout_writer),
            stderr=cast(asyncio.StreamWriter, stderr_writer),
        )
        client = _DapOutputClient()
        stop = asyncio.Event()
        args, command = self._resolve(["dap", "debug-adapter.zip"])
        text_stdout = io.StringIO()
        text_stderr = io.StringIO()
        with (
            patch(
                "idb.cli.commands.dap.get_std_as_streams",
                new=AsyncMock(return_value=streams),
            ),
            patch("idb.cli.commands.dap.signal_handler_event", return_value=stop),
            redirect_stdout(text_stdout),
            redirect_stderr(text_stderr),
        ):
            await command.run_with_client(args, cast(Client, client))

        self.assertEqual(bytes(stdout_writer.data), raw_message)
        self.assertEqual(bytes(stderr_writer.data), b"")
        self.assertEqual(text_stdout.getvalue(), "")
        self.assertEqual(text_stderr.getvalue(), "")
        self.assertIsNotNone(client.call)
        call = cast(dict[str, object], client.call)
        self.assertEqual(call["dap_path"], "debug-adapter.zip")
        self.assertIs(call["input_stream"], reader)
        self.assertIs(call["output_stream"], stdout_writer)
        self.assertIs(call["stop"], stop)
        self.assertIsNone(call["compression"])

    async def test_shell_prompt_dispatch_success_and_error_output(self) -> None:
        cases = [
            (
                "prompt",
                ["shell"],
                ["open good", "open bad", "list-targets", "exit"],
                "idb> SUCCESS=1\nidb> SUCCESS=0\nidb> idb> ",
                "boom\nshell commands must be client commands\n",
                ["good", "bad"],
            ),
            (
                "no_prompt",
                ["shell", "--no-prompt"],
                ["open good", "exit"],
                "SUCCESS=1\n",
                "",
                ["good"],
            ),
            (
                "retry_verdict_for_the_shell",
                ["--retry-verdict", "shell", "--no-prompt"],
                ["open unsafe", "exit"],
                "SUCCESS=0\n",
                "did not answer\nretry: unsafe (outcome_unknown)\n",
                ["unsafe"],
            ),
            (
                "retry_verdict_as_json_for_the_shell",
                ["--retry-verdict", "shell", "--no-prompt", "--json"],
                ["open unsafe", "exit"],
                "SUCCESS=0\n",
                'did not answer\n{"retry": "unsafe", "retry_reason": "outcome_unknown"}\n',
                ["unsafe"],
            ),
            (
                "retry_verdict_for_one_command",
                ["shell", "--no-prompt"],
                ["--retry-verdict open --json unsafe", "open unsafe", "exit"],
                "SUCCESS=0\nSUCCESS=0\n",
                'did not answer\n{"retry": "unsafe", "retry_reason": "outcome_unknown"}\n'
                "did not answer\n",
                ["unsafe", "unsafe"],
            ),
        ]
        for name, argv, lines, expected_stdout, expected_stderr, expected_urls in cases:
            with self.subTest(name=name):
                client = _ShellClient()
                inputs = iter(lines)

                def fake_input(
                    prompt: str = "", input_values: Iterator[str] = inputs
                ) -> str:
                    sys.stdout.write(prompt)
                    return next(input_values)

                args, command = self._resolve(argv)
                stdout = io.StringIO()
                stderr = io.StringIO()
                with (
                    patch("builtins.input", side_effect=fake_input),
                    redirect_stdout(stdout),
                    redirect_stderr(stderr),
                ):
                    await command.run_with_client(args, cast(Client, client))

                self.assertEqual(stdout.getvalue(), expected_stdout)
                self.assertEqual(stderr.getvalue(), expected_stderr)
                self.assertEqual(client.urls, expected_urls)

    async def test_xctest_discovery_human_and_json_output(self) -> None:
        ordered = InstalledTestInfo(
            bundle_id="com.example.Tests",
            name="ExampleTests",
            architectures=cast(set[str], ["arm64", "x86_64"]),
        )
        fallback = InstalledTestInfo(
            bundle_id="id",
            name=None,
            architectures=None,
        )
        cases = [
            (
                "bundles_human",
                ["xctest", "list"],
                _DiscoveryClient(installed=[ordered]),
                "com.example.Tests | ExampleTests | arm64, x86_64\n",
            ),
            (
                "bundles_json",
                ["xctest", "list", "--json"],
                _DiscoveryClient(installed=[ordered]),
                '{"bundle_id": "com.example.Tests", "name": "ExampleTests", "architectures": ["arm64", "x86_64"]}\n',
            ),
            (
                "bundles_fallback_human",
                ["xctest", "list"],
                _DiscoveryClient(installed=[fallback]),
                "id | no bundle name available | no archs available\n",
            ),
            (
                "bundles_fallback_json",
                ["xctest", "list", "--json"],
                _DiscoveryClient(installed=[fallback]),
                '{"bundle_id": "id", "name": null, "architectures": null}\n',
            ),
            (
                "bundles_empty",
                ["xctest", "list"],
                _DiscoveryClient(),
                "",
            ),
            (
                "tests_human",
                ["xctest", "list-bundle", "Tests"],
                _DiscoveryClient(names=["Suite/a", "Suite/b"]),
                "Suite/a\nSuite/b\n",
            ),
            (
                "tests_json",
                ["xctest", "list-bundle", "Tests", "--json"],
                _DiscoveryClient(names=["Suite/a", "Suite/b"]),
                '["Suite/a", "Suite/b"]\n',
            ),
            (
                "tests_empty_human",
                ["xctest", "list-bundle", "Tests"],
                _DiscoveryClient(),
                "\n",
            ),
            (
                "tests_empty_json",
                ["xctest", "list-bundle", "Tests", "--json"],
                _DiscoveryClient(),
                "[]\n",
            ),
        ]
        for name, argv, client, expected_stdout in cases:
            with self.subTest(name=name):
                stdout, stderr = await self._capture_command(argv, client)
                self.assertEqual(stdout, expected_stdout)
                self.assertEqual(stderr, "")

        client = _DiscoveryClient(names=["Suite/a"])
        stdout, stderr = await self._capture_command(
            ["xctest", "list-bundle", "--install", "Tests.xctest"],
            client,
        )
        self.assertEqual(stdout, "Suite/a\n")
        self.assertEqual(stderr, "")
        self.assertEqual(
            client.calls,
            [
                ("install_xctest", ("Tests.xctest", None)),
                ("list_test_bundle", ("InstalledTests", None)),
            ],
        )

    async def test_xctest_run_human_json_debugger_and_artifact_output(self) -> None:
        results = [
            (
                "human_passed",
                [],
                TestRunInfo(
                    bundle_name="Tests",
                    class_name="Suite",
                    method_name="testOne",
                    logs=["alpha", "beta"],
                    duration=1.25,
                    passed=True,
                    failure_info=None,
                    activityLogs=[],
                    crashed=False,
                ),
                "Tests - Suite/testOne | Status: passed | Duration: 1.25\n"
                "    Logs:\n"
                "        alpha\n"
                "        beta\n",
            ),
            (
                "human_failed",
                [],
                TestRunInfo(
                    bundle_name="Tests",
                    class_name="Suite",
                    method_name="testFailure",
                    logs=[],
                    duration=0.5,
                    passed=False,
                    failure_info=TestRunFailureInfo(
                        message="boom", file="Suite.m", line=17
                    ),
                    activityLogs=[],
                    crashed=False,
                ),
                "Tests - Suite/testFailure | Status: failed | Duration: 0.5 | Failure message: boom | Location Suite.m:17\n",
            ),
            (
                "json_crashed",
                ["--json"],
                TestRunInfo(
                    bundle_name="Tests",
                    class_name="Suite",
                    method_name="testCrash",
                    logs=[],
                    duration=0.25,
                    passed=False,
                    failure_info=None,
                    activityLogs=[],
                    crashed=True,
                ),
                '{"bundleName": "Tests", "className": "Suite", "methodName": "testCrash", "logs": [], "duration": 0.25, "passed": false, "crashed": true, "status": "crashed"}\n',
            ),
        ]
        for name, flags, result, expected_stdout in results:
            with self.subTest(name=name):
                client = _ResultClient(result)
                stdout, stderr = await self._capture_command(
                    ["xctest", "run", "logic", *flags, "Tests"], client
                )
                self.assertEqual(stdout, expected_stdout)
                self.assertEqual(stderr, "")
                self.assertEqual(len(client.calls), 1)

        attachment = SimpleNamespace(
            payload=b"png-bytes",
            timestamp=12.25,
            name="Screenshot",
            uniform_type_identifier="public.png",
            user_info_json=b'{"role":"failure"}',
        )
        activity = SimpleNamespace(
            title="Tap activity",
            duration=1.0,
            uuid="activity-uuid",
            activity_type="userCreated",
            start=10.0,
            finish=11.0,
            name="Tap",
            attachments=[attachment],
            sub_activities=[],
        )
        result = SimpleNamespace(
            status=0,
            bundle_name="Tests",
            class_name="Suite",
            method_name="testOne",
            duration=1.25,
            failure_info=None,
            other_failures=[],
            logs=["alpha", "beta"],
            activityLogs=[activity],
        )
        response = SimpleNamespace(
            status=0,
            results=[result],
            log_output=[],
            result_bundle=SimpleNamespace(data=b"result-bundle"),
            coverage_json="",
            log_directory=SimpleNamespace(data=b"logs"),
            debugger=SimpleNamespace(pid=4242),
            code_coverage_data=SimpleNamespace(data=b"raw-coverage"),
        )
        stream = _SingleResponseStream(response)
        grpc_client = GrpcClient.__new__(GrpcClient)
        grpc_client.stub = cast(
            CompanionServiceStub,
            SimpleNamespace(
                xctest_run=SimpleNamespace(open=MagicMock(return_value=stream))
            ),
        )
        grpc_client.logger = MagicMock()
        output = _CombinedOutput()

        with tempfile.TemporaryDirectory() as tmp_dir:
            result_bundle = os.path.join(tmp_dir, "result")
            logs = os.path.join(tmp_dir, "logs")
            coverage = os.path.join(tmp_dir, "coverage")
            activities = os.path.join(tmp_dir, "activities")
            args, command = self._resolve(
                [
                    "xctest",
                    "run",
                    "logic",
                    "--result-bundle-path",
                    result_bundle,
                    "--report-attachments",
                    "--activities-output-path",
                    activities,
                    "--coverage-output-path",
                    coverage,
                    "--coverage-format",
                    "RAW",
                    "--log-directory-path",
                    logs,
                    "--wait-for-debugger",
                    "Tests",
                ]
            )
            with (
                patch(
                    "idb.grpc.client.untar_into_path", new_callable=AsyncMock
                ) as untar,
                patch("idb.grpc.client.sys.stdout", output),
            ):
                await command.run_with_client(args, cast(Client, grpc_client))

            expected_attachment = Path(
                activities,
                "Tests - Suite - testOne",
                "12.25 - Tap - Screenshot.png",
            )
            self.assertEqual(expected_attachment.read_bytes(), b"png-bytes")
            self.assertEqual(
                [call.kwargs["description"] for call in untar.await_args_list],
                ["result bundle", "log directory", "raw code coverage directory"],
            )
            self.assertEqual(
                [call.kwargs["output_path"] for call in untar.await_args_list],
                [result_bundle, logs, coverage],
            )

        self.assertEqual(stream.ended, 1)
        self.assertTrue(stream.entered)
        self.assertTrue(stream.exited)
        self.assertEqual(
            bytes(output.data),
            (
                '{"pid": 4242}\n'
                "Tests - Suite/testOne | Status: passed | Duration: 1.25\n"
                "    Logs:\n"
                "        alpha\n"
                "        beta\n"
                "Activities\n"
                "└── Tap (1.00s)\n"
                "    └── Attachment: Screenshot\n\n"
            ).encode(),
        )

    async def test_log_writes_each_chunk_through_a_buffered_stdout(self) -> None:
        for argv in (["log"], ["companion", "log"]):
            with self.subTest(argv=argv):
                written = io.BytesIO()
                # Block-buffered, as standard output is when it is a file or a pipe.
                stdout = io.TextIOWrapper(io.BufferedWriter(written), encoding="utf-8")
                client = _ObservedLogClient(written)
                args, command = self._resolve(argv)
                with (
                    patch(
                        "idb.cli.commands.log.signal_handler_event",
                        return_value=asyncio.Event(),
                    ),
                    redirect_stdout(stdout),
                ):
                    await command.run_with_client(args, cast(Client, client))

                self.assertEqual(client.seen, [b"first\n", b"first\npartial"])

    async def test_log_ends_quietly_when_the_reader_of_stdout_exits(self) -> None:
        for argv in (["log"], ["companion", "log"]):
            for cancel_error in (None, IdbException("the companion went away")):
                with self.subTest(argv=argv, cancel_error=cancel_error):
                    read_end, write_end = os.pipe()
                    os.close(read_end)
                    # A pipe whose reader has exited, as `| head` leaves it.
                    stdout = open(write_end, "w", encoding="utf-8")
                    self.addCleanup(stdout.close)
                    client = _ObservedLogClient(io.BytesIO(), cancel_error)
                    stop = asyncio.Event()
                    args, command = self._resolve(argv)
                    with (
                        patch(
                            "idb.cli.commands.log.signal_handler_event",
                            return_value=stop,
                        ),
                        redirect_stdout(stdout),
                        nullcontext()
                        if cancel_error is None
                        else self.assertRaises(IdbException),
                    ):
                        await command.run_with_client(args, cast(Client, client))

                    self.assertTrue(stop.is_set())
                    self.assertEqual(client.yielded, ["first\n"])
                    # Standard output now leads to /dev/null, so the flush at exit
                    # of what is still buffered succeeds, even after a failed cancel.
                    stdout.write("after")
                    stdout.flush()

    async def test_log_leaves_the_loop_idle_when_another_descriptor_holds_the_broken_pipe(
        self,
    ) -> None:
        for argv in (["log"], ["companion", "log"]):
            with self.subTest(argv=argv):
                read_end, write_end = os.pipe()
                # A second write end, as stderr is after `2>&1`, keeps the pipe
                # open once standard output leads to /dev/null.
                stderr_end = os.dup(write_end)
                self.addCleanup(os.close, stderr_end)
                os.close(read_end)
                stdout = open(write_end, "w", encoding="utf-8")
                self.addCleanup(stdout.close)
                stop = asyncio.Event()
                args, command = self._resolve(argv)
                with (
                    patch(
                        "idb.cli.commands.log.signal_handler_event", return_value=stop
                    ),
                    redirect_stdout(stdout),
                ):
                    await command.run_with_client(
                        args, cast(Client, _OneLineThenQuietLogClient())
                    )

                self.assertTrue(stop.is_set())
                busy = time.process_time()
                await asyncio.sleep(0.5)
                busy = time.process_time() - busy
                self.assertLess(busy, 0.2, "the event loop spins on the closed pipe")

    async def test_log_stops_when_the_reader_of_stdout_exits_between_lines(
        self,
    ) -> None:
        for argv in (["log"], ["companion", "log"]):
            with self.subTest(argv=argv):
                read_end, write_end = os.pipe()
                stdout = open(write_end, "w", encoding="utf-8")
                self.addCleanup(stdout.close)
                stop = asyncio.Event()
                args, command = self._resolve(argv)
                with (
                    patch(
                        "idb.cli.commands.log.signal_handler_event", return_value=stop
                    ),
                    redirect_stdout(stdout),
                ):
                    streaming = asyncio.ensure_future(
                        command.run_with_client(
                            args, cast(Client, _OneLineThenQuietLogClient())
                        )
                    )
                    # The reader takes its line, as `head -1` does...
                    first = await asyncio.wait_for(
                        asyncio.to_thread(os.read, read_end, 100), timeout=10
                    )
                    self.assertEqual(first, b"first\n")
                    await asyncio.sleep(0.2)
                    self.assertFalse(streaming.done(), "stopped while read")
                    # ...and exits while the stream has nothing more to write.
                    os.close(read_end)
                    await asyncio.wait_for(streaming, timeout=10)

                self.assertTrue(stop.is_set())
                # Standard output now leads to /dev/null, so the flush at exit
                # of what is still buffered succeeds.
                stdout.write("after")
                stdout.flush()
