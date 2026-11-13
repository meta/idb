#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import json
import sys
from argparse import ArgumentParser, Namespace
from collections.abc import AsyncIterator, Callable
from contextlib import aclosing
from dataclasses import asdict, dataclass
from typing import Any

from idb.cli import ClientCommand
from idb.common.types import (
    ACCESSIBILITY_BACKEND_BY_NAME,
    ACCESSIBILITY_CLIENT_TYPE_BY_NAME,
    ACCESSIBILITY_FILTER_BY_NAME,
    ACCESSIBILITY_FORMAT_BY_NAME,
    ACCESSIBILITY_KEY_BY_NAME,
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
    AccessibilityTarget,
    Client,
    IdbException,
    QUIESCENCE_BACKEND_BY_NAME,
    QuiescenceEvent,
    QuiescenceState,
    QuiescenceStateChanged,
    QuiescenceTargetChanged,
    QuiescenceTargetExited,
    QuiescenceTouchesCompleted,
)


def _looks_int(value: str) -> bool:
    try:
        int(value)
        return True
    except ValueError:
        return False


def _parse_target(
    tokens: list[str], match_key: AccessibilitySearchableKey, depth: int
) -> AccessibilityTarget | None:
    """Interpret positional tokens as an accessibility target: 'x y' coordinates
    (a point), a single marker string, or nothing (the frontmost app). Two integer
    tokens are always read as coordinates, so quote a marker that would otherwise
    look like a coordinate pair (e.g. "42 7")."""
    if len(tokens) == 2 and _looks_int(tokens[0]) and _looks_int(tokens[1]):
        return AccessibilityPoint(x=int(tokens[0]), y=int(tokens[1]))
    if len(tokens) == 1:
        return AccessibilityMarker(value=tokens[0], match_key=match_key, depth=depth)
    if not tokens:
        return None
    raise IdbException(
        "expected 'x y' coordinates, a single marker string, or no target "
        "for the frontmost app"
    )


def _split_endpoints(tokens: list[str]) -> tuple[list[str], list[str]]:
    """Split one positional list into a source and a destination, each of which
    is a `_parse_target` token list: 'x y' coordinates or a single marker.

    Both endpoints are variable-length, so the boundary is found by reading the
    source greedily: two leading integers are a coordinate pair, anything else
    is a one-token marker. That is the same rule `_parse_target` applies, so a
    numeric marker has to be quoted here for the same reason it does in
    `ui tap`, and `"42 7"` quoted is still one marker.

    Four tokens can only be point-to-point and two can only be marker-to-marker,
    so the rule decides nothing there; it only picks which end owns the odd
    token in the three-token case."""
    if len(tokens) < 2:
        raise IdbException(
            "drag-and-drop needs two endpoints: 'x y' coordinates or a marker "
            "for each of the source and the destination"
        )
    if len(tokens) > 4:
        raise IdbException(
            f"drag-and-drop takes two endpoints, but {len(tokens)} tokens were "
            "given; an endpoint is 'x y' coordinates or a single marker, so "
            "quote a marker that contains spaces"
        )
    leading_point = _looks_int(tokens[0]) and _looks_int(tokens[1])
    if len(tokens) == 2 and leading_point:
        # `10 20` is one coordinate pair everywhere else in `idb ui`, so reading
        # it as two numeric markers here would contradict the sibling verbs.
        # It is far more likely to be a dropped destination than a real pair of
        # numeric labels, and the caller who did mean the latter has no way to
        # say so, which is exactly why this is an error rather than a guess.
        pair = f"{tokens[0]} {tokens[1]}"
        raise IdbException(
            f"'{pair}' is a single coordinate pair, and drag-and-drop needs "
            f"two endpoints; add the destination, as in "
            f"'drag-and-drop {pair} X Y'"
        )
    split = 2 if leading_point else 1
    return tokens[:split], tokens[split:]


def _parse_endpoint(
    tokens: list[str],
    name: str,
    match_key: AccessibilitySearchableKey,
    depth: int,
) -> AccessibilityTarget:
    """`_parse_target` for one end of a drag, naming which end failed. The
    empty target the other callers accept (the frontmost app) is not a
    meaningful endpoint, so it is rejected rather than passed on."""
    try:
        target = _parse_target(tokens, match_key=match_key, depth=depth)
    except IdbException as error:
        raise IdbException(f"drag-and-drop {name}: {error}") from error
    if target is None:
        raise IdbException(
            f"drag-and-drop {name}: expected 'x y' coordinates or a marker"
        )
    return target


