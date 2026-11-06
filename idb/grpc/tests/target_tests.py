#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
import unittest
from unittest.mock import AsyncMock, MagicMock

from idb.common.format import json_data_target_info, target_description_from_dictionary
from idb.common.types import (
    CompanionInfo,
    Compression,
    TargetDescription,
    TargetType,
    TCPAddress,
)
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import (
    CompanionInfo as GrpcCompanionInfo,
    FocusRequest,
    Payload,
    TargetDescription as GrpcTargetDescription,
    TargetDescriptionResponse,
)
from idb.grpc.target import companion_to_py, merge_connected_targets, target_to_py
from idb.utils.testing import TestCase


class TargetTests(unittest.TestCase):
    def test_merge_connected_targets(self) -> None:
        merged_targets = merge_connected_targets(
            local_targets=[
                TargetDescription(
                    udid="a",
                    name="aa",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=None,
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="b",
                    name="bb",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=None,
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="c",
                    name="cc",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=None,
                    screen_dimensions=None,
                ),
            ],
            connected_targets=[
                TargetDescription(
                    udid="a",
                    name="aa",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=CompanionInfo(
                        udid="a",
                        address=TCPAddress(host="remotehost", port=1),
                        is_local=False,
                        pid=None,
                    ),
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="d",
                    name="dd",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=CompanionInfo(
                        udid="d",
                        address=TCPAddress(host="remotehost", port=2),
                        is_local=False,
                        pid=None,
                    ),
                    screen_dimensions=None,
                ),
            ],
        )
        self.assertEqual(
            merged_targets,
            [
                TargetDescription(
                    udid="a",
                    name="aa",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=CompanionInfo(
                        udid="a",
                        address=TCPAddress(host="remotehost", port=1),
                        is_local=False,
                        pid=None,
                    ),
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="b",
                    name="bb",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=None,
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="c",
                    name="cc",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=None,
                    screen_dimensions=None,
                ),
                TargetDescription(
                    udid="d",
                    name="dd",
                    state=None,
                    target_type=TargetType.SIMULATOR,
                    os_version=None,
                    architecture=None,
                    companion_info=CompanionInfo(
                        udid="d",
                        address=TCPAddress(host="remotehost", port=2),
                        is_local=False,
                        pid=None,
                    ),
                    screen_dimensions=None,
                ),
            ],
        )


_DEVICE = {"DeviceClass": "iPhone", "ProductType": "iPhone14,7"}
_REMOTE_COMPANION = CompanionInfo(
    udid="a",
    address=TCPAddress(host="127.0.0.1", port=35511),
    is_local=False,
    pid=None,
)


def _described_device(extended: bytes) -> GrpcTargetDescription:
    return GrpcTargetDescription(
        udid="a",
        name="PDX640610705",
        state="Booted",
        target_type="device",
        os_version="iOS 26.2",
        extended=extended,
    )


class TargetToPyTests(unittest.TestCase):
    def test_sets_device_from_extended(self) -> None:
        extended = {"device": _DEVICE, "other": "value"}
        target = target_to_py(
            target=_described_device(json.dumps(extended).encode()),
            companion=_REMOTE_COMPANION,
            metadata=b"",
        )
        self.assertEqual(target.device, _DEVICE)
        self.assertEqual(json.loads(target.as_json)["device"], _DEVICE)
        self.assertEqual(target.extended, extended)

    def test_leaves_device_unset_without_extended_device(self) -> None:
        for extended in [b"", b"{}", b'{"other": "value"}', b"[]", b'{"device": null}']:
            with self.subTest(extended=extended):
                target = target_to_py(
                    target=_described_device(extended),
                    companion=_REMOTE_COMPANION,
                    metadata=b"",
                )
                self.assertIsNone(target.device)
                self.assertIsNone(json.loads(target.as_json)["device"])
                self.assertNotIn("device", json_data_target_info(target))

    def test_json_target_info_includes_device_for_tcp_companion(self) -> None:
        target = target_to_py(
            target=_described_device(json.dumps({"device": _DEVICE}).encode()),
            companion=_REMOTE_COMPANION,
            metadata=b"",
        )
        data = json_data_target_info(target)
        self.assertEqual(data["device"], _DEVICE)
        self.assertEqual(data["companion"], "127.0.0.1:35511")
        self.assertFalse(data["is_local"])

    def test_merged_local_device_keeps_connected_device_details_in_json(self) -> None:
        local = target_description_from_dictionary(
            {"udid": "a", "name": "local device", "type": "device", "device": _DEVICE}
        )
        connected = target_to_py(
            target=_described_device(json.dumps({"device": _DEVICE}).encode()),
            companion=_REMOTE_COMPANION,
            metadata=b"",
        )
        merged = merge_connected_targets(
            local_targets=[local], connected_targets=[connected]
        )
        self.assertEqual(merged, [connected])
        self.assertEqual(json.loads(merged[0].as_json)["device"], _DEVICE)
        data = json_data_target_info(merged[0])
        self.assertEqual(data["device"], _DEVICE)
        self.assertEqual(data["companion"], "127.0.0.1:35511")
        self.assertFalse(data["is_local"])


