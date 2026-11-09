#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import logging
from argparse import Namespace
from types import ModuleType
from unittest import mock

from idb.common import plugin
from idb.common.command import Command
from idb.common.types import (
    AppScreenshotCapture,
    Client,
    CompanionInfo,
    IdbException,
    LoggingMetadata,
    Screenshot,
    ScreenshotFormat,
    ScreenshotOptions,
    ScreenshotUnit,
    TCPAddress,
)
from idb.utils.testing import TestCase


class _RecordingPlugin(ModuleType):
    def __init__(self) -> None:
        super().__init__("recording")
        self.command: Command | None = None
        self.args: Namespace | None = None

    def on_command_parsed(
        self, logger: logging.Logger, command: Command, args: Namespace
    ) -> None:
        self.command = command
        self.args = args


class _FailingPlugin(ModuleType):
    def on_command_parsed(
        self, logger: logging.Logger, command: Command, args: Namespace
    ) -> None:
        raise RuntimeError("plugin failure")


class _RejectingPlugin(ModuleType):
    def on_command_parsed(
        self, logger: logging.Logger, command: Command, args: Namespace
    ) -> None:
        raise IdbException("rejected by policy")


class _ResultObservingPlugin(ModuleType):
    def __init__(self, name: str, updates: LoggingMetadata | None) -> None:
        super().__init__(name)
        self.updates = updates
        self.observed_name: str | None = None
        self.observed_result: object | None = None
        self.observed_metadata: LoggingMetadata | None = None

    def on_invocation_result(
        self, name: str, result: object, metadata: LoggingMetadata
    ) -> LoggingMetadata | None:
        self.observed_name = name
        self.observed_result = result
        self.observed_metadata = metadata
        return self.updates


class _FailingResultPlugin(ModuleType):
    def on_invocation_result(
        self, name: str, result: object, metadata: LoggingMetadata
    ) -> LoggingMetadata:
        raise RuntimeError("plugin failure")


class _InstructingPlugin(ModuleType):
    def __init__(self, name: str, section: str) -> None:
        super().__init__(name)
        self.section = section
        self.names: list[str] | None = None

    def get_agent_instructions(self, names: list[str]) -> str:
        self.names = list(names)
        return self.section


class _FailingInstructionsPlugin(ModuleType):
    def get_agent_instructions(self, names: list[str]) -> str:
        raise RuntimeError("instructions failure")


class GetAgentInstructionsTest(TestCase):
    def test_contributions_join_in_plugin_order(self) -> None:
        first = _InstructingPlugin("first", "first section")
        second = _InstructingPlugin("second", "second section")
        with mock.patch.object(plugin, "PLUGINS", [first, second]):
            joined = plugin.get_agent_instructions(names=["agent"])
        self.assertEqual(joined, "first section\nsecond section")
        self.assertEqual(first.names, ["agent"])
        self.assertEqual(second.names, ["agent"])

    def test_plugin_failure_is_swallowed_and_later_plugins_contribute(self) -> None:
        failing = _FailingInstructionsPlugin("failing")
        contributing = _InstructingPlugin("contributing", "still here")
        with mock.patch.object(plugin, "PLUGINS", [failing, contributing]):
            self.assertEqual(
                plugin.get_agent_instructions(names=["agent"]), "still here"
            )

    def test_empty_contributions_are_skipped(self) -> None:
        silent = _InstructingPlugin("silent", "")
        with mock.patch.object(plugin, "PLUGINS", [silent]):
            self.assertEqual(plugin.get_agent_instructions(names=["agent"]), "")

    def test_no_plugins_yield_empty_instructions(self) -> None:
        with mock.patch.object(plugin, "PLUGINS", []):
            self.assertEqual(plugin.get_agent_instructions(names=["agent"]), "")


class _AppCapturePlugin(ModuleType):
    def __init__(self, result: object, error: BaseException | None = None) -> None:
        super().__init__("app_capture")
        self.result = result
        self.error = error
        self.calls: list[tuple[Client, str, ScreenshotOptions]] = []

    async def capture_app_screenshot(
        self, client: Client, bundle_id: str, options: ScreenshotOptions
    ) -> object:
        self.calls.append((client, bundle_id, options))
        if self.error is not None:
            raise self.error
        return self.result


