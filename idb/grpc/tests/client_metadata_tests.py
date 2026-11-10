#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import logging
from unittest import mock

from idb.common import plugin
from idb.common.types import CompanionInfo, TCPAddress
from idb.grpc import client as client_module
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import (
    CompanionInfo as GrpcCompanionInfo,
    ConnectResponse,
    ScreenshotResponse,
    TargetDescription,
    TargetDescriptionResponse,
)
from idb.utils.testing import TestCase


class ClientMetadataTest(TestCase):
    def test_client_resolves_scoped_invocation_metadata(self) -> None:
        client = Client(
            stub=mock.MagicMock(),
            companion=mock.MagicMock(),
            logger=logging.getLogger("test"),
        )

        with plugin.scoped_invocation_metadata({"capture": "capture-1"}):
            self.assertEqual("capture-1", client.metadata.get("capture"))

        self.assertNotIn("capture", client.metadata)

    async def test_screenshot_context_needs_both_peer_capability_and_plugin_optin(
        self,
    ) -> None:
        for supported, enabled in ((False, True), (True, False), (True, True)):
            stub = mock.MagicMock()
            stub.screenshot = mock.AsyncMock(
                return_value=ScreenshotResponse(image_data=b"image", image_format="png")
            )
            client = Client(
                stub,
                CompanionInfo(
                    "target-1",
                    True,
                    None,
                    TCPAddress("localhost", 1),
                    screenshot_app_context=supported,
                ),
                logging.getLogger("test"),
            )
            with mock.patch.object(
                plugin, "should_collect_screenshot_context", return_value=enabled
            ):
                image = await client.screenshot()
            self.assertEqual(
                supported and enabled,
                stub.screenshot.call_args.args[0].include_app_context,
            )
            self.assertEqual(b"image", image)
            self.assertIsNone(image.app_context)
            stub.describe = mock.AsyncMock(
                return_value=TargetDescriptionResponse(
                    target_description=TargetDescription(
                        udid="target-1", target_type="simulator"
                    )
                )
            )
            described = await client.describe()
            assert described.companion_info is not None
            self.assertEqual(supported, described.companion_info.screenshot_app_context)

    async def test_build_reports_the_handshake_companion_to_plugins(self) -> None:
        stub = mock.MagicMock()
        stub.connect = mock.AsyncMock(
            return_value=ConnectResponse(
                companion=GrpcCompanionInfo(udid="target-1", is_local=True)
            )
        )
        channel = mock.MagicMock()
        channel.__aenter__ = mock.AsyncMock(return_value=channel)
        channel.__aexit__ = mock.AsyncMock(return_value=None)
        address = TCPAddress(host="localhost", port=10882)
        with (
            mock.patch.object(client_module, "Channel", return_value=channel),
            mock.patch.object(client_module, "CompanionServiceStub", return_value=stub),
            mock.patch.object(plugin, "on_companion_connected") as connected,
        ):
            async with Client.build(
                address=address,
                logger=logging.getLogger("test"),
                exchange_metadata=False,
            ) as client:
                pass

        connected.assert_called_once()
        reported = connected.call_args.kwargs["companion"]
        self.assertEqual("target-1", reported.udid)
        self.assertIs(client.companion, reported)
