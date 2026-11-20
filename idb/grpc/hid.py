#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from typing import List, Tuple, TypeVar

from idb.common.types import (
    HIDButton,
    HIDButtonType,
    HIDDelay,
    HIDDirection,
    HIDEvent,
    HIDHinge,
    HIDKey,
    HIDOrientation,
    HIDOrientationType,
    HIDPinch,
    HIDPress,
    HIDPressAction,
    HIDShake,
    HIDSwipe,
    HIDText,
    HIDTouch,
    Point,
)
from idb.grpc.idb_pb2 import HIDEvent as GrpcHIDEvent, Point as GrpcPoint


GrpcHIDButton = GrpcHIDEvent.HIDButton
GrpcHIDDelay = GrpcHIDEvent.HIDDelay
GrpcHIDHinge = GrpcHIDEvent.HIDHinge
GrpcHIDKey = GrpcHIDEvent.HIDKey
GrpcHIDPinch = GrpcHIDEvent.HIDPinch
GrpcHIDPress = GrpcHIDEvent.HIDPress
GrpcHIDPressAction = GrpcHIDEvent.HIDPressAction
GrpcHIDSwipe = GrpcHIDEvent.HIDSwipe
GrpcHIDText = GrpcHIDEvent.HIDText
GrpcHIDTouch = GrpcHIDEvent.HIDTouch
GrpcHIDButtonType = GrpcHIDEvent.HIDButtonType
GrpcHIDDirection = GrpcHIDEvent.HIDDirection
GrpcHIDOrientation = GrpcHIDEvent.HIDOrientation
GrpcHIDShake = GrpcHIDEvent.HIDShake
GrpcHIDOrientationType = GrpcHIDEvent.HIDOrientationType
_A = TypeVar("_A")
_B = TypeVar("_B")


BUTTON_TYPE_PAIRS: "List[Tuple[HIDButtonType, GrpcHIDButtonType]]" = [
    (HIDButtonType.APPLE_PAY, GrpcHIDEvent.APPLE_PAY),
    (HIDButtonType.HOME, GrpcHIDEvent.HOME),
    (HIDButtonType.LOCK, GrpcHIDEvent.LOCK),
    (HIDButtonType.SIDE_BUTTON, GrpcHIDEvent.SIDE_BUTTON),
    (HIDButtonType.SIRI, GrpcHIDEvent.SIRI),
    (HIDButtonType.PLAY_PAUSE, GrpcHIDEvent.PLAY_PAUSE),
    (HIDButtonType.VOLUME_UP, GrpcHIDEvent.VOLUME_UP),
    (HIDButtonType.VOLUME_DOWN, GrpcHIDEvent.VOLUME_DOWN),
    (HIDButtonType.EJECT, GrpcHIDEvent.EJECT),
]

DIRECTION_PAIRS: "List[Tuple[HIDDirection, GrpcHIDDirection]]" = [
    (HIDDirection.DOWN, GrpcHIDEvent.DOWN),
    (HIDDirection.UP, GrpcHIDEvent.UP),
]

ORIENTATION_TYPE_PAIRS: "List[Tuple[HIDOrientationType, GrpcHIDOrientationType]]" = [
    (HIDOrientationType.PORTRAIT, GrpcHIDEvent.PORTRAIT),
    (HIDOrientationType.PORTRAIT_UPSIDE_DOWN, GrpcHIDEvent.PORTRAIT_UPSIDE_DOWN),
    (HIDOrientationType.LANDSCAPE_LEFT, GrpcHIDEvent.LANDSCAPE_LEFT),
    (HIDOrientationType.LANDSCAPE_RIGHT, GrpcHIDEvent.LANDSCAPE_RIGHT),
]


def _translation_from_pairs(pairs: list[tuple[_A, _B]], item: _A) -> _B:
    pair_map = dict(pairs)
    return pair_map[item]


def button_type_to_grpc(button_type: HIDButtonType) -> GrpcHIDButtonType:
    return _translation_from_pairs(BUTTON_TYPE_PAIRS, button_type)