def _add_enricher_args(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--key",
        action="append",
        dest="keys",
        default=None,
        help="Accessibility key to include (repeatable); all keys if omitted",
    )
    parser.add_argument(
        "--profile",
        action="store_true",
        default=False,
        help=(
            "Collect element counts and timings for the read. Reported by "
            "--format complete only; the other formats collect but have "
            "nowhere to report, so their output is unchanged."
        ),
    )
    parser.add_argument(
        "--collect-frame-coverage",
        action="store_true",
        default=False,
        help=(
            "Collect upper-region frame coverage for the read. Reported by "
            "--format complete only, like --profile."
        ),
    )


def _add_match_args(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--match",
        default=None,
        help=(
            "Report only the elements whose --match-key contains this "
            "substring, instead of every element on the screen. Unlike "
            "describe MARKER, which resolves to a single element and fails "
            "when there is none, this reports every element that matches and "
            "an empty result when none do."
        ),
    )
    parser.add_argument(
        "--match-key",
        choices=list(ACCESSIBILITY_KEY_BY_NAME),
        default="AXLabel",
        help="Which attribute --match searches (default: AXLabel)",
    )
    _add_ignore_case_arg(parser, subject="--match")


def _add_ignore_case_arg(parser: ArgumentParser, subject: str) -> None:
    # One wire field serves both verbs, so the flag is spelled the same on both
    # commands and only its help names which one it is comparing.
    parser.add_argument(
        "--ignore-case",
        action="store_true",
        default=False,
        help=f"Compare {subject} case-insensitively",
    )


def _add_filter_arg(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--filter",
        dest="filter",
        choices=list(ACCESSIBILITY_FILTER_BY_NAME),
        default=None,
        help=(
            "Which elements the read reports: all of them (the default), or "
            "only the interactable ones — those the companion reports as "
            "actionable, or that have a size and carry a label, an "
            "identifier or an actionable role. Either way, an element wholly "
            "outside the screen is left out with everything beneath it."
        ),
    )


def _filter(args: Namespace) -> AccessibilityElementFilter | None:
    name = getattr(args, "filter", None)
    return ACCESSIBILITY_FILTER_BY_NAME[name] if name else None


def _add_client_type_arg(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--client-type",
        dest="client_type",
        choices=list(ACCESSIBILITY_CLIENT_TYPE_BY_NAME),
        default=None,
        help=(
            "The assistive client the read claims to be, which decides what the "
            "application answers with. xctest, xcodeHelper, application, "
            "scripter and systemEvents get the automation tree: every container "
            "and identifier, as XCUITest sees it. It costs roughly ten times the "
            "round trips of a default read, is not a superset of the default "
            "tree, and an app that stores automationElements serves them as "
            "stored. The rest get the flattened tree VoiceOver reads. Unset "
            "claims no client, as reads always have. --format complete reports "
            "the client under `client`."
        ),
    )


def _client_type(args: Namespace) -> AccessibilityClientType | None:
    name = getattr(args, "client_type", None)
    return ACCESSIBILITY_CLIENT_TYPE_BY_NAME[name] if name else None


def _add_backend_arg(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--api",
        choices=list(ACCESSIBILITY_BACKEND_BY_NAME),
        default=None,
        help=(
            "Which backend serves the read or action. ax and ax-coresimulator "
            "read on the host: ax over the companion's own connection to the "
            "simulator's accessibility service, ax-coresimulator through "
            "CoreSimulator's client to the same service. axbridge uses the "
            "companion's private, persistent guest reader, which is the only "
            "one that can see across a process boundary such as web content in "
            "Safari. Reads default to ax; actions default to axbridge. A "
            "companion that predates a backend ignores it and uses the default."
        ),
    )


def _backend(args: Namespace) -> AccessibilityBackend | None:
    # `.get`, not a subscript: `tap` shares this flag with its hid/ax dispatch, so
    # `--api hid` is a value that names no accessibility backend and has to read as
    # no choice rather than raise.
    return ACCESSIBILITY_BACKEND_BY_NAME.get(getattr(args, "api", None) or "")


