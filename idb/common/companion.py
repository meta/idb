#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import json
import logging
import os
import subprocess
from collections.abc import AsyncGenerator, Sequence
from dataclasses import dataclass
from datetime import timedelta
from logging import DEBUG as LOG_LEVEL_DEBUG, Logger
from typing import Union

from idb.common.constants import IDB_LOGS_PATH
from idb.common.file import get_last_n_lines
from idb.common.format import (
    target_description_from_json,
    target_descriptions_from_json,
)
from idb.common.logging import log_call
from idb.common.types import (
    Architecture,
    Companion as CompanionBase,
    ECIDFilter,
    IdbException,
    OnlyFilter,
    TargetDescription,
    TargetType,
)
from idb.utils.contextlib import asynccontextmanager
from idb.utils.typing import none_throws


DEFAULT_ERASE_COMMAND_TIMEOUT = timedelta(minutes=3)
DEFAULT_COMPANION_COMMAND_TIMEOUT = timedelta(seconds=120)
DEFAULT_COMPANION_TEARDOWN_TIMEOUT = timedelta(seconds=30)


CompanionReport = dict[str, Union[int, str]]


class IdbJsonException(Exception):
    pass


class CompanionSpawnerException(Exception):
    pass


async def _terminate_process(
    process: asyncio.subprocess.Process, timeout: timedelta, logger: logging.Logger
) -> None:
    returncode = process.returncode
    if returncode is not None:
        logger.info(f"Process has exited with {returncode}")
        return
    logger.info(f"Stopping process with SIGTERM, waiting {timeout}")
    process.terminate()
    try:
        returncode = await asyncio.wait_for(
            process.wait(), timeout=timeout.total_seconds()
        )
        logger.info(f"Process has exited after SIGTERM with {returncode}")
    except TimeoutError:
        logger.info(f"Process hasn't exited after {timeout}, SIGKILL'ing...")
        process.kill()


def _only_arg_from_filter(only: OnlyFilter | None) -> list[str]:
    if isinstance(only, TargetType):
        if only == TargetType.MAC:
            return []
        return ["--only", only.value]
    elif isinstance(only, ECIDFilter):
        return ["--only", f"ecid:{only.ecid}"]
    return []


def parse_json_line(line: bytes) -> dict[str, int | str]:
    decoded_line = line.decode()
    try:
        return json.loads(decoded_line)
    except json.JSONDecodeError:
        raise IdbJsonException(f"Failed to parse json from: {decoded_line}")


async def _extract_companion_report_from_spawned_companion(
    stream: asyncio.StreamReader, log_file_path: str
) -> CompanionReport:
    try:
        # The first line of stdout should contain launch info,
        # otherwise something bad has happened
        line = await stream.readline()
        logging.debug(f"Read line from companion: {line}")
        update = parse_json_line(line)
        logging.debug(f"Got update from companion: {update}")
        return update
    except Exception as e:
        raise CompanionSpawnerException(
            f"Failed to spawn companion, couldn't read report "
            f"stderr: {get_last_n_lines(log_file_path, 30)}"
        ) from e


async def _verify_port_from_spawned_companion(
    report: CompanionReport,
    port_name: str,
    log_file_path: str,
    expected_port: int | None,
) -> int:
    try:
        extracted_port = int(report[port_name])
    except Exception as e:
        raise CompanionSpawnerException(
            f"Failed to spawn companion, couldn't read {port_name} output "
            f"stderr: {get_last_n_lines(log_file_path, 30)}"
        ) from e
    if extracted_port == 0:
        raise CompanionSpawnerException(
            f"Failed to spawn companion, {port_name} zero is invalid "
            f"stderr: {get_last_n_lines(log_file_path, 30)}"
        )
    if (
        expected_port is not None
        and expected_port != 0
        and extracted_port != expected_port
    ):
        raise CompanionSpawnerException(
            f"Failed to spawn companion, invalid {port_name} "
            f"(expected {expected_port} got {extracted_port})"
            f"stderr: {get_last_n_lines(log_file_path, 30)}"
        )
    return extracted_port