def direction_to_grpc(direction: HIDDirection) -> GrpcHIDDirection:
    return _translation_from_pairs(DIRECTION_PAIRS, direction)


def point_to_grpc(point: Point) -> GrpcPoint:
    return GrpcPoint(x=point.x, y=point.y)


def touch_to_grpc(touch: HIDTouch) -> GrpcHIDTouch:
    return GrpcHIDTouch(point=point_to_grpc(touch.point))


def button_to_grpc(button: HIDButton) -> GrpcHIDButton:
    return GrpcHIDButton(button=button_type_to_grpc(button.button))


def key_to_grpc(key: HIDKey) -> GrpcHIDKey:
    return GrpcHIDKey(keycode=key.keycode)


def press_action_to_grpc(action: HIDPressAction) -> GrpcHIDPressAction:
    if isinstance(action, HIDTouch):
        return GrpcHIDPressAction(touch=touch_to_grpc(action))
    elif isinstance(action, HIDButton):
        return GrpcHIDPressAction(button=button_to_grpc(action))
    elif isinstance(action, HIDKey):
        return GrpcHIDPressAction(key=key_to_grpc(action))
    else:
        raise Exception(f"Invalid press action {action}")


def press_to_grpc(press: HIDPress) -> GrpcHIDPress:
    return GrpcHIDPress(
        action=press_action_to_grpc(press.action),
        direction=direction_to_grpc(press.direction),
    )


def swipe_to_grpc(swipe: HIDSwipe) -> GrpcHIDSwipe:
    return GrpcHIDSwipe(
        start=point_to_grpc(swipe.start),
        end=point_to_grpc(swipe.end),
        # pyre-ignore
        delta=swipe.delta,
        # pyre-ignore
        duration=swipe.duration,
    )


def delay_to_grpc(delay: HIDDelay) -> GrpcHIDDelay:
    return GrpcHIDDelay(duration=delay.duration)


def pinch_to_grpc(pinch: HIDPinch) -> GrpcHIDPinch:
    return GrpcHIDPinch(
        center=point_to_grpc(pinch.center),
        scale=pinch.scale,
        duration=pinch.duration,
        radius=pinch.radius,
    )


def orientation_type_to_grpc(
    orientation_type: HIDOrientationType,
) -> GrpcHIDOrientationType:
    return _translation_from_pairs(ORIENTATION_TYPE_PAIRS, orientation_type)


def orientation_to_grpc(orientation: HIDOrientation) -> GrpcHIDOrientation:
    return GrpcHIDOrientation(
        orientation=orientation_type_to_grpc(orientation.orientation)
    )


def shake_to_grpc(shake: HIDShake) -> GrpcHIDShake:
    return GrpcHIDShake()


def text_to_grpc(text: HIDText) -> GrpcHIDText:
    return GrpcHIDText(text=text.text, layout=text.layout or "")


def event_to_grpc(event: HIDEvent) -> GrpcHIDEvent:
    if isinstance(event, HIDPress):
        return GrpcHIDEvent(press=press_to_grpc(event))
    elif isinstance(event, HIDSwipe):
        return GrpcHIDEvent(swipe=swipe_to_grpc(event))
    elif isinstance(event, HIDDelay):
        return GrpcHIDEvent(delay=delay_to_grpc(event))
    elif isinstance(event, HIDPinch):
        return GrpcHIDEvent(pinch=pinch_to_grpc(event))
    elif isinstance(event, HIDOrientation):
        return GrpcHIDEvent(orientation=orientation_to_grpc(event))
    elif isinstance(event, HIDHinge):
        return GrpcHIDEvent(hinge=GrpcHIDHinge(angle=event.angle))
    elif isinstance(event, HIDShake):
        return GrpcHIDEvent(shake=shake_to_grpc(event))
    elif isinstance(event, HIDText):
        return GrpcHIDEvent(text=text_to_grpc(event))
    else:
        raise Exception(f"Invalid event {event}")
