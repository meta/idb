#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import dataclasses
from collections.abc import AsyncIterator
from unittest.mock import AsyncMock, call, MagicMock

from idb.common.hid import text_to_events
from idb.common.types import HIDEvent, IdbException
from idb.grpc.client import Client
from idb.grpc.hid import (
    event_to_grpc,
    GrpcHIDButton,
    GrpcHIDDelay,
    GrpcHIDEvent,
    GrpcHIDHinge,
    GrpcHIDKey,
    GrpcHIDOrientation,
    GrpcHIDPinch,
    GrpcHIDPress,
    GrpcHIDPressAction,
    GrpcHIDShake,
    GrpcHIDSwipe,
    GrpcHIDText,
    GrpcHIDTouch,
    GrpcPoint,
    HIDButton,
    HIDButtonType,
    HIDDelay,
    HIDDirection,
    HIDHinge,
    HIDKey,
    HIDOrientation,
    HIDOrientationType,
    HIDPinch,
    HIDPress,
    HIDShake,
    HIDSwipe,
    HIDText,
    HIDTouch,
    Point,
)
from idb.grpc.idb_pb2 import HIDResponse
from idb.grpc.tests.stream_test_support import make_client, ScriptedStream
from idb.utils.testing import TestCase


class HidTests(TestCase):
    def test_hinge(self) -> None:
        for angle in [0, 90, 135.5, 180]:
            with self.subTest(angle=angle):
                self.assertEqual(
                    event_to_grpc(HIDHinge(angle=angle)),
                    GrpcHIDEvent(hinge=GrpcHIDHinge(angle=angle)),
                )

    def test_hinge_rejects_invalid_angles(self) -> None:
        for angle in [-1, 180.001, float("nan"), float("inf"), -float("inf")]:
            with self.subTest(angle=angle), self.assertRaises(ValueError):
                HIDHinge(angle=angle)

    def test_press(self) -> None:
        actions = [
            HIDTouch(point=Point(x=1, y=2)),
            HIDButton(button=HIDButtonType.HOME),
            HIDKey(keycode=3),
        ]
        expected = [
            GrpcHIDPressAction(touch=GrpcHIDTouch(point=GrpcPoint(x=1, y=2))),
            GrpcHIDPressAction(button=GrpcHIDButton(button=GrpcHIDEvent.HOME)),
            GrpcHIDPressAction(key=GrpcHIDKey(keycode=3)),
        ]
        for action, expected_action in zip(actions, expected):
            self.assertEqual(
                event_to_grpc(HIDPress(action=action, direction=HIDDirection.UP)),
                GrpcHIDEvent(
                    press=GrpcHIDPress(
                        action=expected_action, direction=GrpcHIDEvent.UP
                    )
                ),
            )
        for button in HIDButtonType:
            with self.subTest(button=button):
                grpc = event_to_grpc(
                    HIDPress(
                        action=HIDButton(button=button), direction=HIDDirection.DOWN
                    )
                )
                self.assertEqual(
                    GrpcHIDEvent.HIDButtonType.Name(grpc.press.action.button.button),
                    button.name,
                )

    def test_swipe(self) -> None:
        deltas = [None, 5]
        for delta in deltas:
            self.assertEqual(
                event_to_grpc(
                    HIDSwipe(
                        start=Point(x=1, y=2),
                        end=Point(x=3, y=4),
                        delta=delta,
                        duration=0.5,
                    )
                ),
                GrpcHIDEvent(
                    swipe=GrpcHIDSwipe(
                        start=GrpcPoint(x=1, y=2),
                        end=GrpcPoint(x=3, y=4),
                        # pyre-ignore
                        delta=delta,
                        duration=0.5,
                    )
                ),
            )

    def test_delay(self) -> None:
        self.assertEqual(
            event_to_grpc(HIDDelay(duration=1)),
            GrpcHIDEvent(delay=GrpcHIDDelay(duration=1)),
        )

    def test_text(self) -> None:
        self.assertEqual(
            event_to_grpc(HIDText(text="héllo", layout="French")),
            GrpcHIDEvent(text=GrpcHIDText(text="héllo", layout="French")),
        )

    def test_text_without_a_layout_leaves_it_empty(self) -> None:
        grpc = event_to_grpc(HIDText(text="héllo"))
        self.assertEqual(grpc, GrpcHIDEvent(text=GrpcHIDText(text="héllo")))
        self.assertEqual(grpc.WhichOneof("event"), "text")
        self.assertEqual(grpc.text.layout, "")

    async def test_all_event_variants_stream_in_order_and_half_close(
        self,
    ) -> None:
        cases: list[tuple[HIDEvent, GrpcHIDEvent]] = [
            (
                HIDPress(
                    action=HIDTouch(point=Point(x=1, y=2)),
                    direction=HIDDirection.DOWN,
                ),
                GrpcHIDEvent(
                    press=GrpcHIDPress(
                        action=GrpcHIDPressAction(
                            touch=GrpcHIDTouch(point=GrpcPoint(x=1, y=2))
                        ),
                        direction=GrpcHIDEvent.DOWN,
                    )
                ),
            ),
            (
                HIDPress(
                    action=HIDButton(button=HIDButtonType.HOME),
                    direction=HIDDirection.UP,
                ),
                GrpcHIDEvent(
                    press=GrpcHIDPress(
                        action=GrpcHIDPressAction(
                            button=GrpcHIDButton(button=GrpcHIDEvent.HOME)
                        ),
                        direction=GrpcHIDEvent.UP,
                    )
                ),
            ),
            (
                HIDPress(
                    action=HIDKey(keycode=3),
                    direction=HIDDirection.DOWN,
                ),
                GrpcHIDEvent(
                    press=GrpcHIDPress(
                        action=GrpcHIDPressAction(key=GrpcHIDKey(keycode=3)),
                        direction=GrpcHIDEvent.DOWN,
                    )
                ),
            ),
            (
                HIDSwipe(
                    start=Point(x=4, y=5),
                    end=Point(x=6, y=7),
                    delta=8,
                    duration=0.5,
                ),
                GrpcHIDEvent(
                    swipe=GrpcHIDSwipe(
                        start=GrpcPoint(x=4, y=5),
                        end=GrpcPoint(x=6, y=7),
                        delta=8,
                        duration=0.5,
                    )
                ),
            ),
            (
                HIDDelay(duration=1.25),
                GrpcHIDEvent(delay=GrpcHIDDelay(duration=1.25)),
            ),
            (
                HIDPinch(
                    center=Point(x=9, y=10),
                    scale=1.5,
                    duration=0.75,
                    radius=40,
                ),
                GrpcHIDEvent(
                    pinch=GrpcHIDPinch(
                        center=GrpcPoint(x=9, y=10),
                        scale=1.5,
                        duration=0.75,
                        radius=40,
                    )
                ),
            ),
            (
                HIDOrientation(orientation=HIDOrientationType.LANDSCAPE_LEFT),
                GrpcHIDEvent(
                    orientation=GrpcHIDOrientation(
                        orientation=GrpcHIDEvent.LANDSCAPE_LEFT
                    )
                ),
            ),
            (HIDShake(), GrpcHIDEvent(shake=GrpcHIDShake())),
            (
                HIDText(text="é", layout="French"),
                GrpcHIDEvent(text=GrpcHIDText(text="é", layout="French")),
            ),
        ]

        stream = AsyncMock()
        stream.__aenter__.return_value = stream
        stream.__aexit__.return_value = None
        stream.recv_message.side_effect = [HIDResponse(), None]

        client = Client.__new__(Client)
        client.logger = MagicMock()
        client.stub = MagicMock()
        client.stub.hid.open.return_value = stream

        async def events() -> AsyncIterator[HIDEvent]:
            for event, _ in cases:
                yield event

        await client.hid(events())

        expected_requests = [request for _, request in cases]
        client.stub.hid.open.assert_called_once_with()
        stream.__aenter__.assert_awaited_once_with()
        stream.__aexit__.assert_awaited_once_with(None, None, None)
        self.assertEqual(
            stream.method_calls,
            [
                *[call.send_message(request) for request in expected_requests],
                call.end(),
                call.recv_message(),
                call.recv_message(),
            ],
        )
        stream.send_message.assert_has_awaits(
            [call(request) for request in expected_requests],
            any_order=False,
        )
        self.assertEqual(stream.send_message.await_count, len(expected_requests))
        stream.end.assert_awaited_once_with()
        self.assertEqual(stream.recv_message.await_count, 2)