class AppScreenshotPluginTest(TestCase):
    def setUp(self) -> None:
        self.client = mock.Mock(spec=Client)
        self.client.companion = CompanionInfo(
            "target-1", True, None, TCPAddress("localhost", 1)
        )
        self.image = Screenshot(
            b"\x89PNG\r\n\x1a\nimage",
            app_capture=AppScreenshotCapture("nonce-1", "target-1", "com.example.app"),
        )

    async def test_app_capture_returns_the_first_provider_result_without_telemetry(
        self,
    ) -> None:
        first = _AppCapturePlugin(self.image)
        later = _AppCapturePlugin(self.image)
        with (
            mock.patch.object(
                plugin, "PLUGINS", [ModuleType("unrelated"), first, later]
            ),
            mock.patch.object(plugin, "on_invocation_result") as observe,
        ):
            result = await plugin.capture_app_screenshot(
                self.client, "com.example.app", ScreenshotOptions()
            )
        self.assertIs(result, self.image)
        self.assertEqual(
            first.calls, [(self.client, "com.example.app", ScreenshotOptions())]
        )
        self.assertEqual(later.calls, [])
        observe.assert_not_called()

    async def test_an_absent_provider_is_unsupported_not_a_target_capture(self) -> None:
        with mock.patch.object(plugin, "PLUGINS", [ModuleType("unrelated")]):
            with self.assertRaisesRegex(IdbException, "unsupported"):
                await plugin.capture_app_screenshot(
                    self.client, "com.example.app", ScreenshotOptions()
                )
        self.client.screenshot.assert_not_called()

    async def test_provider_failures_and_cancellation_never_try_a_second_provider(
        self,
    ) -> None:
        for error in (
            IdbException("refused"),
            RuntimeError("broken"),
            asyncio.CancelledError(),
        ):
            first = _AppCapturePlugin(self.image, error)
            later = _AppCapturePlugin(self.image)
            with mock.patch.object(plugin, "PLUGINS", [first, later]):
                with self.assertRaises(type(error)) as raised:
                    await plugin.capture_app_screenshot(
                        self.client, "com.example.app", ScreenshotOptions()
                    )
            self.assertIs(raised.exception, error)
            self.assertEqual(len(first.calls), 1)
            self.assertEqual(later.calls, [])
            self.client.screenshot.assert_not_called()

    async def test_invalid_bundle_options_and_companion_fail_before_provider(
        self,
    ) -> None:
        provider = _AppCapturePlugin(self.image)
        with mock.patch.object(plugin, "PLUGINS", [provider]):
            for bundle_id in (
                "",
                " ",
                "--flag",
                ".",
                "com.app/path",
                "com.app\n",
                "é.app",
                "a" * 257,
            ):
                with self.subTest(bundle_id=bundle_id), self.assertRaises(IdbException):
                    await plugin.capture_app_screenshot(
                        self.client, bundle_id, ScreenshotOptions()
                    )
            for options in (
                ScreenshotOptions(format=ScreenshotFormat.JPEG),
                ScreenshotOptions(format=ScreenshotFormat.TIFF),
                ScreenshotOptions(compression_quality=1),
                ScreenshotOptions(scale_factor=1),
                ScreenshotOptions(max_width=100),
                ScreenshotOptions(unit=ScreenshotUnit.POINTS),
            ):
                with self.subTest(options=options), self.assertRaises(IdbException):
                    await plugin.capture_app_screenshot(
                        self.client, "com.example.app", options
                    )
            self.client.companion = None
            with self.assertRaises(IdbException):
                await plugin.capture_app_screenshot(
                    self.client, "com.example.app", ScreenshotOptions()
                )
        self.assertEqual(provider.calls, [])
        self.client.screenshot.assert_not_called()

    async def test_invalid_provider_results_cannot_be_reported_as_app_captures(
        self,
    ) -> None:
        markers = (
            None,
            AppScreenshotCapture("nonce", "other", "com.example.app"),
            AppScreenshotCapture("nonce", "target-1", "com.other"),
            AppScreenshotCapture(" ", "target-1", "com.example.app"),
            AppScreenshotCapture("x" * 257, "target-1", "com.example.app"),
        )
        results = [
            None,
            b"not a Screenshot",
            Screenshot(b"not PNG", app_capture=self.image.app_capture),
            Screenshot(
                bytes(self.image),
                format=ScreenshotFormat.JPEG,
                app_capture=self.image.app_capture,
            ),
        ]
        results.extend(
            Screenshot(bytes(self.image), app_capture=marker) for marker in markers
        )
        for result in results:
            first = _AppCapturePlugin(result)
            later = _AppCapturePlugin(self.image)
            with (
                mock.patch.object(plugin, "PLUGINS", [first, later]),
                self.assertRaises(IdbException),
            ):
                await plugin.capture_app_screenshot(
                    self.client, "com.example.app", ScreenshotOptions()
                )
            self.assertEqual(later.calls, [])
        self.client.screenshot.assert_not_called()


