# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Run idb commands through one shared companion against a booted simulator.

The caller supplies DEVICE_UDID, DEVICE_SET_PATH, IDB_BIN,
IDB_E2E_COMPANION_PATH and IDB_E2E_RECORDER_PATH, and IDB_E2E_REPL_PATH for the
tests that drive idb-repl. The harness starts the companion
and applies the configured suite capability; it does not manage the simulator lifecycle.
"""

from __future__ import annotations

import asyncio
import atexit
import base64
import enum
import hashlib
import http.server
import json
import logging
import os
import plistlib
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from collections.abc import AsyncIterator, Collection, Mapping, Sequence
from contextlib import AbstractAsyncContextManager, asynccontextmanager, ExitStack
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Awaitable, BinaryIO, Callable, NoReturn, TypeVar

from .documentation import (
    demo_for,
    normalisation_rules,
    normalise,
    test_identity,
    Transcript,
)
from .recording import ENCODING_ENV, Recording

DEVICE_UDID_ENV = "DEVICE_UDID"
DEVICE_SET_PATH_ENV = "DEVICE_SET_PATH"
IDB_BIN_ENV = "IDB_BIN"
IDB_ARGS_ENV = "IDB_ARGS"
IDB_E2E_COMPANION_PATH_ENV = "IDB_E2E_COMPANION_PATH"
IDB_SETUP_BIN_ENV = "IDB_SETUP_BIN"
SUITE_CAPABILITY_ENV = "IDB_E2E_SUITE_CAPABILITY"
IDB_E2E_RECORDER_PATH_ENV = "IDB_E2E_RECORDER_PATH"
IDB_E2E_REPL_PATH_ENV = "IDB_E2E_REPL_PATH"
STRICT_ENV = "IDB_E2E_STRICT"
ARTIFACTS_ENV = "IDB_E2E_ARTIFACTS_DIR"
ROUTE_ATTESTATION_ENV = "IDB_E2E_ROUTER_ATTESTATION"
EXPECTED_IMPLEMENTATION_ENV = "IDB_E2E_EXPECTED_IMPLEMENTATION"
CLAIM_KIND_ENV = "IDB_E2E_CLAIM_KIND"
# The bridge protocol version a guest speaks: `BridgeRequest.currentVersion`. A guest refuses any other.
GUEST_PROTOCOL_VERSION = 7


def tagged_answers(result: dict[str, Any]) -> list[tuple[str, Any]]:
    """A result's answers as (kind, what it holds) pairs.

    Each answer is its kind keyed to one named field holding the answer.
    """
    answers = []
    for answer in result["answers"]:
        ((kind, payload),) = answer.items()
        ((_, value),) = payload.items()
        answers.append((kind, value))
    return answers


def reported_answers(result: dict[str, Any]) -> list[Any]:
    """A result's answers, each as the JSON object the host reports.

    A network store's contents travel as the base64 of the property list the
    store holds.
    """
    answers = []
    for kind, value in tagged_answers(result):
        if kind == "networkConfiguration":
            value = plistlib.loads(
                base64.b64decode(value["propertyList"], validate=True)
            )
        answers.append(value)
    return answers


T = TypeVar("T")

_LOGGER: logging.Logger = logging.getLogger(__name__)

# ReplHost.app ships with the companion, so installation tests need no extra app.
FIXTURE_APP_NAME = "ReplHost.app"
FIXTURE_APP_BUNDLE_ID = "com.facebook.idb.replhost"

# Hosts without SimLaunchHostService cannot spawn simulator processes.
HOST_SERVICE_UNAVAILABLE_MARKERS = (
    "SimLaunchHostService.RequestError",
    "Exit Code 149 is not acceptable",
)

# Match the connection error emitted by idb/grpc/client.py.
COMPANION_UNREACHABLE_MARKERS = ("Failed to connect to companion",)

# The simulator's accessibility service named no element: nothing was read or
# written. Retryable while the simulator starts, and for a read at any time.
# Older companions print the first wording; current ones name the read made.
ACCESSIBILITY_NOT_READY_MARKERS = (
    "No translation object returned",
    "No accessibility element at (",
    "The simulator's accessibility service named no frontmost application",
    "The simulator's accessibility service has no application with pid ",
    "The simulator's accessibility service no longer has this element",
)
ACCESSIBILITY_PROBE_ARGS = ("ui", "describe-all", "--json")

# idb's answers when the accessibility tree was momentarily out of step with a
# command, rather than wrong about it.
# Older companions print the first wording. The last is the simulator's
# accessibility service, rather than the application, running out of time.
UNANSWERED = re.compile(
    r"requested accessibility from the application (?:with pid \d+|at that point), "
    r"which did not answer in time"
    r"|The application (?:with pid \d+|at that point) did not respond to an "
    r"accessibility request before it timed out"
    r"|The simulator's accessibility service did not answer "
)
# Older companions print the first marker.
NOTHING_WRITTEN_MARKERS = (
    "nothing was written. Read the tree again and retry",
    "moved before the write, so nothing was written",
)
# The line idb prints after a failure's message saying whether the command is
# safe to send again, in its text and `--json` forms. Clients and companions
# that predate it print no such line.
# Every command reads the tree afresh, so repeating one is the reread that
# `safe_after_reread` asks for. A verdict not listed here, from a newer idb,
# is treated as no verdict at all.
REPEATABLE_VERDICTS = frozenset({"safe", "safe_after_reread"})
RETRY_VERDICT = re.compile(r"^retry: (\S+) \(\S+\)$", re.MULTILINE)
RETRY_VERDICT_JSON = re.compile(
    r'^\{"retry": "([^"]+)", "retry_reason": "[^"]+"\}$', re.MULTILINE
)
ELEMENT_NOT_FOUND_MARKER = "found no element whose"
# SpringBoard's permission prompts vary their buttons by service and by app --
# Photos offers "Limit Access…" and "Allow Full Access" where camera offers a
# plain "Allow" -- but every shape offers this one.
PERMISSION_PROMPT_DENY_LABELS = frozenset({"Don’t Allow", "Don't Allow"})
UI_UPDATE_TIMEOUT_SECONDS = 30.0
# The least a wait gives one read, so one begun as the wait's time runs out can
# still answer.
MIN_READ_TIMEOUT_SECONDS = 10.0
# Consecutive reads that must agree on an element's frame before it has
# settled. Fewer than the three JestE2E asks for, since SpringBoard withdraws
# a notification banner about eight seconds after it arrives.
SETTLED_READS = 2
READ_COMMANDS = frozenset(
    {
        ("ui", "describe"),
        ("ui", "describe-all"),
        ("ui", "describe-point"),
    }
)
# The commands that can be repeated when idb cannot say whether they ran: reads,
# and a write that sets a value rather than adding to one.
REPEATABLE_COMMANDS = READ_COMMANDS | {("ui", "set-value")}

POLL_INTERVAL_SECONDS = 1.0
TRANSIENT_ANSWER_TIMEOUT_SECONDS = 60.0

COMPANION_READY_TIMEOUT_SECONDS = 180.0
ACCESSIBILITY_READY_TIMEOUT_SECONDS = 180.0
DEFAULT_COMMAND_TIMEOUT_SECONDS = 120.0
# The first injection compiles a dylib with swiftc, which takes far longer
# than any idb command.
REPL_COMMAND_TIMEOUT_SECONDS = 300.0
INSTALL_TIMEOUT_SECONDS = 300.0
ROUTE_ATTESTATION_TIMEOUT_SECONDS = 10.0
APP_STATE_TIMEOUT_SECONDS = 60.0
# Well above what a healthy simctl read takes, and short enough to leave an
# app-state wait time to try again after one that hangs.
SIMCTL_POLL_TIMEOUT_SECONDS = 20.0
PROCESS_GROUP_GRACE_SECONDS = 2.0


def _process_group_alive(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    return True


def _signal_process_group(process_group: int, process_signal: int) -> None:
    try:
        os.killpg(process_group, process_signal)
    except ProcessLookupError:
        pass


async def _wait_for_process_group_exit(process_group: int, timeout: float) -> bool:
    deadline = Deadline(timeout)
    while _process_group_alive(process_group):
        if deadline.passed:
            return False
        await asyncio.sleep(min(POLL_INTERVAL_SECONDS / 10, max(deadline.remaining, 0)))
    return True


def _wait_for_process_group_exit_sync(process_group: int, timeout: float) -> bool:
    deadline = Deadline(timeout)
    while _process_group_alive(process_group):
        if deadline.passed:
            return False
        time.sleep(min(POLL_INTERVAL_SECONDS / 10, max(deadline.remaining, 0)))
    return True


class HarnessError(Exception):
    """Test setup or a harness operation failed."""


class CommandTimedOut(HarnessError):
    """A command did not finish within its timeout and was killed."""


class CompanionDied(HarnessError):
    """The shared companion exited; stop the remaining tests."""


class NotReady(Exception):
    """Retry this poll because the expected condition is not met yet."""


class NoExactMatch(NotReady):
    """A read answered, but with no element exactly the one a query is for."""


class Deadline:
    """Track elapsed time using a monotonic clock."""

    def __init__(self, seconds: float) -> None:
        self.seconds = seconds
        self._at = time.monotonic() + seconds

    @property
    def remaining(self) -> float:
        return self._at - time.monotonic()

    @property
    def passed(self) -> bool:
        return self.remaining <= 0


async def wait_until(what: str, timeout: float, poll: Callable[[], Awaitable[T]]) -> T:
    """Retry on NotReady until the timeout; propagate other exceptions.

    The timeout is checked between polls. Each poll must bound its own runtime.
    """
    deadline = Deadline(timeout)
    while True:
        try:
            return await poll()
        except NotReady as not_ready:
            if deadline.passed:
                raise HarnessError(
                    f"{what} within {timeout:.0f}s: {not_ready}"
                ) from None
        await asyncio.sleep(POLL_INTERVAL_SECONDS)


async def run_with_registered_cleanup(
    register_cleanup: Callable[[Callable[[], Awaitable[None]]], None],
    cleanup: Callable[[], Awaitable[object]],
    operation: Callable[[], Awaitable[T]],
) -> T:
    """Register recovery before starting an operation, then run it exactly once."""

    async def registered_cleanup() -> None:
        await cleanup()

    register_cleanup(registered_cleanup)
    return await operation()


class FailureKind(enum.Enum):
    COMMAND = enum.auto()
    COMPANION_UNREACHABLE = enum.auto()
    HOST_SERVICE_UNAVAILABLE = enum.auto()


class SuiteCapability(enum.Enum):
    COMPANION_PROCESS = "companion-process"
    LONG_LIVED_STREAM = "long-lived-stream"
    PROCESS_CONTROL = "process-control"
    ARTIFACT_PUBLICATION = "artifact-publication"
    TARGET_MUTATION = "target-mutation"
    ACCESSIBILITY_READ = "accessibility-read"
    ACCESSIBILITY_INTERACTION = "accessibility-interaction"


_SUITE_CAPABILITY_RANK = {
    capability: rank for rank, capability in enumerate(SuiteCapability)
}
_ACCESSIBILITY_CAPABILITIES = frozenset(
    {
        SuiteCapability.ACCESSIBILITY_READ,
        SuiteCapability.ACCESSIBILITY_INTERACTION,
    }
)


def classify_failure(completed: Completed) -> FailureKind:
    for marker in COMPANION_UNREACHABLE_MARKERS:
        if marker in completed.error_text:
            return FailureKind.COMPANION_UNREACHABLE
    for marker in HOST_SERVICE_UNAVAILABLE_MARKERS:
        if marker in completed.error_text:
            return FailureKind.HOST_SERVICE_UNAVAILABLE
    return FailureKind.COMMAND


def retry_verdict(completed: Completed) -> str | None:
    """The `retry` verdict idb gave a failed command, or None if it gave none."""
    match = RETRY_VERDICT.search(completed.error_text) or RETRY_VERDICT_JSON.search(
        completed.error_text
    )
    return match[1] if match else None


def accessibility_not_ready(completed: Completed) -> bool:
    return any(
        marker in completed.error_text for marker in ACCESSIBILITY_NOT_READY_MARKERS
    )


def worth_repeating(args: Sequence[str], completed: Completed) -> bool:
    """Whether a failed idb command is a transient answer it is safe to repeat.

    Nothing was written, so anything can be repeated. An application that did
    not answer is repeated when idb's retry verdict allows; without one it
    knows, a write's outcome is taken as unknown, so only a command that does the same
    thing when run twice is. A tree that was not ready yet is repeated only
    for a read, since a write's target may not be where it was.
    """
    if completed.returncode == 0:
        return False
    if any(marker in completed.error_text for marker in NOTHING_WRITTEN_MARKERS):
        return True
    if accessibility_not_ready(completed):
        return tuple(args[:2]) in READ_COMMANDS
    if UNANSWERED.search(completed.error_text) is None:
        return False
    verdict = retry_verdict(completed)
    if verdict in REPEATABLE_VERDICTS:
        return True
    if verdict == "unsafe":
        return False
    return tuple(args[:2]) in REPEATABLE_COMMANDS


def strict() -> bool:
    return os.environ.get(STRICT_ENV) == "1"


def expected_implementation(
    *, required: bool = False, override: str | None = None
) -> str | None:
    value = (
        override
        if override is not None
        else os.environ.get(EXPECTED_IMPLEMENTATION_ENV)
    )
    if value is None:
        if required:
            raise HarnessError(
                f"{EXPECTED_IMPLEMENTATION_ENV} is not set; route attestation is mandatory"
            )
        return None
    if value not in {"python", "rust"}:
        source = (
            "expected implementation"
            if override is not None
            else EXPECTED_IMPLEMENTATION_ENV
        )
        raise HarnessError(f"{source}={value!r} is not 'python' or 'rust'")
    return value


def verify_route_attestation(path: Path, expected: str) -> None:
    try:
        actual = path.read_text().strip()
    except FileNotFoundError:
        raise NotReady(f"the route attestation file does not exist at {path}") from None
    except OSError as error:
        raise HarnessError(
            f"the {expected} lane route attestation at {path} is unreadable: {error}"
        ) from None
    if not actual:
        raise NotReady(f"the route attestation file is not complete at {path}")
    if actual != expected:
        raise HarnessError(f"the {expected} lane executed the {actual} sidecar")


def require_route_attestation(path: Path, expected: str) -> None:
    """Verify a final attestation where a pending value is a terminal failure."""
    try:
        verify_route_attestation(path, expected)
    except NotReady as error:
        raise HarnessError(
            f"the {expected} lane did not complete route attestation at {path}: {error}"
        ) from None


def suite_capability() -> SuiteCapability:
    configured = os.environ.get(SUITE_CAPABILITY_ENV)
    if configured is None:
        return SuiteCapability.ACCESSIBILITY_INTERACTION
    try:
        return SuiteCapability(configured)
    except ValueError:
        expected = ", ".join(capability.value for capability in SuiteCapability)
        raise HarnessError(
            f"{SUITE_CAPABILITY_ENV}={configured!r} is not one of: {expected}"
        ) from None


def suite_supports(required: SuiteCapability) -> bool:
    return (
        _SUITE_CAPABILITY_RANK[required] <= _SUITE_CAPABILITY_RANK[suite_capability()]
    )


def select_tests_for_capability(
    loader: unittest.TestLoader,
    tests: unittest.TestSuite,
    test_case: type[unittest.TestCase],
    requirements: Mapping[str, SuiteCapability],
) -> unittest.TestSuite:
    names = loader.getTestCaseNames(test_case)
    if set(names) != set(requirements):
        raise HarnessError(
            f"Capability requirements for {test_case.__name__} do not match its tests"
        )
    selected = [name for name in names if suite_supports(requirements[name])]
    if selected == names:
        return tests
    return unittest.TestSuite(test_case(name) for name in selected)


@dataclass(frozen=True)
class Completed:
    returncode: int
    stdout: bytes
    stderr: bytes

    @property
    def text(self) -> str:
        return self.stdout.decode(errors="replace")

    @property
    def error_text(self) -> str:
        return self.stderr.decode(errors="replace")


async def _terminate_run_process(
    process: asyncio.subprocess.Process,
    communication: asyncio.Task[tuple[bytes | None, bytes | None]],
    argv: Sequence[str],
) -> None:
    survived = False
    _signal_process_group(process.pid, int(signal.SIGTERM))
    try:
        await asyncio.wait_for(
            asyncio.shield(communication), PROCESS_GROUP_GRACE_SECONDS
        )
    except asyncio.TimeoutError:
        pass
    if not await _wait_for_process_group_exit(process.pid, PROCESS_GROUP_GRACE_SECONDS):
        _signal_process_group(process.pid, _KILL_SIGNAL)
        survived = not await _wait_for_process_group_exit(
            process.pid, PROCESS_GROUP_GRACE_SECONDS
        )
    if process.returncode is None:
        try:
            await asyncio.wait_for(process.wait(), PROCESS_GROUP_GRACE_SECONDS)
        except asyncio.TimeoutError:
            survived = True
    if not communication.done():
        communication.cancel()
    await asyncio.gather(communication, return_exceptions=True)
    if survived:
        raise HarnessError(f"{' '.join(argv)} descendants survived forced termination")


async def _terminate_run_process_reliably(
    process: asyncio.subprocess.Process,
    communication: asyncio.Task[tuple[bytes | None, bytes | None]],
    argv: Sequence[str],
) -> None:
    termination = asyncio.create_task(
        _terminate_run_process(process, communication, argv)
    )
    interrupted: asyncio.CancelledError | None = None
    while not termination.done():
        try:
            await asyncio.shield(termination)
        except asyncio.CancelledError as error:
            interrupted = error
    termination.result()
    if interrupted is not None:
        raise interrupted


async def run(
    argv: Sequence[str],
    timeout: float,
    stdin: bytes | None = None,
    env: Mapping[str, str] | None = None,
) -> Completed:
    # A spawned guest can retain pipes after simctl exits, preventing pipe EOF.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        process = await asyncio.create_subprocess_exec(
            *argv,
            env=env,
            stdin=asyncio.subprocess.PIPE
            if stdin is not None
            else asyncio.subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        communication = asyncio.create_task(process.communicate(stdin))
        timed_out = False
        try:
            await asyncio.wait_for(asyncio.shield(communication), timeout)
        except asyncio.TimeoutError:
            timed_out = True
            await _terminate_run_process_reliably(process, communication, argv)
        except BaseException:
            await _terminate_run_process_reliably(process, communication, argv)
            raise
        if timed_out:
            raise CommandTimedOut(
                f"{' '.join(argv)} did not finish within {timeout:.0f}s"
            ) from None
        stdout.seek(0)
        stderr.seek(0)
        return Completed(process.returncode or 0, stdout.read(), stderr.read())


async def run_attested_client(
    argv: Sequence[str],
    timeout: float,
    stdin: bytes | None = None,
    *,
    env: Mapping[str, str] | None = None,
    expected: str | None = None,
    attestation_path: Path | None = None,
    required: bool = False,
) -> Completed:
    """Run one command with a fresh route attestation when configured."""
    implementation = expected_implementation(required=required, override=expected)
    if implementation is None:
        if env is None:
            return await run(argv, timeout=timeout, stdin=stdin)
        return await run(argv, timeout=timeout, stdin=stdin, env=env)

    async def run_at(attestation: Path) -> Completed:
        if attestation.exists():
            raise HarnessError(
                f"stale route attestation already existed at {attestation}"
            )
        child_environment = dict(os.environ) if env is None else dict(env)
        child_environment[ROUTE_ATTESTATION_ENV] = str(attestation)
        completed = await run(
            argv,
            timeout=timeout,
            stdin=stdin,
            env=child_environment,
        )
        try:
            verify_route_attestation(attestation, implementation)
        except NotReady as error:
            raise HarnessError(
                f"the {implementation} lane exited before completing route attestation at "
                f"{attestation}: {error}; client return code {completed.returncode}; "
                f"stderr: {completed.error_text or '<empty>'}"
            ) from None
        return completed

    if attestation_path is not None:
        return await run_at(attestation_path)
    with tempfile.TemporaryDirectory(prefix="idb-e2e-route-") as directory:
        return await run_at(Path(directory) / "selected")


async def wait_for_route_attestation(
    path: Path,
    expected: str,
    process: IdbProcess,
    timeout: float = ROUTE_ATTESTATION_TIMEOUT_SECONDS,
) -> None:
    """Wait for a live process to atomically attest its selected route."""
    deadline = Deadline(timeout)
    while True:
        try:
            actual = path.read_text().strip()
        except FileNotFoundError:
            actual = None
        except OSError as error:
            raise HarnessError(
                f"the {expected} lane route attestation at {path} could not be read: "
                f"{error}"
            ) from error
        if actual:
            if actual != expected:
                raise HarnessError(f"the {expected} lane executed the {actual} sidecar")
            if process.returncode is not None:
                stderr = process.stderr_capture.tail.decode(errors="replace")
                raise HarnessError(
                    f"the {expected} lane exited with {process.returncode} immediately "
                    f"after route attestation; stderr: {stderr or '<empty>'}"
                )
            return
        if process.returncode is not None:
            stderr = process.stderr_capture.tail.decode(errors="replace")
            raise HarnessError(
                f"the {expected} lane exited with {process.returncode} before route "
                f"attestation; stderr: {stderr or '<empty>'}"
            )
        if deadline.passed:
            detail = "only an empty" if actual == "" else "no"
            raise HarnessError(
                f"the {expected} lane produced {detail} route attestation at {path} "
                f"within {timeout:.0f}s"
            )
        await asyncio.sleep(POLL_INTERVAL_SECONDS)


@asynccontextmanager
async def attested_process(
    argv: Sequence[str],
    what: str,
    *,
    display_argv: Sequence[str] | None = None,
    failure: Callable[[str], NoReturn] | None = None,
    recording: Recording | None = None,
    config: IdbProcessConfig | None = None,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    required: bool = False,
    attestation_timeout: float = ROUTE_ATTESTATION_TIMEOUT_SECONDS,
) -> AsyncIterator[IdbProcess]:
    """Construct and clean up one process with fresh route attestation."""
    expected = expected_implementation(required=required)
    if expected is None:
        async with IdbProcess(
            argv,
            what,
            display_argv=display_argv,
            failure=failure,
            recording=recording,
            config=config,
            env=env,
            cwd=cwd,
        ) as process:
            yield process
        return
    with tempfile.TemporaryDirectory(prefix="idb-e2e-route-") as directory:
        attestation = Path(directory) / "selected"
        if attestation.exists():
            raise HarnessError(
                f"stale route attestation already existed at {attestation}"
            )
        child_environment = dict(os.environ) if env is None else dict(env)
        child_environment[ROUTE_ATTESTATION_ENV] = str(attestation)
        async with IdbProcess(
            argv,
            what,
            display_argv=display_argv,
            failure=failure,
            recording=recording,
            config=config,
            env=child_environment,
            cwd=cwd,
        ) as process:
            await wait_for_route_attestation(
                attestation,
                expected,
                process,
                timeout=attestation_timeout,
            )
            yield process


class Simctl:
    """Read simulator state independently of idb."""

    def __init__(self, udid: str, device_set_path: Path) -> None:
        self.udid = udid
        self.device_set_path = device_set_path

    def argv(self, *args: str) -> list[str]:
        return ["xcrun", "simctl", "--set", str(self.device_set_path), *args]

    async def run(self, *args: str, timeout: float = 60.0) -> Completed:
        return await run(self.argv(*args), timeout=timeout)

    async def state(self) -> str | None:
        completed = await self.run("list", "-j", "devices")
        if completed.returncode != 0:
            return None
        return _device_states(json.loads(completed.stdout)).get(self.udid)

    async def installed_bundle_ids(self, timeout: float = 60.0) -> set[str]:
        completed = await self.run("listapps", self.udid, timeout=timeout)
        if completed.returncode != 0:
            raise HarnessError(
                f"simctl listapps failed (rc={completed.returncode}): {completed.error_text}"
            )
        # listapps writes an old-style plist, which json cannot read.
        try:
            converted = await run(
                ["plutil", "-convert", "json", "-o", "-", "-"],
                timeout=60.0,
                stdin=completed.stdout,
            )
        except CommandTimedOut as timed_out:
            # Only a hung simctl is worth another poll, so a hung plutil must not read as one.
            raise HarnessError(str(timed_out)) from None
        if converted.returncode != 0:
            raise HarnessError(
                f"simctl listapps output could not be converted to JSON "
                f"(rc={converted.returncode}): {converted.error_text}"
            )
        return set(json.loads(converted.stdout).keys())

    async def running_bundle_ids(self, timeout: float = 60.0) -> set[str]:
        completed = await self.run(
            "spawn", self.udid, "launchctl", "list", timeout=timeout
        )
        if completed.returncode != 0:
            raise HarnessError(
                f"simctl could not list the simulator's services "
                f"(rc={completed.returncode}): {completed.error_text}"
            )
        return running_bundle_ids_from_listing(completed.text)

    async def app_container(self, bundle_id: str, kind: str = "data") -> Path:
        completed = await self.run("get_app_container", self.udid, bundle_id, kind)
        if completed.returncode != 0:
            raise HarnessError(
                f"simctl has no {kind} container for {bundle_id} "
                f"(rc={completed.returncode}): {completed.error_text}"
            )
        path = completed.text.strip()
        if not path:
            raise HarnessError(f"simctl reported no {kind} container for {bundle_id}")
        return Path(path)


class AppState(enum.Enum):
    """What an app is, as simctl reports it independently of idb."""

    # launchctl lists a live UIKitApplication job for it, or does not.
    RUNNING = "running"
    STOPPED = "stopped"
    # simctl listapps includes it, or does not.
    INSTALLED = "installed"
    ABSENT = "absent"


# A stopped launchd job remains in the listing with `-` instead of a PID. Only
# positive-PID UIKitApplication rows prove that an application is still alive.
_APPLICATION_LINE = re.compile(
    r"(?m)^\s*([1-9][0-9]*)\s+\S+\s+UIKitApplication:([^\[\s]+)"
)


def running_bundle_ids_from_listing(listing: str) -> set[str]:
    """The bundle ids of apps with live processes in a launchctl listing."""
    return {bundle_id for _, bundle_id in _APPLICATION_LINE.findall(listing)}


def _device_states(listing: dict[str, Any]) -> dict[str, str]:
    states: dict[str, str] = {}
    for devices in listing.get("devices", {}).values():
        for device in devices:
            states[device["udid"]] = device.get("state", "")
    return states


class Environment:
    def __init__(
        self,
        udid: str,
        device_set_path: Path,
        idb_bin: Path,
        idb_args: Sequence[str],
        setup_idb_bin: Path,
        companion_path: Path,
        recorder_path: Path,
        protected_package: tempfile.TemporaryDirectory[str] | None = None,
        repl_path: Path | None = None,
    ) -> None:
        self.udid = udid
        self.device_set_path = device_set_path
        self.idb_bin = idb_bin
        self.idb_args = tuple(idb_args)
        self.setup_idb_bin = setup_idb_bin
        self.companion_path = companion_path
        self.recorder_path = recorder_path
        self.repl_path = repl_path
        self._protected_package = protected_package
        self.simctl = Simctl(udid, device_set_path)

    @property
    def fixture_app(self) -> Path:
        return self.companion_path.parent / "Resources" / FIXTURE_APP_NAME

    @property
    def guest_binary(self) -> Path:
        return self.companion_path.parent / "Resources" / "SimulatorFrameworkBridge-iOS"

    @classmethod
    async def resolve(cls) -> "Environment":
        idb_bin = _binary_from_environment(IDB_BIN_ENV)
        protected_package = None
        if os.environ.get(CLAIM_KIND_ENV) == "synthetic_installed":
            idb_bin, protected_package = _protect_synthetic_package(idb_bin)
        idb_args = shlex.split(os.environ.get(IDB_ARGS_ENV, ""))
        setup_idb_bin = _optional_binary_from_environment(IDB_SETUP_BIN_ENV, idb_bin)
        companion_path = _binary_from_environment(IDB_E2E_COMPANION_PATH_ENV)
        recorder_path = _binary_from_environment(IDB_E2E_RECORDER_PATH_ENV)
        repl = os.environ.get(IDB_E2E_REPL_PATH_ENV)
        repl_path = _executable(Path(repl), IDB_E2E_REPL_PATH_ENV) if repl else None
        udid = _required(DEVICE_UDID_ENV, "the booted simulator to test against")
        device_set_path = Path(
            _required(DEVICE_SET_PATH_ENV, f"the device set {DEVICE_UDID_ENV} lives in")
        )
        if not device_set_path.is_dir():
            raise HarnessError(
                f"{DEVICE_SET_PATH_ENV}={device_set_path} is not a directory"
            )

        simctl = Simctl(udid, device_set_path)
        state = await simctl.state()
        if state is None:
            raise HarnessError(
                f"{DEVICE_UDID_ENV}={udid} is not present in {device_set_path}"
            )
        if state != "Booted":
            raise HarnessError(
                f"{DEVICE_UDID_ENV}={udid} must already be booted; it is {state}"
            )
        return cls(
            udid,
            device_set_path,
            idb_bin,
            idb_args,
            setup_idb_bin,
            companion_path,
            recorder_path,
            protected_package,
            repl_path,
        )


def _required(name: str, meaning: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise HarnessError(f"{name} is not set; it names {meaning}.")
    return value


def _optional_binary_from_environment(name: str, default: Path) -> Path:
    value = os.environ.get(name)
    return default if not value else _executable(Path(value), name)


def _binary_from_environment(name: str) -> Path:
    return _executable(Path(_required(name, "a binary this suite drives")), name)


def _protect_synthetic_package(
    idb_bin: Path,
) -> tuple[Path, tempfile.TemporaryDirectory[str]]:
    temporary = tempfile.TemporaryDirectory(
        prefix="idb-e2e-package-", dir=Path("/tmp").resolve()
    )
    package = Path(temporary.name) / "bin"
    package.mkdir()
    try:
        for source in idb_bin.parent.iterdir():
            if source.is_file():
                shutil.copy2(source, package / source.name)
        for name in (
            "idb",
            "idb-python",
            "idb-router-engine",
            "idb-router-guard",
            "idb-rust",
        ):
            child = package / name
            if not child.is_file():
                raise HarnessError(f"the synthetic package has no {name} executable")
            child.chmod(0o555)
        package.chmod(0o555)
    except BaseException:
        temporary.cleanup()
        raise
    return package / idb_bin.name, temporary


def on_disk_path(path: Path) -> Path:
    """The path as the filesystem spells it, component by component.

    A simulator's `launchd_sim` resolves a program path case-sensitively, even
    where the filesystem beneath it does not, and answers a spelling it does not
    recognise with `LaunchdSimError 111 / Invalid or missing
    Program/ProgramArguments` -- its answer for a path that does not exist.
    Nothing on the host side distinguishes the two: opening, stat and code
    signing all accept either spelling. So a binary about to be spawned in the
    guest is named the way the directory that holds it is named.

    A component matching nothing, or matching more than one entry on a
    case-sensitive filesystem, is left as it was given: there is no single
    spelling to prefer, and the caller's own checks decide what happens next.
    """
    on_disk = Path(path.anchor)
    for component in path.relative_to(path.anchor).parts:
        entries = []
        try:
            entries = os.listdir(on_disk)
        except OSError:
            pass
        if component not in entries:
            matches = [e for e in entries if e.lower() == component.lower()]
            component = matches[0] if len(matches) == 1 else component
        on_disk = on_disk / component
    return on_disk


def _executable(path: Path, name: str) -> Path:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise HarnessError(f"{name}={path} is not an executable file")
    # abspath rather than resolve: the spelling is what matters here, and
    # following symlinks would answer with a path the caller never named.
    return on_disk_path(Path(os.path.abspath(path)))


def artifact_directory() -> Path | None:
    value = os.environ.get(ARTIFACTS_ENV) or os.environ.get("TEST_RESULT_ARTIFACTS_DIR")
    if not value:
        return None
    directory = Path(value)
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def _prepare_artifact_file(path: Path) -> None:
    path.touch()
    # Older companions preserve an existing mode but create logs too narrowly
    # for the remote artifact uploader to read after the test exits.
    path.chmod(0o644)


HOST_LOAD_FILE_NAME = "host-load.txt"
HOST_LOAD_INTERVAL_SECONDS = 5.0
HOST_LOAD_SAMPLE_TIMEOUT_SECONDS = 30.0
# Two samples a second apart, because top's first sample has no per-process CPU.
HOST_LOAD_ARGV = (
    "top",
    "-l",
    "2",
    "-s",
    "1",
    "-o",
    "cpu",
    "-n",
    "15",
    "-stats",
    "pid,command,cpu,mem",
)


def last_top_sample(output: bytes) -> bytes:
    start = output.rfind(b"Processes:")
    return output if start < 0 else output[start:]


def sample_top() -> bytes:
    try:
        completed = subprocess.run(
            HOST_LOAD_ARGV,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            timeout=HOST_LOAD_SAMPLE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return f"top did not finish within {HOST_LOAD_SAMPLE_TIMEOUT_SECONDS:.0f}s\n".encode()
    except OSError as error:
        return f"top could not run: {error}\n".encode()
    if completed.returncode != 0:
        return (
            f"top failed (rc={completed.returncode}): ".encode()
            + completed.stderr
            + b"\n"
        )
    return last_top_sample(completed.stdout)


class HostLoad:
    """Record the host's CPU, memory and busiest processes throughout the run.

    A simulator that stalls otherwise looks the same as a host that has run out
    of CPU or memory. Sampled from a thread, because each test replaces the
    event loop.
    """

    def __init__(
        self,
        path: Path,
        sample: Callable[[], bytes] = sample_top,
        interval: float = HOST_LOAD_INTERVAL_SECONDS,
    ) -> None:
        _prepare_artifact_file(path)
        self.path = path
        self._sample = sample
        self._interval = interval
        self._stopping = threading.Event()
        self._thread = threading.Thread(target=self._run, name="host-load", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        warned = False
        while True:
            taken = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            sample = self._sample()
            try:
                with self.path.open("ab") as log:
                    log.write(f"=== {taken}\n".encode() + sample)
            except OSError as error:
                # A write can fail transiently, e.g. on a full disk; keep sampling.
                if not warned:
                    _LOGGER.warning(
                        "Could not record host load to %s: %s", self.path, error
                    )
                    warned = True
            if self._stopping.wait(self._interval):
                return

    def stop(self) -> None:
        self._stopping.set()
        self._thread.join(timeout=HOST_LOAD_SAMPLE_TIMEOUT_SECONDS)


# Without a push certificate, as on a CI host, apsd reconnects to Apple's push
# service without backing off: a third of the simulator's log and a steady share
# of a core for the whole run. Pushes sent through simctl do not go through it.
PUSH_SERVICE_TARGET = "system/com.apple.apsd"
PUSH_SERVICE_STOP_TIMEOUT_SECONDS = 30.0


async def stop_push_service(simctl: Simctl) -> None:
    """Stop apsd in the simulator, carrying on with a warning if it can't be."""
    try:
        completed = await simctl.run(
            "spawn",
            simctl.udid,
            "launchctl",
            "bootout",
            PUSH_SERVICE_TARGET,
            timeout=PUSH_SERVICE_STOP_TIMEOUT_SECONDS,
        )
    except HarnessError as error:
        _LOGGER.warning("Could not stop apsd in the simulator: %s", error)
        return
    if completed.returncode != 0:
        _LOGGER.warning(
            "Could not stop apsd in the simulator (rc=%d): %s",
            completed.returncode,
            completed.error_text,
        )


