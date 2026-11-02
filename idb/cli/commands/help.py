#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


from argparse import ArgumentParser, Namespace

import idb.common.plugin as plugin
from idb.cli import BaseCommand
from idb.common.types import IdbException

_AGENT_GUIDE = """\
idb agent guide

This guide is for coding agents and automation driving iOS simulators and devices through idb. The CLI is the source of truth for its own commands: `idb <command> --help` describes every flag; this guide describes the workflow expectations that make automated sessions reliable.

Read before acting
- Prefer reading the accessibility tree over screenshots: `idb ui describe-all --json` returns every element in the tree, including layout containers and rows scrolled off screen.
- To find what you can act on, add `--filter interactable`: `idb ui describe-all --json --filter interactable` reports only on-screen elements that are actionable or carry a label or identifier, and leaves out zero-sized and offscreen ones.
- `--format nested` preserves the element hierarchy; `--format complete` returns a consolidated document that also names the backend that served the read.
- Narrow reads: `idb ui describe <marker>` describes one element by its accessibility identity; `idb ui describe-point <x> <y>` by position.

Wait for element presence
- On simulators, use `idb ui wait <marker> --match-key AXUniqueId --timeout 30` to let the companion poll for an element. Use this instead of busy-looping on `describe-all` or adding fixed sleeps while waiting for a screen to update.
- Matching is a case-sensitive substring; omit `--match-key` to match a label.
- With `--json`, a match returns `{"found": true}`. A timeout returns `found: false`, an `error` message, and a nonzero exit status. When available, `diagnostics` contains nonmatching values of the searched key from the final poll, separate `sample_truncated` and `read_truncated` flags, and any read error. The legacy `truncated` flag covers either kind; separate flags are null with older companions; `read_truncated` is also null when the backend cannot report tree completeness. Other failures remain errors.
- Presence does not establish visibility or hittability. Read the element again when you need its properties before acting.

Interact by element identity, not coordinates
- `idb ui tap <marker> --match-key AXUniqueId` resolves the accessibility element and invokes its press action, so it does not drift with layout, scale, or scroll position the way coordinate taps do.
- `idb ui set-value` and `idb ui scroll` address elements the same way.
- When an element exposes no AXUniqueId but you can name what is on screen, tap it by its visible label: `idb ui tap "<label>"` - the label is the default match key, and it works on surfaces that never set identifiers.
- Coordinate taps (`idb ui tap <x> <y>`) are a last resort for targets with neither identifier nor label. When one is genuinely required, record why with `--reason`.

Profile through `idb profile`
- `idb profile <kind> --bundle-id <id> --json` reports leaks, heap, call stacks, memory and Instruments traces as structured JSON parsed on the companion, so it reads the same from any client host. `idb help agent profiling` covers choosing a kind.

Record intent
- `--reason "<why>"` is accepted by every command and records the intent of the invocation for the operators of the host being driven. Supply it whenever the purpose of a command is not obvious from the command itself, and always for coordinate taps and screenshots.

Identify yourself
- idb recognizes standard agent environment signals, in priority order: AI_AGENT (user-agent style, `AI_AGENT=<product>/<version>/<mode>` - the preferred contract), AGENT (a bare product name), CODING_AGENT_METADATA (the structured channel: comma-separated key=value pairs, for example `CODING_AGENT_METADATA=id=<agent-product>,session_id=<uuid>`, carrying session and invocation identity), and CLAUDECODE=1.
- If your harness sets none of these, export one so tooling can distinguish agent traffic from human sessions.
"""

_AGENT_PROFILING_GUIDE = """\
idb agent guide: profiling

`idb profile` runs a profiler against one process on the target and reports what it found. Pass `--json` for the structured report: keys are camelCase, zero values are kept, and byte counts are plain integers. Without `--json` you get the profiler's own text output.

Choose a kind
- Leaked memory: `idb profile leaks`. Add the memory graph for Xcode's debugger with `idb profile memgraph --output app.memgraph`.
- What is on the heap: `idb profile heap` reports allocation counts and bytes per class.
- Where time goes right now: `idb profile sample --duration 5` reports the heaviest call stacks per thread.
- Memory by region or category: `idb profile vmmap` and `idb profile footprint`.
- CPU, memory, disk and energy over time: `idb profile resources --duration 30 --json` prints one JSON object per sample, as it is taken.
- An Instruments recording: `idb profile trace --template "Time Profiler" --duration 10 --json` records, then reports the template's tables (Time Profiler reports time-profile; Hangs reports potential-hangs). `--schema` picks other tables and `--row-limit` bounds them. `--output app.trace` keeps the bundle for Instruments.

Target the process
- `--bundle-id` profiles the running instance of an installed application; `--pid` profiles a process directly.
- To cover an app's startup, `idb profile trace --launch <bundle-id>` launches it under the recording. `--all-processes` traces the whole target.

Stopping and failures
- `resources` and `trace` run until `--duration` elapses or you interrupt them. Interrupting ends them cleanly: `trace` still exports what it recorded. The other kinds run to completion on their own.
- If the profiled process exits or the profiler fails, the command fails promptly with the profiler's error rather than waiting.
- Tracing a simulator in a custom device set needs idb's test shim on the companion host.
"""

# Topic key -> (one-line summary, body). Subtopic words join with "-", so
# `idb help agent performance` resolves the key "agent-performance".
_TOPICS: dict[str, tuple[str, str]] = {
    "agent": ("guidance for coding agents and automation driving idb", _AGENT_GUIDE),
    "agent-profiling": (
        "choosing and reading `idb profile` reports",
        _AGENT_PROFILING_GUIDE,
    ),
}


def _topic_list() -> str:
    lines = ["Topics served by this idb build:"]
    for key, (summary, _) in sorted(_TOPICS.items()):
        lines.append(f"  {key} - {summary}")
    lines.append("Run `idb help <topic>` to read one.")
    return "\n".join(lines)


class HelpCommand(BaseCommand):
    @property
    def description(self) -> str:
        return "Topic guides served by the CLI itself (see `idb help agent`)"

    @property
    def name(self) -> str:
        return "help"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "topic",
            nargs="*",
            help="Topic words, joined to a key (`agent performance` reads "
            "the agent-performance topic). Omit to list topics.",
        )
        super().add_parser_arguments(parser)

    async def _run_impl(self, args: Namespace) -> None:
        key = "-".join(args.topic)
        if not key:
            print(_topic_list())
            return
        topic = _TOPICS.get(key)
        # Plugins may extend a topic or serve topics of their own, so an
        # unknown key only fails once the plugins had their say.
        contributed = plugin.get_agent_instructions(names=list(args.topic))
        if topic is None and not contributed:
            raise IdbException(f"No help topic '{key}'.\n{_topic_list()}")
        sections = [
            section for section in (topic[1] if topic else "", contributed) if section
        ]
        print("\n".join(sections))
