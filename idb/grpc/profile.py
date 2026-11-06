#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import os
import shutil
import tempfile
from collections.abc import AsyncIterator, Callable

from google.protobuf.descriptor import FieldDescriptor
from google.protobuf.message import Message
from idb.common.tar import drain_untar
from idb.common.types import (
    FootprintProfile,
    HeapProfile,
    IdbException,
    LeaksProfile,
    MemgraphProfile,
    ProfileAllProcesses,
    ProfileBundleID,
    ProfileKind,
    ProfileLaunch,
    ProfilePid,
    ProfileTarget,
    ResourceSampleScope,
    ResourcesProfile,
    SampleProfile,
    TraceProfile,
    VmmapProfile,
)
from idb.grpc.idb_pb2 import ProfileRequest, ProfileResponse
from idb.grpc.stream import Stream


class ProfileException(IdbException):
    pass


def accepts_stop(kind: ProfileKind) -> bool:
    return isinstance(kind, (ResourcesProfile, TraceProfile))


def target_to_grpc(target: ProfileTarget) -> ProfileRequest.Target:
    match target:
        case ProfilePid(pid=pid):
            return ProfileRequest.Target(pid=pid)
        case ProfileBundleID(bundle_id=bundle_id):
            return ProfileRequest.Target(bundle_id=bundle_id)
        case ProfileLaunch(bundle_id=bundle_id):
            return ProfileRequest.Target(launch_bundle_id=bundle_id)
        case ProfileAllProcesses():
            return ProfileRequest.Target(all_processes=True)


def start_request(
    kind: ProfileKind, target: ProfileTarget, include_artifact: bool
) -> ProfileRequest:
    # Zero is unset on the wire, and takes the companion's default.
    start = ProfileRequest.Start(
        target=target_to_grpc(target), include_artifact=include_artifact
    )
    match kind:
        case LeaksProfile():
            start.leaks.SetInParent()
        case MemgraphProfile():
            start.memgraph.SetInParent()
        case HeapProfile():
            start.heap.SetInParent()
        case SampleProfile(seconds=seconds):
            start.sample.seconds = seconds or 0
        case VmmapProfile():
            start.vmmap.SetInParent()
        case FootprintProfile():
            start.footprint.SetInParent()
        case ResourcesProfile(interval_ms=interval_ms, scope=scope):
            start.resources.interval_ms = interval_ms or 0
            start.resources.scope = (
                ProfileRequest.Resources.APP_AND_HELPERS
                if scope == ResourceSampleScope.APP_AND_HELPERS
                else ProfileRequest.Resources.APP
            )
        case TraceProfile(
            template=template, schemas=schemas, duration=duration, row_limit=row_limit
        ):
            start.trace.template = template or ""
            start.trace.schemas.extend(schemas)
            start.trace.duration_seconds = duration or 0
            start.trace.row_limit = row_limit or 0
    return ProfileRequest(start=start)


def message_to_json(message: Message) -> dict[str, object]:
    """Keys each field by its JSON name, keeping zero values, which `MessageToDict` drops, and 64-bit integers as
    numbers, which it renders as strings. Unset optional, message and oneof fields are left out."""
    output: dict[str, object] = {}
    for field in message.DESCRIPTOR.fields:
        value = getattr(message, field.name)
        if _is_repeated(field):
            output[field.json_name] = [_value_to_json(field, item) for item in value]
            continue
        has_presence = (
            field.message_type is not None or field.containing_oneof is not None
        )
        if has_presence and not message.HasField(field.name):
            continue
        output[field.json_name] = _value_to_json(field, value)
    return output


# `FieldDescriptorProto.Label.LABEL_REPEATED`, which protobuf 7 no longer exposes on `FieldDescriptor`.
_LABEL_REPEATED = 3


def _is_repeated(field: object) -> bool:
    # `is_repeated` replaces `label`, which protobuf 6 deprecates and 7 removes; the C++
    # implementation of older protobufs, still bundled in some builds, has only `label`.
    is_repeated = getattr(field, "is_repeated", None)
    if is_repeated is not None:
        return bool(is_repeated)
    return getattr(field, "label", None) == _LABEL_REPEATED


def _value_to_json(field: FieldDescriptor, value: object) -> object:
    if field.message_type is not None:
        # pyre-ignore[6]: a message field holds a message.
        return message_to_json(value)
    if field.enum_type is not None:
        # pyre-ignore[6]: an enum field holds its number.
        return field.enum_type.values_by_number[value].name.lower()
    return value


async def drain_profile(
    stream: Stream[ProfileRequest, ProfileResponse],
    stop: asyncio.Event | None,
    on_sample: Callable[[dict[str, object]], None] | None,
) -> ProfileResponse.Result | None:
    """Reads samples until the result, sending Stop if `stop` is set first. Pass no `stop` for a profile that does
    not accept Stop; it should have ended the request stream instead. Returns None if the stream ends without a
    result, which a failed profile does: its error is the call's status, raised as the stream closes."""
    stop_waiter = None if stop is None else asyncio.ensure_future(stop.wait())
    ended = stop is None
    try:
        while True:
            read = asyncio.ensure_future(stream.recv_message())
            if stop_waiter is not None and not stop_waiter.done():
                await asyncio.wait(
                    [stop_waiter, read], return_when=asyncio.FIRST_COMPLETED
                )
                if not read.done():
                    await stream.send_message(
                        ProfileRequest(stop=ProfileRequest.Stop())
                    )
                    await stream.end()
                    ended = True
            response = await read
            output = None if response is None else response.WhichOneof("output")
            if output in (None, "result"):
                # grpclib only reads the call's status once the requests are ended, so end them if the companion
                # finished before Stop was sent.
                if not ended:
                    await stream.end()
                return None if response is None else response.result
            if output == "sample" and on_sample is not None:
                on_sample(message_to_json(response.sample))
    finally:
        if stop_waiter is not None:
            stop_waiter.cancel()
            await asyncio.gather(stop_waiter, return_exceptions=True)


async def generate_artifact_bytes(
    stream: Stream[ProfileRequest, ProfileResponse],
) -> AsyncIterator[bytes]:
    async for response in stream:
        data = response.artifact.data
        if len(data):
            yield data


async def drain_artifact(
    stream: Stream[ProfileRequest, ProfileResponse], path: str
) -> None:
    """Writes the artifact that follows the result to `path`: a file, such as a memory graph, or the contents of a
    directory, such as a trace bundle."""
    with tempfile.TemporaryDirectory() as extracted:
        await drain_untar(generate_artifact_bytes(stream), output_path=extracted)
        entries = os.listdir(extracted)
        if not entries:
            raise ProfileException("The companion sent no artifact")
        single = os.path.join(extracted, entries[0])
        if len(entries) == 1 and os.path.isfile(single):
            shutil.move(single, path)
        else:
            shutil.copytree(extracted, path)