class Companion:
    """Share a companion across tests.

    Use Popen because IsolatedAsyncioTestCase replaces the event loop after
    each test, while the companion must keep running.
    """

    def __init__(self, environment: Environment, *, cwd: Path | None = None) -> None:
        # Use /tmp to stay within the Unix socket path limit on macOS.
        self.directory = Path(tempfile.mkdtemp(prefix="idb-e2e-", dir="/tmp"))
        self.socket_path = self.directory / "companion.sock"
        artifacts = artifact_directory()
        self.log_path = (
            artifacts / f"{self.directory.name}-companion.log"
            if artifacts is not None
            else self.directory / "companion.log"
        )
        _prepare_artifact_file(self.log_path)
        self._stopped = False
        self.process = subprocess.Popen(
            [
                str(environment.companion_path.resolve()),
                "--udid",
                environment.udid,
                "--device-set-path",
                str(environment.device_set_path),
                "--grpc-domain-sock",
                str(self.socket_path),
                "--log-file-path",
                str(self.log_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            cwd=None if cwd is None else str(cwd),
            start_new_session=True,
        )
        try:
            self.address = self._wait_until_ready()
        except BaseException:
            self.stop()
            raise

    def _wait_until_ready(self) -> str:
        # The companion reports readiness as a JSON line containing grpc_path.
        stdout = self.process.stdout
        assert stdout is not None
        deadline = Deadline(COMPANION_READY_TIMEOUT_SECONDS)
        while True:
            remaining = deadline.remaining
            if remaining <= 0:
                raise HarnessError(
                    f"The companion did not report ready within "
                    f"{deadline.seconds:.0f}s; log: {self.log_excerpt()}"
                )
            if self.process.poll() is not None:
                raise HarnessError(
                    f"The companion exited with {self.process.returncode} before "
                    f"reporting ready; log: {self.log_excerpt()}"
                )
            ready, _, _ = select.select(
                [stdout], [], [], min(remaining, POLL_INTERVAL_SECONDS)
            )
            if not ready:
                continue
            line = stdout.readline()
            if not line:
                continue
            try:
                report = json.loads(line)
            except ValueError:
                continue
            path = report.get("grpc_path") if isinstance(report, dict) else None
            if path:
                return str(path)

    def died(self) -> CompanionDied | None:
        """Return an error with the exit code and log if the companion exited."""
        returncode = self.process.poll()
        if returncode is None:
            return None
        return CompanionDied(
            f"The companion exited with {returncode}; stopping the test suite.\n"
            f"companion log: {self.log_excerpt()}"
        )

    def status_description(self) -> str:
        returncode = self.process.poll()
        if returncode is None:
            return "the companion is still running"
        return f"the companion exited with {returncode}"

    def log_excerpt(self, limit: int = 4000) -> str:
        try:
            return self.log_path.read_text(errors="replace")[-limit:]
        except OSError:
            return "<no companion log>"

    def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        process_group = self.process.pid
        forced = False
        try:
            _signal_process_group(process_group, int(signal.SIGTERM))
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    pass
            if _process_group_alive(process_group):
                _signal_process_group(process_group, _KILL_SIGNAL)
                forced = True
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired as error:
                    raise HarnessError(
                        "companion survived forced process-group termination"
                    ) from error
            if forced and not _wait_for_process_group_exit_sync(process_group, 15):
                raise HarnessError(
                    "companion descendants survived forced process-group termination"
                )
        finally:
            if self.process.stdout is not None:
                self.process.stdout.close()


def client_argv(
    idb_bin: Path,
    idb_args: Sequence[str],
    companion_address: str,
    *args: str,
) -> list[str]:
    return [str(idb_bin), *idb_args, "--companion", companion_address, *args]


def idb_argv(environment: Environment, companion: Companion, *args: str) -> list[str]:
    return client_argv(
        environment.idb_bin,
        environment.idb_args,
        companion.address,
        *args,
    )


async def wait_for_accessibility(
    environment: Environment, companion: Companion
) -> None:
    """Wait for an accessibility read before running tests.

    A booted simulator may not have an accessibility translation object yet.
    """

    async def probe() -> None:
        completed = await run(
            idb_argv(environment, companion, *ACCESSIBILITY_PROBE_ARGS),
            timeout=DEFAULT_COMMAND_TIMEOUT_SECONDS,
        )
        if completed.returncode == 0:
            return
        kind = classify_failure(completed)
        if kind is FailureKind.HOST_SERVICE_UNAVAILABLE:
            # Let individual tests report the unavailable service as a skip or failure.
            return
        if kind is not FailureKind.COMMAND or not accessibility_not_ready(completed):
            raise HarnessError(
                f"Accessibility setup failed: "
                f"idb {' '.join(ACCESSIBILITY_PROBE_ARGS)} "
                f"(rc={completed.returncode}): {completed.error_text}"
            )
        raise NotReady("no accessibility translation object")

    await wait_until(
        "The simulator did not begin serving accessibility reads",
        ACCESSIBILITY_READY_TIMEOUT_SECONDS,
        probe,
    )


_environment: Environment | None = None
_companion: Companion | None = None
_recording: Recording | None = None
_host_load: HostLoad | None = None
_acquisition_failure: BaseException | None = None


async def shared_environment() -> Environment:
    """Validate the environment once and cache any setup failure."""
    global _environment, _acquisition_failure
    if _acquisition_failure is not None:
        raise _acquisition_failure
    if _environment is None:
        try:
            _environment = await Environment.resolve()
        except BaseException as error:
            _acquisition_failure = error
            raise
        _start_host_load()
        await stop_push_service(_environment.simctl)
    return _environment


def _start_host_load() -> None:
    global _host_load
    artifacts = artifact_directory()
    if _host_load is not None or artifacts is None:
        return
    _host_load = HostLoad(artifacts / HOST_LOAD_FILE_NAME)
    atexit.register(_host_load.stop)


async def shared_companion() -> Companion:
    global _companion, _acquisition_failure
    capability = suite_capability()
    if _acquisition_failure is not None:
        raise _acquisition_failure
    if _companion is None:
        environment = await shared_environment()
        try:
            companion = Companion(environment)
        except BaseException as error:
            _acquisition_failure = error
            raise
        try:
            if capability in _ACCESSIBILITY_CAPABILITIES:
                await wait_for_accessibility(environment, companion)
        except BaseException as error:
            companion.stop()
            _acquisition_failure = error
            raise
        _companion = companion
        atexit.register(companion.stop)
    return _companion


async def shared_recording(environment: Environment, companion: Companion) -> Recording:
    global _recording
    if _recording is None:
        _recording = Recording(
            environment.recorder_path,
            environment.udid,
            environment.device_set_path,
            artifact_directory() or companion.directory,
            companion.directory.name,
            os.environ.get(ENCODING_ENV) or "auto",
        )
        atexit.register(_recording.close_logs)
        atexit.register(_recording.stop)
        await _recording.wait_until_ready()
    return _recording


LOOPBACK_ADDRESS = "127.0.0.1"


class LocalPages:
    """A fixed set of pages served over loopback, keyed by request path."""

    def __init__(self, pages: Mapping[str, str]) -> None:
        self._pages = dict(pages)
        self._server: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> str:
        """Serve the pages on an arbitrary free port, and answer their origin."""
        pages = self._pages

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _respond(self, body: bytes | None) -> None:
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_HEAD(self) -> None:
                page = pages.get(self.path)
                self._respond(None if page is None else b"")

            def do_GET(self) -> None:
                page = pages.get(self.path)
                self._respond(None if page is None else page.encode())

            def log_message(self, format: str, *args: Any) -> None:
                logging.debug("local pages " + format, *args)

        server = http.server.ThreadingHTTPServer((LOOPBACK_ADDRESS, 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self._server = server
        self._thread = thread
        # Addressed by the same literal it is bound to: a name would leave the
        # simulator to resolve it, and it can resolve to an address nothing is
        # listening on.
        return f"http://{LOOPBACK_ADDRESS}:{server.server_address[1]}"

    def stop(self) -> None:
        if self._server is None:
            return
        self._server.shutdown()
        self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        self._server = None
        self._thread = None


def _elements(node: Any) -> list[dict[str, Any]]:
    """Flatten flat, nested and complete accessibility output into its elements.

    Only a document's `elements` and an element's `children` hold elements. Other
    dictionaries can carry an identifier and a frame without being one, such as
    the element that `interactable` says takes a touch aimed at this one.
    """
    if isinstance(node, list):
        return [element for child in node for element in _elements(child)]
    if not isinstance(node, dict):
        return []
    if "elements" in node:
        return _elements(node["elements"])
    return [node, *_elements(node.get("children"))]


def _placed(
    node: Any, ancestors: tuple[dict[str, Any], ...] = ()
) -> list[tuple[dict[str, Any], tuple[dict[str, Any], ...]]]:
    """Every element of accessibility output, with the elements it sits inside."""
    if isinstance(node, list):
        return [placed for child in node for placed in _placed(child, ancestors)]
    if not isinstance(node, dict):
        return []
    if "elements" in node:
        return _placed(node["elements"], ancestors)
    return [(node, ancestors), *_placed(node.get("children"), (*ancestors, node))]


def _describe_matches(document: Any, matches: Callable[[dict[str, Any]], bool]) -> str:
    """Every element of `document` that `matches` accepts, and how they differ.

    Elements that share an identifier can be a control and a container around
    it, or one element the tree reports twice. Where each sits, and every field
    the matches report differently, are what tell those apart.
    """
    found = [placed for placed in _placed(document) if matches(placed[0])]
    lines = [f"{len(found)} matching element{'' if len(found) == 1 else 's'}:"]
    for index, (element, ancestors) in enumerate(found, 1):
        path = " > ".join(str(ancestor.get("type")) for ancestor in ancestors)
        line = f"  [{index}] under {path or 'the root'}"
        for other, (container, _) in enumerate(found, 1):
            if ancestors and container is ancestors[-1]:
                line += f", a child of [{other}]"
            elif any(container is ancestor for ancestor in ancestors):
                line += f", inside [{other}]"
        lines.append(line)
    fields = [
        {key: value for key, value in element.items() if key != "children"}
        for element, _ in found
    ]
    keys = list(dict.fromkeys(key for own in fields for key in own))
    differing = [
        key
        for key in keys
        if len({json.dumps(own.get(key), sort_keys=True) for own in fields}) > 1
    ]
    if len(found) == 1:
        differing = keys
    elif differing:
        lines.append("They differ in:")
    for key in differing:
        values = " ".join(
            f"[{index}] {json.dumps(own.get(key), sort_keys=True)}"
            for index, own in enumerate(fields, 1)
        )
        lines.append(f"  {key}: {values}")
    agreeing = [key for key in keys if key not in differing]
    if agreeing:
        lines.append(f"They agree on: {', '.join(agreeing)}")
    return "\n".join(lines)


def _label(element: dict[str, Any]) -> str:
    """Read the label from legacy output (AXLabel) or complete output (label)."""
    for key in ("AXLabel", "label"):
        value = element.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _has_area(element: dict[str, Any]) -> bool:
    frame = element.get("frame")
    return (
        isinstance(frame, dict)
        and bool(frame.get("width"))
        and bool(frame.get("height"))
    )


def _screen(document: Any) -> dict[str, float] | None:
    """The bounds of the screen everything in a document sits on.

    A complete document says which screen it was read from. One that does not
    is measured by its largest frame, which is only the screen when the tree
    holds nothing larger: a list's background can extend well above the
    window, and the application's own frame can be reported in pixels.
    """
    reported = document.get("screen") if isinstance(document, dict) else None
    if isinstance(reported, dict) and reported.get("width") and reported.get("height"):
        return {
            "x": 0.0,
            "y": 0.0,
            "width": float(reported["width"]),
            "height": float(reported["height"]),
        }
    frames = [element["frame"] for element in _elements(document) if _has_area(element)]
    if not frames:
        return None
    return max(frames, key=lambda frame: frame["width"] * frame["height"])


def _on_screen(element: dict[str, Any], screen: dict[str, float] | None) -> bool:
    """Something a viewer can see: it has area, is not hidden, and is on the screen.

    The accessibility tree holds what an app has built, not what is in front of
    the viewer: a row scrolled out of the window, a zero-sized placeholder and a
    hidden element are all in it. A demo is a recording of a screen, so what it
    claims to show has to be on that screen.
    """
    if screen is None or not _has_area(element) or element.get("hidden") is True:
        return False
    frame = element["frame"]
    return (
        frame["x"] < screen["x"] + screen["width"]
        and frame["y"] < screen["y"] + screen["height"]
        and frame["x"] + frame["width"] > screen["x"]
        and frame["y"] + frame["height"] > screen["y"]
    )


def _wholly_on_screen(element: dict[str, Any], screen: dict[str, float] | None) -> bool:
    """On the screen from edge to edge, so a touch at its centre lands on it.

    A banner sliding in, or a row half scrolled away, overlaps the screen
    while its centre is still off it.
    """
    if not _on_screen(element, screen):
        return False
    assert screen is not None
    frame = element["frame"]
    return (
        frame["x"] >= screen["x"]
        and frame["y"] >= screen["y"]
        and frame["x"] + frame["width"] <= screen["x"] + screen["width"]
        and frame["y"] + frame["height"] <= screen["y"] + screen["height"]
    )


def _center(element: dict[str, Any]) -> tuple[int, int]:
    frame = element["frame"]
    return (
        int(frame["x"] + frame["width"] / 2),
        int(frame["y"] + frame["height"] / 2),
    )


def _permission_prompt_button(
    document: Any, labels: Collection[str]
) -> dict[str, Any] | None:
    for element in _elements(document):
        if (
            element.get("role") == "AXButton"
            and _label(element) in labels
            and _has_area(element)
        ):
            return element
    return None


class MatchKey(enum.Enum):
    """An accessibility key a query matches, and the field a complete read reports it in."""

    IDENTIFIER = ("AXUniqueId", "identifier")
    LABEL = ("AXLabel", "label")

    def __init__(self, flag: str, field: str) -> None:
        self.flag = flag
        self.field = field


class AccessibilityApi(enum.Enum):
    AX = "ax"
    AXBRIDGE = "axbridge"


class Until(enum.Enum):
    """What an element has to be before a wait for it is over."""

    PRESENT = "reported"
    ON_SCREEN = "wholly on screen"
    # Wholly on screen, with the same frame on SETTLED_READS reads in a row.
    SETTLED = "settled on screen"


@dataclass(frozen=True)
class Describe:
    """Find an element by polling `ui describe`, every answer to which carries it."""


@dataclass(frozen=True)
class UiWait:
    """Let `ui wait` find an element first, through `api` or else the query's own.

    `ui wait` only answers whether the element is there, so `ui describe`
    reads still decide everything else.
    """

    api: AccessibilityApi | None = None


# How a wait finds an element before reading it.
Lookup = Describe | UiWait
DESCRIBE = Describe()


@dataclass(frozen=True)
class Query:
    """One element, as a wait addresses it."""

    value: str
    match_key: MatchKey = MatchKey.IDENTIFIER
    element_type: str | None = None
    api: AccessibilityApi = AccessibilityApi.AXBRIDGE

    @property
    def marker_args(self) -> tuple[str, ...]:
        return (
            self.value,
            "--match-key",
            self.match_key.flag,
            "--api",
            self.api.value,
        )

    def matches(self, element: dict[str, Any]) -> bool:
        """`ui describe` matches a substring; a query is for exactly this element."""
        return element.get(self.match_key.field) == self.value and (
            self.element_type is None or element.get("type") == self.element_type
        )

    def describe_keys(self, keys: Sequence[str]) -> tuple[str, ...]:
        """`keys`, with what `matches` and a frame check read added.

        `--key` drops every attribute not asked for, so a narrowed read has to
        ask for these too or no element in it could match.
        """
        if not keys:
            return ()
        needed = (self.match_key.flag, "frame") + (
            ("type",) if self.element_type is not None else ()
        )
        return tuple(dict.fromkeys((*keys, *needed)))

    def __str__(self) -> str:
        return (
            f"the {self.element_type or 'element'} whose "
            f"{self.match_key.flag} is {self.value!r}"
        )


@dataclass(frozen=True)
class Found:
    """An element, and the read of it that ended a wait."""

    element: dict[str, Any]
    document: dict[str, Any]


class UnexpectedAnswer(Exception):
    """A read failed for a reason waiting longer would not change."""

    def __init__(self, completed: Completed) -> None:
        super().__init__(completed.error_text)
        self.completed = completed


class ElementWait:
    """What successive reads of one query have shown, against the condition a wait needs."""

    def __init__(self, query: Query, until: Until) -> None:
        self.query = query
        self.until = until
        self._frame: dict[str, Any] | None = None
        self._agreeing = 0

    def observe(self, completed: Completed) -> Found:
        """The element and its read, once the reads so far satisfy the condition.

        Raises NotReady while they do not, and UnexpectedAnswer for a failure
        that is neither a missing element nor a transient answer.
        """
        if completed.returncode != 0:
            if ELEMENT_NOT_FOUND_MARKER in completed.error_text:
                self._agreeing = 0
                raise NotReady(f"{self.query} is not reported")
            if worth_repeating(("ui", "describe"), completed):
                # Reads either side of it were not in a row, so it cannot
                # settle anything.
                self._agreeing = 0
                raise NotReady(f"a transient answer: {completed.error_text.strip()}")
            raise UnexpectedAnswer(completed)
        document = json.loads(completed.text)
        exact = [
            element for element in _elements(document) if self.query.matches(element)
        ]
        if not exact:
            self._agreeing = 0
            raise NoExactMatch(f"{self.query} is not among the elements reported")
        # Which of several matches the wait follows is what goes wrong when
        # the query is ambiguous, so each message names them all.
        described = (
            f"; {_describe_matches(document, self.query.matches)}"
            if len(exact) > 1
            else ""
        )
        matches = [element for element in exact if _has_area(element)]
        if not matches:
            self._agreeing = 0
            raise NotReady(f"{self.query} is not reported with a frame{described}")
        if self.until is Until.PRESENT:
            return Found(matches[0], document)
        screen = _screen(document)
        on_screen = [
            element for element in matches if _wholly_on_screen(element, screen)
        ]
        if not on_screen:
            self._agreeing = 0
            raise NotReady(
                f"{self.query} is at {matches[0]['frame']}, not wholly on the "
                f"screen {screen}{described}"
            )
        element = on_screen[0]
        if self.until is Until.ON_SCREEN:
            return Found(element, document)
        if element["frame"] == self._frame:
            self._agreeing += 1
        else:
            self._frame = element["frame"]
            self._agreeing = 1
        if self._agreeing < SETTLED_READS:
            raise NotReady(
                f"{self.query} is still moving, now at {self._frame}{described}"
            )
        return Found(element, document)


class IdbEndToEndTestCase(unittest.IsolatedAsyncioTestCase):
    """Run CLI tests against the shared companion and simulator."""

    environment: Environment
    companion: Companion
    recording: Recording | None = None
    requires_route_attestation = False
    # The capability each test needs, when a class's tests need more than the
    # rest of the suite. Every test in such a class must have an entry.
    capabilities: Mapping[str, SuiteCapability] | None = None
    route_attestation_timeout_seconds = ROUTE_ATTESTATION_TIMEOUT_SECONDS
    resolve_process_executable = False

    # Set only while a documented demo is running, which is what makes a named
    # command capture its output.
    transcript: Transcript | None = None

    # Keep the result so companion death can stop the remaining tests.
    _result: unittest.TestResult | None = None

    def run(self, result: unittest.TestResult | None = None) -> Any:
        self._result = result if result is not None else self.defaultTestResult()
        counts = self._result_counts()
        started = time.monotonic()
        try:
            return super().run(self._result)
        finally:
            if self.recording is not None:
                status = next(
                    (
                        name
                        for name, count in self._result_counts().items()
                        if count > counts[name]
                    ),
                    "passed",
                )
                self.recording.finish_test(status)
                self.recording.event(
                    "test_duration", seconds=time.monotonic() - started
                )

    def _result_counts(self) -> dict[str, int]:
        assert self._result is not None
        return {
            "error": len(self._result.errors),
            "failed": len(self._result.failures),
            "unexpected_success": len(self._result.unexpectedSuccesses),
            "skipped": len(self._result.skipped),
            "expected_failure": len(self._result.expectedFailures),
        }

    async def asyncSetUp(self) -> None:
        self.skip_without_capability()
        await super().asyncSetUp()
        self.environment = await shared_environment()
        self.companion = await shared_companion()
        self.recording = await shared_recording(self.environment, self.companion)
        self.recording.start_test(test_identity(self.id()))
        self.start_demo()
        self.check_companion()

    def skip_without_capability(self) -> None:
        if self.capabilities is None:
            return
        required = self.capabilities.get(self._testMethodName)
        if required is None:
            raise HarnessError(
                f"No suite capability owns {type(self).__name__}.{self._testMethodName}"
            )
        if not suite_supports(required):
            self.skipTest(
                f"{self._testMethodName} requires {required.value} capability"
            )

    async def wait_or_fail(
        self, what: str, timeout: float, poll: Callable[[], Awaitable[T]]
    ) -> T:
        """`wait_until`, reporting a wait that runs out as this test's failure."""
        try:
            return await wait_until(what, timeout, poll)
        except HarnessError as error:
            self.fail(str(error))

    def start_demo(self) -> None:
        demo = demo_for(self)
        if demo is None or self.recording is None:
            return
        home = os.environ.get("HOME")
        self.recording.demo(
            demo.slug,
            demo.title,
            demo.summary,
            source=demo.source,
            line=demo.line,
        )
        self.transcript = Transcript(
            normalisation_rules(
                self.environment.udid,
                self.environment.device_set_path,
                self.companion.directory,
                artifacts=artifact_directory(),
                home=Path(home) if home else None,
                temporary_directory=Path(tempfile.gettempdir()),
            )
        )

    async def asyncTearDown(self) -> None:
        # Stop capturing before teardown so its screenshot and cleanup commands
        # stay out of the published transcript.
        self.transcript = None
        if self.recording is not None:
            if await self.recording.screenshot() is None:
                try:
                    screenshot = await self.idb("screenshot", "-", check=False)
                except HarnessError as error:
                    self.recording.event("screenshot_unavailable", reason=str(error))
                else:
                    if screenshot.returncode == 0:
                        self.recording.save_screenshot(screenshot.stdout)
                    else:
                        self.recording.event(
                            "screenshot_unavailable", reason=screenshot.error_text
                        )
        await super().asyncTearDown()

    def check_companion(self) -> None:
        died = self.companion.died()
        if died is None:
            return
        self._stop_suite()
        raise died

    def _stop_suite(self) -> None:
        """Stop after this test reports its result.

        The remaining tests cannot run without the shared companion. Ordinary
        command failures leave the suite running.
        """
        if self._result is not None:
            self._result.stop()

    @property
    def udid(self) -> str:
        return self.environment.udid

    @property
    def simctl(self) -> Simctl:
        return self.environment.simctl

    async def run_client(
        self,
        argv: Sequence[str],
        timeout: float,
        stdin: bytes | None = None,
    ) -> Completed:
        return await run_attested_client(
            argv,
            timeout,
            stdin,
            required=getattr(self, "requires_route_attestation", False),
        )

    async def idb(
        self,
        *args: str,
        check: bool = True,
        timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
        stdin: bytes | None = None,
        step: str | None = None,
    ) -> Completed:
        """Run idb; with check=True, report nonzero exits as failures or skips.

        step describes this command as one step of a documented demo. Only
        named commands appear in the published transcript, so the polling a
        test does around them stays out of the documentation.

        A transient accessibility answer is repeated where `worth_repeating`
        allows, until TRANSIENT_ANSWER_TIMEOUT_SECONDS pass. Only the attempt
        that ends the command is published as the step.
        """
        deadline = Deadline(TRANSIENT_ANSWER_TIMEOUT_SECONDS)
        while True:
            repeat = False

            def published(completed: Completed) -> str | None:
                nonlocal repeat
                repeat = worth_repeating(args, completed) and not deadline.passed
                return None if repeat else step

            completed = await self._run_once(
                args, timeout=timeout, stdin=stdin, published=published
            )
            if not repeat:
                break
            await asyncio.sleep(POLL_INTERVAL_SECONDS)
        if check and completed.returncode != 0:
            self.fail_or_skip_for(" ".join(args), completed)
        return completed

    async def idb_repl(
        self,
        context: str,
        *args: str,
        check: bool = True,
        timeout: float = REPL_COMMAND_TIMEOUT_SECONDS,
        step: str | None = None,
    ) -> Completed:
        """Run idb-repl in `context` against this test's companion.

        step publishes the command as it does for `idb`. The published argv
        leaves out `--companion`, whose socket is private to this run.
        """
        repl = self.environment.repl_path
        if repl is None:
            raise HarnessError(
                f"{IDB_E2E_REPL_PATH_ENV} is not set; it names the idb-repl this test drives."
            )
        argv = [str(repl), context, "--companion", self.companion.address, *args]
        completed = await self._run_traced(
            argv,
            ["idb-repl", context, *args],
            lambda: run(argv, timeout=timeout),
            stdin=None,
            published=lambda _: step,
        )
        if check and completed.returncode != 0:
            self.fail_or_skip_for(" ".join(["idb-repl", context, *args]), completed)
        return completed

    async def _run_once(
        self,
        args: Sequence[str],
        *,
        timeout: float,
        stdin: bytes | None = None,
        published: Callable[[Completed], str | None],
    ) -> Completed:
        """Run idb once and trace it, published as the step `published` names.

        `published` sees the answer before it is traced, so a caller that
        repeats a command can publish only the attempt that ends it.
        """
        argv = idb_argv(self.environment, self.companion, *args)
        return await self._run_traced(
            argv,
            ["idb", *args],
            lambda: self.run_client(argv, timeout=timeout, stdin=stdin),
            stdin=stdin,
            published=published,
        )

    async def _run_traced(
        self,
        argv: Sequence[str],
        shown: Sequence[str],
        run: Callable[[], Awaitable[Completed]],
        *,
        stdin: bytes | None,
        published: Callable[[Completed], str | None],
    ) -> Completed:
        """Run a client command and trace it as `shown`, the argv a reader sees."""
        started = time.monotonic()
        given = {} if stdin is None else {"stdin": stdin}
        if self.recording is not None:
            self.recording.command(list(shown))
        try:
            completed = await run()
        except BaseException as error:
            if self.recording is not None:
                self.recording.exec_output(
                    argv,
                    f"raised after {time.monotonic() - started:.2f}s: {error!r}",
                    given,
                )
                # A command that raised is never published — a demo whose
                # test failed stops the documentation being generated at
                # all — so the argv is recorded as it ran rather than
                # normalised, which is what someone reading the trace to
                # debug the run needs.
                self.recording.event(
                    "command_error",
                    argv=list(shown),
                    error=str(error),
                    seconds=time.monotonic() - started,
                )
            raise
        step = published(completed)
        if self.recording is not None:
            self.recording.exec_output(
                argv,
                f"exited {completed.returncode} after {time.monotonic() - started:.2f}s",
                {**given, "stdout": completed.stdout, "stderr": completed.stderr},
            )
            self.recording.event(
                "command_finished",
                returncode=completed.returncode,
                seconds=time.monotonic() - started,
                **self._command_fields(step, shown, completed),
            )
        return completed

    def _command_fields(
        self, step: str | None, argv: Sequence[str], completed: Completed
    ) -> dict[str, Any]:
        """The trace fields of a finished command.

        A command a demo named is published, so its argv is normalised
        alongside its output. Every other command keeps the argv it really
        ran, which is what a failure needs to be diagnosed from.
        """
        if step is None or self.transcript is None:
            return {"argv": list(argv)}
        return {
            "argv": self.transcript.argv(argv),
            "step": step,
            **self.transcript.captures(completed.stdout, completed.stderr),
        }

    def note(self, text: str, *marks: str) -> None:
        """Say what the last published step showed, beside it in the demo.

        A step's output is what the command printed, not what the test made of
        it. A note is the test's reading of that output -- which element it
        found, where, and what that proves -- published beside the step, with
        the pieces of the output it names marked so a reader can find them in
        it. Outside a documented demo there is nothing to publish, so nothing
        is recorded.
        """
        if self.transcript is None or self.recording is None:
            return
        self.recording.event(
            "step_note",
            text=normalise(text, self.transcript.rules),
            marks=[normalise(mark, self.transcript.rules) for mark in marks],
        )

    async def setup_idb(
        self,
        *args: str,
        check: bool = True,
        timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
    ) -> Completed:
        """Run a fixture-preparation command outside the client under test."""
        completed = await run(
            client_argv(
                self.environment.setup_idb_bin,
                (),
                self.companion.address,
                *args,
            ),
            timeout=timeout,
        )
        if check and completed.returncode != 0:
            self.fail_or_skip_for("setup: " + " ".join(args), completed)
        return completed

    async def setup_terminate_quietly(self, bundle_id: str) -> None:
        await self.setup_idb("terminate", bundle_id, check=False)

    async def setup_uninstall_quietly(self, bundle_id: str) -> None:
        await self.setup_terminate_quietly(bundle_id)
        await self.setup_idb("uninstall", bundle_id, check=False)

    async def setup_deny_permission_prompts(self) -> None:
        """Deny every permission prompt on screen, so none covers what a test reads.

        SpringBoard holds a prompt above every app until it is answered, across
        relaunches and uninstalls, so one left by an earlier test -- or by
        anything else that used the simulator before -- covers everything a
        later test reads. Denying grants nothing.
        """
        await self._setup_press_prompt_until_gone(
            PERMISSION_PROMPT_DENY_LABELS,
            "permission_prompt_denied",
            "A permission prompt was not dismissed",
        )

    async def setup_answer_permission_prompt(self, answer: str) -> None:
        """Press `answer` on the permission prompt until the prompt is gone.

        SpringBoard does not take every tap on a prompt: it can stay up after
        one, covering what the test reads next.
        """
        await self._setup_press_prompt_until_gone(
            frozenset({answer}),
            "permission_prompt_answered",
            f"The permission prompt stayed up after pressing {answer!r}",
        )

    async def _setup_press_prompt_until_gone(
        self, labels: Collection[str], event: str, failure: str
    ) -> None:
        args = ("ui", "describe-all", "--json")

        async def press() -> None:
            completed = await self.setup_idb(*args, check=False)
            if completed.returncode != 0:
                if worth_repeating(args, completed):
                    raise NotReady(completed.error_text.strip())
                self.fail_or_skip_for("setup: " + " ".join(args), completed)
            document = json.loads(completed.text)
            button = _permission_prompt_button(document, labels)
            if button is None:
                return
            shown = [_label(element) for element in _elements(document)]
            shown = [label for label in shown if label]
            if self.recording is not None:
                self.recording.event(event, labels=shown)
            x, y = _center(button)
            await self.setup_idb("ui", "tap", str(x), str(y))
            raise NotReady(f"a permission prompt showed {shown}")

        await self.wait_or_fail(failure, UI_UPDATE_TIMEOUT_SECONDS, press)

    async def setup_web_origin(
        self,
        live: str,
        stand_in: Mapping[str, str],
        arrives: Callable[[str], Awaitable[bool]],
    ) -> str:
        """The origin a web test reads from, live where the simulator has it.

        Only the simulator can answer this. Fetching the page from the host
        answers a different question and gets it wrong in both directions: a
        continuous integration host reaches the internet through a proxy its
        simulator does not use, and a corporate laptop refuses the test
        process egress that its simulator is given. So the browser is asked
        to open the first page the test will read, and `arrives` reports
        whether it appeared; when it did not, the stand-in pages are served
        over loopback and the same journey runs against those.
        """
        first = next(iter(stand_in))
        if await arrives(live + first):
            return live
        pages = LocalPages(stand_in)
        origin = pages.start()
        self.addCleanup(pages.stop)
        logging.info(
            "%s did not open in the simulator; serving stand-in pages from %s",
            live,
            origin,
        )
        return origin

    def idb_process(
        self,
        *args: str,
        idb_bin: Path | None = None,
        process_config: IdbProcessConfig | None = None,
        companion: Companion | None = None,
        cwd: Path | None = None,
        env: Mapping[str, str] | None = None,
    ) -> AbstractAsyncContextManager[IdbProcess]:
        """Start a streaming command and stop it when the async context exits."""
        selected_companion = self.companion if companion is None else companion
        argv = (
            idb_argv(self.environment, selected_companion, *args)
            if idb_bin is None
            else client_argv(
                idb_bin,
                self.environment.idb_args,
                selected_companion.address,
                *args,
            )
        )
        if getattr(self, "resolve_process_executable", False):
            argv[0] = str(Path(argv[0]).resolve())
        return attested_process(
            argv,
            " ".join(args),
            display_argv=["idb", *args],
            failure=self.fail,
            recording=self.recording,
            config=process_config,
            env=env,
            cwd=cwd,
            required=getattr(self, "requires_route_attestation", False),
            attestation_timeout=getattr(
                self,
                "route_attestation_timeout_seconds",
                ROUTE_ATTESTATION_TIMEOUT_SECONDS,
            ),
        )

    def fail_or_skip_for(self, what: str, completed: Completed) -> NoReturn:
        """Report command output; skip unsupported hosts unless strict mode is set.

        Include companion status for connection failures, and stop the suite if
        the companion has exited.
        """
        message = (
            f"idb {what} failed (rc={completed.returncode})\n"
            f"stdout: {completed.text}\n"
            f"stderr: {completed.error_text}"
        )
        kind = classify_failure(completed)

        if kind is FailureKind.COMPANION_UNREACHABLE:
            if self.companion.died() is not None:
                self._stop_suite()
            self.fail(
                f"The client could not reach the companion; "
                f"{self.companion.status_description()}.\n{message}\n"
                f"companion log: {self.companion.log_excerpt()}"
            )

        if kind is FailureKind.HOST_SERVICE_UNAVAILABLE:
            if strict():
                self.fail(
                    f"{STRICT_ENV}=1 and the simulator's host does not run "
                    f"SimLaunchHostService: {message}"
                )
            self.skipTest(
                f"This simulator's host does not run SimLaunchHostService; nothing "
                f"can be spawned in the guest: idb {what}"
            )

        # Preserve the command error even if the companion exited afterwards.
        companion_returncode = self.companion.process.poll()
        if companion_returncode is not None:
            self._stop_suite()
            self.fail(
                f"{message}\n"
                f"The companion has since exited with {companion_returncode}, so "
                f"later commands will fail to connect.\n"
                f"companion log: {self.companion.log_excerpt()}"
            )
        self.fail(message)

    async def idb_text(self, *args: str, **kwargs: Any) -> str:
        return (await self.idb(*args, **kwargs)).text

    async def idb_json(self, *args: str, **kwargs: Any) -> Any:
        return json.loads(await self.idb_text(*args, "--json", **kwargs))

    async def idb_json_lines(self, *args: str, **kwargs: Any) -> list[Any]:
        text = await self.idb_text(*args, "--json", **kwargs)
        return [json.loads(line) for line in text.splitlines() if line.strip()]

    async def wait_for(
        self,
        query: Query,
        *,
        until: Until = Until.PRESENT,
        lookup: Lookup = DESCRIBE,
        keys: Sequence[str] = (),
        timeout: float = UI_UPDATE_TIMEOUT_SECONDS,
        step: str | None = None,
    ) -> Found:
        """Wait until the query's element is `until`, and return it as last read.

        Every read is one `ui describe` of the element, so the frame returned
        is the frame the condition was judged on, not one read afterwards.
        `ui describe` answers with the first element whose value contains the
        query's, so once it answers with another element, the rest of the wait
        reads the whole screen with `ui describe-all` instead. An element that
        is not there yet and a transient answer are both waited through; any
        other failure fails the test at once, as does a read that outlasts the
        wait. Only the read that ends the wait is published, as `step`. `keys`
        narrows what each read reports, with `--key`.
        """
        deadline = Deadline(timeout)
        if isinstance(lookup, UiWait):
            seconds = max(deadline.remaining, 1.0)
            await self.setup_idb(
                "ui",
                "wait",
                *replace(query, api=lookup.api or query.api).marker_args,
                "--timeout",
                f"{seconds:.0f}",
                timeout=seconds + MIN_READ_TIMEOUT_SECONDS,
            )
        reported = (
            "--format",
            "complete",
            *(
                argument
                for key in query.describe_keys(keys)
                for argument in ("--key", key)
            ),
            "--json",
        )
        args = ("ui", "describe", *query.marker_args, *reported)
        wait = ElementWait(query, until)

        async def read() -> Found:
            nonlocal args
            outcome: Found | Exception | None = None

            def published(completed: Completed) -> str | None:
                nonlocal outcome
                try:
                    outcome = wait.observe(completed)
                except (NotReady, UnexpectedAnswer) as error:
                    outcome = error
                    return None
                return step

            await self._run_once(
                args,
                timeout=min(
                    DEFAULT_COMMAND_TIMEOUT_SECONDS,
                    max(deadline.remaining, MIN_READ_TIMEOUT_SECONDS),
                ),
                published=published,
            )
            if isinstance(outcome, UnexpectedAnswer):
                self.fail_or_skip_for(" ".join(args), outcome.completed)
            if isinstance(outcome, NoExactMatch):
                args = ("ui", "describe-all", "--api", query.api.value, *reported)
            if isinstance(outcome, Exception):
                raise outcome
            assert outcome is not None
            return outcome

        return await self.wait_or_fail(
            f"{query} was not {until.value}", max(deadline.remaining, 0.0), read
        )

    async def wait_for_app(
        self,
        bundle_id: str,
        state: AppState,
        *,
        timeout: float = APP_STATE_TIMEOUT_SECONDS,
    ) -> None:
        """Wait until simctl reports the app `state`, whatever idb reports."""
        if state in (AppState.RUNNING, AppState.STOPPED):
            listing = self.simctl.running_bundle_ids
            listed, unlisted = AppState.RUNNING, AppState.STOPPED
        else:
            listing = self.simctl.installed_bundle_ids
            listed, unlisted = AppState.INSTALLED, AppState.ABSENT

        async def check() -> None:
            try:
                bundle_ids = await listing(timeout=SIMCTL_POLL_TIMEOUT_SECONDS)
            except CommandTimedOut as timed_out:
                # simctl can hang on the host without reaching the simulator,
                # and a fresh simctl is not stuck behind it.
                raise NotReady(str(timed_out)) from None
            reported = listed if bundle_id in bundle_ids else unlisted
            if reported is not state:
                raise NotReady(f"simctl reports it {reported.value}")

        await self.wait_or_fail(
            f"{bundle_id} did not become {state.value}", timeout, check
        )

    async def tap_when_settled(
        self, query: Query, *tap_args: str, step: str | None = None
    ) -> Found:
        """Tap the centre of the query's element once it has settled on screen.

        The tap goes to the frame of the read that found it settled.
        """
        found = await self.wait_for(query, until=Until.SETTLED)
        x, y = _center(found.element)
        await self.idb("ui", "tap", str(x), str(y), *tap_args, step=step)
        return found

    async def idb_expect_failure(
        self,
        *args: str,
        expected_error: str | Sequence[str],
        **kwargs: Any,
    ) -> Completed:
        """A command whose named rejection is the behaviour under test.

        The non-zero exit has to have come from the command, the companion must
        still be alive, and stderr must identify the expected rejection. Without
        all three, an infrastructure or routing failure could impersonate it.
        """
        kwargs["check"] = False
        completed = await self.idb(*args, **kwargs)
        if completed.returncode == 0:
            self.fail(
                f"idb {' '.join(args)} unexpectedly succeeded\nstdout: {completed.text}"
            )
        if classify_failure(completed) is not FailureKind.COMMAND:
            self.fail_or_skip_for(" ".join(args), completed)
        if self.companion.died() is not None:
            self.fail_or_skip_for(" ".join(args), completed)
        markers = (
            (expected_error,)
            if isinstance(expected_error, str)
            else tuple(expected_error)
        )
        if not markers:
            self.fail(f"idb {' '.join(args)} declared no expected error marker")
        if any(not marker.strip() for marker in markers):
            self.fail(
                f"idb {' '.join(args)} declared an empty expected error marker: "
                f"{markers!r}"
            )
        actual = completed.error_text.casefold()
        if not any(marker.casefold() in actual for marker in markers):
            self.fail(
                f"idb {' '.join(args)} failed for an unexpected reason "
                f"(rc={completed.returncode})\n"
                f"expected stderr containing one of {markers!r}\n"
                f"stdout: {completed.text}\nstderr: {completed.error_text}"
            )
        return completed

    async def installed_apps(self) -> dict[str, dict[str, Any]]:
        return {row["bundle_id"]: row for row in await self.idb_json_lines("list-apps")}

    async def setup_install_fixture_app(self) -> str:
        """Install the companion fixture with the setup client and queue removal."""
        fixture = self.environment.fixture_app
        if not fixture.is_dir():
            raise HarnessError(
                f"The companion's {FIXTURE_APP_NAME} is missing at {fixture}"
            )
        self.addAsyncCleanup(self.setup_uninstall_quietly, FIXTURE_APP_BUNDLE_ID)
        await self.setup_idb(
            "install",
            str(fixture),
            timeout=INSTALL_TIMEOUT_SECONDS,
        )
        return FIXTURE_APP_BUNDLE_ID

    async def guest(self, *arguments: str) -> Completed:
        binary = self.environment.guest_binary
        completed = await self.simctl.run("spawn", self.udid, str(binary), *arguments)
        self.assertEqual(
            completed.returncode,
            0,
            f"guest {arguments}: {completed.text}\n{completed.error_text}",
        )
        return completed

    async def install_fixture_app(self) -> str:
        """Install ReplHost.app, register uninstall cleanup, and return its bundle ID."""
        fixture = self.environment.fixture_app
        if not fixture.is_dir():
            raise HarnessError(
                f"The companion's {FIXTURE_APP_NAME} is missing at {fixture}"
            )
        self.addAsyncCleanup(self.uninstall_quietly, FIXTURE_APP_BUNDLE_ID)
        await self.idb("install", str(fixture), timeout=INSTALL_TIMEOUT_SECONDS)
        return FIXTURE_APP_BUNDLE_ID

    async def uninstall_quietly(self, bundle_id: str) -> None:
        await self.idb("terminate", bundle_id, check=False)
        await self.idb("uninstall", bundle_id, check=False)

    async def terminate_quietly(self, bundle_id: str) -> None:
        await self.idb("terminate", bundle_id, check=False)

    def make_temporary_directory(self) -> Path:
        directory = Path(tempfile.mkdtemp(prefix="idb-e2e-test-"))
        self.addCleanup(shutil.rmtree, directory, True)
        return directory


class ProcessStream(enum.Enum):
    STDOUT = "stdout"
    STDERR = "stderr"


@dataclass(frozen=True)
class ProcessOutput:
    """Bounded in-memory output metadata backed by a temporary spool."""

    total_bytes: int
    sha256: str
    prefix: bytes
    tail: bytes


@dataclass(frozen=True)
class ProcessObservation:
    """One chunk in harness-observed read order.

    The sequence is assigned when a drain task resumes from its pipe read. It
    intentionally describes the order observed by this harness, not an
    unknowable ordering between writes to separate operating-system pipes.
    """

    sequence: int
    observed_at_ns: int
    stream: ProcessStream
    stream_offset: int
    data: bytes


@dataclass(frozen=True)
class IdbProcessConfig:
    read_chunk_bytes: int = 64 * 1024
    prefix_bytes: int = 64 * 1024
    tail_bytes: int = 64 * 1024
    reader_throttle_seconds: float = 0.0
    reader_gate: Callable[[ProcessStream], Awaitable[None]] | None = None
    graceful_stop_seconds: float = 60.0
    kill_wait_seconds: float = 10.0

    def __post_init__(self) -> None:
        if self.read_chunk_bytes <= 0:
            raise ValueError("read_chunk_bytes must be positive")
        for name, value in (
            ("prefix_bytes", self.prefix_bytes),
            ("tail_bytes", self.tail_bytes),
            ("reader_throttle_seconds", self.reader_throttle_seconds),
            ("graceful_stop_seconds", self.graceful_stop_seconds),
            ("kill_wait_seconds", self.kill_wait_seconds),
        ):
            if value < 0:
                raise ValueError(f"{name} must not be negative")


_OBSERVATION_RECORD: struct.Struct = struct.Struct("!QBQQQ")
_PROCESS_STREAM_TAG: dict[ProcessStream, int] = {
    ProcessStream.STDOUT: 1,
    ProcessStream.STDERR: 2,
}
_PROCESS_STREAM_FROM_TAG: dict[int, ProcessStream] = {
    tag: stream for stream, tag in _PROCESS_STREAM_TAG.items()
}
_KILL_SIGNAL: int = int(getattr(signal, "SIGKILL", signal.SIGTERM))


class _OutputSpool:
    def __init__(self, path: Path, prefix_bytes: int, tail_bytes: int) -> None:
        self.path = path
        self._file: BinaryIO = path.open("w+b", buffering=0)
        self._prefix_limit = prefix_bytes
        self._tail_limit = tail_bytes
        self._prefix = bytearray()
        self._tail = bytearray()
        self._digest = hashlib.sha256()
        self.total_bytes = 0
        self.eof = False
        self.error: Exception | None = None
        self.changed = asyncio.Event()

    def append(self, data: bytes) -> int:
        offset = self.total_bytes
        self._file.write(data)
        self._digest.update(data)
        self.total_bytes += len(data)
        prefix_remaining = self._prefix_limit - len(self._prefix)
        if prefix_remaining > 0:
            self._prefix.extend(data[:prefix_remaining])
        if self._tail_limit > 0:
            self._tail.extend(data)
            if len(self._tail) > self._tail_limit:
                del self._tail[: len(self._tail) - self._tail_limit]
        self.changed.set()
        return offset

    def read(self, offset: int, length: int) -> bytes:
        if self._file.closed:
            raise HarnessError(f"The output spool {self.path} is closed")
        position = self._file.tell()
        self._file.seek(offset)
        data = self._file.read(length)
        self._file.seek(position)
        return data

    def read_all(self) -> bytes:
        return self.read(0, self.total_bytes)

    def finish(self) -> None:
        self.eof = True
        self.changed.set()

    def fail(self, error: Exception) -> None:
        self.error = error
        self.changed.set()

    def snapshot(self) -> ProcessOutput:
        return ProcessOutput(
            total_bytes=self.total_bytes,
            sha256=self._digest.copy().hexdigest(),
            prefix=bytes(self._prefix),
            tail=bytes(self._tail),
        )

    def close(self) -> None:
        if not self._file.closed:
            self._file.close()


def _bounded_output(output: ProcessOutput) -> bytes:
    """What a streaming process printed, as much of it as its capture kept."""
    omitted = output.total_bytes - len(output.prefix) - len(output.tail)
    if omitted < 0:
        return output.prefix + output.tail[-omitted:]
    if omitted == 0:
        return output.prefix + output.tail
    return output.prefix + f"\n[{omitted} bytes omitted]\n".encode() + output.tail


def _raise_process_failure(message: str) -> NoReturn:
    raise HarnessError(message)


class IdbProcess:
    """Manage one subprocess with bounded, ordered, binary-exact capture."""

    def __init__(
        self,
        argv: Sequence[str],
        what: str,
        *,
        display_argv: Sequence[str] | None = None,
        failure: Callable[[str], NoReturn] | None = None,
        recording: Recording | None = None,
        config: IdbProcessConfig | None = None,
        env: Mapping[str, str] | None = None,
        cwd: Path | None = None,
    ) -> None:
        self._argv = list(argv)
        self._display_argv = list(display_argv or argv)
        self._what = what
        self._failure = failure or _raise_process_failure
        self._recording = recording
        self._config = config or IdbProcessConfig()
        self._env = None if env is None else dict(env)
        self._cwd = cwd
        self._process: asyncio.subprocess.Process | None = None
        self._process_group: int | None = None
        self._captures: dict[ProcessStream, _OutputSpool] = {}
        self._reader_tasks: dict[ProcessStream, asyncio.Task[None]] = {}
        self._process_wait_task: asyncio.Task[int] | None = None
        self._completion_task: asyncio.Task[int] | None = None
        self._stop_task: asyncio.Task[int] | None = None
        self._close_task: asyncio.Task[None] | None = None
        self._observation_spool: BinaryIO | None = None
        self._observation_count = 0
        self._observation_event = asyncio.Event()
        self._last_observed_at_ns = 0
        self._read_offsets = dict.fromkeys(ProcessStream, 0)
        self._spool_directory: Path | None = None
        self._stdin_closed = False
        self._recording_finished = False
        self._signals_sent: list[int] = []
        self._killed = False
        self._started = False
        self._closed = False

    async def __aenter__(self) -> "IdbProcess":
        if self._started:
            raise HarnessError(f"{self._what} was already started")
        self._started = True
        self._create_spools()
        if self._recording is not None:
            self._recording.command(self._display_argv)
        try:
            process = await asyncio.create_subprocess_exec(
                *self._argv,
                env=self._env,
                cwd=None if self._cwd is None else str(self._cwd),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )
        except BaseException as error:
            if self._recording is not None:
                self._recording.event(
                    "command_error", argv=self._display_argv, error=str(error)
                )
            self._close_spools()
            raise
        self._start_tasks(process)
        return self

    async def __aexit__(
        self, _exception_type: object, exception: object, _traceback: object
    ) -> None:
        try:
            await self.aclose()
        except BaseException as cleanup_error:
            if isinstance(exception, BaseException):
                exception.add_note(f"Process cleanup also failed: {cleanup_error}")
                return
            raise

    def _create_spools(self) -> None:
        directory = Path(tempfile.mkdtemp(prefix="idb-e2e-process-"))
        self._spool_directory = directory
        self._captures = {
            stream: _OutputSpool(
                directory / f"{stream.value}.bin",
                self._config.prefix_bytes,
                self._config.tail_bytes,
            )
            for stream in ProcessStream
        }
        self._observation_spool = (directory / "observations.bin").open(
            "w+b", buffering=0
        )

    def _start_tasks(self, process: asyncio.subprocess.Process) -> None:
        assert process.stdout is not None and process.stderr is not None
        self._process = process
        self._process_group = process.pid
        self._process_wait_task = asyncio.create_task(
            process.wait(), name="idb-e2e-process-wait"
        )
        readers = {
            ProcessStream.STDOUT: process.stdout,
            ProcessStream.STDERR: process.stderr,
        }
        self._reader_tasks = {
            stream: asyncio.create_task(
                self._drain(stream, reader),
                name=f"idb-e2e-{stream.value}-drain",
            )
            for stream, reader in readers.items()
        }
        self._completion_task = asyncio.create_task(
            self._complete(), name="idb-e2e-process-completion"
        )

    async def _drain(self, stream: ProcessStream, reader: asyncio.StreamReader) -> None:
        capture = self._captures[stream]
        try:
            while True:
                if self._config.reader_gate is not None:
                    await self._config.reader_gate(stream)
                data = await reader.read(self._config.read_chunk_bytes)
                if not data:
                    return
                self._record_observation(stream, data)
                if self._config.reader_throttle_seconds:
                    await asyncio.sleep(self._config.reader_throttle_seconds)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            capture.fail(error)
            self._kill_after_reader_failure()
        finally:
            capture.finish()
            self._observation_event.set()

    def _record_observation(self, stream: ProcessStream, data: bytes) -> None:
        capture = self._captures[stream]
        offset = capture.append(data)
        observed_at_ns = max(time.monotonic_ns(), self._last_observed_at_ns)
        self._last_observed_at_ns = observed_at_ns
        spool = self._observation_spool
        if spool is None or spool.closed:
            raise HarnessError("The process observation spool is closed")
        spool.write(
            _OBSERVATION_RECORD.pack(
                self._observation_count,
                _PROCESS_STREAM_TAG[stream],
                observed_at_ns,
                offset,
                len(data),
            )
        )
        self._observation_count += 1
        self._observation_event.set()

    def _kill_after_reader_failure(self) -> None:
        process = self._process
        if process is None or process.returncode is not None or self._killed:
            return
        self._killed = True
        self._signals_sent.append(_KILL_SIGNAL)
        process_group = self._process_group
        assert process_group is not None
        _signal_process_group(process_group, _KILL_SIGNAL)

    async def _complete(self) -> int:
        process_wait = self._process_wait_task
        assert process_wait is not None
        returncode = await process_wait
        await asyncio.gather(*self._reader_tasks.values(), return_exceptions=True)
        for stream, capture in self._captures.items():
            if capture.error is not None:
                raise HarnessError(
                    f"Reading {stream.value} from {self._what} failed: {capture.error}"
                )
        return returncode

    @property
    def returncode(self) -> int | None:
        process = self._process
        return None if process is None else process.returncode

    @property
    def pid(self) -> int | None:
        process = self._process
        return None if process is None else process.pid

    @property
    def observation_count(self) -> int:
        return self._observation_count

    @property
    def spool_directory(self) -> Path | None:
        return self._spool_directory

    @property
    def closed(self) -> bool:
        return self._closed

    @property
    def reader_tasks_done(self) -> bool:
        return bool(self._reader_tasks) and all(
            task.done() for task in self._reader_tasks.values()
        )

    @property
    def signals_sent(self) -> tuple[int, ...]:
        return tuple(self._signals_sent)

    @property
    def was_killed(self) -> bool:
        return self._killed

    @property
    def stdout_capture(self) -> ProcessOutput:
        return self._captures[ProcessStream.STDOUT].snapshot()

    @property
    def stderr_capture(self) -> ProcessOutput:
        return self._captures[ProcessStream.STDERR].snapshot()

    def spooled_output(self, stream: ProcessStream) -> bytes:
        return self._captures[stream].read_all()

    def observation_log(self) -> list[ProcessObservation]:
        spool = self._observation_spool
        if spool is None or spool.closed:
            raise HarnessError("The process observation spool is closed")
        position = spool.tell()
        spool.seek(0)
        observations: list[ProcessObservation] = []
        try:
            while header := spool.read(_OBSERVATION_RECORD.size):
                if len(header) != _OBSERVATION_RECORD.size:
                    raise HarnessError("The process observation spool is truncated")
                sequence, tag, observed_at_ns, offset, length = (
                    _OBSERVATION_RECORD.unpack(header)
                )
                stream = _PROCESS_STREAM_FROM_TAG.get(tag)
                if stream is None:
                    raise HarnessError(f"Unknown process observation stream tag {tag}")
                data = self._captures[stream].read(offset, length)
                if len(data) != length:
                    raise HarnessError("The process output spool is truncated")
                observations.append(
                    ProcessObservation(
                        sequence=sequence,
                        observed_at_ns=observed_at_ns,
                        stream=stream,
                        stream_offset=offset,
                        data=data,
                    )
                )
        finally:
            spool.seek(position)
        return observations

    async def read_some(
        self, timeout: float, stream: ProcessStream = ProcessStream.STDOUT
    ) -> bytes:
        """Read the next captured chunk without requiring a newline."""
        capture = self._captures[stream]
        offset = self._read_offsets[stream]
        await self._wait_for_stream_data(stream, capture, offset, timeout)
        available = capture.total_bytes - offset
        data = capture.read(offset, min(available, self._config.read_chunk_bytes))
        self._read_offsets[stream] += len(data)
        return data

    async def _wait_for_stream_data(
        self,
        stream: ProcessStream,
        capture: _OutputSpool,
        offset: int,
        timeout: float,
    ) -> None:
        deadline = Deadline(timeout)
        while capture.total_bytes <= offset and not capture.eof:
            capture.changed.clear()
            if capture.total_bytes > offset or capture.eof:
                break
            try:
                await asyncio.wait_for(capture.changed.wait(), deadline.remaining)
            except asyncio.TimeoutError:
                self._failure(
                    f"{self._what} wrote nothing to {stream.value} within {timeout:.0f}s"
                )
        if capture.error is not None:
            self._failure(
                f"Reading {stream.value} from {self._what} failed: {capture.error}"
            )
        if capture.total_bytes <= offset:
            completion = self._require_completion()
            try:
                await asyncio.wait_for(asyncio.shield(completion), deadline.remaining)
            except asyncio.TimeoutError:
                self._failure(
                    f"idb {self._what} closed {stream.value} but did not exit "
                    f"within {timeout:.0f}s"
                )
            stderr = self.spooled_output(ProcessStream.STDERR).decode(errors="replace")
            self._failure(
                f"idb {self._what} closed {stream.value} without writing anything "
                f"(rc={self.returncode})\nstderr: {stderr}"
            )

    async def wait_for_observations(self, count: int, timeout: float) -> None:
        if count < 0:
            raise ValueError("count must not be negative")
        deadline = Deadline(timeout)
        while self._observation_count < count:
            self._observation_event.clear()
            if self._observation_count >= count:
                return
            completion = self._completion_task
            if completion is not None and completion.done():
                self._failure(
                    f"{self._what} ended after {self._observation_count} observations; "
                    f"expected {count}"
                )
            try:
                await asyncio.wait_for(
                    self._observation_event.wait(), deadline.remaining
                )
            except asyncio.TimeoutError:
                self._failure(
                    f"{self._what} produced fewer than {count} observations within "
                    f"{timeout:.0f}s"
                )

    async def send(self, data: bytes) -> None:
        process = self._require_process()
        if self._stdin_closed:
            self._failure(f"stdin for {self._what} is already closed")
        if process.returncode is not None:
            self._failure(
                f"Cannot write to {self._what}; it exited with {process.returncode}"
            )
        stdin = process.stdin
        assert stdin is not None
        try:
            stdin.write(data)
            await stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as error:
            self._failure(f"Writing stdin for {self._what} failed: {error}")

    async def close_stdin(self) -> None:
        if self._stdin_closed:
            return
        self._stdin_closed = True
        process = self._require_process()
        stdin = process.stdin
        assert stdin is not None
        stdin.close()
        try:
            await stdin.wait_closed()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_signal(self, process_signal: int | signal.Signals) -> None:
        process = self._require_process()
        if process.returncode is not None:
            self._failure(
                f"Cannot signal {self._what}; it exited with {process.returncode}"
            )
        numeric_signal = int(process_signal)
        process_group = self._process_group
        assert process_group is not None
        try:
            os.killpg(process_group, numeric_signal)
        except ProcessLookupError:
            self._failure(
                f"Cannot signal {self._what}; its process group no longer exists"
            )
        self._signals_sent.append(numeric_signal)

    async def wait(self, timeout: float) -> int:
        if timeout < 0:
            raise ValueError("timeout must not be negative")
        completion = self._require_completion()
        if completion.done():
            return await completion
        try:
            return await asyncio.wait_for(asyncio.shield(completion), timeout)
        except asyncio.TimeoutError:
            self._failure(f"{self._what} did not exit within {timeout:.0f}s")
        except HarnessError as error:
            self._failure(str(error))

    async def wait_for_exit(self, timeout: float) -> int:
        return await self.wait(timeout)

    async def stop(
        self,
        graceful_timeout: float | None = None,
        kill_timeout: float | None = None,
    ) -> int:
        if self._stop_task is None:
            graceful = (
                self._config.graceful_stop_seconds
                if graceful_timeout is None
                else graceful_timeout
            )
            kill = (
                self._config.kill_wait_seconds if kill_timeout is None else kill_timeout
            )
            if graceful < 0 or kill < 0:
                raise ValueError("stop timeouts must not be negative")
            self._stop_task = asyncio.create_task(
                self._stop(graceful, kill), name="idb-e2e-process-stop"
            )
        return await asyncio.shield(self._stop_task)

    async def _stop(self, graceful_timeout: float, kill_timeout: float) -> int:
        await self.close_stdin()
        completion = self._require_completion()
        process_group = self._process_group
        assert process_group is not None
        if _process_group_alive(process_group):
            self._send_cleanup_signal(int(signal.SIGTERM))
        try:
            returncode = await asyncio.wait_for(
                asyncio.shield(completion), graceful_timeout
            )
        except asyncio.TimeoutError:
            self._killed = True
            self._send_cleanup_signal(_KILL_SIGNAL)
            try:
                returncode = await asyncio.wait_for(
                    asyncio.shield(completion), kill_timeout
                )
            except asyncio.TimeoutError:
                for task in self._reader_tasks.values():
                    if not task.done():
                        task.cancel()
                try:
                    returncode = await asyncio.wait_for(
                        asyncio.shield(completion), kill_timeout
                    )
                except asyncio.TimeoutError:
                    raise HarnessError(
                        f"{self._what} could not be reaped after forced termination"
                    ) from None

        if not await _wait_for_process_group_exit(process_group, graceful_timeout):
            self._killed = True
            self._send_cleanup_signal(_KILL_SIGNAL)
            if not await _wait_for_process_group_exit(process_group, kill_timeout):
                raise HarnessError(
                    f"{self._what} descendants survived forced termination"
                )
        return returncode

    def _send_cleanup_signal(self, process_signal: int) -> None:
        process_group = self._process_group
        assert process_group is not None
        self._signals_sent.append(process_signal)
        _signal_process_group(process_group, process_signal)

    async def aclose(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(
                self._close(), name="idb-e2e-process-close"
            )
        try:
            await asyncio.shield(self._close_task)
        except asyncio.CancelledError:
            await self._close_task
            raise

    async def _close(self) -> None:
        if self._closed:
            return
        try:
            if self._process is not None:
                await self.stop()
        finally:
            await self._cancel_remaining_tasks()
            self._finish_recording()
            self._close_spools()
            self._closed = True

    async def _cancel_remaining_tasks(self) -> None:
        tasks: list[asyncio.Task[object]] = []
        for task in (
            *self._reader_tasks.values(),
            self._completion_task,
            self._process_wait_task,
        ):
            if task is not None and not task.done():
                task.cancel()
                tasks.append(task)
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    def _finish_recording(self) -> None:
        if self._recording is None or self._recording_finished:
            return
        self._recording_finished = True
        self._recording.exec_output(
            self._argv,
            f"streamed, then exited {self.returncode}",
            {
                stream.value: _bounded_output(capture.snapshot())
                for stream, capture in self._captures.items()
            },
        )
        self._recording.event(
            "command_finished",
            argv=self._display_argv,
            returncode=self.returncode,
        )

    def _close_spools(self) -> None:
        for capture in self._captures.values():
            capture.close()
        if self._observation_spool is not None and not self._observation_spool.closed:
            self._observation_spool.close()
        if self._spool_directory is not None:
            shutil.rmtree(self._spool_directory, ignore_errors=True)

    def _require_process(self) -> asyncio.subprocess.Process:
        if self._process is None:
            raise HarnessError(f"{self._what} has not been started")
        return self._process

    def _require_completion(self) -> asyncio.Task[int]:
        if self._completion_task is None:
            raise HarnessError(f"{self._what} has not been started")
        return self._completion_task


class GuestRPC:
    """Exercise the packaged bridge contract through argv or one owned socket."""

    def __init__(self, test: IdbEndToEndTestCase, *, persistent: bool) -> None:
        self.test = test
        self.persistent = persistent
        self._lifetime = ExitStack()
        self._process: asyncio.subprocess.Process | None = None
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._sequence = 0

    async def __aenter__(self) -> GuestRPC:
        if not self.persistent:
            return self
        try:
            directory = tempfile.mkdtemp(prefix="idb-rpc-", dir="/tmp")
            self._lifetime.callback(shutil.rmtree, directory)
            self._path = Path(directory) / "bridge.sock"
            self._stdout = self._lifetime.enter_context(tempfile.TemporaryFile())
            self._stderr = self._lifetime.enter_context(tempfile.TemporaryFile())
            self._binary = self.test.environment.guest_binary
            self._process = await asyncio.create_subprocess_exec(
                *self.test.simctl.argv(
                    "spawn",
                    self.test.udid,
                    str(self._binary),
                    "serve",
                    str(self._path),
                    "--startup-timeout",
                    "10",
                    "--idle-timeout",
                    "120",
                    "--exit-on-disconnect",
                    "1",
                ),
                stdin=asyncio.subprocess.DEVNULL,
                stdout=self._stdout,
                stderr=self._stderr,
            )

            async def connect() -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
                if self._process is not None and self._process.returncode is not None:
                    raise HarnessError(
                        f"guest exited before connecting: {self._diagnostics()}"
                    )
                try:
                    return await asyncio.wait_for(
                        asyncio.open_unix_connection(self._path), 1.0
                    )
                except (OSError, asyncio.TimeoutError) as error:
                    raise NotReady(str(error)) from error

            self._reader, self._writer = await wait_until(
                "guest RPC socket", 10.0, connect
            )
            self.test.assertEqual(await self.send({"ping": {}}), [])
            return self
        except BaseException as error:
            await self._close_preserving(error)
            raise

    def _diagnostics(self) -> str:
        self._stdout.seek(0)
        self._stderr.seek(0)
        return f"stdout: {self._stdout.read()!r}; stderr: {self._stderr.read()!r}"

    async def send(self, command: dict[str, Any]) -> list[Any]:
        return reported_answers(await self.send_result(command))

    async def send_result(self, command: dict[str, Any]) -> dict[str, Any]:
        self._sequence += 1
        request = {
            "version": GUEST_PROTOCOL_VERSION,
            "id": f"test-{self._sequence}",
            "command": command,
        }
        payload = json.dumps(request).encode()
        if self.persistent:
            assert self._reader is not None and self._writer is not None
            self._writer.write(len(payload).to_bytes(4, "big") + payload)
            await asyncio.wait_for(self._writer.drain(), 60.0)
            header = await asyncio.wait_for(self._reader.readexactly(4), 60.0)
            size = int.from_bytes(header, "big")
            self.test.assertGreater(size, 0)
            self.test.assertLessEqual(size, 16 * 1024 * 1024)
            response = json.loads(
                await asyncio.wait_for(self._reader.readexactly(size), 60.0)
            )
        else:
            response = json.loads(
                (await self.test.guest("rpc", payload.decode())).stdout
            )
        self.test.assertEqual(response["version"], GUEST_PROTOCOL_VERSION)
        self.test.assertEqual(response["id"], request["id"])
        self.test.assertEqual(response["result"]["exitCode"], 0, response)
        return response["result"]

    async def __aexit__(self, *exception: object) -> None:
        error = exception[1] if isinstance(exception[1], BaseException) else None
        try:
            if self.persistent and exception[0] is None:
                self.test.assertEqual(await self.send({"shutdown": {}}), [])
                assert self._reader is not None
                self.test.assertEqual(
                    await asyncio.wait_for(self._reader.read(), 5.0), b""
                )
                assert self._process is not None
                await asyncio.wait_for(self._process.wait(), 5.0)
                self.test.assertEqual(self._process.returncode, 0, self._diagnostics())
                self.test.assertFalse(self._path.exists())
        except BaseException as shutdown_error:
            error = shutdown_error
            raise
        finally:
            await self._close_preserving(error)

    async def _close_preserving(self, error: BaseException | None) -> None:
        try:
            await self._close()
        except BaseException as cleanup_error:
            if error is None:
                raise
            error.add_note(f"GuestRPC cleanup failed: {cleanup_error}")

    async def _close(self) -> None:
        if self._writer is not None:
            self._writer.close()
            try:
                await asyncio.wait_for(self._writer.wait_closed(), 5.0)
            except (OSError, asyncio.TimeoutError):
                pass
        if self._process is not None and self._process.returncode is None:
            try:
                await asyncio.wait_for(self._process.wait(), 60.0)
            except asyncio.TimeoutError as error:
                raise HarnessError(
                    "owned guest did not exit after disconnect; retaining its socket directory"
                ) from error
        self._lifetime.close()
