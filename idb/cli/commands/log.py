#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import os
import stat
import sys
from argparse import ArgumentParser, Namespace, REMAINDER
from collections.abc import AsyncIterator, Callable, Iterator
from contextlib import contextmanager

from idb.cli import ClientCommand
from idb.common.signal import signal_handler_event
from idb.common.types import Client


async def _print_log(chunks: AsyncIterator[str], stop: asyncio.Event) -> None:
    with _stop_when_stdout_loses_its_reader(stop) as reader_gone:
        try:
            async for chunk in chunks:
                # Standard output is block-buffered when it is a file or a pipe, which
                # would hold back a quiet stream's lines for as long as it runs.
                print(chunk, end="", flush=True)
            print("", flush=True)
        except BrokenPipeError:
            # The reader has gone, as `head` does once it has its lines: cancel the
            # stream as an interrupt does, and end without an error. Standard output
            # is discarded first, so the exit stays quiet even if the cancel fails.
            reader_gone()
            async for _ in chunks:
                pass


@contextmanager
def _stop_when_stdout_loses_its_reader(
    stop: asyncio.Event,
) -> Iterator[Callable[[], None]]:
    # A write would notice the reader has gone, but a quiet stream may not write
    # again for a long time, so the pipe is watched instead.
    fd = _stdout_pipe()
    loop = asyncio.get_running_loop()

    def reader_gone() -> None:
        # The watch goes first: once standard output leads to /dev/null, the loop
        # cannot remove it, and epoll keeps reporting the closed pipe for as long
        # as another descriptor, such as stderr after `2>&1`, holds it open.
        if fd is not None:
            loop.remove_reader(fd)
        _discard_stdout()
        stop.set()

    if fd is None:
        yield reader_gone
        return
    # A read watch on the write end of a pipe fires only when the read end has
    # closed: there is never anything to read, but once nothing reads the pipe,
    # epoll reports an error on the write end and kqueue reports EOF, and the
    # loop treats either as ready.
    loop.add_reader(fd, reader_gone)
    try:
        yield reader_gone
    finally:
        loop.remove_reader(fd)


def _stdout_pipe() -> int | None:
    try:
        fd = sys.stdout.fileno()
        is_pipe = stat.S_ISFIFO(os.fstat(fd).st_mode)
    except (AttributeError, OSError):
        return None
    return fd if is_pipe else None


def _discard_stdout() -> None:
    # Python flushes stdout again at exit, which would fail the same way, so
    # what is still buffered goes to /dev/null instead.
    try:
        fd = sys.stdout.fileno()
    except (AttributeError, OSError):
        return
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, fd)
    os.close(devnull)


class LogCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Obtain logs from the target"

    @property
    def name(self) -> str:
        return "log"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "log_arguments",
            help="""\
Example: idb log -- --style json
Possible arguments:
--system | --process (pid|process) | --parent (pid|process) ]
    [ --level default|info|debug][ --predicate <predicate> ]
    [ --source ][ --style (syslog|json) ]
    [ --timeout <num>[m|h|d] ][ --type activity|log|trace ]

Examples:
log stream --level=info
log stream --predicate examples:
    --predicate 'eventMessage contains "my message"'
    --predicate 'eventType == logEvent and messageType == info'
    --predicate 'processImagePath endswith "d"'
    --predicate 'not processImagePath contains[c] "some spammer"'
    --predicate 'processID < 100'
    --predicate 'senderImagePath beginswith "my sender"'""",
            default=[],
            nargs=REMAINDER,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        stop = signal_handler_event("log")
        await _print_log(
            client.tail_logs(
                stop=stop, arguments=self.normalise_log_arguments(args.log_arguments)
            ),
            stop,
        )

    def normalise_log_arguments(
        self, log_arguments: list[str] | None
    ) -> list[str] | None:
        if log_arguments is None:
            return None

        if len(log_arguments) > 0 and log_arguments[0] == "--":
            log_arguments = log_arguments[1:]

        return log_arguments


class CompanionLogCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Obtain logs from the companion"

    @property
    def name(self) -> str:
        return "log"

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        stop = signal_handler_event("log")
        await _print_log(client.tail_companion_logs(stop=stop), stop)