class TextTests(TestCase):
    async def _sent(
        self, text: str, hid_text: bool, layout: str | None = None
    ) -> list[object]:
        self.stream = ScriptedStream(HIDResponse())
        client, _ = make_client("hid", self.stream, is_local=True)
        client.companion = dataclasses.replace(client.companion, hid_text=hid_text)
        await client.text(text, layout=layout)
        return [message for message, _ in self.stream.sent]

    async def test_a_companion_that_takes_text_is_sent_it_in_one_frame(self) -> None:
        self.assertEqual(
            await self._sent("azerty é", hid_text=True),
            [GrpcHIDEvent(text=GrpcHIDText(text="azerty é"))],
        )
        self.assertEqual(self.stream.transcript[1], ("end", None))

    async def test_a_companion_that_takes_text_is_sent_the_layout(self) -> None:
        self.assertEqual(
            await self._sent("azerty", hid_text=True, layout="French"),
            [GrpcHIDEvent(text=GrpcHIDText(text="azerty", layout="French"))],
        )

    async def test_a_companion_that_does_not_take_text_is_sent_key_presses(
        self,
    ) -> None:
        for layout in (None, "US"):
            with self.subTest(layout=layout):
                self.assertEqual(
                    await self._sent("aA", hid_text=False, layout=layout),
                    [event_to_grpc(event) for event in text_to_events("aA")],
                )

    async def test_a_companion_that_does_not_take_text_cannot_type_on_a_layout(
        self,
    ) -> None:
        with self.assertRaisesRegex(
            IdbException, "does not support typing on a keyboard layout"
        ):
            await self._sent("azerty", hid_text=False, layout="French")
        self.assertFalse(self.stream.entered)
        self.assertEqual(self.stream.sent, [])