def action_backend(args: Namespace) -> AccessibilityBackend:
    """The backend serving an action the caller did not choose a backend for.

    Actions default to the guest reader where reads do not: the host backend
    cannot see across a process boundary, so a marker a read resolves through
    axbridge is one the host backend fails to find.
    """
    return _backend(args) or ACCESSIBILITY_BACKEND_BY_NAME["axbridge"]


def _add_format_arg(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--format",
        dest="format",
        choices=list(ACCESSIBILITY_FORMAT_BY_NAME),
        default=None,
        help=(
            "Output format: default (the flat element array), nested (each "
            "element carries its children), or complete (a consolidated "
            "document that also reports which backend served the read, the "
            "target, screen bounds, truncation and any blocking modal). "
            "--nested is a deprecated alias for --format nested. A companion "
            "that predates format selection returns the default format; "
            "requesting complete against one prints a warning."
        ),
    )


def _format(args: Namespace) -> AccessibilityOutputFormat | None:
    name = getattr(args, "format", None)
    if name is None:
        return None
    if args.nested:
        raise IdbException(
            "--nested is a deprecated alias for --format nested; pass one or the other"
        )
    return ACCESSIBILITY_FORMAT_BY_NAME[name]


def _warn_if_complete_downgraded(
    requested: AccessibilityOutputFormat | None, payload: str
) -> None:
    # The complete document is an object naming the backend that served it; a
    # legacy-shaped response to a COMPLETE request means the companion ignored
    # the unknown format value — the one silent skew case, surfaced here.
    if requested != AccessibilityOutputFormat.COMPLETE:
        return
    try:
        document = json.loads(payload)
    except json.JSONDecodeError:
        return
    if isinstance(document, dict) and "backend" in document:
        return
    print(
        "warning: the companion does not support --format complete (it "
        "predates format selection); the read was served in the legacy "
        "format by the default backend",
        file=sys.stderr,
    )


class AccessibilityInfoAllCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Describes Accessibility Information for the entire screen"

    @property
    def name(self) -> str:
        return "describe-all"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--nested",
            help="Will report data in the newer nested format, rather than the flat one",
            action="store_true",
            default=False,
        )
        _add_match_args(parser)
        _add_filter_arg(parser)
        _add_enricher_args(parser)
        _add_backend_arg(parser)
        _add_client_type_arg(parser)
        _add_format_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        requested_format = _format(args)
        info = await client.accessibility_info(
            target=None,
            options=AccessibilityInfoOptions(
                nested=args.nested,
                keys=args.keys,
                backend=_backend(args),
                format=requested_format,
                profile=args.profile,
                collect_frame_coverage=args.collect_frame_coverage,
                match=args.match,
                match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
                ignore_case=args.ignore_case,
                filter=_filter(args),
                client_type=_client_type(args),
            ),
        )
        _warn_if_complete_downgraded(requested_format, info.json)
        print(info.json)


class AccessibilityInfoAtPointCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Describes Accessibility Information at a point on the screen"

    @property
    def name(self) -> str:
        return "describe-point"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--nested",
            help="Will report data in the newer nested format, rather than the flat one",
            action="store_true",
            default=False,
        )
        parser.add_argument("x", help="The x-coordinate", type=int)
        parser.add_argument("y", help="The y-coordinate", type=int)
        _add_enricher_args(parser)
        _add_backend_arg(parser)
        _add_client_type_arg(parser)
        _add_format_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        requested_format = _format(args)
        info = await client.accessibility_info(
            target=AccessibilityPoint(x=args.x, y=args.y),
            options=AccessibilityInfoOptions(
                nested=args.nested,
                keys=args.keys,
                backend=_backend(args),
                format=requested_format,
                profile=args.profile,
                collect_frame_coverage=args.collect_frame_coverage,
                client_type=_client_type(args),
            ),
        )
        _warn_if_complete_downgraded(requested_format, info.json)
        print(info.json)


class AccessibilityDescribeMarkerCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Describe the accessibility element matching a marker"

    @property
    def name(self) -> str:
        return "describe"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "marker",
            help="Marker matched (substring) against the element's --match-key",
        )
        parser.add_argument(
            "--match-key",
            choices=list(ACCESSIBILITY_KEY_BY_NAME),
            default="AXLabel",
            help="Accessibility key to match the marker against",
        )
        parser.add_argument(
            "--depth", type=int, default=10, help="Maximum tree depth to search"
        )
        parser.add_argument(
            "--nested",
            action="store_true",
            default=False,
            help="Report data in the nested format rather than the flat one",
        )
        _add_ignore_case_arg(parser, subject="the marker")
        _add_enricher_args(parser)
        _add_backend_arg(parser)
        _add_client_type_arg(parser)
        _add_format_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        requested_format = _format(args)
        info = await client.accessibility_info(
            target=AccessibilityMarker(
                value=args.marker,
                match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
                depth=args.depth,
            ),
            options=AccessibilityInfoOptions(
                nested=args.nested,
                keys=args.keys,
                backend=_backend(args),
                format=requested_format,
                profile=args.profile,
                collect_frame_coverage=args.collect_frame_coverage,
                ignore_case=args.ignore_case,
                client_type=_client_type(args),
            ),
        )
        _warn_if_complete_downgraded(requested_format, info.json)
        print(info.json)


class AccessibilityWaitCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Wait for an accessibility element matching a marker to appear"

    @property
    def name(self) -> str:
        return "wait"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument("marker", help="Case-sensitive substring to match")
        parser.add_argument(
            "--match-key", choices=list(ACCESSIBILITY_KEY_BY_NAME), default="AXLabel"
        )
        parser.add_argument("--timeout", type=float, default=10.0)
        parser.add_argument("--poll-interval", type=float, default=0.5)
        parser.add_argument(
            "--api", choices=list(ACCESSIBILITY_BACKEND_BY_NAME), default="axbridge"
        )

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        result = await client.accessibility_wait_result(
            target=AccessibilityMarker(
                value=args.marker,
                match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
            ),
            timeout=args.timeout,
            poll_interval=args.poll_interval,
            backend=ACCESSIBILITY_BACKEND_BY_NAME[args.api],
        )
        message = result.message or (
            f"Timed out waiting for {args.match_key} containing {args.marker!r} "
            f"after {args.timeout:g}s"
        )
        if args.json:
            output: dict[str, Any] = {"found": result.found}
            if not result.found:
                output["error"] = message
                if result.diagnostics is not None:
                    output["diagnostics"] = asdict(result.diagnostics)
            print(json.dumps(output))
        if result.found:
            return
        if not args.json and result.diagnostics is not None:
            diagnostics = result.diagnostics
            if diagnostics.read_error is not None:
                message += (
                    f"\nLast poll could not read the tree: {diagnostics.read_error}"
                )
            else:
                sample_truncated = (
                    diagnostics.sample_truncated
                    if diagnostics.sample_truncated is not None
                    else diagnostics.truncated
                )
                suffix = " (truncated)" if sample_truncated else ""
                message += f"\nLast poll's nonmatching {args.match_key} values{suffix}:"
                message += "\n" + (
                    "\n".join(f"  {value!r}" for value in diagnostics.unmatched_values)
                    or "  (none)"
                )
            if diagnostics.read_truncated:
                message += (
                    "\nLast poll's tree read was truncated; "
                    "the marker may be outside it."
                )
        raise IdbException(message)


def _quiescence_text(event: QuiescenceEvent) -> str:
    match event:
        case QuiescenceStateChanged(pid=pid, state=QuiescenceState.BUSY):
            return f"busy ({', '.join(sorted(event.busy_signals))}) (pid {pid})"
        case QuiescenceStateChanged(pid=pid, state=state):
            return f"{state.value} (pid {pid})"
        case QuiescenceTouchesCompleted(pid=pid):
            return f"touches completed (pid {pid})"
        case QuiescenceTargetChanged(pid=pid):
            return f"now following pid {pid}"
        case QuiescenceTargetExited(pid=pid):
            return f"pid {pid} exited"