class CompanionToPyTests(unittest.TestCase):
    def test_maps_supported_compressions(self) -> None:
        companion = companion_to_py(
            companion=GrpcCompanionInfo(
                udid="a", supported_compressions=[Payload.GZIP, Payload.ZSTD]
            ),
            address=TCPAddress(host="localhost", port=1),
        )
        self.assertEqual(
            companion.supported_compressions,
            frozenset({Compression.GZIP, Compression.ZSTD}),
        )

    def test_maps_zstd_zip_streams(self) -> None:
        address = TCPAddress(host="localhost", port=1)
        self.assertTrue(
            companion_to_py(
                companion=GrpcCompanionInfo(udid="a", zstd_zip_streams=True),
                address=address,
            ).zstd_zip_streams
        )
        self.assertFalse(
            companion_to_py(
                companion=GrpcCompanionInfo(udid="a"), address=address
            ).zstd_zip_streams
        )

    def test_maps_install_connect_to(self) -> None:
        address = TCPAddress(host="localhost", port=1)
        self.assertTrue(
            companion_to_py(
                companion=GrpcCompanionInfo(udid="a", install_connect_to=True),
                address=address,
            ).install_connect_to
        )
        self.assertFalse(
            companion_to_py(
                companion=GrpcCompanionInfo(udid="a"), address=address
            ).install_connect_to
        )

    def test_maps_notification_service_extension_capability(self) -> None:
        address = TCPAddress(host="localhost", port=1)
        self.assertFalse(
            companion_to_py(
                companion=GrpcCompanionInfo(udid="a"), address=address
            ).supports_notification_service_extension
        )
        self.assertTrue(
            companion_to_py(
                companion=GrpcCompanionInfo(
                    udid="a", supports_notification_service_extension=True
                ),
                address=address,
            ).supports_notification_service_extension
        )

    def test_omits_unknown_compressions(self) -> None:
        companion = companion_to_py(
            companion=GrpcCompanionInfo(udid="a", supported_compressions=[99]),
            address=TCPAddress(host="localhost", port=1),
        )
        self.assertEqual(companion.supported_compressions, frozenset())


class FocusTests(TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.stub.focus = AsyncMock()

    async def test_focus_sends_one_unary_request(self) -> None:
        await self.client.focus()

        self.client.stub.focus.assert_awaited_once_with(FocusRequest())


class DescribeTests(TestCase):
    async def test_reports_whether_the_companion_takes_zstd_zip_streams(
        self,
    ) -> None:
        for advertised in (True, False):
            with self.subTest(advertised=advertised):
                client = Client.__new__(Client)
                client.logger = MagicMock()
                client.stub = MagicMock()
                client.stub.describe = AsyncMock(
                    return_value=TargetDescriptionResponse(
                        target_description=GrpcTargetDescription(
                            udid="a", target_type="simulator"
                        ),
                    )
                )
                client.companion = CompanionInfo(
                    udid="a",
                    is_local=False,
                    pid=None,
                    address=TCPAddress(host="localhost", port=1),
                    zstd_zip_streams=advertised,
                )

                description = await client.describe()

                self.assertEqual(
                    json.loads(description.as_json)["companion_info"][
                        "zstd_zip_streams"
                    ],
                    advertised,
                )

    async def test_reports_whether_the_companion_takes_install_connect_to(
        self,
    ) -> None:
        for advertised in (True, False):
            with self.subTest(advertised=advertised):
                client = Client.__new__(Client)
                client.logger = MagicMock()
                client.stub = MagicMock()
                client.stub.describe = AsyncMock(
                    return_value=TargetDescriptionResponse(
                        target_description=GrpcTargetDescription(
                            udid="a", target_type="simulator"
                        ),
                    )
                )
                client.companion = CompanionInfo(
                    udid="a",
                    is_local=False,
                    pid=None,
                    address=TCPAddress(host="localhost", port=1),
                    install_connect_to=advertised,
                    supports_notification_service_extension=advertised,
                )

                description = await client.describe()

                companion_info = description.companion_info
                assert companion_info is not None
                self.assertEqual(companion_info.install_connect_to, advertised)
                self.assertEqual(
                    companion_info.supports_notification_service_extension, advertised
                )
                self.assertEqual(
                    json.loads(description.as_json)["companion_info"][
                        "supports_notification_service_extension"
                    ],
                    advertised,
                )
                self.assertEqual(
                    json.loads(description.as_json)["companion_info"][
                        "install_connect_to"
                    ],
                    advertised,
                )
