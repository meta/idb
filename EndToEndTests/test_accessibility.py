# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Read accessibility elements through the ax and axbridge APIs.

`--api ax` reads from macOS; `--api axbridge` runs SimulatorFrameworkBridge
inside the simulator. Complete output identifies which backend served the
request. ReplHost, launched with `--accessibility-fixture`, shows a fixed
screen whose elements carry known identifiers and change only when something
acts on them; taps and scrolls are read back through axbridge. Safari is read
as well, for the web content another process is showing, which ax cannot
reach.
"""

from __future__ import annotations

import asyncio
import json
import plistlib
import unittest
from typing import Any, Callable

from .harness import (
    _center,
    _describe_matches,
    _elements,
    _has_area,
    _label,
    _on_screen,
    _screen,
    accessibility_not_ready,
    ACCESSIBILITY_READY_TIMEOUT_SECONDS,
    FIXTURE_APP_BUNDLE_ID,
    IdbEndToEndTestCase,
    LocalPages,
    NotReady,
    Query,
    select_tests_for_capability,
    SuiteCapability,
    UI_UPDATE_TIMEOUT_SECONDS,
    UiWait,
    Until,
    wait_until,
)

SAFARI_BUNDLE_ID = "com.apple.mobilesafari"
FIXTURE_LAUNCH_ARGUMENT = "--accessibility-fixture"
ROW_PREFIX = "com.facebook.idb.replhost.row."
GENERAL_ROW_ID = f"{ROW_PREFIX}general"
GENERAL_ROW = Query(GENERAL_ROW_ID)
SEARCH_FIELD_ID = "com.facebook.idb.replhost.search"
SEARCH_FIELD = Query(SEARCH_FIELD_ID)
# Views that carry the rows' identifier prefix without being rows.
ROW_CONTAINER_TYPES = frozenset({"CollectionView", "Table", "ScrollView", "List"})
FRENCH_KEYBOARD = "fr_FR@sw=AZERTY-French;hw=French"
# The letters AZERTY moves, the digits it shifts, punctuation it keeps on other
# keys than a US keyboard does, and characters behind option and a dead key.
# Nothing in it is a quote or a doubled hyphen or space, which smart
# punctuation would rewrite.
AZERTY_TEXT = "azerty AZERTY qwm 0123456789 .,;:!?@-_ €ê ñ^"
# The simulator's keyboards, which it goes by only once they are marked
# expanded, and the one it last used: the domain each is a default of, and the
# `defaults write` arguments that set it.
KEYBOARD_SETTINGS: dict[str, tuple[str, Callable[[Any], list[str]]]] = {
    "AppleKeyboards": ("-g", lambda keyboards: ["-array", *keyboards]),
    "AppleKeyboardsExpanded": ("-g", lambda expanded: ["-int", str(int(expanded))]),
    "KeyboardLastUsed": (
        "com.apple.keyboard.preferences",
        lambda keyboard: ["-string", keyboard],
    ),
}
# A tap idb refused does nothing at all, so a wait long enough to catch a
# screen that did change is short.
NOTHING_OPENS_TIMEOUT_SECONDS = 2.0
# Long enough for a `ui wait` to read the screen before General opens, so its
# answer shows that it waited rather than that it started late.
WAIT_BLOCKS_SECONDS = 2.0
MINIMUM_SCROLL_DISTANCE = 20.0

# The companion uses an exclusive simulator process for --api axbridge.
AX_BACKEND = "ax"
AXBRIDGE_BACKEND = "axbridge-exclusive"

# Exclude narrow elements such as keyboard keys and status-bar icons.
MINIMUM_CONTROL_WIDTH = 100

DESCRIBE_ALL_ARGS = ("ui", "describe-all", "--nested")

# Enough of a matched element to say what it is and where it sits, rather
# than every attribute a read would otherwise carry on every match.
LABEL_AND_FRAME_KEYS = ("--key", "AXLabel", "--key", "AXFrame")

SAFARI_ADDRESS_BAR_ID = "TabBarItemTitle"
# Safari names the address bar this only once it has the cursor.
SAFARI_URL_FIELD_ID = "URL"
RETURN_KEY_CODE = 40
# idb's own documentation, read by idb. Each page is long enough that what the
# demo asks for is far below what Safari has drawn, and what it asks for on the
# second one is a label inside a rendered diagram.
LIVE_ORIGIN = "https://fbidb.io"
FIRST_PAGE_PATH = "/docs/idb/fbsimulatorcontrol"
FIRST_PAGE_HEADING = "Functionality beyond Apple's tools"
# Matched without the apostrophe, so the published command does not have to
# quote its way around one.
FIRST_PAGE_MATCH = "Functionality beyond Apple"
SECOND_PAGE_PATH = "/docs/idb/accessibility"
SECOND_PAGE_LABEL = "SimulatorFrameworkBridge"


def _stand_in_page(title: str, body: str) -> str:
    """One page of the site served in place of the live one.

    Padded above the part the demo reads so that, as on the live page, what
    it asks for is below what Safari has drawn.
    """
    filler = "".join(
        f"<p>Paragraph {index}, above what this page is read for.</p>"
        for index in range(1, 60)
    )
    return (
        "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{title}</title></head><body>{filler}{body}</body></html>"
    )


STAND_IN_PAGES = {
    FIRST_PAGE_PATH: _stand_in_page(
        "FBSimulatorControl",
        f"<h2>{FIRST_PAGE_HEADING}</h2>"
        "<p>What the framework reaches that the shipped tools do not.</p>",
    ),
    SECOND_PAGE_PATH: _stand_in_page(
        "Accessibility",
        f"<h2>{SECOND_PAGE_LABEL}</h2>"
        f"<p>A read is served by {SECOND_PAGE_LABEL}, which runs inside the "
        "simulator rather than beside it.</p>"
        "<figure><figcaption>How a read reaches axbridge</figcaption>"
        "<div style='border:1px solid #333;width:200px;padding:4px'>"
        f"<span style='font-size:7px'>{SECOND_PAGE_LABEL}</span>"
        "</div></figure>",
    ),
}


def _labelled_controls(document: Any) -> list[dict[str, Any]]:
    """Select labelled, row-width elements smaller than the largest container."""
    elements = [
        element
        for element in _elements(document)
        if _label(element) and _has_area(element)
    ]
    if not elements:
        return []
    largest = max(
        element["frame"]["width"] * element["frame"]["height"] for element in elements
    )
    return [
        element
        for element in elements
        if element["frame"]["width"] * element["frame"]["height"] < largest
        and element["frame"]["width"] >= MINIMUM_CONTROL_WIDTH
    ]


def _identifier(element: dict[str, Any]) -> str | None:
    """Read the identifier from legacy output (AXUniqueId) or complete output."""
    return element.get("AXUniqueId") or element.get("identifier")


def _labels(document: Any) -> set[str]:
    return {_label(element) for element in _labelled_controls(document)}


def _visible(
    document: Any, identifier: str, element_type: str | None = None
) -> list[dict[str, Any]]:
    """Every element on screen with this identifier, and this type if one is named."""
    screen = _screen(document)
    return [
        element
        for element in _elements(document)
        if element.get("identifier") == identifier
        and (element_type is None or element.get("type") == element_type)
        and _on_screen(element, screen)
    ]


def _rows(document: Any) -> list[dict[str, Any]]:
    """The fixture's rows, which are the elements identified with their prefix.

    The list the rows sit in shares that prefix without being a row: its
    position never changes as it scrolls, and it is not something a scroll can
    be asked to begin from.
    """
    return [
        element
        for element in _elements(document)
        if str(element.get("identifier", "")).startswith(ROW_PREFIX)
        and element.get("type") not in ROW_CONTAINER_TYPES
        and _has_area(element)
    ]


def _row_positions(document: Any) -> dict[str, float]:
    """Where every row is, on the screen or off it, so movement can be measured."""
    return {element["identifier"]: element["frame"]["y"] for element in _rows(document)}


def _row_movement(
    before: dict[str, float], after: dict[str, float]
) -> dict[str, float]:
    """How far each row in both readings moved; negative is up the screen."""
    return {
        identifier: after[identifier] - y
        for identifier, y in before.items()
        if identifier in after
    }


def _rows_on_screen(document: Any) -> list[str]:
    """The rows a viewer can see, from the top of the screen down."""
    screen = _screen(document)
    return [
        element["identifier"]
        for element in sorted(
            _rows(document), key=lambda element: element["frame"]["y"]
        )
        if _on_screen(element, screen)
    ]


def _search_field(document: Any, value: str | None = None) -> dict[str, Any]:
    """The fixture's search field, holding `value` if one is given.

    Anything but exactly one field with a frame is not ready, and says what
    carried the field's identifier so the extra or missing one can be told
    apart.
    """

    def is_search_field(element: dict[str, Any]) -> bool:
        return element.get("identifier") == SEARCH_FIELD_ID

    fields = [
        element
        for element in _elements(document)
        if is_search_field(element) and _has_area(element)
    ]
    if len(fields) != 1:
        raise NotReady(
            f"Expected one search field with a frame, found {len(fields)}; "
            + _describe_matches(document, is_search_field)
        )
    if value is not None and fields[0].get("value") != value:
        raise NotReady(
            f"Search field has value {fields[0].get('value')!r}, expected {value!r}"
        )
    return fields[0]


ACCESSIBILITY_READ_TESTS = frozenset(
    {
        "test_ui_describe_all_reads_the_fixture_through_both_backends",
        "test_ui_describe_all_reads_as_the_named_client_through_both_backends",
        "test_ui_describe_all_reports_what_its_options_ask_for",
        "test_ui_describe_all_filtered_to_interactable_reports_only_visible_rows",
        "test_ui_describe_resolves_a_point_and_a_marker",
    }
)
INTERACTION_TESTS = frozenset(
    {
        "test_ui_scroll_moves_rows_down_and_up",
        "test_ui_set_value_updates_the_search_field",
        "test_ui_text_types_on_the_simulators_keyboard_layout",
        "test_ui_tap_by_identifier_opens_general",
        "test_ui_tap_by_point_opens_general",
        "test_ui_tap_refuses_a_mismatched_expected_value",
        "test_ui_wait_blocks_until_the_element_appears",
        "test_ui_wait_rejects_a_zero_poll_interval",
        "test_ui_wait_times_out_on_a_missing_element",
    }
)
ACCESSIBILITY_TEST_CAPABILITIES = {
    **{name: SuiteCapability.ACCESSIBILITY_READ for name in ACCESSIBILITY_READ_TESTS},
    **{name: SuiteCapability.ACCESSIBILITY_INTERACTION for name in INTERACTION_TESTS},
}
WEB_CONTENT_TEST_CAPABILITIES = {
    "test_ui_describe_all_reads_an_offscreen_web_element": (
        SuiteCapability.ACCESSIBILITY_INTERACTION
    ),
}


def load_tests(
    loader: unittest.TestLoader,
    tests: unittest.TestSuite,
    pattern: str | None,
) -> unittest.TestSuite:
    return unittest.TestSuite(
        select_tests_for_capability(
            loader, loader.loadTestsFromTestCase(test_case), test_case, requirements
        )
        for test_case, requirements in (
            (AccessibilityTests, ACCESSIBILITY_TEST_CAPABILITIES),
            (WebContentTests, WEB_CONTENT_TEST_CAPABILITIES),
        )
    )


class AccessibilityFixtureTestCase(IdbEndToEndTestCase):
    control: dict[str, Any]

    async def asyncSetUp(self) -> None:
        await super().asyncSetUp()
        await self.setup_deny_permission_prompts()
        for bundle_id in (SAFARI_BUNDLE_ID, FIXTURE_APP_BUNDLE_ID):
            await self.setup_terminate_quietly(bundle_id)
        await self.setup_install_fixture_app()
        await self.setup_idb("launch", FIXTURE_APP_BUNDLE_ID, FIXTURE_LAUNCH_ARGUMENT)
        self.control = await self.wait_for_control()

    async def describe_all_complete(self, api: str, *arguments: str) -> dict[str, Any]:
        document = await self.idb_json(
            "ui", "describe-all", "--api", api, "--format", "complete", *arguments
        )
        self.assertIsInstance(
            document,
            dict,
            "--format complete reported an element array, not a document",
        )
        return document

    async def wait_for_control(self) -> dict[str, Any]:
        """Wait for the fixture's General row. Relaunch the fixture if it has exited.

        Retry only an empty result or a missing translation object.
        """

        async def read() -> dict[str, Any]:
            completed = await self.idb(*DESCRIBE_ALL_ARGS, "--json", check=False)
            if completed.returncode != 0:
                if not accessibility_not_ready(completed):
                    self.fail_or_skip_for(" ".join(DESCRIBE_ALL_ARGS), completed)
                if FIXTURE_APP_BUNDLE_ID not in await self.simctl.running_bundle_ids():
                    await self.setup_idb(
                        "launch",
                        FIXTURE_APP_BUNDLE_ID,
                        FIXTURE_LAUNCH_ARGUMENT,
                        check=False,
                    )
                raise NotReady("the simulator has no accessibility translation object")
            controls = [
                control
                for control in _labelled_controls(json.loads(completed.text))
                if _identifier(control) == GENERAL_ROW_ID
            ]
            if not controls:
                raise NotReady(
                    f"The fixture has no General row yet; response: {completed.text}"
                )
            return controls[0]

        return await self.wait_or_fail(
            "No General row", ACCESSIBILITY_READY_TIMEOUT_SECONDS, read
        )

    async def wait_for_scroll(
        self, before: dict[str, float], direction: str
    ) -> tuple[dict[str, float], dict[str, Any]]:
        """Where the rows are once the list has moved the way it was scrolled and stopped, and the reading that showed it."""
        previous: dict[str, float] | None = None

        async def read() -> tuple[dict[str, float], dict[str, Any]]:
            nonlocal previous
            snapshot = await self.describe_all_complete("axbridge")
            after = _row_positions(snapshot)
            movement = _row_movement(before, after)
            # Scrolling down moves the rows up the screen.
            sign = -1 if direction == "down" else 1
            if not any(
                sign * delta > MINIMUM_SCROLL_DISTANCE for delta in movement.values()
            ):
                raise NotReady(f"Row movement after scrolling {direction}: {movement}")
            # `idb ui scroll` returns while the list is still animating, and a
            # row read mid-animation is somewhere else by the time it is used.
            settled = after == previous
            previous = after
            if not settled:
                raise NotReady(f"The list is still moving after scrolling {direction}")
            return after, snapshot

        return await wait_until(
            f"The list did not scroll {direction}", UI_UPDATE_TIMEOUT_SECONDS, read
        )


class AccessibilityTests(AccessibilityFixtureTestCase):
    capabilities = ACCESSIBILITY_TEST_CAPABILITIES

    async def test_ui_describe_all_reads_the_fixture_through_both_backends(
        self,
    ) -> None:
        ax = await self.describe_all_complete("ax")
        axbridge = await self.describe_all_complete("axbridge")

        self.assertEqual(ax["backend"], AX_BACKEND)
        self.assertEqual(axbridge["backend"], AXBRIDGE_BACKEND)
        for name, document in ((AX_BACKEND, ax), (AXBRIDGE_BACKEND, axbridge)):
            controls = _labelled_controls(document)
            self.assertTrue(controls, f"{name} saw none of the fixture's rows")
        shared = _labels(ax) & _labels(axbridge)
        self.assertTrue(
            shared,
            f"the backends named no row in common; "
            f"{AX_BACKEND} saw {sorted(_labels(ax))} and "
            f"{AXBRIDGE_BACKEND} saw {sorted(_labels(axbridge))}",
        )

    async def test_ui_describe_all_reads_as_the_named_client_through_both_backends(
        self,
    ) -> None:
        for api in ("ax", "axbridge"):
            with self.subTest(api=api):
                default = await self.describe_all_complete(api)
                automation = await self.describe_all_complete(
                    api, "--client-type", "xctest"
                )
                voiceover = await self.describe_all_complete(
                    api, "--client-type", "voiceOver"
                )

                self.assertNotIn(
                    "client", default, "a read that names no client reports none"
                )
                self.assertEqual(automation["client"]["type"], "xctest")
                self.assertEqual(automation["client"]["tree"], "automation")
                self.assertTrue(automation["client"]["caveat"])
                self.assertEqual(
                    voiceover["client"],
                    {"type": "voiceOver", "tree": "voiceover", "caveat": None},
                )
                automation_count = sum(
                    "type" in element for element in _elements(automation["elements"])
                )
                voiceover_count = sum(
                    "type" in element for element in _elements(voiceover["elements"])
                )
                self.assertGreater(
                    automation_count,
                    voiceover_count,
                    f"{api}: the automation tree should carry the containers the VoiceOver tree flattens",
                )

    async def test_ui_describe_all_reports_what_its_options_ask_for(self) -> None:
        selected = await self.idb_json(
            "ui",
            "describe-all",
            "--format",
            "complete",
            "--key",
            "AXLabel",
            "--key",
            "frame",
            "--profile",
            "--collect-frame-coverage",
        )
        # A frame is a dictionary too, so what is an element is what has a type.
        elements = [
            element for element in _elements(selected["elements"]) if "type" in element
        ]
        self.assertTrue(elements, "describe-all reported no elements")
        self.assertEqual(
            {key for element in elements for key in element},
            {"type", "children", "label", "frame"},
            "describe-all reported keys it was not asked for",
        )
        self.assertEqual(selected["profile"]["element_count"], len(elements))
        self.assertGreater(selected["profile"]["total_duration_ms"], 0)
        self.assertEqual(selected["frames"]["total"], len(elements))
        self.assertGreater(selected["coverage"]["frame"], 0)

    async def test_ui_describe_all_filtered_to_interactable_reports_only_visible_rows(
        self,
    ) -> None:
        everything = await self.describe_all_complete("axbridge")
        interactable = await self.idb_json(
            "ui",
            "describe-all",
            "--api",
            "axbridge",
            "--format",
            "complete",
            "--filter",
            "interactable",
        )

        visible = _rows_on_screen(everything)
        offscreen_labels = {
            _label(row) for row in _rows(everything) if row["identifier"] not in visible
        }
        self.assertTrue(
            offscreen_labels, "describe-all reported no rows below the screen"
        )
        self.assertEqual(sorted(_row_positions(interactable)), sorted(visible))
        # An offscreen row's label reports a frame in the row's own coordinates,
        # which can place it on screen, so it is matched by name.
        self.assertFalse(
            offscreen_labels & {_label(element) for element in _elements(interactable)},
            "--filter interactable reported the label of a row below the screen",
        )
        _search_field(interactable)

    async def test_ui_describe_resolves_a_point_and_a_marker(self) -> None:
        marker = _label(self.control)
        x, y = _center(self.control)

        self.assertTrue(
            await self.idb_json("ui", "describe-point", str(x), str(y)),
            "describe-point reported nothing under the point",
        )
        self.assertTrue(
            await self.idb_json("ui", "describe", marker),
            f"describe {marker!r} reported nothing",
        )
        document = await self.idb_json(
            "ui", "describe", marker, "--api", "axbridge", "--format", "complete"
        )
        self.assertEqual(document["backend"], AXBRIDGE_BACKEND)
        self.assertTrue(
            _elements(document["elements"]),
            f"{AXBRIDGE_BACKEND} did not resolve the marker {marker!r}",
        )

        axbridge_point = await self.idb_json(
            "ui",
            "describe-point",
            str(x),
            str(y),
            "--api",
            "axbridge",
            "--format",
            "complete",
        )
        self.assertEqual(axbridge_point["backend"], AXBRIDGE_BACKEND)
        self.assertIn(
            marker,
            [_label(element) for element in _elements(axbridge_point["elements"])],
            f"{AXBRIDGE_BACKEND} resolved {(x, y)} to something other than {marker!r}",
        )

        await self.idb_expect_failure(
            "ui",
            "describe",
            "idb-e2e-no-such-element",
            expected_error="found no element whose",
        )

    async def test_ui_wait_blocks_until_the_element_appears(self) -> None:
        title = _label(self.control)
        before = _elements(await self.describe_all_complete("axbridge"))
        self.assertNotIn(title, [element.get("identifier") for element in before])

        async with self.idb_process(
            "ui",
            "wait",
            title,
            "--match-key",
            "AXUniqueId",
            "--timeout",
            str(UI_UPDATE_TIMEOUT_SECONDS),
            "--json",
        ) as waiting:
            await asyncio.sleep(WAIT_BLOCKS_SECONDS)
            self.assertIsNone(waiting.returncode, "wait finished before General opened")
            await self.idb("ui", "tap", GENERAL_ROW_ID, "--match-key", "AXUniqueId")
            result = await waiting.read_some(UI_UPDATE_TIMEOUT_SECONDS)
            self.assertEqual(json.loads(result), {"found": True})
            self.assertEqual(await waiting.wait_for_exit(10), 0)

    async def test_ui_wait_times_out_on_a_missing_element(self) -> None:
        for backend in ("axbridge", "ax"):
            with self.subTest(backend=backend):
                completed = await self.idb_expect_failure(
                    "ui",
                    "wait",
                    "idb-e2e-no-such-element",
                    "--api",
                    backend,
                    "--timeout",
                    "1",
                    "--json",
                    expected_error="timed out after",
                )
                result = json.loads(completed.text)
                self.assertFalse(result["found"])
                self.assertIn("AXLabel", result["error"])
                self.assertIn("idb-e2e-no-such-element", result["error"])
                backend_name = "accessibility" if backend == "ax" else backend
                self.assertEqual(
                    result["error"],
                    f"The {backend_name} backend timed out after 1.0s waiting for an "
                    'element whose AXLabel contains "idb-e2e-no-such-element"',
                )
                diagnostics = result["diagnostics"]
                self.assertIsNone(diagnostics["read_error"])
                self.assertTrue(diagnostics["unmatched_values"])
                self.assertTrue(
                    all(
                        isinstance(value, str)
                        for value in diagnostics["unmatched_values"]
                    )
                )
                self.assertNotIn(
                    "idb-e2e-no-such-element", diagnostics["unmatched_values"]
                )

    async def test_ui_wait_rejects_a_zero_poll_interval(self) -> None:
        rejected = await self.idb_expect_failure(
            "ui",
            "wait",
            GENERAL_ROW_ID,
            "--poll-interval",
            "0",
            "--json",
            expected_error="poll_interval",
        )
        self.assertEqual(rejected.stdout, b"")

    async def wait_for_search_value(self, value: str) -> None:
        async def read() -> None:
            _search_field(await self.describe_all_complete("axbridge"), value)

        await wait_until(
            f"The fixture's search field holding {value!r}",
            UI_UPDATE_TIMEOUT_SECONDS,
            read,
        )

    async def test_ui_set_value_updates_the_search_field(self) -> None:
        field = (await self.wait_for(SEARCH_FIELD, until=Until.SETTLED)).element
        x, y = _center(field)

        completed = await self.idb(
            "ui", "set-value", str(x), str(y), "--value", "idb-first"
        )

        self.assertEqual(completed.stdout, b"")
        await self.wait_for_search_value("idb-first")
        # The first write can give the field the keyboard, so the second is
        # written at wherever the field is once that has settled.
        field = (await self.wait_for(SEARCH_FIELD, until=Until.SETTLED)).element
        x, y = _center(field)
        await self.idb("ui", "set-value", str(x), str(y), "--value", "idb-second")
        await self.wait_for_search_value("idb-second")

    async def defaults(self, *arguments: str) -> bytes:
        completed = await self.simctl.run("spawn", self.udid, "defaults", *arguments)
        self.assertEqual(
            completed.returncode,
            0,
            f"defaults {' '.join(arguments)} failed: {completed.error_text}",
        )
        return completed.stdout

    async def keyboards(self) -> dict[str, Any]:
        """The simulator's keyboard settings, as far as it has any."""
        settings = {}
        for domain in {domain for domain, _ in KEYBOARD_SETTINGS.values()}:
            exported = plistlib.loads(await self.defaults("export", domain, "-"))
            settings.update(
                (key, exported[key])
                for key, (owner, _) in KEYBOARD_SETTINGS.items()
                if owner == domain and key in exported
            )
        return settings

    async def write_keyboards(self, settings: dict[str, Any]) -> None:
        for key, (domain, arguments) in KEYBOARD_SETTINGS.items():
            if key in settings:
                await self.defaults("write", domain, key, *arguments(settings[key]))
            else:
                await self.simctl.run(
                    "spawn", self.udid, "defaults", "delete", domain, key
                )

    async def set_keyboards(self, settings: dict[str, Any]) -> None:
        """Give the simulator the keyboard `settings` and relaunch the fixture.

        An app types on the hardware layout it was launched with, whatever the
        keyboards become afterwards.
        """

        async def write() -> None:
            await self.write_keyboards(settings)
            # A simulator on its first boot writes keyboards of its own, which
            # can land on top of these.
            current = await self.keyboards()
            if current != settings:
                raise NotReady(f"The simulator's keyboards are {current}")

        await wait_until(
            f"The simulator's keyboards being {settings}",
            UI_UPDATE_TIMEOUT_SECONDS,
            write,
        )
        await self.setup_terminate_quietly(FIXTURE_APP_BUNDLE_ID)
        await self.setup_idb("launch", FIXTURE_APP_BUNDLE_ID, FIXTURE_LAUNCH_ARGUMENT)
        self.control = await self.wait_for_control()

    async def test_ui_text_types_on_the_simulators_keyboard_layout(self) -> None:
        # Written back as they were and no more: the next test launches the
        # fixture afresh, and the simulator may be writing keyboards of its own.
        self.addAsyncCleanup(self.write_keyboards, await self.keyboards())
        await self.set_keyboards(
            {
                "AppleKeyboards": [FRENCH_KEYBOARD],
                "AppleKeyboardsExpanded": True,
                "KeyboardLastUsed": FRENCH_KEYBOARD,
            }
        )
        await self.tap_when_settled(SEARCH_FIELD)

        completed = await self.idb("ui", "text", AZERTY_TEXT)

        self.assertEqual(completed.stdout, b"")
        await self.wait_for_search_value(AZERTY_TEXT)
        await self.idb_expect_failure(
            "ui",
            "text",
            "ab日",
            expected_error=(
                "Cannot type the character at offset 2 "
                "on the French hardware keyboard layout"
            ),
        )
        # These are the keys that type "qwerty" on a US keyboard, and they
        # follow straight on from the text: the refused text typed nothing.
        await self.idb("ui", "text", "qwerty", "--layout", "US")
        await self.wait_for_search_value(AZERTY_TEXT + "azerty")

    async def test_ui_tap_refuses_a_mismatched_expected_value(self) -> None:
        title = _label(self.control)

        await self.idb_expect_failure(
            "ui",
            "tap",
            GENERAL_ROW_ID,
            "--match-key",
            "AXUniqueId",
            "--expected-value",
            "idb-e2e-value-it-does-not-have",
            expected_error="before tapping",
        )
        rejected = await self.idb_expect_failure(
            "ui",
            "wait",
            title,
            "--match-key",
            "AXUniqueId",
            "--timeout",
            str(NOTHING_OPENS_TIMEOUT_SECONDS),
            "--json",
            expected_error="timed out after",
        )
        self.assertFalse(
            json.loads(rejected.text)["found"],
            "The rejected tap opened General",
        )

    async def test_ui_tap_by_point_opens_general(self) -> None:
        title = _label(self.control)
        await self.tap_when_settled(GENERAL_ROW, "--api", "ax")
        await self.wait_for(Query(title, element_type="NavigationBar"), lookup=UiWait())

    async def test_ui_tap_by_identifier_opens_general(self) -> None:
        title = _label(self.control)
        await self.idb("ui", "tap", GENERAL_ROW_ID, "--match-key", "AXUniqueId")
        await self.wait_for(Query(title, element_type="NavigationBar"), lookup=UiWait())

    async def test_ui_scroll_moves_rows_down_and_up(self) -> None:
        before = _row_positions(await self.describe_all_complete("axbridge"))

        await self.idb(
            "ui", "scroll", "down", GENERAL_ROW_ID, "--match-key", "AXUniqueId"
        )
        after_down, scrolled = await self.wait_for_scroll(before, "down")

        on_screen = _rows_on_screen(scrolled)
        self.assertTrue(on_screen, "No row is on screen after scrolling down")
        # A row at an edge can sit half under the bar the list scrolls
        # beneath, which is not where a scroll can begin.
        row = on_screen[len(on_screen) // 2]
        await self.idb("ui", "scroll", "up", row, "--match-key", "AXUniqueId")
        await self.wait_for_scroll(after_down, "up")


class SafariTestCase(IdbEndToEndTestCase):
    async def asyncSetUp(self) -> None:
        await super().asyncSetUp()
        await self.setup_deny_permission_prompts()
        await self.setup_terminate_quietly(FIXTURE_APP_BUNDLE_ID)
        self.addAsyncCleanup(self.setup_terminate_quietly, SAFARI_BUNDLE_ID)
        await self.setup_terminate_quietly(SAFARI_BUNDLE_ID)

    async def wait_for_tappable_address_bar(self) -> None:
        """Wait for Safari to draw the address bar, which it settles for a second or two after a page arrives."""
        await self.setup_idb(
            "ui",
            "wait",
            SAFARI_ADDRESS_BAR_ID,
            "--match-key",
            "AXUniqueId",
            "--timeout",
            str(UI_UPDATE_TIMEOUT_SECONDS),
        )

    async def wait_for_address_bar(self) -> None:
        """Wait for the address bar to take the cursor, before anything is typed."""
        await self.setup_idb(
            "ui",
            "wait",
            SAFARI_URL_FIELD_ID,
            "--match-key",
            "AXUniqueId",
            "--api",
            "axbridge",
            "--timeout",
            str(UI_UPDATE_TIMEOUT_SECONDS),
        )

    async def safari_shows_first_page(self, url: str) -> bool:
        """Whether Safari can open this address and draw the page behind it."""
        await self.setup_idb("open", url)
        arrived = await self.setup_idb(
            "ui",
            "wait",
            FIRST_PAGE_HEADING,
            "--match-key",
            "AXLabel",
            "--api",
            "axbridge",
            "--timeout",
            str(UI_UPDATE_TIMEOUT_SECONDS),
            check=False,
        )
        return arrived.returncode == 0

    async def wait_for_web_label(self, label: str) -> None:
        await self.setup_idb(
            "ui",
            "wait",
            label,
            "--match-key",
            "AXLabel",
            "--api",
            "axbridge",
            "--timeout",
            str(UI_UPDATE_TIMEOUT_SECONDS),
        )


class WebContentTests(SafariTestCase):
    capabilities = WEB_CONTENT_TEST_CAPABILITIES

    async def test_ui_describe_all_reads_an_offscreen_web_element(self) -> None:
        pages = LocalPages({FIRST_PAGE_PATH: STAND_IN_PAGES[FIRST_PAGE_PATH]})
        origin = pages.start()
        self.addCleanup(pages.stop)
        await self.idb("open", origin + FIRST_PAGE_PATH)
        await self.wait_for_web_label(FIRST_PAGE_HEADING)

        document = await self.idb_json(
            "ui",
            "describe-all",
            "--api",
            "axbridge",
            "--format",
            "complete",
            "--match",
            FIRST_PAGE_MATCH,
            *LABEL_AND_FRAME_KEYS,
        )

        headings = [
            element
            for element in _elements(document["elements"])
            if _label(element) == FIRST_PAGE_HEADING and _has_area(element)
        ]
        self.assertTrue(headings, f"no {FIRST_PAGE_HEADING!r} heading was reported")
        screen = _screen(document)
        assert screen is not None
        self.assertGreater(
            headings[0]["frame"]["y"],
            screen["height"],
            "the heading is on screen, so this read shows nothing below it",
        )
