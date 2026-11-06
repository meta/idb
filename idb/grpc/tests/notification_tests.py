#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from itertools import product
from unittest.mock import AsyncMock, MagicMock

from idb.common.types import CompanionInfo, IdbException, TCPAddress
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import SendNotificationRequest
from idb.utils.testing import TestCase


def _client(supported: bool = False) -> tuple[Client, MagicMock]:
    stub = MagicMock()
    stub.send_notification = AsyncMock()
    return Client(
        stub=stub,
        logger=MagicMock(),
        companion=CompanionInfo(
            udid="a",
            is_local=False,
            pid=None,
            address=TCPAddress(host="localhost", port=1),
            supports_notification_service_extension=supported,
        ),
    ), stub


class NotificationTest(TestCase):
    async def test_service_extension_is_negotiated_before_sending(self) -> None:
        cases = [
            ("opaque payload", "opaque payload", False),
            (
                '{"idb-service-extension":true,"aps":{"alert":"Hello"}}',
                '{"aps": {"alert": "Hello"}}',
                True,
            ),
            (
                '{"idb-service-extension":false,"aps":{"alert":"Hello"}}',
                '{"aps": {"alert": "Hello"}}',
                False,
            ),
            *[
                (f'{{"idb-service-extension":{value}}}', None, False)
                for value in ("1", "0", "null", '"true"', "[]", "{}")
            ],
        ]
        for supported, explicit, (payload, cleaned, marker) in product(
            (False, True), (False, True), cases
        ):
            with self.subTest(supported=supported, explicit=explicit, payload=payload):
                client, stub = _client(supported)
                requested = explicit or marker
                if cleaned is None or (requested and not supported):
                    message = (
                        "must be a boolean"
                        if cleaned is None
                        else "does not support notification service extension delivery"
                    )
                    with self.assertRaisesRegex(IdbException, message):
                        await client.send_notification(
                            "app", payload, process_service_extension=explicit
                        )
                    stub.send_notification.assert_not_awaited()
                else:
                    await client.send_notification(
                        "app", payload, process_service_extension=explicit
                    )
                    stub.send_notification.assert_awaited_once_with(
                        SendNotificationRequest(
                            bundle_id="app",
                            json_payload=cleaned,
                            process_service_extension=requested,
                        )
                    )

    async def test_default_request_preserves_the_ordinary_wire_bytes(self) -> None:
        for payload in (
            "payload",
            "not JSON",
            ' { "aps" : { "alert" : "Hello" } } ',
            '{"nested":{"idb-service-extension":true}}',
            '{"aps":{"alert":"idb-service-extension"}}',
        ):
            with self.subTest(payload=payload):
                client, stub = _client()
                await client.send_notification("app", payload)
                request = stub.send_notification.call_args.args[0]
                self.assertFalse(request.process_service_extension)
                self.assertEqual(request.json_payload, payload)
                self.assertEqual(
                    request.SerializeToString(),
                    SendNotificationRequest(
                        bundle_id="app", json_payload=payload
                    ).SerializeToString(),
                )
        self.assertEqual(
            SendNotificationRequest(
                bundle_id="app", json_payload="payload"
            ).SerializeToString(),
            b"\x0a\x03app\x12\x07payload",
        )
