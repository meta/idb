#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import json
import sys
from abc import abstractmethod
from argparse import _MutuallyExclusiveGroup, ArgumentParser, Namespace

from idb.cli import ClientCommand
from idb.common.signal import signal_handler_event
from idb.common.types import (
    Client,
    FootprintProfile,
    HeapProfile,
    LeaksProfile,
    MemgraphProfile,
    ProfileAllProcesses,
    ProfileBundleID,
    ProfileKind,
    ProfileLaunch,
    ProfilePid,
    ProfileResult,
    ProfileTarget,
    ResourceSampleScope,
    ResourcesProfile,
    SampleProfile,
    TraceProfile,
    VmmapProfile,
)


def target_from_args(args: Namespace) -> ProfileTarget:
    if args.pid is not None:
        return ProfilePid(pid=args.pid)
    if args.bundle_id is not None:
        return ProfileBundleID(bundle_id=args.bundle_id)
    if getattr(args, "launch", None) is not None:
        return ProfileLaunch(bundle_id=args.launch)
    return ProfileAllProcesses()


def human_format_trace(report: dict[str, object]) -> str:
    lines: list[str] = []
    # pyre-ignore[16]: the report is the JSON of a `ProfileTraceReport`.
    for table in report["tables"]:
        rows = table["rows"]
        lines.append(f"{table['schema']} ({len(rows)} of {table['rowCount']} rows)")
        lines.append("\t".join(column["name"] for column in table["columns"]))
        for row in rows:
            lines.append("\t".join(_human_format_trace_value(v) for v in row["values"]))
        lines.append("")
    return "\n".join(lines)


def _human_format_trace_value(value: dict[str, object]) -> str:
    if "text" in value:
        return str(value["text"])
    if "backtrace" in value:
        # pyre-ignore[16]: a backtrace holds frames.
        return " < ".join(frame["symbol"] for frame in value["backtrace"]["frames"])
    return ""


def human_format_resource_sample(sample: dict[str, object]) -> str:
    # pyrefly: ignore[invalid-argument]
    cpu = f"{sample['cpuPct']:.1f}%" if "cpuPct" in sample else "-"
    return (
        f"{sample['elapsedMs']}ms {sample['processName']}({sample['pid']}) cpu={cpu} "
        f"footprint={sample['footprintBytes']} resident={sample['residentBytes']}"
    )


class ProfileCommand(ClientCommand):
    """Prints what the tool wrote, or the report parsed from it with --json."""

    writes_artifact: bool = False

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        target = parser.add_mutually_exclusive_group(required=True)
        target.add_argument("--pid", type=int, help="Profile the process with this pid")
        target.add_argument(
            "--bundle-id",
            type=str,
            help="Profile the running process of this installed application",
        )
        self.add_target_arguments(target)
        if self.writes_artifact:
            parser.add_argument(
                "--output",
                type=str,
                help="Write the file the profiler records to this path on the client host",
            )
        super().add_parser_arguments(parser)

    def add_target_arguments(self, target: _MutuallyExclusiveGroup) -> None:
        pass

    @abstractmethod
    def kind(self, args: Namespace) -> ProfileKind:
        pass

    def stop_event(self, args: Namespace) -> asyncio.Event:
        return asyncio.Event()

    def print_result(self, args: Namespace, result: ProfileResult) -> None:
        if args.json:
            print(json.dumps(result.report))
            return
        sys.stdout.buffer.write(result.tool_output)
        sys.stdout.buffer.flush()

    def print_sample(self, args: Namespace, sample: dict[str, object]) -> None:
        pass

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        result = await client.profile(
            kind=self.kind(args),
            target=target_from_args(args),
            stop=self.stop_event(args),
            artifact_path=getattr(args, "output", None),
            on_sample=lambda sample: self.print_sample(args, sample),
        )
        self.print_result(args, result)
        if result.artifact is not None:
            print(f"Wrote {result.artifact}", file=sys.stderr)


class ProfileLeaksCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "leaks"

    @property
    def description(self) -> str:
        return "Find leaked memory in a process"

    def kind(self, args: Namespace) -> ProfileKind:
        return LeaksProfile()


