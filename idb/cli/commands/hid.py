#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from argparse import ArgumentParser, Namespace

from idb.cli import ClientCommand
from idb.common.hid import (
    iterator_to_async_iterator,
    key_press_with_modifiers_to_events,
)
from idb.common.types import Client, HIDButtonType, HIDOrientationType


class MultiTapCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Multi Tap On the Screen (default: double tap)"

    @property
    def name(self) -> str:
        return "multi-tap"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument("x", help="The x-coordinate", type=int)
        parser.add_argument("y", help="The y-coordinate", type=int)
        parser.add_argument(
            "--count",
            help="Number of taps (default: 2)",
            type=int,
            default=2,
        )
        parser.add_argument("--duration", help="Press duration", type=float)
        parser.add_argument(
            "--pause",
            help="Pause between taps in seconds (default: 0.1)",
            type=float,
            default=0.1,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.multi_tap(
            x=args.x,
            y=args.y,
            count=args.count,
            duration=args.duration,
            pause=args.pause,
        )


class ButtonCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "A single press of a button"

    @property
    def name(self) -> str:
        return "button"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "button",
            help="The button name",
            choices=[button.name for button in HIDButtonType],
            type=str,
        )
        parser.add_argument("--duration", help="Press duration", type=float)
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.button(
            button_type=HIDButtonType[args.button], duration=args.duration
        )


class RotateCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Rotate the device to an orientation"

    @property
    def name(self) -> str:
        return "rotate"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "orientation",
            help="The device orientation",
            choices=[orientation.name for orientation in HIDOrientationType],
            type=str,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.rotate(orientation=HIDOrientationType[args.orientation])


class ShakeCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Shake the device"

    @property
    def name(self) -> str:
        return "shake"

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.shake()


# Remote action -> USB HID keyboard usage the tvOS focus engine consumes (keyboard-backed; no proto
# change). Arrows move focus, Return selects, Escape acts as Menu/back.
_REMOTE_KEYCODES: dict[str, int] = {
    "up": 0x52,
    "down": 0x51,
    "left": 0x50,
    "right": 0x4F,
    "select": 0x28,
    "menu": 0x29,
}


class RemoteCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Send a Siri Remote action for tvOS focus navigation"

    @property
    def name(self) -> str:
        return "remote"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "action",
            help="The remote action",
            choices=list(_REMOTE_KEYCODES),
            type=str,
        )
        parser.add_argument("--duration", help="Press duration", type=float)
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.key(keycode=_REMOTE_KEYCODES[args.action], duration=args.duration)


class KeyCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "A short press of a keycode with optional keyboard modifiers"

    @property
    def name(self) -> str:
        return "key"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument("key", help="The key code", type=int)
        parser.add_argument("--duration", help="Press duration", type=float)
        parser.add_argument("--shift", action="store_true", help="Hold Shift modifier")
        parser.add_argument(
            "--control", action="store_true", help="Hold Control modifier"
        )
        parser.add_argument(
            "--option", action="store_true", help="Hold Option/Alt modifier"
        )
        parser.add_argument(
            "--command", action="store_true", help="Hold Command/GUI modifier"
        )
        parser.add_argument(
            "--tab",
            action="store_true",
            help="Hold Tab modifier (for [iOS Full Keyboard Access](https://support.apple.com/en-gb/guide/iphone/ipha4375873f/ios))",
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        modifiers = []
        if args.control:
            modifiers.append("control")
        if args.option:
            modifiers.append("option")
        if args.shift:
            modifiers.append("shift")
        if args.command:
            modifiers.append("command")
        if args.tab:
            modifiers.append("tab")

        if modifiers:
            events = key_press_with_modifiers_to_events(
                keycode=args.key,
                modifiers=modifiers,
                duration=args.duration,
            )
            await client.hid(iterator_to_async_iterator(events))
        else:
            await client.key(keycode=args.key, duration=args.duration)


class KeySequenceCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "A sequence of short presses of a keycode"

    @property
    def name(self) -> str:
        return "key-sequence"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "key_sequence",
            help="list of space separated key codes string (i.e. 1 2 3))",
            nargs="*",
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.key_sequence(key_sequence=list(map(int, args.key_sequence)))


class TextCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Input text"

    @property
    def name(self) -> str:
        return "text"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument("text", help="Text to input", type=str)
        parser.add_argument(
            "--layout",
            help=(
                "Hardware keyboard layout to type on, e.g. US or French. "
                "Defaults to the simulator's own"
            ),
            type=str,
            default=None,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.text(text=args.text, layout=args.layout)


class SwipeCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Swipe from one point to another point"

    @property
    def name(self) -> str:
        return "swipe"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "x_start", help="The x-coordinate of the swipe start point", type=int
        )
        parser.add_argument(
            "y_start", help="The y-coordinate of the swipe start point", type=int
        )
        parser.add_argument(
            "x_end", help="The x-coordinate of the swipe end point", type=int
        )
        parser.add_argument(
            "y_end", help="The y-coordinate of the swipe end point", type=int
        )

        parser.add_argument("--duration", help="Swipe duration", type=float)

        parser.add_argument(
            "--delta",
            dest="delta",
            help="delta in points between every touch point on the line "
            "between start and end points",
            type=int,
            required=False,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.swipe(
            p_start=(args.x_start, args.y_start),
            p_end=(args.x_end, args.y_end),
            duration=args.duration,
            delta=args.delta,
        )


class PinchCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Perform a pinch gesture"

    @property
    def name(self) -> str:
        return "pinch"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument("x", help="X coordinate of pinch center", type=float)
        parser.add_argument("y", help="Y coordinate of pinch center", type=float)
        parser.add_argument(
            "scale", help="Scale factor (>1.0 = zoom in, <1.0 = zoom out)", type=float
        )
        parser.add_argument(
            "--duration", help="Duration in seconds", type=float, default=0.5
        )
        parser.add_argument(
            "--radius",
            help="Initial finger distance from center in pixels",
            type=float,
            default=100.0,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await client.pinch(
            center_x=args.x,
            center_y=args.y,
            scale=args.scale,
            duration=args.duration,
            radius=args.radius,
        )
