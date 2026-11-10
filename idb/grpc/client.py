#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import codecs
import functools
import inspect
import json
import logging
import os
import shutil
import sys
import tempfile
import urllib.parse
from asyncio import StreamReader, StreamWriter
from collections.abc import (
    AsyncGenerator,
    AsyncIterable,
    AsyncIterator,
    Callable,
    Iterable,
)
from io import StringIO
from pathlib import Path
from typing import Any

import idb.common.plugin as plugin
from grpclib.client import Channel
from grpclib.exceptions import GRPCError, ProtocolError, StreamTerminatedError
from idb.common.constants import TESTS_POLL_INTERVAL
from idb.common.file import drain_to_file, generate_file_chunks
from idb.common.format import json_format_debugger_info
from idb.common.gzip import drain_gzip_decompress, gunzip
from idb.common.hid import (
    button_press_to_events,
    iterator_to_async_iterator,
    key_press_to_events,
    multi_tap_to_events,
    pinch_to_events,
    rotate_to_events,
    shake_to_events,
    swipe_to_events,
    tap_to_events,
    text_to_events,
)
from idb.common.logging import log_call
from idb.common.stream import stream_map
from idb.common.tar import create_tar, drain_untar, generate_tar
from idb.common.types import (
    AccessibilityBackend,
    AccessibilityDragOptions,
    AccessibilityInfo,
    AccessibilityInfoOptions,
    AccessibilityMarker,
    AccessibilityPoint,
    AccessibilityScrollDirection,
    AccessibilitySearchableKey,
    AccessibilitySearchDiagnostics,
    AccessibilityTarget,
    AccessibilityWaitResult,
    Address,
    AppProcessState,
    Client as ClientBase,
    CodeCoverageFormat,
    Companion,
    CompanionInfo,
    Compression,
    CrashLog,
    CrashLogInfo,
    CrashLogQuery,
    DEFAULT_SCREENSHOT_OPTIONS,
    DeliveredNotification,
    DeviceOrientation,
    DomainSocketAddress,
    FileContainer,
    FileContainerType,
    FileEntryInfo,
    FileListing,
    HIDButtonType,
    HIDEvent,
    HIDHinge,
    HIDOrientationType,
    IdbConnectionException,
    IdbException,
    InstalledAppInfo,
    InstalledArtifact,
    InstalledTestInfo,
    LockState,
    LoggingMetadata,
    OnlyFilter,
    Permission,
    ProfileKind,
    ProfileResult,
    ProfileTarget,
    QuiescenceBackend,
    QuiescenceEvent,
    QuiescenceState,
    QuiescenceStateChanged,
    QuiescenceTargetChanged,
    QuiescenceTargetExited,
    QuiescenceTouchesCompleted,
    RecordedAudio,
    RetryVerdict,
    Screenshot,
    ScreenshotOptions,
    TargetDescription,
    TCPAddress,
    TestRunInfo,
    VideoFormat,
)
from idb.grpc.accessibility import accessibility_info_to_grpc
from idb.grpc.crash import (
    _to_crash_log,
    _to_crash_log_info_list,
    crash_log_query_to_grpc,
)
from idb.grpc.dap import RemoteDapServer
from idb.grpc.file import container_to_grpc as file_container_to_grpc
from idb.grpc.hid import event_to_grpc
from idb.grpc.idb_grpc import CompanionServiceStub
from idb.grpc.idb_pb2 import (
    AccessibilityActionRequest,
    AccessibilityActionResponse,
    AccessibilityQuiescenceRequest,
    AccessibilityQuiescenceResponse,
    AddMediaRequest,
    ANY as AnySetting,
    ApproveRequest,
    ClearDeliveredNotificationsRequest,
    ClearKeychainRequest,
    ConnectRequest,
    ContactsClearRequest,
    ContactsUpdateRequest,
    CrashShowRequest,
    DebugServerRequest,
    DebugServerResponse,
    DeliveredNotificationsRequest,
    FocusRequest,
    GetOrientationRequest,
    GetOrientationResponse,
    GetSettingRequest,
    HingeAngleRequest,
    InjectAudioRequest,
    InjectVideoRequest,
    InstallRequest,
    LaunchRequest,
    ListAppsRequest,
    ListSettingRequest,
    LOCALE as LocaleSetting,
    Location,
    LockScreenRequest,
    LogRequest,
    LsRequest,
    MkdirRequest,
    MvRequest,
    OpenUrlRequest,
    Payload,
    PhotosClearRequest,
    PullRequest,
    PushRequest,
    RecordRequest,
    RecordResponse,
    RevokeRequest,
    RmRequest,
    SendNotificationRequest,
    SetLocationRequest,
    SetOrientationRequest,
    SettingRequest,
    SimulateMemoryWarningRequest,
    TailRequest,
    TargetDescriptionRequest,
    TerminateRequest,
    UninstallRequest,
    VideoStreamRequest,
    XctestListBundlesRequest,
    XctestListTestsRequest,
    XctestRunResponse,
    XctraceRecordRequest,
)
from idb.grpc.install import (
    Bundle,
    Destination,
    generate_binary_chunks,
    generate_io_chunks,
    generate_requests,
    ipa_size,
    remaining_size,
    select_stream_compression,
    UploadProgress,
)
from idb.grpc.launch import drain_launch_stream, wait_for_launch_stream
from idb.grpc.port_forward import forward_port
from idb.grpc.profile import (
    accepts_stop,
    drain_artifact,
    drain_profile,
    message_to_json,
    ProfileException,
    start_request,
)
from idb.grpc.screenshot import screenshot_from_grpc, screenshot_to_grpc
from idb.grpc.status_details import RetryVerdictCodec
from idb.grpc.stream import (
    cancel_wrapper,
    drain_to_stream,
    generate_bytes,
    stop_wrapper,
)
from idb.grpc.target import companion_to_py, target_to_py
from idb.grpc.video import generate_video_bytes, recorded_audio_from_grpc
from idb.grpc.xctest import (
    make_request,
    make_results,
    save_attachments,
    untar_into_path,
)
from idb.grpc.xctest_log_parser import XCTestLogParser
from idb.grpc.xctrace import xctrace_drain_until_running, xctrace_generate_bytes
from idb.utils.contextlib import asynccontextmanager


APPROVE_MAP: dict[Permission, "ApproveRequest.Permission"] = {
    Permission.PHOTOS: ApproveRequest.PHOTOS,
    Permission.CAMERA: ApproveRequest.CAMERA,
    Permission.CONTACTS: ApproveRequest.CONTACTS,
    Permission.URL: ApproveRequest.URL,
    Permission.LOCATION: ApproveRequest.LOCATION,
    Permission.NOTIFICATION: ApproveRequest.NOTIFICATION,
    Permission.MICROPHONE: ApproveRequest.MICROPHONE,
}

REVOKE_MAP: dict[Permission, "RevokeRequest.Permission"] = {
    Permission.PHOTOS: RevokeRequest.PHOTOS,
    Permission.CAMERA: RevokeRequest.CAMERA,
    Permission.CONTACTS: RevokeRequest.CONTACTS,
    Permission.URL: RevokeRequest.URL,
    Permission.LOCATION: RevokeRequest.LOCATION,
    Permission.NOTIFICATION: RevokeRequest.NOTIFICATION,
    Permission.MICROPHONE: RevokeRequest.MICROPHONE,
}

VIDEO_FORMAT_MAP: dict[VideoFormat, "VideoStreamRequest.Format"] = {
    VideoFormat.H264: VideoStreamRequest.H264,
    VideoFormat.RBGA: VideoStreamRequest.RBGA,
    VideoFormat.MJPEG: VideoStreamRequest.MJPEG,
    VideoFormat.MINICAP: VideoStreamRequest.MINICAP,
}

COMPRESSION_MAP: dict[Compression, "Payload.Compression"] = {
    Compression.GZIP: Payload.GZIP,
    Compression.ZSTD: Payload.ZSTD,
}


_QUIESCENCE_STATES: dict[int, QuiescenceState] = {
    AccessibilityQuiescenceResponse.BUSY: QuiescenceState.BUSY,
    AccessibilityQuiescenceResponse.SETTLING: QuiescenceState.SETTLING,
    AccessibilityQuiescenceResponse.QUIET: QuiescenceState.QUIET,
}

_QUIESCENCE_SIGNALS: dict[int, str] = {
    AccessibilityQuiescenceResponse.RUN_LOOP_IDLE: "run_loop_idle",
    AccessibilityQuiescenceResponse.ANIMATIONS_INACTIVE: "animations_inactive",
    AccessibilityQuiescenceResponse.SCROLL_IDLE: "scroll_idle",
    AccessibilityQuiescenceResponse.INTERACTION_ENABLED: "interaction_enabled",
}


