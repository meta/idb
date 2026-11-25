#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from unittest.mock import AsyncMock, MagicMock

from grpclib.const import Status
from grpclib.exceptions import GRPCError
from idb.common.types import (
    AccessibilityBackend,
    AccessibilityClientType,
    AccessibilityDragOptions,
    AccessibilityElementFilter,
    AccessibilityInfoOptions,
    AccessibilityMarker,
    AccessibilityOutputFormat,
    AccessibilityPoint,
    AccessibilityScrollDirection,
    AccessibilitySearchableKey,
    AccessibilitySearchDiagnostics,
    AccessibilityWaitResult,
    Client as BaseClient,
    IdbException,
)
from idb.grpc.accessibility import accessibility_info_to_grpc
from idb.grpc.client import Client
from idb.grpc.idb_pb2 import (
    AccessibilityActionRequest,
    AccessibilityActionResponse,
    AccessibilityInfoRequest,
    Point,
)
from idb.utils.testing import TestCase


class AccessibilityInfoRequestTests(TestCase):
    # The historical request

    def test_default_options_are_a_legacy_whole_app_read(self) -> None:
        # Every new field is its zero value, so a caller who asks for nothing
        # sends what idb sent before any of them existed.
        self.assertEqual(
            accessibility_info_to_grpc(None, AccessibilityInfoOptions()),
            AccessibilityInfoRequest(),
        )

    def test_nested_flag_and_nested_format_agree(self) -> None:
        self.assertEqual(
            accessibility_info_to_grpc(None, AccessibilityInfoOptions(nested=True)),
            accessibility_info_to_grpc(
                None,
                AccessibilityInfoOptions(format=AccessibilityOutputFormat.NESTED),
            ),
        )

    def test_format_wins_over_the_deprecated_nested_flag(self) -> None:
        request = accessibility_info_to_grpc(
            None,
            AccessibilityInfoOptions(
                nested=True, format=AccessibilityOutputFormat.COMPLETE
            ),
        )
        self.assertEqual(request.format, AccessibilityInfoRequest.COMPLETE)

    # Targets

    def test_marker_target(self) -> None:
        request = accessibility_info_to_grpc(
            AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.UNIQUE_ID,
                depth=4,
            ),
            AccessibilityInfoOptions(),
        )
        self.assertEqual(request.marker, "Login")
        self.assertEqual(request.match_key, AccessibilitySearchableKey.UNIQUE_ID.value)
        self.assertEqual(request.depth, 4)
        self.assertEqual(request.match, "")

    def test_marker_target_carries_the_read_options(self) -> None:
        # A marker read is a read: the keys and the enrichers travel with it,
        # not only with a whole-app read.
        request = accessibility_info_to_grpc(
            AccessibilityMarker(
                value="Login",
                match_key=AccessibilitySearchableKey.LABEL,
                depth=10,
            ),
            AccessibilityInfoOptions(
                keys=["AXLabel", "frame"],
                profile=True,
                collect_frame_coverage=True,
                ignore_case=True,
            ),
        )
        self.assertEqual(list(request.keys), ["AXLabel", "frame"])
        self.assertTrue(request.profile)
        self.assertTrue(request.collect_frame_coverage)
        self.assertTrue(request.ignore_case)

    def test_point_target(self) -> None:
        request = accessibility_info_to_grpc(
            AccessibilityPoint(x=10, y=20), AccessibilityInfoOptions()
        )
        self.assertEqual(request.point.x, 10)
        self.assertEqual(request.point.y, 20)
        self.assertEqual(request.marker, "")

    # Match

    def test_match_sets_the_substring_and_its_key(self) -> None:
        request = accessibility_info_to_grpc(
            None,
            AccessibilityInfoOptions(
                match="Cart", match_key=AccessibilitySearchableKey.VALUE
            ),
        )
        self.assertEqual(request.match, "Cart")
        self.assertEqual(request.match_key, AccessibilitySearchableKey.VALUE.value)
        self.assertEqual(request.marker, "")

    def test_match_defaults_to_the_label(self) -> None:
        request = accessibility_info_to_grpc(
            None, AccessibilityInfoOptions(match="Cart")
        )
        self.assertEqual(request.match_key, AccessibilitySearchableKey.LABEL.value)

    def test_empty_match_is_no_match(self) -> None:
        # An empty substring is contained in everything, so treating it as a
        # match would send a predicate that keeps every element while looking
        # like a narrowing.
        request = accessibility_info_to_grpc(None, AccessibilityInfoOptions(match=""))
        self.assertEqual(request, AccessibilityInfoRequest())

    def test_match_with_a_marker_is_refused(self) -> None:
        with self.assertRaises(IdbException):
            accessibility_info_to_grpc(
                AccessibilityMarker(
                    value="Login",
                    match_key=AccessibilitySearchableKey.LABEL,
                    depth=10,
                ),
                AccessibilityInfoOptions(match="Cart"),
            )

    def test_match_with_a_point_is_refused(self) -> None:
        with self.assertRaises(IdbException):
            accessibility_info_to_grpc(
                AccessibilityPoint(x=1, y=2),
                AccessibilityInfoOptions(match="Cart"),
            )

    def test_ignore_case_is_independent_of_the_match(self) -> None:
        # --ignore-case also governs marker resolution on a read, so it is set
        # whether or not a match is present.
        request = accessibility_info_to_grpc(
            None, AccessibilityInfoOptions(ignore_case=True)
        )
        self.assertTrue(request.ignore_case)

    # Filter and backend

    def test_every_filter_maps(self) -> None:
        for element_filter, expected in [
            (AccessibilityElementFilter.ALL, AccessibilityInfoRequest.FILTER_ALL),
            (
                AccessibilityElementFilter.INTERACTABLE,
                AccessibilityInfoRequest.FILTER_INTERACTABLE,
            ),
        ]:
            request = accessibility_info_to_grpc(
                None, AccessibilityInfoOptions(filter=element_filter)
            )
            self.assertEqual(request.filter, expected)

    def test_unset_filter_is_the_wire_default(self) -> None:
        request = accessibility_info_to_grpc(None, AccessibilityInfoOptions())
        self.assertEqual(request.filter, AccessibilityInfoRequest.FILTER_ALL)

    def test_every_client_type_maps(self) -> None:
        for client_type in AccessibilityClientType:
            request = accessibility_info_to_grpc(
                None, AccessibilityInfoOptions(client_type=client_type)
            )
            self.assertEqual(
                request.client_type,
                getattr(AccessibilityInfoRequest, f"CLIENT_TYPE_{client_type.name}"),
            )

    def test_unset_client_type_is_the_wire_default(self) -> None:
        request = accessibility_info_to_grpc(None, AccessibilityInfoOptions())
        self.assertEqual(
            request.client_type, AccessibilityInfoRequest.CLIENT_TYPE_UNSPECIFIED
        )

    def test_filter_and_match_compose(self) -> None:
        request = accessibility_info_to_grpc(
            None,
            AccessibilityInfoOptions(
                match="Cart",
                filter=AccessibilityElementFilter.INTERACTABLE,
                backend=AccessibilityBackend.AXBRIDGE,
            ),
        )
        self.assertEqual(request.match, "Cart")
        self.assertEqual(request.filter, AccessibilityInfoRequest.FILTER_INTERACTABLE)
        self.assertEqual(request.backend, AccessibilityInfoRequest.AXBRIDGE)