class ProfileMemgraphCommand(ProfileCommand):
    writes_artifact = True

    @property
    def name(self) -> str:
        return "memgraph"

    @property
    def description(self) -> str:
        return "Capture a process's memory graph, reporting its leaks"

    def kind(self, args: Namespace) -> ProfileKind:
        return MemgraphProfile()


class ProfileHeapCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "heap"

    @property
    def description(self) -> str:
        return "Summarize a process's heap allocations by class"

    def kind(self, args: Namespace) -> ProfileKind:
        return HeapProfile()


class ProfileSampleCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "sample"

    @property
    def description(self) -> str:
        return "Sample a process's call stacks"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "--duration", type=int, help="Seconds to sample for (default: 10)"
        )
        super().add_parser_arguments(parser)

    def kind(self, args: Namespace) -> ProfileKind:
        return SampleProfile(seconds=args.duration)


class ProfileVmmapCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "vmmap"

    @property
    def description(self) -> str:
        return "Summarize a process's virtual memory regions"

    def kind(self, args: Namespace) -> ProfileKind:
        return VmmapProfile()


class ProfileFootprintCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "footprint"

    @property
    def description(self) -> str:
        return "Break down a process's memory footprint by category"

    def kind(self, args: Namespace) -> ProfileKind:
        return FootprintProfile()


class ProfileResourcesCommand(ProfileCommand):
    @property
    def name(self) -> str:
        return "resources"

    @property
    def description(self) -> str:
        return "Sample a process's CPU, memory, disk and energy use until ^C"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "--interval-ms",
            type=int,
            help="Milliseconds between samples (default: 1000)",
        )
        parser.add_argument(
            "--include-helpers",
            action="store_true",
            default=False,
            help="Include the application's helper processes",
        )
        parser.add_argument(
            "--duration", type=float, help="Seconds to sample for, instead of until ^C"
        )
        super().add_parser_arguments(parser)

    def kind(self, args: Namespace) -> ProfileKind:
        return ResourcesProfile(
            interval_ms=args.interval_ms,
            scope=(
                ResourceSampleScope.APP_AND_HELPERS
                if args.include_helpers
                else ResourceSampleScope.APP
            ),
        )

    def stop_event(self, args: Namespace) -> asyncio.Event:
        stop = signal_handler_event("profile resources")
        if args.duration is not None:
            asyncio.get_running_loop().call_later(args.duration, stop.set)
        return stop

    def print_sample(self, args: Namespace, sample: dict[str, object]) -> None:
        print(json.dumps(sample) if args.json else human_format_resource_sample(sample))
        sys.stdout.flush()

    def print_result(self, args: Namespace, result: ProfileResult) -> None:
        pass


class ProfileTraceCommand(ProfileCommand):
    writes_artifact = True

    @property
    def name(self) -> str:
        return "trace"

    @property
    def description(self) -> str:
        return "Record an Instruments trace and report its tables"

    def add_target_arguments(self, target: _MutuallyExclusiveGroup) -> None:
        target.add_argument(
            "--launch",
            type=str,
            metavar="BUNDLE_ID",
            help="Launch this installed application, so the trace covers its startup",
        )
        target.add_argument(
            "--all-processes",
            action="store_true",
            default=False,
            help="Trace every process on the target",
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "--template",
            type=str,
            help="The Instruments template to record with (default: Time Profiler)",
        )
        parser.add_argument(
            "--schema",
            dest="schemas",
            action="append",
            default=[],
            help="A table to export, such as time-profile; repeatable (default: the tables the template is known for)",
        )
        parser.add_argument(
            "--duration",
            type=float,
            help="Seconds to record for, unless stopped sooner with ^C",
        )
        parser.add_argument(
            "--row-limit",
            type=int,
            help="The most rows of each table to report (default: every row)",
        )
        super().add_parser_arguments(parser)

    def kind(self, args: Namespace) -> ProfileKind:
        return TraceProfile(
            template=args.template,
            schemas=tuple(args.schemas),
            duration=args.duration,
            row_limit=args.row_limit,
        )

    def stop_event(self, args: Namespace) -> asyncio.Event:
        return signal_handler_event("profile trace")

    def print_result(self, args: Namespace, result: ProfileResult) -> None:
        trace = None if result.report is None else result.report.get("trace")
        if args.json or not isinstance(trace, dict):
            super().print_result(args, result)
            return
        print(human_format_trace(trace))