def _quiescence_event_from_grpc(
    response: AccessibilityQuiescenceResponse,
) -> QuiescenceEvent:
    pid = response.pid
    event = response.WhichOneof("event")
    if event == "touches_completed":
        return QuiescenceTouchesCompleted(pid=pid)
    if event == "target_changed":
        return QuiescenceTargetChanged(pid=pid)
    if event == "target_exited":
        return QuiescenceTargetExited(pid=pid)
    if event != "state" or response.state.state not in _QUIESCENCE_STATES:
        raise IdbException(f"The companion sent an unknown quiescence event {event}")
    return QuiescenceStateChanged(
        pid=pid,
        state=_QUIESCENCE_STATES[response.state.state],
        # A signal newer than this client is still reported, by its number.
        busy_signals=tuple(
            _QUIESCENCE_SIGNALS.get(signal, str(signal))
            for signal in response.state.busy_signals
        ),
    )


def _idb_exception(error: GRPCError) -> IdbException:
    retry = error.details if isinstance(error.details, RetryVerdict) else None
    return IdbException(error.message, retry=retry)  # noqa B306


def log_and_handle_exceptions(grpc_method_name: str):  # pyre-ignore
    metadata: LoggingMetadata = {
        "grpc_method_name": grpc_method_name,
    }

    def decorating(func) -> Any:  # pyre-ignore:
        @functools.wraps(func)
        @log_call(name=func.__name__, metadata=metadata)
        async def func_wrapper(*args: Any, **kwargs: Any) -> Any:  # pyre-ignore
            try:
                return await func(*args, **kwargs)
            except GRPCError as e:
                raise _idb_exception(e) from e
            except (ProtocolError, StreamTerminatedError) as e:
                raise IdbException(e.args) from e
            except OSError as e:
                raise IdbConnectionException(e.strerror)

        @functools.wraps(func)
        @log_call(name=func.__name__, metadata=metadata)
        async def func_wrapper_gen(*args: Any, **kwargs: Any) -> Any:  # pyre-ignore
            try:
                async for item in func(*args, **kwargs):
                    yield item
            except GRPCError as e:
                raise _idb_exception(e) from e
            except (ProtocolError, StreamTerminatedError) as e:
                raise IdbException(e.args) from e
            except OSError as e:
                raise IdbConnectionException(e.strerror)

        if inspect.isasyncgenfunction(func):
            return func_wrapper_gen
        else:
            return func_wrapper

    return decorating


def _video_injection_file(path: str) -> str:
    file_path = os.path.realpath(path)
    if not os.path.isfile(file_path):
        raise IdbException(f"Video injection input is not a regular file: {file_path}")
    return file_path


async def _read_audio_chunks(file_path: str) -> AsyncIterator[bytes]:
    """Reports a failure to read the local file as such, not as a lost companion connection."""
    try:
        async for chunk in generate_file_chunks(file_path):
            yield chunk
    except OSError as error:
        raise IdbException(f"Could not read {file_path}: {error}") from error