# The JSON spelling mirrors the companion's event vocabulary.
def _quiescence_json(event: QuiescenceEvent) -> dict[str, Any]:
    match event:
        case QuiescenceStateChanged(pid=pid, state=QuiescenceState.BUSY):
            return {
                "event": "state",
                "state": "busy",
                "signals": sorted(event.busy_signals),
                "pid": pid,
            }
        case QuiescenceStateChanged(pid=pid, state=state):
            return {"event": "state", "state": state.value, "pid": pid}
        case QuiescenceTouchesCompleted(pid=pid):
            return {"event": "touches_completed", "pid": pid}
        case QuiescenceTargetChanged(pid=pid):
            return {"event": "target_changed", "pid": pid}
        case QuiescenceTargetExited(pid=pid):
            return {"event": "target_exited", "pid": pid}


async def _quiescence_answer(
    events: AsyncIterator[QuiescenceEvent],
    emit: Callable[[QuiescenceEvent], None],
    answers: set[QuiescenceState],
) -> QuiescenceState:
    async for event in events:
        emit(event)
        if isinstance(event, QuiescenceTargetExited):
            raise IdbException(
                f"The application with pid {event.pid} exited before it went quiet"
            )
        if isinstance(event, QuiescenceStateChanged) and event.state in answers:
            return event.state
    raise IdbException("The quiescence stream ended without reporting a state")


# Returns the last state reported once the duration elapses; a duration of None
# watches until interrupted.
async def _quiescence_watch(
    events: AsyncIterator[QuiescenceEvent],
    emit: Callable[[QuiescenceEvent], None],
    duration: float | None,
) -> QuiescenceState | None:
    last: QuiescenceState | None = None

    async def consume() -> None:
        nonlocal last
        async for event in events:
            emit(event)
            if isinstance(event, QuiescenceTargetExited):
                raise IdbException(f"The application with pid {event.pid} exited")
            if isinstance(event, QuiescenceStateChanged):
                last = event.state
            elif isinstance(event, QuiescenceTargetChanged):
                last = None
        raise IdbException("The quiescence stream ended")

    try:
        await asyncio.wait_for(consume(), duration)
    except asyncio.TimeoutError:
        pass
    return last


def _validate_quiet_arguments(args: Namespace) -> None:
    timeout = args.timeout
    if timeout is not None and not 0 <= timeout < float("inf"):
        raise IdbException(
            f"The timeout must be a finite value of 0 or greater (got {timeout})"
        )
    for flag, value in (
        ("--busy-threshold-ms", args.busy_threshold_ms),
        ("--quiet-window-ms", args.quiet_window_ms),
    ):
        if value is not None and value < 0:
            raise IdbException(f"{flag} must be 0 or greater (got {value})")


@dataclass(frozen=True)
class _QuietNow:
    pass


# A timeout of None waits for as long as it takes.
@dataclass(frozen=True)
class _QuietWait:
    timeout: float | None


# A duration of None watches until interrupted.
@dataclass(frozen=True)
class _QuietWatch:
    duration: float | None


def _quiet_wait(
    timeout: float | None, watch: bool
) -> _QuietNow | _QuietWait | _QuietWatch:
    # The command line spells "no limit" as 0; that spelling ends here.
    if timeout is None:
        if watch:
            raise IdbException(
                "--watch needs a timeout: seconds to watch for, or 0 to watch "
                "until interrupted"
            )
        return _QuietNow()
    if watch:
        return _QuietWatch(duration=timeout or None)
    return _QuietWait(timeout=timeout or None)