async def _extract_domain_sock_from_spawned_companion(
    stream: asyncio.StreamReader, log_file_path: str
) -> str:
    update = await _extract_companion_report_from_spawned_companion(
        stream=stream, log_file_path=log_file_path
    )
    return str(update["grpc_path"])


@dataclass(frozen=True)
class CompanionServerConfig:
    udid: str
    only: OnlyFilter
    log_file_path: str | None
    cwd: str | None
    tmp_path: str | None
    reparent: bool


class Companion(CompanionBase):
    def __init__(
        self,
        companion_path: str,
        device_set_path: str | None,
        logger: Logger,
        architecture: Architecture = Architecture.ANY,
        only: OnlyFilter | None = None,
    ) -> None:
        self._companion_path = companion_path
        self._device_set_path = device_set_path
        self._logger = logger
        self._architecture = architecture
        self._only = only

    @asynccontextmanager
    async def _start_companion_command(
        self, arguments: list[str]
    ) -> AsyncGenerator[asyncio.subprocess.Process, None]:
        cmd: list[str] = []
        if self._architecture != Architecture.ANY:
            cmd = ["arch", "-" + self._architecture.value]
        cmd += [self._companion_path]
        device_set_path = self._device_set_path
        if device_set_path is not None:
            cmd.extend(["--device-set-path", device_set_path])
        if self._only is not None:
            cmd.extend(_only_arg_from_filter(only=self._only))
        cmd.extend(arguments)
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=subprocess.PIPE,
            stderr=(
                None
                if self._logger.getEffectiveLevel() <= LOG_LEVEL_DEBUG
                else subprocess.DEVNULL
            ),
        )
        logger = self._logger.getChild(f"{process.pid}:{' '.join(cmd)}")
        logger.info("Launched process")
        try:
            yield process
        finally:
            await _terminate_process(
                process=process,
                timeout=DEFAULT_COMPANION_TEARDOWN_TIMEOUT,
                logger=logger,
            )

    async def _run_companion_command(
        self, arguments: list[str], timeout: timedelta | None
    ) -> str:
        timeout = timeout if timeout is not None else DEFAULT_COMPANION_COMMAND_TIMEOUT
        async with self._start_companion_command(arguments=arguments) as process:
            try:
                (output, _) = await asyncio.wait_for(
                    process.communicate(), timeout=timeout.total_seconds()
                )
                if process.returncode != 0:
                    message = f"Failed to run {arguments}"
                    self._logger.error(f"{message}. Output: [[{output}]]")
                    raise IdbException(message)
                self._logger.info(f"Ran {arguments} successfully.")
                return output.decode()
            except asyncio.TimeoutError:
                raise IdbException(
                    f"Timed out after {timeout} secs on command {' '.join(arguments)}"
                )

    async def _run_udid_command(
        self,
        udid: str,
        command: str,
        timeout: timedelta | None,
        extra_arguments: Sequence[str] | None = None,
    ) -> str:
        arguments = [f"--{command}", udid]
        if extra_arguments is not None:
            arguments.extend(extra_arguments)
        return await self._run_companion_command(
            arguments=[f"--{command}", udid], timeout=timeout
        )

    def _log_file_path(self, target_udid: str) -> str:
        os.makedirs(name=IDB_LOGS_PATH, exist_ok=True)
        return IDB_LOGS_PATH + "/" + target_udid

    async def _spawn_server(
        self,
        config: CompanionServerConfig,
        port_env_variables: dict[str, str],
        bind_arguments: list[str],
    ) -> tuple[asyncio.subprocess.Process, str]:
        if os.getuid() == 0:
            logging.warning(
                "idb should not be run as root. "
                "Listing available targets on this host and spawning "
                "companions will not work"
            )
        arguments: list[str] = []
        if self._architecture != Architecture.ANY:
            arguments = ["arch", "-" + self._architecture.value]
        arguments += (
            [
                self._companion_path,
                "--udid",
                config.udid,
            ]
            + bind_arguments
            + _only_arg_from_filter(config.only)
        )
        log_file_path = config.log_file_path
        if log_file_path is None:
            log_file_path = self._log_file_path(config.udid)
        device_set_path = self._device_set_path
        if device_set_path is not None:
            arguments.extend(["--device-set-path", device_set_path])

        env = dict(os.environ)
        if config.tmp_path:
            # Companions ignore an inherited TMPDIR in favour of IDB_COMPANION_TMPDIR;
            # older ones read only TMPDIR.
            env["IDB_COMPANION_TMPDIR"] = config.tmp_path
            env["TMPDIR"] = config.tmp_path
        if port_env_variables:
            env.update(port_env_variables)

        with open(log_file_path, "a") as log_file:
            process = await asyncio.create_subprocess_exec(
                *arguments,
                stdout=asyncio.subprocess.PIPE,
                stdin=asyncio.subprocess.PIPE if config.reparent else None,
                stderr=log_file,
                cwd=config.cwd,
                env=env,
                preexec_fn=os.setpgrp if config.reparent else None,
            )
            logging.debug(f"started companion at process id {process.pid}")
            return (process, log_file_path)

    async def spawn_tcp_server(
        self,
        config: CompanionServerConfig,
        port: int | None,
        swift_port: int | None = None,
        tls_cert_path: str | None = None,
        debug_port: int | None = None,
    ) -> tuple[asyncio.subprocess.Process, int, int | None]:
        port_env_variables: dict[str, str] = {}
        if swift_port is not None:
            port_env_variables["IDB_SWIFT_COMPANION_PORT"] = str(swift_port)

        bind_arguments = ["--grpc-port", str(port) if port is not None else "0"]
        if debug_port is not None:
            bind_arguments.extend(["--debug-port", str(debug_port)])
        if tls_cert_path is not None:
            bind_arguments.extend(["--tls-cert-path", tls_cert_path])
        (process, log_file_path) = await self._spawn_server(
            config=config,
            port_env_variables=port_env_variables,
            bind_arguments=bind_arguments,
        )
        stdout = none_throws(process.stdout)
        companion_report = await _extract_companion_report_from_spawned_companion(
            stream=stdout, log_file_path=log_file_path
        )
        extracted_port = await _verify_port_from_spawned_companion(
            companion_report, "grpc_port", log_file_path, port
        )

        extracted_swift_port: int | None = None
        if swift_port:
            try:
                extracted_swift_port = await _verify_port_from_spawned_companion(
                    companion_report,
                    "grpc_swift_port",
                    log_file_path,
                    swift_port,
                )
            except Exception:
                self._logger.exception("Failed to verify SWIFT GRPC port")
        else:
            self._logger.info("Swift server not requested, skipping verification")

        return (process, extracted_port, extracted_swift_port)

    async def spawn_domain_sock_server(
        self, config: CompanionServerConfig, path: str
    ) -> asyncio.subprocess.Process:
        (process, log_file_path) = await self._spawn_server(
            config=config,
            port_env_variables={},
            bind_arguments=["--grpc-domain-sock", path],
        )
        stdout = none_throws(process.stdout)
        try:
            extracted_path = await _extract_domain_sock_from_spawned_companion(
                stream=stdout, log_file_path=log_file_path
            )
        except Exception as e:
            raise CompanionSpawnerException(
                f"Failed to spawn companion, couldn't read domain socket path "
                f"stderr: {get_last_n_lines(log_file_path, 30)}"
            ) from e
        if not extracted_path:
            raise CompanionSpawnerException(
                f"Failed to spawn companion, no extracted domain socket path "
                f"stderr: {get_last_n_lines(log_file_path, 30)}"
            )
        if extracted_path != path:
            raise CompanionSpawnerException(
                "Failed to spawn companion, extracted domain socket path "
                f"is not correct (expected {path} got {extracted_path})"
                f"stderr: {get_last_n_lines(log_file_path, 30)}"
            )
        return process

    @log_call()
    async def create(
        self, device_type: str, os_version: str, timeout: timedelta | None = None
    ) -> TargetDescription:
        output = await self._run_companion_command(
            arguments=["--create", f"{device_type},{os_version}"], timeout=timeout
        )
        return target_description_from_json(output.splitlines()[-1])

    @log_call()
    async def boot(
        self, udid: str, verify: bool = True, timeout: timedelta | None = None
    ) -> None:
        await self._run_udid_command(
            udid=udid,
            command="boot",
            timeout=timeout,
            extra_arguments=["--verify-booted", "1" if verify else "0"],
        )

    @asynccontextmanager
    async def boot_headless(
        self, udid: str, verify: bool = True, timeout: timedelta | None = None
    ) -> AsyncGenerator[None, None]:
        async with self._start_companion_command(
            [
                "--headless",
                "1",
                "--boot",
                udid,
                "--verify-booted",
                "1" if verify else "0",
            ]
        ) as process:
            # The first line written to stdout is information about the booted sim.
            data = await asyncio.wait_for(
                none_throws(process.stdout).readline(),
                timeout=None if timeout is None else timeout.total_seconds(),
            )
            line = data.decode()
            target = target_description_from_json(line)
            self._logger.info(f"{target} is now booted")
            yield None
            self._logger.info(f"Done with {target}. Shutting down.")

    @log_call()
    async def shutdown(self, udid: str, timeout: timedelta | None = None) -> None:
        await self._run_udid_command(udid=udid, command="shutdown", timeout=timeout)

    @log_call()
    async def erase(
        self, udid: str, timeout: timedelta = DEFAULT_ERASE_COMMAND_TIMEOUT
    ) -> None:
        await self._run_udid_command(udid=udid, command="erase", timeout=timeout)

    @log_call()
    async def clone(
        self,
        udid: str,
        destination_device_set: str | None = None,
        timeout: timedelta | None = None,
    ) -> TargetDescription:
        arguments = ["--clone", udid]
        if destination_device_set is not None:
            arguments.extend(["--clone-destination-set", destination_device_set])
        output = await self._run_companion_command(arguments=arguments, timeout=timeout)
        return target_description_from_json(output.splitlines()[-1])

    @log_call()
    async def delete(self, udid: str | None, timeout: timedelta | None = None) -> None:
        await self._run_udid_command(
            udid=udid if udid is not None else "all", command="delete", timeout=timeout
        )

    @log_call()
    async def clean(self, udid: str, timeout: timedelta | None = None) -> None:
        await self._run_udid_command(udid=udid, command="clean", timeout=timeout)

    @log_call()
    async def list_targets(
        self, only: OnlyFilter | None = None, timeout: timedelta | None = None
    ) -> list[TargetDescription]:
        arguments = ["--list", "1"] + _only_arg_from_filter(only=only)
        output = await self._run_companion_command(arguments=arguments, timeout=timeout)
        return [
            target_description_from_json(data=line.strip())
            for line in output.splitlines()
            if len(line.strip())
        ]

    async def tail_targets(
        self, only: OnlyFilter | None = None
    ) -> AsyncGenerator[list[TargetDescription], None]:
        arguments = ["--notify", "stdout"] + _only_arg_from_filter(only=only)
        async with self._start_companion_command(arguments=arguments) as process:
            async for line in none_throws(process.stdout):
                yield target_descriptions_from_json(data=line.decode().strip())

    @log_call()
    async def target_description(
        self,
        udid: str | None = None,
        only: OnlyFilter | None = None,
        timeout: timedelta | None = None,
    ) -> TargetDescription:
        all_details = await self.list_targets(only=only, timeout=timeout)
        details = all_details
        if udid is not None:
            details = [target for target in all_details if target.udid == udid]
        if len(details) > 1:
            raise IdbException(f"More than one device info found {details}")
        if len(details) == 0:
            raise IdbException(f"No device info found, got {all_details}")
        return details[0]

    @asynccontextmanager
    async def unix_domain_server(
        self, udid: str, path: str, only: OnlyFilter | None = None
    ) -> AsyncGenerator[str, None]:
        async with self._start_companion_command(
            ["--udid", udid, "--grpc-domain-sock", path]
            + _only_arg_from_filter(only=only)
        ) as process:
            line = await none_throws(process.stdout).readline()
            output = parse_json_line(line)
            grpc_path = output.get("grpc_path")
            if grpc_path is None:
                raise IdbException(f"No grpc_path in {line}")
            self._logger.info(f"Started domain sock server on {grpc_path}")
            yield grpc_path if isinstance(grpc_path, str) else str(grpc_path)