class Client(ClientBase):
    def __init__(
        self,
        stub: CompanionServiceStub,
        companion: CompanionInfo,
        logger: logging.Logger,
    ) -> None:
        self.stub = stub
        self.companion = companion
        self.logger = logger

    @property
    def metadata(self) -> LoggingMetadata:
        return plugin.current_scoped_invocation_metadata()

    @property
    def address(self) -> Address:
        return self.companion.address

    @property
    def is_local(self) -> bool:
        if os.environ.get("IDB_FORCE_REMOTE") == "1":
            return False
        return self.companion.is_local

    @classmethod
    @asynccontextmanager
    async def build(
        cls,
        address: Address,
        logger: logging.Logger,
        exchange_metadata: bool = True,
        extra_metadata: dict[str, str] | None = None,
        use_tls: bool = False,
    ) -> AsyncGenerator["Client", None]:
        metadata_to_companion = (
            {
                **{
                    key: value
                    for (key, value) in plugin.resolve_metadata(logger=logger).items()
                    if isinstance(value, str)
                },
                **(extra_metadata or {}),
            }
            if exchange_metadata
            else {}
        )
        ssl_context = plugin.channel_ssl_context() if use_tls else None
        if use_tls:
            assert ssl_context is not None
        async with (
            Channel(
                host=address.host,
                port=address.port,
                loop=asyncio.get_running_loop(),
                ssl=ssl_context,
                status_details_codec=RetryVerdictCodec(),
            )
            if isinstance(address, TCPAddress)
            else Channel(
                path=address.path,
                loop=asyncio.get_running_loop(),
                status_details_codec=RetryVerdictCodec(),
            )
        ) as channel:
            stub = CompanionServiceStub(channel=channel)
            with tempfile.NamedTemporaryFile(mode="w+b") as f:
                try:
                    response = await stub.connect(
                        ConnectRequest(
                            metadata=metadata_to_companion, local_file_path=f.name
                        )
                    )
                except Exception as ex:
                    raise IdbException(
                        f"Failed to connect to companion at address {address}: {ex}"
                    )
            logger.debug(
                f"Companion at {address} {'is' if response.companion.is_local else 'is not'} local"
            )
            companion = companion_to_py(companion=response.companion, address=address)
            plugin.on_companion_connected(logger=logger, companion=companion)
            if exchange_metadata:
                metadata_from_companion = {
                    key: value
                    for (key, value) in companion.metadata.items()
                    if isinstance(value, str)
                }
                plugin.append_companion_metadata(
                    logger=logger, metadata=metadata_from_companion
                )
            yield Client(stub=stub, companion=companion, logger=logger)

    @classmethod
    @asynccontextmanager
    async def for_companion(
        cls,
        companion: Companion,
        udid: str,
        logger: logging.Logger,
        only: OnlyFilter | None = None,
    ) -> AsyncGenerator["Client", None]:
        with tempfile.NamedTemporaryFile() as temp:
            # Remove the tempfile so we can bind to it first.
            os.remove(temp.name)
            async with (
                companion.unix_domain_server(
                    udid=udid, path=temp.name, only=only
                ) as resolved_path,
                Client.build(
                    address=DomainSocketAddress(path=resolved_path),
                    logger=logger,
                ) as client,
            ):
                yield client

    async def _tail_specific_logs(
        self,
        source: LogRequest.Source,
        stop: asyncio.Event,
        arguments: list[str] | None,
    ) -> AsyncIterator[str]:
        async with self.stub.log.open() as stream:
            await stream.send_message(
                LogRequest(arguments=arguments, source=source), end=True
            )
            # Use an incremental decoder to properly handle multi-byte UTF-8
            # characters that may be split across message boundaries
            decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
            async for message in cancel_wrapper(stream=stream, stop=stop):
                yield decoder.decode(message.output)

    async def _install_to_destination(
        self,
        bundle: Bundle,
        destination: Destination,
        compression: Compression | None,
        make_debuggable: bool | None,
        bundle_id: str | None,
        bundle_type: FileContainerType | None,
        override_modification_time: bool | None = None,
        skip_signing_bundles: bool | None = None,
        connect_to: TCPAddress | None = None,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        connect_to_frame = self._connect_to_frame(bundle, connect_to)
        async with self.stub.install.open() as stream:
            generator = None
            progress = None
            if isinstance(bundle, str):
                url = urllib.parse.urlparse(bundle)
                if url.scheme:
                    # send url
                    payload = Payload(url=bundle)
                    generator = generate_requests([InstallRequest(payload=payload)])

                else:
                    try:
                        file_path = str(Path(bundle).resolve(strict=True))
                    except FileNotFoundError:
                        # For remote companions, raise IdbException instead of
                        # letting FileNotFoundError propagate. Without this,
                        # the decorator's broad `except OSError` converts it to
                        # IdbConnectionException, pruning a healthy remote companion
                        # making `idb list-targets` return no targets until
                        # `idb connect` is re-run.
                        if not self.is_local:
                            raise IdbException(f"Bundle path does not exist: {bundle}")
                        raise
                    if self.is_local:
                        self.logger.debug(
                            f"Companion is local, sending local file by path {file_path}"
                        )
                        # send file_path
                        generator = generate_requests(
                            [InstallRequest(payload=Payload(file_path=file_path))]
                        )
                    else:
                        self.logger.debug(
                            f"Companion is remote, generating binary chunks for {file_path}"
                        )
                        # Only app and dSYM tars are compressed as declared; the other destinations always send gzip.
                        if destination in (InstallRequest.APP, InstallRequest.DSYM):
                            compression = select_stream_compression(
                                requested=compression,
                                supported=self.companion.supported_compressions,
                            )
                        self.logger.debug(
                            f"Streaming {file_path} with {(compression or Compression.GZIP).name} compression"
                        )
                        if on_upload_progress is not None:
                            progress = UploadProgress(
                                report=on_upload_progress,
                                total=ipa_size(file_path, destination),
                            )
                        # chunk file from file_path
                        generator = generate_binary_chunks(
                            path=file_path,
                            destination=destination,
                            compression=compression,
                            logger=self.logger,
                            zstd_zip_stream=self._streams_zips_as_zstd(
                                destination, compression
                            ),
                            progress=progress,
                        )

            else:
                # chunk file from memory
                self.logger.debug("Sending file data from input stream")
                if on_upload_progress is not None:
                    progress = UploadProgress(
                        report=on_upload_progress, total=remaining_size(bundle)
                    )
                # `compression` is deliberately not reassigned: these bytes go out
                # as their producer compressed them, so only a zip may be wrapped.
                generator = generate_io_chunks(
                    io=bundle,
                    logger=self.logger,
                    zstd_zip_stream=self._streams_zips_as_zstd(
                        destination,
                        select_stream_compression(
                            requested=compression,
                            supported=self.companion.supported_compressions,
                        ),
                    ),
                    progress=progress,
                )
                # stream to companion
            await stream.send_message(InstallRequest(destination=destination))
            if make_debuggable is not None:
                await stream.send_message(
                    InstallRequest(make_debuggable=make_debuggable)
                )
            if override_modification_time is not None:
                await stream.send_message(
                    InstallRequest(
                        override_modification_time=override_modification_time
                    )
                )
            if skip_signing_bundles is not None:
                await stream.send_message(
                    InstallRequest(skip_signing_bundles=skip_signing_bundles)
                )
            if bundle_id is not None:
                link_to_bundle_type = None
                if bundle_type == FileContainerType.APPLICATION:
                    link_to_bundle_type = InstallRequest.LinkDsymToBundle.APP
                elif bundle_type == FileContainerType.XCTEST:
                    link_to_bundle_type = InstallRequest.LinkDsymToBundle.XCTEST
                else:
                    raise IdbException(
                        f"Unexpected bundle_type. Bundle_type {bundle_type} specified for {bundle_id}"
                    )
                message = InstallRequest.LinkDsymToBundle(
                    bundle_id=bundle_id, bundle_type=link_to_bundle_type
                )
                await stream.send_message(InstallRequest(link_dsym_to_bundle=message))
            if connect_to_frame is not None:
                await stream.send_message(connect_to_frame)
            if compression is not None:
                await stream.send_message(
                    InstallRequest(
                        payload=Payload(compression=COMPRESSION_MAP[compression])
                    )
                )

            async for message in generator:
                await stream.send_message(message)
            if progress is not None:
                progress.finish()
            self.logger.debug("Finished sending install payload to companion")
            await stream.end()
            async for response in stream:
                yield InstalledArtifact(
                    name=response.name, uuid=response.uuid, progress=response.progress
                )

    def _connect_to_frame(
        self, bundle: Bundle, connect_to: TCPAddress | None
    ) -> InstallRequest | None:
        """The frame asking the companion to connect to `connect_to`, refused before
        anything is sent when the install can't honour it."""
        if connect_to is None:
            return None
        if not (isinstance(bundle, str) and urllib.parse.urlparse(bundle).scheme):
            raise IdbException("connect_to applies only to a URL")
        if not self.companion.install_connect_to:
            raise IdbException(
                "This idb_companion does not accept connect_to; update it"
            )
        return InstallRequest(
            connect_to=InstallRequest.ConnectTo(
                host=connect_to.host, port=connect_to.port
            )
        )

    def _streams_zips_as_zstd(
        self, destination: Destination, compression: Compression
    ) -> bool:
        # A companion without `zstd_zip_streams` would extract the stream as a tar.
        return (
            destination == InstallRequest.APP
            and compression == Compression.ZSTD
            and self.companion.zstd_zip_streams
        )

    @property
    def _is_verbose(self) -> bool:
        return self.logger.isEnabledFor(logging.DEBUG)

    def _log_from_companion(self, data: str) -> None:
        self.logger.info(data.strip())

    @log_and_handle_exceptions("list_apps")
    async def list_apps(
        self, fetch_process_state: bool = True
    ) -> list[InstalledAppInfo]:
        response = await self.stub.list_apps(
            ListAppsRequest(suppress_process_state=fetch_process_state is False)
        )
        return [
            InstalledAppInfo(
                bundle_id=app.bundle_id,
                name=app.name,
                architectures=app.architectures,
                install_type=app.install_type,
                process_state=AppProcessState(app.process_state),
                debuggable=app.debuggable,
                process_id=app.process_identifier,
            )
            for app in response.apps
        ]

    @log_and_handle_exceptions("accessibility_info")
    async def accessibility_info(
        self,
        target: AccessibilityTarget | None,
        options: AccessibilityInfoOptions,
    ) -> AccessibilityInfo:
        response = await self.stub.accessibility_info(
            accessibility_info_to_grpc(target, options)
        )
        return AccessibilityInfo(json=response.json)

    @log_and_handle_exceptions("accessibility_wait")
    async def accessibility_wait(
        self,
        target: AccessibilityMarker,
        timeout: float = 10.0,
        poll_interval: float = 0.5,
        backend: AccessibilityBackend = AccessibilityBackend.AXBRIDGE,
    ) -> bool:
        return (
            await self._accessibility_wait_result(
                target=target,
                timeout=timeout,
                poll_interval=poll_interval,
                backend=backend,
            )
        ).found

    @log_and_handle_exceptions("accessibility_wait_result")
    async def accessibility_wait_result(
        self,
        target: AccessibilityMarker,
        timeout: float = 10.0,
        poll_interval: float = 0.5,
        backend: AccessibilityBackend = AccessibilityBackend.AXBRIDGE,
    ) -> AccessibilityWaitResult:
        return await self._accessibility_wait_result(
            target=target,
            timeout=timeout,
            poll_interval=poll_interval,
            backend=backend,
        )

    @log_and_handle_exceptions("accessibility_quiescence")
    async def accessibility_quiescence(
        self,
        pid: int | None = None,
        bundle_id: str | None = None,
        busy_threshold_ms: int | None = None,
        quiet_window_ms: int | None = None,
        backend: QuiescenceBackend = QuiescenceBackend.AXBRIDGE,
    ) -> AsyncGenerator[QuiescenceEvent, None]:
        request = AccessibilityQuiescenceRequest(
            pid=pid,
            bundle_id=bundle_id,
            busy_threshold_ms=busy_threshold_ms,
            quiet_window_ms=quiet_window_ms,
            # Unset is AXBRIDGE, the only backend an older companion has.
            backend=(
                AccessibilityQuiescenceRequest.SHIMULATOR
                if backend == QuiescenceBackend.SHIMULATOR
                else None
            ),
        )
        async with self.stub.accessibility_quiescence.open() as stream:
            await stream.send_message(request, end=True)
            async for response in stream:
                if (
                    backend == QuiescenceBackend.SHIMULATOR
                    and response.backend != AccessibilityQuiescenceRequest.SHIMULATOR
                ):
                    raise IdbException(
                        "The companion predates the shimulator backend and measured "
                        "with axbridge instead; update idb_companion"
                    )
                yield _quiescence_event_from_grpc(response)

    async def _accessibility_wait_result(
        self,
        target: AccessibilityMarker,
        timeout: float,
        poll_interval: float,
        backend: AccessibilityBackend,
    ) -> AccessibilityWaitResult:
        response = await self.stub.accessibility_action(
            AccessibilityActionRequest(
                marker=target.value,
                match_key=target.match_key.value,
                depth=target.depth,
                backend=backend.value,
                # Deprecated, and still sent: a companion older than the
                # request-level field reads only this one.
                wait=AccessibilityActionRequest.Wait(
                    timeout=timeout, poll_interval=poll_interval, backend=backend.value
                ),
            )
        )
        wait = response.wait
        result = wait.result if response.HasField("wait") else response.wait_result
        if result not in (
            AccessibilityActionResponse.FOUND,
            AccessibilityActionResponse.TIMED_OUT,
        ):
            raise IdbException("The companion did not report a wait result")
        diagnostics = None
        if wait.HasField("diagnostics"):
            diagnostics = AccessibilitySearchDiagnostics(
                unmatched_values=list(wait.diagnostics.unmatched_values),
                truncated=wait.diagnostics.truncated,
                read_error=wait.diagnostics.read_error or None,
            )
        return AccessibilityWaitResult(
            found=result == AccessibilityActionResponse.FOUND,
            message=wait.message or None,
            diagnostics=diagnostics,
        )

    @log_and_handle_exceptions("accessibility_tap")
    async def accessibility_tap(
        self,
        target: AccessibilityTarget,
        expected_value: str | None = None,
        expected_key: AccessibilitySearchableKey = AccessibilitySearchableKey.LABEL,
        ignore_case: bool = False,
        backend: AccessibilityBackend | None = None,
    ) -> None:
        request = AccessibilityActionRequest(
            tap=AccessibilityActionRequest.Tap(
                check_expected_value=expected_value is not None,
                expected_value=expected_value or "",
                expected_key=expected_key.value,
            ),
        )
        if isinstance(target, AccessibilityMarker):
            request.marker = target.value
            request.match_key = target.match_key.value
            request.depth = target.depth
        elif isinstance(target, AccessibilityPoint):
            request.point.x = target.x
            request.point.y = target.y
        request.ignore_case = ignore_case
        if backend is not None:
            request.backend = backend.value
        await self.stub.accessibility_action(request)

    @log_and_handle_exceptions("accessibility_scroll")
    async def accessibility_scroll(
        self,
        target: AccessibilityTarget | None,
        direction: AccessibilityScrollDirection,
        ignore_case: bool = False,
        backend: AccessibilityBackend | None = None,
    ) -> None:
        request = AccessibilityActionRequest(
            scroll=AccessibilityActionRequest.Scroll(direction=direction.value),
        )
        if isinstance(target, AccessibilityMarker):
            request.marker = target.value
            request.match_key = target.match_key.value
            request.depth = target.depth
        elif isinstance(target, AccessibilityPoint):
            request.point.x = target.x
            request.point.y = target.y
        request.ignore_case = ignore_case
        if backend is not None:
            request.backend = backend.value
        await self.stub.accessibility_action(request)

    @log_and_handle_exceptions("accessibility_set_value")
    async def accessibility_set_value(
        self,
        target: AccessibilityTarget,
        value: str,
        ignore_case: bool = False,
        backend: AccessibilityBackend | None = None,
    ) -> None:
        request = AccessibilityActionRequest(
            set_value=AccessibilityActionRequest.SetValue(value=value),
        )
        if isinstance(target, AccessibilityMarker):
            request.marker = target.value
            request.match_key = target.match_key.value
            request.depth = target.depth
        elif isinstance(target, AccessibilityPoint):
            request.point.x = target.x
            request.point.y = target.y
        request.ignore_case = ignore_case
        if backend is not None:
            request.backend = backend.value
        await self.stub.accessibility_action(request)

    @log_and_handle_exceptions("accessibility_drag")
    async def accessibility_drag(
        self,
        source: AccessibilityTarget,
        destination: AccessibilityTarget,
        options: AccessibilityDragOptions,
        ignore_case: bool = False,
        backend: AccessibilityBackend | None = None,
    ) -> None:
        drag = AccessibilityActionRequest.Drag(
            press_duration=options.press_duration or 0.0,
            duration=options.duration or 0.0,
            release_duration=options.release_duration or 0.0,
            delta=options.delta or 0.0,
        )
        if isinstance(destination, AccessibilityMarker):
            drag.marker = destination.value
            drag.destination_match_key = destination.match_key.value
            drag.destination_depth = destination.depth
        elif isinstance(destination, AccessibilityPoint):
            drag.point.x = destination.x
            drag.point.y = destination.y
        request = AccessibilityActionRequest(drag=drag)
        if isinstance(source, AccessibilityMarker):
            request.marker = source.value
            request.match_key = source.match_key.value
            request.depth = source.depth
        elif isinstance(source, AccessibilityPoint):
            request.point.x = source.x
            request.point.y = source.y
        request.ignore_case = ignore_case
        if backend is not None:
            request.backend = backend.value
        await self.stub.accessibility_action(request)

    @log_and_handle_exceptions("add_media")
    async def add_media(self, file_paths: list[str]) -> None:
        async with self.stub.add_media.open() as stream:
            if self.is_local:
                for file_path in file_paths:
                    await stream.send_message(
                        AddMediaRequest(payload=Payload(file_path=file_path))
                    )
                await stream.end()
                await stream.recv_message()
            else:
                self.logger.info(f"Adding media from {file_paths}")
                generator = stream_map(
                    generate_tar(
                        paths=file_paths,
                        place_in_subfolders=True,
                        verbose=self._is_verbose,
                    ),
                    lambda chunk: AddMediaRequest(payload=Payload(data=chunk)),
                )
                await drain_to_stream(
                    stream=stream, generator=generator, logger=self.logger
                )

    @log_and_handle_exceptions("inject_audio")
    async def inject_audio(self, audio_file_path: str) -> None:
        file_path = os.path.realpath(audio_file_path)
        if not os.path.isfile(file_path):
            raise IdbException(
                f"Audio injection input is not a regular file: {file_path}"
            )
        async with self.stub.inject_audio.open() as stream:
            if self.is_local:
                await stream.send_message(
                    InjectAudioRequest(payload=Payload(file_path=file_path))
                )
                await stream.end()
                await stream.recv_message()
                return

            generator = stream_map(
                _read_audio_chunks(file_path),
                lambda chunk: InjectAudioRequest(payload=Payload(data=chunk)),
            )
            await drain_to_stream(
                stream=stream, generator=generator, logger=self.logger
            )

    @log_and_handle_exceptions("inject_video")
    async def inject_video(
        self,
        back_path: str,
        front_path: str | None,
        loop: bool,
        stop: asyncio.Event,
    ) -> AsyncIterator[list[str]]:
        if not self.is_local:
            raise IdbException(
                "Video injection needs a companion on this host, since the companion reads the video files"
            )
        start = InjectVideoRequest.Start(
            back_path=_video_injection_file(back_path),
            front_path=_video_injection_file(front_path) if front_path else "",
            loop=loop,
        )
        async with self.stub.inject_video.open() as stream:
            await stream.send_message(InjectVideoRequest(start=start))
            async for response in stop_wrapper(stream=stream, stop=stop):
                yield list(response.processes)
            if not stop.is_set():
                # The companion ended the injection. grpclib reads its status, and
                # with it any error, only once this side has ended too.
                await stream.end()
                return
            await stream.send_message(
                InjectVideoRequest(stop=InjectVideoRequest.Stop())
            )
            await stream.end()
            while await stream.recv_message() is not None:
                pass

    @log_and_handle_exceptions("approve")
    async def approve(
        self,
        bundle_id: str,
        permissions: set[Permission],
        scheme: str | None = None,
    ) -> None:
        await self.stub.approve(
            ApproveRequest(
                bundle_id=bundle_id,
                permissions=[APPROVE_MAP[permission] for permission in permissions],
                # pyre-ignore
                scheme=scheme,
            )
        )

    @log_and_handle_exceptions("revoke")
    async def revoke(
        self,
        bundle_id: str,
        permissions: set[Permission],
        scheme: str | None = None,
    ) -> None:
        await self.stub.revoke(
            RevokeRequest(
                bundle_id=bundle_id,
                permissions=[REVOKE_MAP[permission] for permission in permissions],
                # pyre-ignore
                scheme=scheme,
            )
        )

    @log_and_handle_exceptions("clear_keychain")
    async def clear_keychain(self) -> None:
        await self.stub.clear_keychain(ClearKeychainRequest())

    @log_and_handle_exceptions("contacts_update")
    async def contacts_update(self, contacts_path: str) -> None:
        data = await create_tar([contacts_path])
        await self.stub.contacts_update(
            ContactsUpdateRequest(payload=Payload(data=data))
        )

    @log_and_handle_exceptions("contacts_clear")
    async def contacts_clear(self) -> None:
        await self.stub.contacts_clear(ContactsClearRequest())

    @log_and_handle_exceptions("photos_clear")
    async def photos_clear(self) -> None:
        await self.stub.photos_clear(PhotosClearRequest())

    async def _lock_screen(self, action: LockScreenRequest.Action) -> LockState:
        response = await self.stub.lock_screen(LockScreenRequest(action=action))
        return LockState(locked=response.locked)

    @log_and_handle_exceptions("lock_screen")
    async def lock_state(self) -> LockState:
        return await self._lock_screen(LockScreenRequest.STATE)

    @log_and_handle_exceptions("lock_screen")
    async def lock(self) -> LockState:
        return await self._lock_screen(LockScreenRequest.LOCK)

    @log_and_handle_exceptions("lock_screen")
    async def unlock(self) -> LockState:
        return await self._lock_screen(LockScreenRequest.UNLOCK)

    @log_and_handle_exceptions("screenshot")
    async def screenshot(
        self, options: ScreenshotOptions = DEFAULT_SCREENSHOT_OPTIONS
    ) -> Screenshot:
        request = screenshot_to_grpc(options)
        request.include_app_context = (
            self.companion.screenshot_app_context
            and plugin.should_collect_screenshot_context()
        )
        response = await self.stub.screenshot(request)
        return screenshot_from_grpc(options, response)

    @log_and_handle_exceptions("set_location")
    async def set_location(self, latitude: float, longitude: float) -> None:
        await self.stub.set_location(
            SetLocationRequest(
                location=Location(latitude=latitude, longitude=longitude)
            )
        )

    @log_and_handle_exceptions("simulate_memory_warning")
    async def simulate_memory_warning(self) -> None:
        await self.stub.simulate_memory_warning(SimulateMemoryWarningRequest())

    @log_and_handle_exceptions("send_notification")
    async def send_notification(
        self,
        bundle_id: str,
        json_payload: str,
        *,
        process_service_extension: bool = False,
    ) -> None:
        if '"idb-service-extension"' in json_payload:
            try:
                payload = json.loads(json_payload)
            except json.JSONDecodeError as error:
                raise IdbException(f"Invalid notification payload: {error}") from error
            if isinstance(payload, dict) and "idb-service-extension" in payload:
                requested = payload.pop("idb-service-extension")
                if not isinstance(requested, bool):
                    raise IdbException("idb-service-extension must be a boolean")
                process_service_extension = process_service_extension or requested
                json_payload = json.dumps(payload)
        if (
            process_service_extension
            and not self.companion.supports_notification_service_extension
        ):
            raise IdbException(
                "The companion does not support notification service extension delivery"
            )
        await self.stub.send_notification(
            SendNotificationRequest(
                bundle_id=bundle_id,
                json_payload=json_payload,
                process_service_extension=process_service_extension,
            )
        )

    @log_and_handle_exceptions("delivered_notifications")
    async def delivered_notifications(
        self, bundle_id: str
    ) -> list[DeliveredNotification]:
        response = await self.stub.delivered_notifications(
            DeliveredNotificationsRequest(bundle_id=bundle_id)
        )
        return [
            DeliveredNotification(
                bundle_id=notification.bundle_id,
                identifier=notification.identifier,
                title=notification.title,
                subtitle=notification.subtitle,
                body=notification.body,
                thread_identifier=notification.thread_identifier,
                date=notification.date if notification.HasField("date") else None,
            )
            for notification in response.notifications
        ]

    @log_and_handle_exceptions("clear_delivered_notifications")
    async def clear_delivered_notifications(self, bundle_id: str) -> None:
        await self.stub.clear_delivered_notifications(
            ClearDeliveredNotificationsRequest(bundle_id=bundle_id)
        )

    @log_and_handle_exceptions("terminate")
    async def terminate(self, bundle_id: str) -> None:
        await self.stub.terminate(TerminateRequest(bundle_id=bundle_id))

    @log_and_handle_exceptions("describe")
    async def describe(self, fetch_diagnostics: bool = False) -> TargetDescription:
        response = await self.stub.describe(
            TargetDescriptionRequest(fetch_diagnostics=fetch_diagnostics)
        )
        target = response.target_description
        return target_to_py(
            target=target,
            # Use the local understanding of the companion instead of the remote's.
            companion=CompanionInfo(
                address=self.address,
                udid=target.udid,
                is_local=self.is_local,
                pid=None,
                supported_compressions=self.companion.supported_compressions,
                zstd_zip_streams=self.companion.zstd_zip_streams,
                screenshot_app_context=self.companion.screenshot_app_context,
                install_connect_to=self.companion.install_connect_to,
                supports_notification_service_extension=(
                    self.companion.supports_notification_service_extension
                ),
            ),
            # Extract the companion metadata from the response.
            metadata=response.companion.metadata,
        )

    @log_and_handle_exceptions("focus")
    async def focus(self) -> None:
        await self.stub.focus(FocusRequest())

    @log_and_handle_exceptions("open_url")
    async def open_url(self, url: str) -> None:
        await self.stub.open_url(OpenUrlRequest(url=url))

    @log_and_handle_exceptions("uninstall")
    async def uninstall(self, bundle_id: str) -> None:
        await self.stub.uninstall(UninstallRequest(bundle_id=bundle_id))

    @log_and_handle_exceptions("rm")
    async def rm(self, container: FileContainer, paths: list[str]) -> None:
        await self.stub.rm(
            RmRequest(paths=paths, container=file_container_to_grpc(container))
        )

    @log_and_handle_exceptions("mv")
    async def mv(
        self, container: FileContainer, src_paths: list[str], dest_path: str
    ) -> None:
        await self.stub.mv(
            MvRequest(
                src_paths=src_paths,
                dst_path=dest_path,
                container=file_container_to_grpc(container),
            )
        )

    @log_and_handle_exceptions("ls")
    async def ls_single(
        self, container: FileContainer, path: str
    ) -> list[FileEntryInfo]:
        response = await self.stub.ls(
            LsRequest(path=path, container=file_container_to_grpc(container))
        )
        return [FileEntryInfo(path=file.path) for file in response.files]

    @log_and_handle_exceptions("ls")
    async def ls(self, container: FileContainer, paths: list[str]) -> list[FileListing]:
        response = await self.stub.ls(
            LsRequest(paths=paths, container=file_container_to_grpc(container))
        )
        return [
            FileListing(
                parent=listing.parent.path,
                entries=[FileEntryInfo(path=entry.path) for entry in listing.files],
            )
            for listing in response.listings
        ]

    @log_and_handle_exceptions("mkdir")
    async def mkdir(self, container: FileContainer, path: str) -> None:
        await self.stub.mkdir(
            MkdirRequest(path=path, container=file_container_to_grpc(container))
        )

    @log_and_handle_exceptions("crash_delete")
    async def crash_delete(self, query: CrashLogQuery) -> list[CrashLogInfo]:
        response = await self.stub.crash_delete(crash_log_query_to_grpc(query))
        return _to_crash_log_info_list(response)

    @log_and_handle_exceptions("crash_list")
    async def crash_list(self, query: CrashLogQuery) -> list[CrashLogInfo]:
        response = await self.stub.crash_list(crash_log_query_to_grpc(query))
        return _to_crash_log_info_list(response)

    @log_and_handle_exceptions("crash_show")
    async def crash_show(self, name: str) -> CrashLog:
        response = await self.stub.crash_show(CrashShowRequest(name=name))
        return _to_crash_log(response)

    @log_and_handle_exceptions("install")
    async def install(
        self,
        bundle: Bundle,
        compression: Compression | None = None,
        make_debuggable: bool | None = None,
        override_modification_time: bool | None = None,
        *,
        connect_to: TCPAddress | None = None,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        async for response in self._install_to_destination(
            bundle=bundle,
            destination=InstallRequest.APP,
            compression=compression,
            make_debuggable=make_debuggable,
            bundle_id=None,
            bundle_type=None,
            override_modification_time=override_modification_time,
            connect_to=connect_to,
            on_upload_progress=on_upload_progress,
        ):
            yield response

    @log_and_handle_exceptions("install")
    async def install_xctest(
        self,
        xctest: Bundle,
        skip_signing_bundles: bool | None = None,
        *,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        async for response in self._install_to_destination(
            bundle=xctest,
            destination=InstallRequest.XCTEST,
            compression=None,
            make_debuggable=None,
            bundle_id=None,
            bundle_type=None,
            skip_signing_bundles=skip_signing_bundles,
            on_upload_progress=on_upload_progress,
        ):
            yield response

    @log_and_handle_exceptions("install")
    async def install_dylib(
        self,
        dylib: Bundle,
        *,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        async for response in self._install_to_destination(
            bundle=dylib,
            destination=InstallRequest.DYLIB,
            compression=None,
            make_debuggable=None,
            bundle_id=None,
            bundle_type=None,
            on_upload_progress=on_upload_progress,
        ):
            yield response

    @log_and_handle_exceptions("install")
    async def install_dsym(
        self,
        dsym: Bundle,
        bundle_id: str | None,
        compression: Compression | None,
        bundle_type: FileContainerType | None = None,
        *,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        async for response in self._install_to_destination(
            bundle=dsym,
            destination=InstallRequest.DSYM,
            compression=compression,
            make_debuggable=None,
            bundle_id=bundle_id,
            bundle_type=bundle_type,
            on_upload_progress=on_upload_progress,
        ):
            yield response

    @log_and_handle_exceptions("install")
    async def install_framework(
        self,
        framework_path: Bundle,
        *,
        on_upload_progress: Callable[[str], None] | None = None,
    ) -> AsyncIterator[InstalledArtifact]:
        async for response in self._install_to_destination(
            bundle=framework_path,
            destination=InstallRequest.FRAMEWORK,
            compression=None,
            make_debuggable=None,
            bundle_id=None,
            bundle_type=None,
            on_upload_progress=on_upload_progress,
        ):
            yield response

    @log_and_handle_exceptions("push")
    async def push(
        self,
        src_paths: list[str],
        container: FileContainer,
        dest_path: str,
        compression: Compression | None,
    ) -> None:
        async with self.stub.push.open() as stream:
            await stream.send_message(
                PushRequest(
                    inner=PushRequest.Inner(
                        dst_path=dest_path, container=file_container_to_grpc(container)
                    )
                )
            )
            if self.is_local:
                for src_path in src_paths:
                    await stream.send_message(
                        PushRequest(payload=Payload(file_path=src_path))
                    )
                await stream.end()
                await stream.recv_message()
            else:
                compression = select_stream_compression(
                    requested=compression,
                    supported=self.companion.supported_compressions,
                )
                if compression is not None:
                    self.logger.debug(f"Pushing with {compression.name} compression")
                    await stream.send_message(
                        PushRequest(
                            payload=Payload(compression=COMPRESSION_MAP[compression])
                        )
                    )

                await drain_to_stream(
                    stream=stream,
                    generator=stream_map(
                        generate_tar(
                            paths=src_paths,
                            compression=compression or Compression.GZIP,
                            verbose=self._is_verbose,
                        ),
                        lambda chunk: PushRequest(payload=Payload(data=chunk)),
                    ),
                    logger=self.logger,
                )

    @log_and_handle_exceptions("pull")
    async def pull(
        self, container: FileContainer, src_path: str, dest_path: str
    ) -> None:
        async with self.stub.pull.open() as stream:
            request = request = PullRequest(
                src_path=src_path,
                # not sending the destination to remote companion
                # so it streams the file back
                # pyre-ignore
                dst_path=dest_path if self.is_local else None,
                container=file_container_to_grpc(container),
            )
            await stream.send_message(request)
            await stream.end()
            if self.is_local:
                await stream.recv_message()
            else:
                await drain_untar(generate_bytes(stream), output_path=dest_path)
            self.logger.info(f"pulled file to {dest_path}")

    @log_and_handle_exceptions("tail")
    async def tail(
        self, stop: asyncio.Event, container: FileContainer, path: str
    ) -> AsyncIterator[bytes]:
        async with self.stub.tail.open() as stream:
            await stream.send_message(
                TailRequest(
                    start=TailRequest.Start(
                        container=file_container_to_grpc(container), path=path
                    )
                )
            )
            async for response in cancel_wrapper(stream=stream, stop=stop):
                yield response.data
            await stream.send_message(TailRequest(stop=TailRequest.Stop()))

    @log_and_handle_exceptions("xctest_list_tests")
    async def list_test_bundle(self, test_bundle_id: str, app_path: str) -> list[str]:
        response = await self.stub.xctest_list_tests(
            XctestListTestsRequest(bundle_name=test_bundle_id, app_path=app_path)
        )
        return list(response.names)

    @log_and_handle_exceptions("xctest_list_bundles")
    async def list_xctests(self) -> list[InstalledTestInfo]:
        response = await self.stub.xctest_list_bundles(XctestListBundlesRequest())
        return [
            InstalledTestInfo(
                bundle_id=bundle.bundle_id,
                name=bundle.name,
                architectures=bundle.architectures,
            )
            for bundle in response.bundles
        ]

    @log_and_handle_exceptions("hid")
    async def send_events(self, events: Iterable[HIDEvent]) -> None:
        await self.hid(iterator_to_async_iterator(events))

    @log_and_handle_exceptions("hid")
    async def tap(self, x: float, y: float, duration: float | None = None) -> None:
        await self.send_events(tap_to_events(x, y, duration))

    @log_and_handle_exceptions("hid")
    async def multi_tap(
        self,
        x: float,
        y: float,
        count: int = 2,
        duration: float | None = None,
        pause: float = 0.1,
    ) -> None:
        await self.send_events(multi_tap_to_events(x, y, count, duration, pause))

    @log_and_handle_exceptions("hid")
    async def button(
        self, button_type: HIDButtonType, duration: float | None = None
    ) -> None:
        await self.send_events(button_press_to_events(button_type, duration))

    @log_and_handle_exceptions("get_orientation")
    async def get_orientation(self) -> DeviceOrientation:
        response = await self.stub.get_orientation(GetOrientationRequest())
        try:
            return DeviceOrientation[
                GetOrientationResponse.Orientation.Name(response.orientation)
            ]
        except (ValueError, KeyError) as error:
            raise IdbException(
                f"Unrecognized device orientation: {response.orientation}"
            ) from error

    @log_and_handle_exceptions("set_orientation")
    async def set_orientation(self, orientation: HIDOrientationType) -> None:
        await self.stub.set_orientation(
            SetOrientationRequest(orientation=orientation.value)
        )

    @log_and_handle_exceptions("hid")
    async def rotate(self, orientation: HIDOrientationType) -> None:
        await self.send_events(rotate_to_events(orientation))

    @log_and_handle_exceptions("hinge_angle")
    async def get_hinge_angle(self) -> float:
        response = await self.stub.hinge_angle(HingeAngleRequest())
        return response.angle

    @log_and_handle_exceptions("hid")
    async def set_hinge_angle(self, angle: float) -> None:
        await self.send_events([HIDHinge(angle=angle)])

    @log_and_handle_exceptions("hid")
    async def shake(self) -> None:
        await self.send_events(shake_to_events())

    @log_and_handle_exceptions("hid")
    async def key(self, keycode: int, duration: float | None = None) -> None:
        await self.send_events(key_press_to_events(keycode, duration))

    @log_and_handle_exceptions("hid")
    async def text(self, text: str) -> None:
        await self.send_events(text_to_events(text))

    @log_and_handle_exceptions("hid")
    async def swipe(
        self,
        p_start: tuple[int, int],
        p_end: tuple[int, int],
        duration: float | None = None,
        delta: int | None = None,
    ) -> None:
        await self.send_events(swipe_to_events(p_start, p_end, duration, delta))

    @log_and_handle_exceptions("hid")
    async def key_sequence(self, key_sequence: list[int]) -> None:
        events: list[HIDEvent] = []
        for key in key_sequence:
            events.extend(key_press_to_events(key))
        await self.send_events(events)

    @log_and_handle_exceptions("hid")
    async def hid(self, event_iterator: AsyncIterable[HIDEvent]) -> None:
        async with self.stub.hid.open() as stream:
            grpc_event_iterator = (
                event_to_grpc(event) async for event in event_iterator
            )
            await drain_to_stream(
                stream=stream,
                generator=grpc_event_iterator,
                logger=self.logger,
            )
            await stream.recv_message()

    @log_and_handle_exceptions("hid")
    async def pinch(
        self,
        center_x: float,
        center_y: float,
        scale: float,
        duration: float = 0.5,
        radius: float = 100.0,
    ) -> None:
        await self.send_events(
            pinch_to_events(
                center_x=center_x,
                center_y=center_y,
                scale=scale,
                duration=duration,
                radius=radius,
            )
        )

    @log_and_handle_exceptions("debugserver")
    async def debug_server(self, request: DebugServerRequest) -> DebugServerResponse:
        async with self.stub.debugserver.open() as stream:
            await stream.send_message(request)
            await stream.end()
            return await stream.recv_message()

    @log_and_handle_exceptions("debugserver")
    async def debugserver_start(self, bundle_id: str) -> list[str]:
        response = await self.debug_server(
            request=DebugServerRequest(
                start=DebugServerRequest.Start(bundle_id=bundle_id)
            )
        )
        return response.status.lldb_bootstrap_commands

    @log_and_handle_exceptions("debugserver")
    async def debugserver_stop(self) -> None:
        await self.debug_server(
            request=DebugServerRequest(stop=DebugServerRequest.Stop())
        )

    @log_and_handle_exceptions("debugserver")
    async def debugserver_status(self) -> list[str] | None:
        response = await self.debug_server(
            request=DebugServerRequest(status=DebugServerRequest.Status())
        )
        commands = response.status.lldb_bootstrap_commands
        return commands if commands else None

    @log_and_handle_exceptions("launch")
    async def launch(
        self,
        bundle_id: str,
        args: list[str] | None = None,
        env: dict[str, str] | None = None,
        foreground_if_running: bool = False,
        wait_for_debugger: bool = False,
        stop: asyncio.Event | None = None,
        pid_file: str | None = None,
        enable_repl: bool = False,
    ) -> None:
        async with self.stub.launch.open() as stream:
            request = LaunchRequest(
                start=LaunchRequest.Start(
                    bundle_id=bundle_id,
                    env=env,
                    app_args=args,
                    foreground_if_running=foreground_if_running,
                    wait_for_debugger=wait_for_debugger,
                    wait_for=True if stop else False,
                    enable_repl=enable_repl,
                )
            )
            await stream.send_message(request)
            if stop:
                await wait_for_launch_stream(stream, stop, pid_file)
            else:
                await stream.end()
                await drain_launch_stream(stream, pid_file)

    @log_and_handle_exceptions("record")
    async def record_video(
        self,
        stop: asyncio.Event,
        output_file: str,
        fps: int | None = None,
        scale_factor: float | None = None,
        bitrate: float | None = None,
        key_frame_rate: float | None = None,
        audio: bool = False,
    ) -> RecordedAudio | None:
        self.logger.info("Starting connection to backend")
        requested_encode_options = any([fps, scale_factor, bitrate, key_frame_rate])
        applied: list[RecordResponse.Applied] = []
        recorded_audio: list[RecordResponse.Audio] = []
        async with self.stub.record.open() as stream:
            if self.is_local:
                self.logger.info(
                    f"Starting video recording to local file {output_file}"
                )
                file_path = output_file
            else:
                self.logger.info("Starting video recording with response data")
                file_path = None
            await stream.send_message(
                RecordRequest(
                    start=RecordRequest.Start(
                        # pyre-ignore
                        file_path=file_path,
                        # Zero is how the wire says "unset", and each has a companion-side default.
                        fps=fps or 0,
                        scale_factor=scale_factor or 0,
                        avg_bitrate=bitrate or 0,
                        key_frame_rate=key_frame_rate or 0,
                        audio=audio,
                    )
                )
            )
            await stop.wait()
            self.logger.info("Stopping video recording")
            await stream.send_message(RecordRequest(stop=RecordRequest.Stop()))
            await stream.end()
            if self.is_local:
                self.logger.info("Video saved at output path")
                # The echo of the encode options and the description of the audio, when there are
                # any, precede the file path.
                while True:
                    response = await stream.recv_message()
                    output = response.WhichOneof("output") if response else None
                    if output == "applied":
                        applied.append(response.applied)
                    elif output == "audio":
                        recorded_audio.append(response.audio)
                    else:
                        break
            else:
                self.logger.info(f"Decompressing gzip to {output_file}")
                await drain_gzip_decompress(
                    generate_video_bytes(stream, applied, recorded_audio),
                    output_path=output_file,
                )
                self.logger.info(f"Finished decompression to {output_file}")
        if requested_encode_options and not applied:
            self.logger.warning(
                "The companion did not report which encode options it applied, so it predates them "
                "and recorded at its own defaults"
            )
        if not audio:
            return None
        if not any(echo.audio for echo in applied) or not recorded_audio:
            raise IdbException(
                f"The companion recorded no audio: it predates audio recording, so {output_file} "
                "holds video alone"
            )
        return recorded_audio_from_grpc(recorded_audio[0])

    @log_and_handle_exceptions("video_stream")
    async def stream_video(
        self,
        output_file: str | None,
        fps: int | None,
        format: VideoFormat,
        compression_quality: float,
        scale_factor: float = 1,
    ) -> AsyncGenerator[bytes, None]:
        self.logger.info("Starting connection to backend")
        async with self.stub.video_stream.open() as stream:
            if self.is_local and output_file:
                self.logger.info(
                    f"Streaming locally with companion writing to {output_file}"
                )
                await stream.send_message(
                    VideoStreamRequest(
                        start=VideoStreamRequest.Start(
                            file_path=output_file,
                            # pyre-ignore
                            fps=fps,
                            format=VIDEO_FORMAT_MAP[format],
                            compression_quality=compression_quality,
                            scale_factor=scale_factor,
                        )
                    )
                )
            else:
                self.logger.info("Starting streaming over the wire")
                await stream.send_message(
                    VideoStreamRequest(
                        start=VideoStreamRequest.Start(
                            # pyre-ignore
                            file_path=None,
                            # pyre-ignore
                            fps=fps,
                            format=VIDEO_FORMAT_MAP[format],
                            compression_quality=compression_quality,
                            scale_factor=scale_factor,
                        )
                    )
                )
            try:
                iterator = generate_bytes(stream=stream, logger=self.logger)
                if output_file and not self.is_local:
                    self.logger.info(f"Writing wired bytes to {output_file}")
                    await drain_to_file(stream=iterator, file_path=output_file)
                else:
                    async for data in iterator:
                        yield data
            finally:
                self.logger.info("Stopping video streaming")
                await stream.send_message(
                    VideoStreamRequest(stop=VideoStreamRequest.Stop())
                )
                await stream.end()

    async def _handle_code_coverage_in_response(
        self,
        response: XctestRunResponse,
        coverage_output_path: str | None,
        coverage_format: CodeCoverageFormat,
    ) -> None:
        if (
            response.code_coverage_data
            and response.code_coverage_data.data
            and response.code_coverage_data.data.count
            and coverage_output_path
        ):
            output_path: str = coverage_output_path
            self.logger.info(f"Decompressing code coverage to {output_path}")
            if coverage_format == CodeCoverageFormat.EXPORTED:
                await gunzip(
                    response.code_coverage_data.data,
                    output_path=output_path,
                )
            elif coverage_format == CodeCoverageFormat.RAW:
                await untar_into_path(
                    payload=response.code_coverage_data,
                    description="raw code coverage directory",
                    output_path=output_path,
                    logger=self.logger,
                )
            self.logger.info(f"Finished decompression to {output_path}")
        elif response.coverage_json and coverage_output_path:
            # handle deprecated response field
            with open(coverage_output_path, "w") as f:
                f.write(response.coverage_json)

    @log_and_handle_exceptions("xctest_run")
    async def run_xctest(
        self,
        test_bundle_id: str,
        app_bundle_id: str,
        test_host_app_bundle_id: str | None = None,
        is_ui_test: bool = False,
        is_logic_test: bool = False,
        tests_to_run: set[str] | None = None,
        tests_to_skip: set[str] | None = None,
        env: dict[str, str] | None = None,
        args: list[str] | None = None,
        result_bundle_path: str | None = None,
        idb_log_buffer: StringIO | None = None,
        timeout: int | None = None,
        poll_interval_sec: float = TESTS_POLL_INTERVAL,
        report_activities: bool = False,
        report_attachments: bool = False,
        activities_output_path: str | None = None,
        coverage_output_path: str | None = None,
        enable_continuous_coverage_collection: bool = False,
        coverage_format: CodeCoverageFormat = CodeCoverageFormat.EXPORTED,
        log_directory_path: str | None = None,
        wait_for_debugger: bool = False,
    ) -> AsyncIterator[TestRunInfo]:
        async with self.stub.xctest_run.open() as stream:
            request = make_request(
                test_bundle_id=test_bundle_id,
                app_bundle_id=app_bundle_id,
                test_host_app_bundle_id=test_host_app_bundle_id,
                is_ui_test=is_ui_test,
                is_logic_test=is_logic_test,
                tests_to_run=tests_to_run,
                tests_to_skip=tests_to_skip,
                env=env,
                args=args,
                result_bundle_path=result_bundle_path,
                timeout=timeout,
                report_activities=(
                    report_activities
                    or activities_output_path is not None
                    or report_attachments
                ),
                report_attachments=report_attachments,
                collect_coverage=coverage_output_path is not None,
                enable_continuous_coverage_collection=enable_continuous_coverage_collection,
                coverage_format=coverage_format,
                collect_logs=log_directory_path is not None,
                wait_for_debugger=wait_for_debugger,
                collect_result_bundle=result_bundle_path is not None,
            )
            log_parser = XCTestLogParser()
            await stream.send_message(request)
            await stream.end()
            async for response in stream:
                # response.log_output is a container of strings.
                # google.protobuf.pyext._message.RepeatedScalarContainer.
                for line in [
                    line
                    for lines in response.log_output
                    for line in lines.splitlines(keepends=True)
                ]:
                    log_parser.parse_streaming_log(line.rstrip())
                    self._log_from_companion(line)
                    if idb_log_buffer:
                        idb_log_buffer.write(line)

                if result_bundle_path:
                    await untar_into_path(
                        payload=response.result_bundle,
                        description="result bundle",
                        output_path=result_bundle_path,
                        logger=self.logger,
                    )
                if log_directory_path:
                    await untar_into_path(
                        payload=response.log_directory,
                        description="log directory",
                        output_path=log_directory_path,
                        logger=self.logger,
                    )

                await self._handle_code_coverage_in_response(
                    response, coverage_output_path, coverage_format
                )

                if wait_for_debugger and response.debugger.pid:
                    sys.stdout.buffer.write(
                        json_format_debugger_info(response.debugger).encode()
                    )
                    sys.stdout.buffer.write(os.linesep.encode())
                    sys.stdout.buffer.flush()

                for result in make_results(response, log_parser):
                    if activities_output_path:
                        save_attachments(
                            run_info=result,
                            activities_output_path=activities_output_path,
                        )
                    yield result

    @log_and_handle_exceptions("log")
    async def tail_logs(
        self, stop: asyncio.Event, arguments: list[str] | None = None
    ) -> AsyncIterator[str]:
        async for message in self._tail_specific_logs(
            source=LogRequest.TARGET, stop=stop, arguments=arguments
        ):
            yield message

    @log_and_handle_exceptions("log")
    async def tail_companion_logs(self, stop: asyncio.Event) -> AsyncIterator[str]:
        async for message in self._tail_specific_logs(
            source=LogRequest.COMPANION, stop=stop, arguments=None
        ):
            yield message

    @log_and_handle_exceptions("setting")
    async def set_preference(
        self, name: str, value: str, value_type: str, domain: str | None
    ) -> None:
        await self.stub.setting(
            SettingRequest(
                stringSetting=SettingRequest.StringSetting(
                    setting=AnySetting,
                    value=value,
                    name=name,
                    value_type=value_type,
                    # pyre-ignore
                    domain=domain,
                )
            )
        )

    @log_and_handle_exceptions("get_setting")
    async def get_preference(self, name: str, domain: str | None) -> str:
        response = await self.stub.get_setting(
            # pyre-ignore
            GetSettingRequest(setting=AnySetting, name=name, domain=domain)
        )
        return response.value

    @log_and_handle_exceptions("list_settings")
    async def list_locale_identifiers(self) -> list[str]:
        response = await self.stub.list_settings(
            ListSettingRequest(
                setting=LocaleSetting,
            )
        )
        return list(response.values)

    @log_and_handle_exceptions("profile")
    async def profile(
        self,
        kind: ProfileKind,
        target: ProfileTarget,
        stop: asyncio.Event,
        artifact_path: str | None = None,
        on_sample: Callable[[dict[str, object]], None] | None = None,
    ) -> ProfileResult:
        stoppable = accepts_stop(kind)
        async with self.stub.profile.open() as stream:
            await stream.send_message(
                start_request(kind, target, include_artifact=artifact_path is not None),
                end=not stoppable,
            )
            result = await drain_profile(
                stream, stop=stop if stoppable else None, on_sample=on_sample
            )
            if result is not None and artifact_path is not None:
                await drain_artifact(stream, artifact_path)
        if result is None:
            raise ProfileException("The companion ended the profile without a result")
        return ProfileResult(
            report=(
                message_to_json(result.report) if result.HasField("report") else None
            ),
            tool_output=result.tool_output,
            artifact=artifact_path,
        )

    @log_and_handle_exceptions("xctrace_record")
    async def xctrace_record(
        self,
        stop: asyncio.Event,
        # original 'xctrace record' options
        output: str,
        template_name: str,
        all_processes: bool = False,
        time_limit: float | None = None,
        package: str | None = None,
        process_to_attach: str | None = None,
        process_to_launch: str | None = None,
        process_env: dict[str, str] | None = None,
        launch_args: list[str] | None = None,
        target_stdin: str | None = None,
        target_stdout: str | None = None,
        # FB options
        post_args: list[str] | None = None,
        stop_timeout: float | None = None,
        # control events
        started: asyncio.Event | None = None,
    ) -> list[str]:
        self.logger.info("Starting xctrace connection")
        async with self.stub.xctrace_record.open() as stream:
            self.logger.info("Sending xctrace record request")
            target = None
            if all_processes:
                target = XctraceRecordRequest.Target(all_processes=all_processes)
            elif process_to_attach:
                target = XctraceRecordRequest.Target(
                    process_to_attach=process_to_attach
                )
            else:
                target = XctraceRecordRequest.Target(
                    launch_process=XctraceRecordRequest.LauchProcess(
                        # pyre-ignore
                        process_to_launch=process_to_launch,
                        launch_args=launch_args,
                        # pyre-ignore
                        target_stdin=target_stdin,
                        # pyre-ignore
                        target_stdout=target_stdout,
                        process_env=process_env,
                    )
                )
            await stream.send_message(
                XctraceRecordRequest(
                    start=XctraceRecordRequest.Start(
                        template_name=template_name,
                        # pyre-ignore
                        time_limit=time_limit,
                        # pyre-ignore
                        package=package,
                        target=target,
                    )
                )
            )
            self.logger.info("Starting xctrace record")
            await xctrace_drain_until_running(stream=stream, logger=self.logger)
            if started:
                started.set()
            self.logger.info("Xctrace record has started, waiting for stop")
            async for response in stop_wrapper(stream=stream, stop=stop):
                log = response.log
                if len(log):
                    self.logger.info(log.decode())
            self.logger.info("Stopping xctrace record")
            await stream.send_message(
                XctraceRecordRequest(
                    stop=XctraceRecordRequest.Stop(
                        # pyre-ignore
                        timeout=stop_timeout,
                        args=post_args,
                    )
                )
            )
            await stream.end()

            result = []

            with tempfile.TemporaryDirectory() as tmp_trace_dir:
                self.logger.info(f"Writing xctrace data from tar to {tmp_trace_dir}")
                await drain_untar(
                    xctrace_generate_bytes(stream=stream, logger=self.logger),
                    output_path=tmp_trace_dir,
                )
                if os.path.exists(
                    os.path.join(os.path.abspath(tmp_trace_dir), "instrument_data")
                ):
                    trace_file = f"{output}.trace"
                    shutil.copytree(tmp_trace_dir, trace_file)
                    result.append(trace_file)
                    self.logger.info(f"Trace written to {trace_file}")
                else:
                    # tar is a folder containing one or more trace files
                    for file in os.listdir(tmp_trace_dir):
                        _, file_extension = os.path.splitext(file)
                        tmp_trace_file = os.path.join(
                            os.path.abspath(tmp_trace_dir), file
                        )
                        trace_file = f"{output}{file_extension}"
                        shutil.move(tmp_trace_file, trace_file)
                        result.append(trace_file)
                        self.logger.info(f"Trace written to {trace_file}")

            return result

    @log_and_handle_exceptions("forward_port")
    async def forward_port(
        self,
        device_port: int,
        input_stream: StreamReader,
        output_stream: StreamWriter,
    ) -> None:
        await forward_port(self.stub, device_port, input_stream, output_stream)

    @log_and_handle_exceptions("dap")
    async def dap(
        self,
        dap_path: str,
        input_stream: StreamReader,
        output_stream: StreamWriter,
        stop: asyncio.Event,
        compression: Compression | None,
    ) -> None:
        path = Path(dap_path)
        pkg_id = path.stem
        self.logger.debug("Creating dap subfolder for different pkg of dap server.")
        await self.mkdir(container=FileContainerType.ROOT, path="dap")

        ls_response = await self.ls(container=FileContainerType.ROOT, paths=["dap"])
        installed_daps = [entry.path for entry in ls_response[0].entries]
        if pkg_id in installed_daps:
            self.logger.info(f"Dap pkg already exist. Id: {pkg_id}")
        else:
            self.logger.info(f"Pushing {path.absolute()} to simulator dap subfolder.")
            await self.push(
                src_paths=[str(path.absolute())],
                container=FileContainerType.ROOT,
                dest_path="dap",
                compression=compression,
            )

        async with RemoteDapServer.start(self.stub, self.logger, pkg_id) as dap_server:
            self.logger.debug("Dap server started. Waiting for input from stdin...")

            await dap_server.pipe(
                input_stream=input_stream,
                output_stream=output_stream,
                stop=stop,
            )
