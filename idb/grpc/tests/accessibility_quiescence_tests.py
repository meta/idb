#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from idb.common.types import (
    IdbException,
    QuiescenceBackend,
    QuiescenceState,
    QuiescenceStateChanged,
    QuiescenceTargetChanged,
    QuiescenceTargetExited,
    QuiescenceTouchesCompleted,
)
from idb.grpc.idb_pb2 import (
    AccessibilityQuiescenceRequest,
    AccessibilityQuiescenceResponse,
)
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.utils.testing import TestCase


Response = AccessibilityQuiescenceResponse


class AccessibilityQuiescenceTests(TestCase):
    async def test_the_request_carries_only_what_was_set(self) -> None:
        for kwargs, expected in [
            ({}, AccessibilityQuiescenceRequest()),
            ({"pid": 42}, AccessibilityQuiescenceRequest(pid=42)),
            (
                {"bundle_id": "com.example.app"},
                AccessibilityQuiescenceRequest(bundle_id="com.example.app"),
            ),
            (
                {"busy_threshold_ms": 1500, "quiet_window_ms": 0},
                AccessibilityQuiescenceRequest(
                    busy_threshold_ms=1500, quiet_window_ms=0
                ),
            ),
        ]:
            with self.subTest(kwargs=kwargs):
                stream = ScriptedStream()
                client, _ = make_client("accessibility_quiescence", stream)
                events = [e async for e in client.accessibility_quiescence(**kwargs)]
                self.assertEqual(events, [])
                self.assertEqual(stream.sent, [(expected, True)])
                request = stream.sent[0][0]
                assert isinstance(request, AccessibilityQuiescenceRequest)
                self.assertEqual(
                    request.WhichOneof("quiet_window") is not None,
                    "quiet_window_ms" in kwargs,
                )
                self.assertTrue(stream.exited)

    async def test_every_event_is_translated_in_order(self) -> None:
        stream = ScriptedStream(
            Response(
                pid=42,
                state=Response.StateChanged(
                    state=Response.BUSY,
                    busy_signals=[Response.ANIMATIONS_INACTIVE, Response.RUN_LOOP_IDLE],
                ),
            ),
            Response(pid=42, touches_completed=Response.TouchesCompleted()),
            Response(pid=42, state=Response.StateChanged(state=Response.SETTLING)),
            Response(pid=43, target_changed=Response.TargetChanged()),
            Response(pid=43, state=Response.StateChanged(state=Response.QUIET)),
            Response(pid=43, target_exited=Response.TargetExited()),
        )
        client, _ = make_client("accessibility_quiescence", stream)
        events = [e async for e in client.accessibility_quiescence()]
        self.assertEqual(
            events,
            [
                QuiescenceStateChanged(
                    pid=42,
                    state=QuiescenceState.BUSY,
                    busy_signals=("animations_inactive", "run_loop_idle"),
                ),
                QuiescenceTouchesCompleted(pid=42),
                QuiescenceStateChanged(pid=42, state=QuiescenceState.SETTLING),
                QuiescenceTargetChanged(pid=43),
                QuiescenceStateChanged(pid=43, state=QuiescenceState.QUIET),
                QuiescenceTargetExited(pid=43),
            ],
        )

    async def test_an_event_without_a_known_state_is_an_error(self) -> None:
        for response in [
            Response(pid=42),
            Response(pid=42, state=Response.StateChanged()),
        ]:
            with self.subTest(response=response):
                stream = ScriptedStream(response)
                client, _ = make_client("accessibility_quiescence", stream)
                with self.assertRaises(IdbException):
                    [e async for e in client.accessibility_quiescence()]

    async def test_the_shimulator_backend_is_requested_and_an_older_companion_refused(
        self,
    ) -> None:
        shimulator = AccessibilityQuiescenceRequest.SHIMULATOR
        stream = ScriptedStream(
            Response(
                pid=42,
                backend=shimulator,
                state=Response.StateChanged(state=Response.QUIET),
            ),
        )
        client, _ = make_client("accessibility_quiescence", stream)
        events = [
            e
            async for e in client.accessibility_quiescence(
                pid=42, backend=QuiescenceBackend.SHIMULATOR
            )
        ]
        self.assertEqual(
            events, [QuiescenceStateChanged(pid=42, state=QuiescenceState.QUIET)]
        )
        self.assertEqual(
            stream.sent,
            [(AccessibilityQuiescenceRequest(pid=42, backend=shimulator), True)],
        )

        # A companion that predates the field measured with axbridge and says nothing.
        older = ScriptedStream(
            Response(pid=42, state=Response.StateChanged(state=Response.QUIET)),
        )
        client, _ = make_client("accessibility_quiescence", older)
        with self.assertRaisesRegex(IdbException, "predates the shimulator backend"):
            [
                e
                async for e in client.accessibility_quiescence(
                    pid=42, backend=QuiescenceBackend.SHIMULATOR
                )
            ]