class AccessibilityQuietCommand(ClientCommand):
    @property
    def description(self) -> str:
        return (
            "Report whether an application's UI is quiet: its run loop idle and no "
            "animations running. Without a timeout, exits 0 if quiet now and 1 if "
            "busy. With a timeout, exits 0 as soon as it is quiet and 1 if the "
            "timeout elapses first. A timeout of 0 waits for as long as it takes. "
            "With --watch, keeps reporting events once the application is quiet "
            "until the timeout elapses (or, with 0, until interrupted), then exits "
            "0 if the last state was quiet, 1 otherwise."
        )

    @property
    def name(self) -> str:
        return "quiet"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "timeout",
            nargs="?",
            type=float,
            help="Seconds to wait for the application to go quiet, or 0 to wait for "
            "as long as it takes. Omit to report the state now.",
        )
        parser.add_argument(
            "--watch",
            action="store_true",
            help="Keep reporting events once the application is quiet, until the "
            "timeout elapses (or, with 0, until interrupted). Requires a timeout.",
        )
        target = parser.add_mutually_exclusive_group()
        target.add_argument(
            "--pid",
            type=int,
            help="Measure an application by process id, instead of following the "
            "frontmost app",
        )
        target.add_argument(
            "--bundle-id",
            help="Measure an application by bundle id, instead of following the "
            "frontmost app",
        )
        parser.add_argument(
            "--api",
            choices=list(QUIESCENCE_BACKEND_BY_NAME),
            default="axbridge",
            help="What measures the application. axbridge reads the accessibility "
            "runtime's idle notifications. shimulator asks the app itself, through "
            "idb's shim: launch the app through idb with IDB_IDLE_SYNC=1 in its "
            "environment (IDB_IDB_IDLE_SYNC=1 in the client's). With no --pid or "
            "--bundle-id it measures the one armed app.",
        )
        parser.add_argument(
            "--busy-threshold-ms",
            type=int,
            help="Milliseconds a signal may go unanswered before the application "
            "counts as busy; with --api shimulator, the shortest main-thread work "
            "that makes it busy (default: the companion's)",
        )
        parser.add_argument(
            "--quiet-window-ms",
            type=int,
            help="Milliseconds every signal must stay answered before the "
            "application counts as quiet (default: the companion's, or 0 when "
            "reporting the state now)",
        )

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        _validate_quiet_arguments(args)
        timeout = args.timeout

        def emit(line: str, output: dict[str, Any]) -> None:
            print(json.dumps(output, sort_keys=True) if args.json else line, flush=True)

        def emit_event(event: QuiescenceEvent) -> None:
            emit(_quiescence_text(event), _quiescence_json(event))

        wait = _quiet_wait(timeout, args.watch)
        # Reporting now, "quiet now" means idle on the first probe, not idle for a
        # window the caller did not ask to wait for.
        quiet_window_ms = args.quiet_window_ms
        if isinstance(wait, _QuietNow) and quiet_window_ms is None:
            quiet_window_ms = 0
        events = client.accessibility_quiescence(
            pid=args.pid,
            bundle_id=args.bundle_id,
            busy_threshold_ms=args.busy_threshold_ms,
            quiet_window_ms=quiet_window_ms,
            backend=QUIESCENCE_BACKEND_BY_NAME[args.api],
        )
        async with aclosing(events):
            if isinstance(wait, _QuietNow):
                state = await _quiescence_answer(
                    events, emit_event, {QuiescenceState.BUSY, QuiescenceState.QUIET}
                )
                if state == QuiescenceState.QUIET:
                    return
                raise SystemExit(1)
            if isinstance(wait, _QuietWatch):
                last = await _quiescence_watch(events, emit_event, wait.duration)
                if last == QuiescenceState.QUIET:
                    return
                raise SystemExit(1)
            try:
                await asyncio.wait_for(
                    _quiescence_answer(events, emit_event, {QuiescenceState.QUIET}),
                    wait.timeout,
                )
            except asyncio.TimeoutError:
                emit(
                    f"not quiet within {timeout}s",
                    {"event": "timed_out", "timeout": timeout},
                )
                raise SystemExit(1)


class AccessibilityScrollCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Scroll an accessibility element (or the frontmost app)"

    @property
    def name(self) -> str:
        return "scroll"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "direction",
            choices=[d.name.lower() for d in AccessibilityScrollDirection],
            help="Scroll direction",
        )
        parser.add_argument(
            "target",
            nargs="*",
            help="Optional 'x y' coordinates or a single marker; omit to target "
            "the frontmost app. Two integers are read as coordinates — quote a "
            "marker that looks like a coordinate pair.",
        )
        parser.add_argument(
            "--match-key",
            choices=list(ACCESSIBILITY_KEY_BY_NAME),
            default="AXLabel",
            help="Accessibility key to match a marker against",
        )
        parser.add_argument(
            "--depth", type=int, default=10, help="Maximum tree depth to search"
        )
        _add_ignore_case_arg(parser, subject="the marker")
        _add_backend_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        target = _parse_target(
            args.target,
            match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
            depth=args.depth,
        )
        await client.accessibility_scroll(
            target=target,
            direction=AccessibilityScrollDirection[args.direction.upper()],
            ignore_case=args.ignore_case,
            backend=action_backend(args),
        )


class AccessibilitySetValueCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Set the accessibility value of an element"

    @property
    def name(self) -> str:
        return "set-value"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "target",
            nargs="+",
            help="'x y' coordinates or a single marker string",
        )
        parser.add_argument("--value", required=True, help="The value to set")
        parser.add_argument(
            "--match-key",
            choices=list(ACCESSIBILITY_KEY_BY_NAME),
            default="AXLabel",
            help="Accessibility key to match a marker against",
        )
        parser.add_argument(
            "--depth", type=int, default=10, help="Maximum tree depth to search"
        )
        _add_ignore_case_arg(parser, subject="the marker")
        _add_backend_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        target = _parse_target(
            args.target,
            match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
            depth=args.depth,
        )
        if target is None:
            raise IdbException("set-value requires 'x y' coordinates or a marker")
        await client.accessibility_set_value(
            target=target,
            value=args.value,
            ignore_case=args.ignore_case,
            backend=action_backend(args),
        )


class AccessibilityDragAndDropCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Press an element, drag it to another, and release"

    @property
    def name(self) -> str:
        return "drag-and-drop"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "endpoints",
            nargs="+",
            metavar=("SOURCE", "DESTINATION"),
            help="Source and destination for the drag, in that order. Specify "
            "each as either two integer coordinates ('X Y') or one accessibility "
            "marker. Examples: '10 20 30 40' drags from (10, 20) to (30, 40); "
            "'Photo Album' drags from marker Photo to marker Album; and 'Photo "
            "30 40' drags from marker Photo to (30, 40). Quote marker names that "
            "contain spaces.",
        )
        parser.add_argument(
            "--match-key",
            choices=list(ACCESSIBILITY_KEY_BY_NAME),
            default="AXLabel",
            help="Accessibility key to match the source marker against",
        )
        parser.add_argument(
            "--depth", type=int, default=10, help="Maximum tree depth to search"
        )
        parser.add_argument(
            "--to-match-key",
            choices=list(ACCESSIBILITY_KEY_BY_NAME),
            default=None,
            help="Accessibility key to match the destination marker against "
            "(default: --match-key)",
        )
        parser.add_argument(
            "--to-depth",
            type=int,
            default=None,
            help="Maximum tree depth to search for the destination (default: --depth)",
        )
        parser.add_argument(
            "--press-duration",
            type=float,
            default=None,
            help="Seconds to hold the source before moving (default: 0.5). This "
            "hold is what makes the gesture a drag rather than a flick.",
        )
        parser.add_argument(
            "--duration",
            type=float,
            default=None,
            help="Seconds the movement itself takes (default: 0.5)",
        )
        parser.add_argument(
            "--release-duration",
            type=float,
            default=None,
            help="Seconds to hold the destination before releasing (default: 0.1)",
        )
        parser.add_argument(
            "--delta",
            type=float,
            default=None,
            help="Distance in points between interpolated touch points (default: "
            "10). A delta at or above the distance dragged is rejected: it moves "
            "in one jump, which reads as a flick.",
        )
        _add_ignore_case_arg(parser, subject="the markers")
        _add_backend_arg(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        source_tokens, destination_tokens = _split_endpoints(args.endpoints)
        source = _parse_endpoint(
            source_tokens,
            "source",
            match_key=ACCESSIBILITY_KEY_BY_NAME[args.match_key],
            depth=args.depth,
        )
        destination = _parse_endpoint(
            destination_tokens,
            "destination",
            match_key=ACCESSIBILITY_KEY_BY_NAME[args.to_match_key or args.match_key],
            depth=args.to_depth if args.to_depth is not None else args.depth,
        )
        await client.accessibility_drag(
            source=source,
            destination=destination,
            options=AccessibilityDragOptions(
                press_duration=args.press_duration,
                duration=args.duration,
                release_duration=args.release_duration,
                delta=args.delta,
            ),
            ignore_case=args.ignore_case,
            backend=action_backend(args),
        )
