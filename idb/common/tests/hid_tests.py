#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import unittest

from idb.common.hid import (
    button_press_to_events,
    key_press_to_events,
    multi_tap_to_events,
    tap_to_events,
    text_to_events,
)
from idb.common.types import (
    HIDButton,
    HIDButtonType,
    HIDDelay,
    HIDDirection,
    HIDKey,
    HIDPress,
    HIDTouch,
    Point,
)


class HidTests(unittest.TestCase):
    def test_press_events_preserve_direction_and_duration(self) -> None:
        for duration, delays in [
            (None, []),
            (0.0, []),
            (0.25, [HIDDelay(duration=0.25)]),
        ]:
            for events, action in [
                (
                    tap_to_events(10, 20, duration),
                    HIDTouch(point=Point(x=10, y=20)),
                ),
                (
                    button_press_to_events(HIDButtonType.HOME, duration),
                    HIDButton(button=HIDButtonType.HOME),
                ),
                (key_press_to_events(4, duration), HIDKey(keycode=4)),
            ]:
                with self.subTest(duration=duration, action=action):
                    self.assertEqual(
                        events,
                        [
                            HIDPress(action=action, direction=HIDDirection.DOWN),
                            *delays,
                            HIDPress(action=action, direction=HIDDirection.UP),
                        ],
                    )

    def test_multi_tap_places_pauses_between_presses(self) -> None:
        action = HIDTouch(point=Point(x=10, y=20))
        press = [
            HIDPress(action=action, direction=HIDDirection.DOWN),
            HIDDelay(duration=0.25),
            HIDPress(action=action, direction=HIDDirection.UP),
        ]
        self.assertEqual(
            multi_tap_to_events(10, 20, count=3, duration=0.25, pause=0.2),
            [*press, HIDDelay(duration=0.2), *press, HIDDelay(duration=0.2), *press],
        )

    def test_single_tap_has_no_pause(self) -> None:
        action = HIDTouch(point=Point(x=10, y=20))
        self.assertEqual(
            multi_tap_to_events(10, 20, count=1),
            [
                HIDPress(action=action, direction=HIDDirection.DOWN),
                HIDPress(action=action, direction=HIDDirection.UP),
            ],
        )

    def test_zero_taps_has_no_events(self) -> None:
        self.assertEqual(multi_tap_to_events(10, 20, count=0), [])

    def test_text_is_us_key_presses(self) -> None:
        shift, a = HIDKey(keycode=225), HIDKey(keycode=4)
        self.assertEqual(
            text_to_events("aA"),
            [
                HIDPress(action=a, direction=HIDDirection.DOWN),
                HIDPress(action=a, direction=HIDDirection.UP),
                HIDPress(action=shift, direction=HIDDirection.DOWN),
                HIDPress(action=a, direction=HIDDirection.DOWN),
                HIDPress(action=a, direction=HIDDirection.UP),
                HIDPress(action=shift, direction=HIDDirection.UP),
            ],
        )

    def test_text_off_the_us_keyboard_has_no_key_presses(self) -> None:
        with self.assertRaisesRegex(Exception, "No keycode found for é"):
            text_to_events("é")