class PluginDispatchTest(TestCase):
    def test_rejection_propagates(self) -> None:
        rejecting = _RejectingPlugin("rejecting")
        with mock.patch.object(plugin, "PLUGINS", [rejecting]):
            with self.assertRaises(IdbException):
                plugin.on_command_parsed(
                    logger=logging.getLogger("test"),
                    command=mock.MagicMock(spec=Command),
                    args=Namespace(),
                )

    def test_rejection_short_circuits_later_plugins(self) -> None:
        rejecting = _RejectingPlugin("rejecting")
        recording = _RecordingPlugin()
        with mock.patch.object(plugin, "PLUGINS", [rejecting, recording]):
            with self.assertRaises(IdbException):
                plugin.on_command_parsed(
                    logger=logging.getLogger("test"),
                    command=mock.MagicMock(spec=Command),
                    args=Namespace(),
                )
        self.assertIsNone(recording.command)

    def test_plugin_failure_is_swallowed_and_later_plugins_run(self) -> None:
        failing = _FailingPlugin("failing")
        recording = _RecordingPlugin()
        command = mock.MagicMock(spec=Command)
        args = Namespace()
        test_logger = logging.getLogger("test")
        with (
            mock.patch.object(plugin, "PLUGINS", [failing, recording]),
            mock.patch.object(test_logger, "exception") as log_exception,
        ):
            plugin.on_command_parsed(logger=test_logger, command=command, args=args)
        self.assertIs(recording.command, command)
        self.assertIs(recording.args, args)
        log_exception.assert_called_once()


class OnInvocationResultTest(TestCase):
    def test_invocation_context_is_forwarded_to_plugins(self) -> None:
        observing = _ResultObservingPlugin("observing", updates=None)
        result = object()
        metadata: LoggingMetadata = {"grpc_method_name": "accessibility_info"}
        with mock.patch.object(plugin, "PLUGINS", [observing]):
            plugin.on_invocation_result(
                name="accessibility_info", result=result, metadata=metadata
            )
        self.assertEqual(observing.observed_name, "accessibility_info")
        self.assertIs(observing.observed_result, result)
        self.assertIs(observing.observed_metadata, metadata)

    def test_updates_from_plugins_are_merged_with_later_plugins_winning(self) -> None:
        first = _ResultObservingPlugin("first", updates={"col": "1", "only": "first"})
        second = _ResultObservingPlugin("second", updates={"col": "2"})
        with mock.patch.object(plugin, "PLUGINS", [first, second]):
            updates = plugin.on_invocation_result(
                name="invocation", result=object(), metadata={}
            )
        self.assertEqual(updates, {"col": "2", "only": "first"})

    def test_plugin_returning_none_contributes_nothing(self) -> None:
        observing = _ResultObservingPlugin("observing", updates=None)
        with mock.patch.object(plugin, "PLUGINS", [observing]):
            updates = plugin.on_invocation_result(
                name="invocation", result=object(), metadata={}
            )
        self.assertEqual(updates, {})

    def test_plugin_without_hook_is_skipped(self) -> None:
        with mock.patch.object(plugin, "PLUGINS", [_RecordingPlugin()]):
            updates = plugin.on_invocation_result(
                name="invocation", result=object(), metadata={}
            )
        self.assertEqual(updates, {})

    def test_plugin_failure_is_swallowed_and_later_plugins_run(self) -> None:
        failing = _FailingResultPlugin("failing")
        observing = _ResultObservingPlugin("observing", updates={"col": "value"})
        with (
            mock.patch.object(plugin, "PLUGINS", [failing, observing]),
            mock.patch.object(plugin.logger, "exception") as log_exception,
        ):
            updates = plugin.on_invocation_result(
                name="invocation", result=object(), metadata={}
            )
        self.assertEqual(updates, {"col": "value"})
        log_exception.assert_called_once()


class _CompanionObservingPlugin(ModuleType):
    def __init__(self) -> None:
        super().__init__("companion_observing")
        self.companions: list[CompanionInfo] = []

    def on_companion_connected(
        self, logger: logging.Logger, companion: CompanionInfo
    ) -> None:
        self.companions.append(companion)


class _FailingCompanionPlugin(ModuleType):
    def on_companion_connected(
        self, logger: logging.Logger, companion: CompanionInfo
    ) -> None:
        raise RuntimeError("boom")


class _FailingCompanionInstance:
    def on_companion_connected(
        self, logger: logging.Logger, companion: CompanionInfo
    ) -> None:
        raise RuntimeError("boom")


class OnCompanionConnectedTest(TestCase):
    def test_connected_companion_is_forwarded_past_failing_plugins(self) -> None:
        companion = CompanionInfo(
            udid="target-1",
            is_local=True,
            pid=None,
            address=TCPAddress(host="localhost", port=10882),
        )
        test_logger = logging.getLogger("test")
        for failing in (
            _FailingCompanionPlugin("failing"),
            _FailingCompanionInstance(),
        ):
            with self.subTest(plugin_type=type(failing).__name__):
                observing = _CompanionObservingPlugin()
                with (
                    mock.patch.object(
                        plugin,
                        "PLUGINS",
                        [failing, ModuleType("silent"), observing],
                    ),
                    mock.patch.object(test_logger, "exception") as log_exception,
                ):
                    plugin.on_companion_connected(
                        logger=test_logger, companion=companion
                    )

                self.assertEqual([companion], observing.companions)
                self.assertIs(companion, observing.companions[0])
                log_exception.assert_called_once_with(
                    "on_companion_connected plugin failed, swallowing exception"
                )