class AccessibilityActionTests(TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.stub.accessibility_action = AsyncMock()

    async def test_every_action_request_maps_exactly(self) -> None:
        cases = [
            (
                "tap",
                lambda: self.client.accessibility_tap(
                    AccessibilityMarker(
                        "Tap",
                        AccessibilitySearchableKey.UNIQUE_ID,
                        3,
                    ),
                    expected_value="selected",
                    expected_key=AccessibilitySearchableKey.VALUE,
                    ignore_case=True,
                ),
                AccessibilityActionRequest(
                    marker="Tap",
                    match_key=AccessibilitySearchableKey.UNIQUE_ID.value,
                    depth=3,
                    ignore_case=True,
                    tap=AccessibilityActionRequest.Tap(
                        check_expected_value=True,
                        expected_value="selected",
                        expected_key=AccessibilitySearchableKey.VALUE.value,
                    ),
                ),
            ),
            (
                "scroll",
                lambda: self.client.accessibility_scroll(
                    None,
                    AccessibilityScrollDirection.RIGHT,
                    ignore_case=True,
                ),
                AccessibilityActionRequest(
                    ignore_case=True,
                    scroll=AccessibilityActionRequest.Scroll(
                        direction=AccessibilityScrollDirection.RIGHT.value,
                    ),
                ),
            ),
            (
                "set_value",
                lambda: self.client.accessibility_set_value(
                    AccessibilityMarker(
                        "Field",
                        AccessibilitySearchableKey.VALUE,
                        6,
                    ),
                    "replacement",
                    ignore_case=True,
                ),
                AccessibilityActionRequest(
                    marker="Field",
                    match_key=AccessibilitySearchableKey.VALUE.value,
                    depth=6,
                    ignore_case=True,
                    set_value=AccessibilityActionRequest.SetValue(
                        value="replacement",
                    ),
                ),
            ),
            (
                "drag",
                lambda: self.client.accessibility_drag(
                    AccessibilityPoint(1, 2),
                    AccessibilityMarker(
                        "Destination",
                        AccessibilitySearchableKey.TITLE,
                        7,
                    ),
                    AccessibilityDragOptions(
                        press_duration=0.25,
                        duration=0.5,
                        release_duration=0.75,
                        delta=4.0,
                    ),
                    ignore_case=True,
                ),
                AccessibilityActionRequest(
                    point=Point(x=1, y=2),
                    ignore_case=True,
                    drag=AccessibilityActionRequest.Drag(
                        marker="Destination",
                        destination_match_key=AccessibilitySearchableKey.TITLE.value,
                        destination_depth=7,
                        press_duration=0.25,
                        duration=0.5,
                        release_duration=0.75,
                        delta=4.0,
                    ),
                ),
            ),
        ]

        for action, invoke, expected_request in cases:
            with self.subTest(action=action):
                self.client.stub.accessibility_action.reset_mock()
                await invoke()
                self.client.stub.accessibility_action.assert_awaited_once_with(
                    expected_request
                )


class AccessibilityWaitTests(TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.stub.accessibility_action = AsyncMock()

    async def test_wait_sends_marker_and_options(self) -> None:
        self.client.stub.accessibility_action.return_value = (
            AccessibilityActionResponse(
                wait_result=AccessibilityActionResponse.TIMED_OUT,
                wait=AccessibilityActionResponse.WaitResponse(
                    result=AccessibilityActionResponse.FOUND,
                ),
            )
        )
        found = await self.client.accessibility_wait(
            AccessibilityMarker("General", AccessibilitySearchableKey.UNIQUE_ID, 12),
            timeout=30,
            poll_interval=0.25,
            backend=AccessibilityBackend.AX,
        )
        self.assertIs(found, True)
        self.client.stub.accessibility_action.assert_awaited_once_with(
            AccessibilityActionRequest(
                marker="General",
                match_key=AccessibilitySearchableKey.UNIQUE_ID.value,
                depth=12,
                backend=AccessibilityBackend.AX.value,
                wait=AccessibilityActionRequest.Wait(
                    timeout=30,
                    poll_interval=0.25,
                    backend=AccessibilityBackend.AX.value,
                ),
            )
        )

    async def test_wait_sends_the_backend_on_both_fields(self) -> None:
        # The request-level field is the one a current companion reads; Wait's own
        # is deprecated and still sent, because a companion older than the
        # request-level field reads only that one.
        self.client.stub.accessibility_action.return_value = (
            AccessibilityActionResponse(wait_result=AccessibilityActionResponse.FOUND)
        )
        await self.client.accessibility_wait(
            AccessibilityMarker("General"),
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )
        request = self.client.stub.accessibility_action.await_args[0][0]
        self.assertEqual(
            request.backend, AccessibilityBackend.AXBRIDGE_PERSISTENT.value
        )
        self.assertEqual(
            request.wait.backend, AccessibilityBackend.AXBRIDGE_PERSISTENT.value
        )

    async def test_wait_timeout_returns_false(self) -> None:
        self.client.stub.accessibility_action.return_value = (
            AccessibilityActionResponse(
                wait_result=AccessibilityActionResponse.TIMED_OUT
            )
        )
        self.assertIs(
            await self.client.accessibility_wait(AccessibilityMarker("missing")), False
        )

    async def test_wait_returns_diagnostics_and_message(self) -> None:
        self.client.stub.accessibility_action.return_value = (
            AccessibilityActionResponse(
                wait_result=AccessibilityActionResponse.FOUND,
                wait=AccessibilityActionResponse.WaitResponse(
                    result=AccessibilityActionResponse.TIMED_OUT,
                    message="Timed out waiting for AXLabel containing 'missing'",
                    diagnostics=AccessibilityActionResponse.WaitDiagnostics(
                        unmatched_values=["Settings", "General"],
                        truncated=True,
                    ),
                ),
            )
        )
        result = await self.client.accessibility_wait_result(
            AccessibilityMarker("missing")
        )
        self.assertFalse(result)
        self.assertEqual(
            result,
            AccessibilityWaitResult(
                found=False,
                message="Timed out waiting for AXLabel containing 'missing'",
                diagnostics=AccessibilitySearchDiagnostics(
                    unmatched_values=["Settings", "General"], truncated=True
                ),
            ),
        )

    async def test_wait_distinguishes_sample_and_tree_truncation(self) -> None:
        # Field 2 remains the legacy aggregate. Fields 4 and 5 carry explicit
        # read/sample flags, including false; an old companion omits both.
        for payload, truncated, read_truncated, sample_truncated in [
            (b"\x10\x01\x20\x00\x28\x01", True, False, True),
            (b"\x10\x01\x20\x01\x28\x00", True, True, False),
            (b"\x10\x01\x20\x01\x28\x01", True, True, True),
            (b"\x20\x00\x28\x00", False, False, False),
            (b"\x10\x01\x28\x01", True, None, True),
            (b"\x10\x01", True, None, None),
            (b"", False, None, None),
        ]:
            with self.subTest(payload=payload):
                self.client.stub.accessibility_action.return_value = AccessibilityActionResponse(
                    wait=AccessibilityActionResponse.WaitResponse(
                        result=AccessibilityActionResponse.TIMED_OUT,
                        diagnostics=AccessibilityActionResponse.WaitDiagnostics.FromString(
                            payload
                        ),
                    )
                )
                result = await self.client.accessibility_wait_result(
                    AccessibilityMarker("missing")
                )
                self.assertIs(result.diagnostics.truncated, truncated)
                self.assertIs(
                    getattr(result.diagnostics, "read_truncated", None),
                    read_truncated,
                )
                self.assertIs(
                    getattr(result.diagnostics, "sample_truncated", None),
                    sample_truncated,
                )

    async def test_wait_distinguishes_missing_empty_and_failed_observations(
        self,
    ) -> None:
        target = AccessibilityMarker("missing")
        for payload, found in [(b"\x08\x01", True), (b"\x08\x02", False)]:
            with self.subTest(legacy_wire=payload):
                self.client.stub.accessibility_action.return_value = (
                    AccessibilityActionResponse.FromString(payload)
                )
                self.assertEqual(
                    await self.client.accessibility_wait_result(target),
                    AccessibilityWaitResult(found=found),
                )
                self.assertIs(await self.client.accessibility_wait(target), found)
                legacy = MagicMock(spec=BaseClient)
                legacy.accessibility_wait = AsyncMock(return_value=found)
                self.assertEqual(
                    await BaseClient.accessibility_wait_result(legacy, target),
                    AccessibilityWaitResult(found=found),
                )
                legacy.accessibility_wait.assert_awaited_once_with(
                    target=target,
                    timeout=10.0,
                    poll_interval=0.5,
                    backend=AccessibilityBackend.AXBRIDGE,
                )
        for wire, expected in [
            (None, None),
            (
                AccessibilityActionResponse.WaitDiagnostics(),
                AccessibilitySearchDiagnostics(),
            ),
            (
                AccessibilityActionResponse.WaitDiagnostics(
                    read_error="app unavailable"
                ),
                AccessibilitySearchDiagnostics(read_error="app unavailable"),
            ),
        ]:
            with self.subTest(diagnostics=wire):
                self.client.stub.accessibility_action.return_value = (
                    AccessibilityActionResponse(
                        wait=AccessibilityActionResponse.WaitResponse(
                            result=AccessibilityActionResponse.TIMED_OUT,
                            diagnostics=wire,
                        ),
                    )
                )
                result = await self.client.accessibility_wait_result(
                    AccessibilityMarker("missing")
                )
                self.assertFalse(result.found)
                self.assertEqual(result.diagnostics, expected)

    async def test_missing_wait_result_is_an_error(self) -> None:
        for response in [
            AccessibilityActionResponse(),
            AccessibilityActionResponse(wait_result=99),
            AccessibilityActionResponse(
                wait_result=AccessibilityActionResponse.FOUND,
                wait=AccessibilityActionResponse.WaitResponse(),
            ),
            AccessibilityActionResponse(
                wait_result=AccessibilityActionResponse.FOUND,
                wait=AccessibilityActionResponse.WaitResponse(result=99),
            ),
        ]:
            with self.subTest(response=response):
                self.client.stub.accessibility_action.return_value = response
                with self.assertRaisesRegex(
                    IdbException, "did not report a wait result"
                ):
                    await self.client.accessibility_wait(AccessibilityMarker("missing"))

    async def test_transport_failure_is_not_a_timeout_result(self) -> None:
        self.client.stub.accessibility_action.side_effect = GRPCError(
            Status.UNAVAILABLE, "reader failed"
        )
        with self.assertRaises(IdbException):
            await self.client.accessibility_wait(AccessibilityMarker("missing"))


class AccessibilityActionBackendTests(TestCase):
    """Every mutating action carries the caller's backend on the request."""

    def setUp(self) -> None:
        super().setUp()
        self.client = Client.__new__(Client)
        self.client.logger = MagicMock()
        self.client.stub = MagicMock()
        self.client.stub.accessibility_action = AsyncMock()

    def sent_request(self) -> AccessibilityActionRequest:
        return self.client.stub.accessibility_action.await_args[0][0]

    async def test_tap_carries_the_backend(self) -> None:
        await self.client.accessibility_tap(
            AccessibilityMarker("GETTING STARTED"),
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )
        self.assertEqual(
            self.sent_request().backend,
            AccessibilityBackend.AXBRIDGE_PERSISTENT.value,
        )

    async def test_scroll_carries_the_backend(self) -> None:
        await self.client.accessibility_scroll(
            None,
            AccessibilityScrollDirection.DOWN,
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )
        self.assertEqual(
            self.sent_request().backend,
            AccessibilityBackend.AXBRIDGE_PERSISTENT.value,
        )

    async def test_set_value_carries_the_backend(self) -> None:
        await self.client.accessibility_set_value(
            AccessibilityMarker("Field"),
            "hello",
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )
        self.assertEqual(
            self.sent_request().backend,
            AccessibilityBackend.AXBRIDGE_PERSISTENT.value,
        )

    async def test_drag_carries_the_backend(self) -> None:
        await self.client.accessibility_drag(
            AccessibilityPoint(x=10, y=20),
            AccessibilityPoint(x=30, y=40),
            AccessibilityDragOptions(),
            backend=AccessibilityBackend.AXBRIDGE_PERSISTENT,
        )
        self.assertEqual(
            self.sent_request().backend,
            AccessibilityBackend.AXBRIDGE_PERSISTENT.value,
        )

    async def test_an_unasked_backend_is_left_unset(self) -> None:
        # Unset is the wire default, which the companion reads as its own default,
        # so a caller that does not choose is unaffected.
        await self.client.accessibility_tap(AccessibilityMarker("General"))
        self.assertEqual(
            self.sent_request().backend, AccessibilityInfoRequest.BACKEND_UNSPECIFIED
        )
