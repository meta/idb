#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import asyncio
import gzip
import io
import os
import tarfile
import tempfile
import warnings
from types import SimpleNamespace

from grpclib.const import Status
from grpclib.exceptions import GRPCError, ProtocolError
from idb.common.types import (
    IdbException,
    LeaksProfile,
    MemgraphProfile,
    ProfileBundleID,
    ProfileLaunch,
    ProfilePid,
    ResourceSampleScope,
    ResourcesProfile,
    TraceProfile,
)
from idb.grpc.idb_pb2 import (
    Payload,
    ProfileLeaksReport,
    ProfileReport,
    ProfileRequest,
    ProfileResourceSample,
    ProfileResponse,
    ProfileTraceReport,
)
from idb.grpc.profile import (
    _is_repeated,
    message_to_json,
    ProfileException,
    start_request,
)
from idb.grpc.tests.stream_test_support import make_client
from idb.utils.testing import TestCase


def _leaks_result() -> ProfileResponse:
    report = ProfileReport(
        leaks=ProfileLeaksReport(
            leak_count=2,
            leaked_bytes=2**40,
            groups=[ProfileLeaksReport.Group(kind=ProfileLeaksReport.CYCLE)],
        )
    )
    return ProfileResponse(
        result=ProfileResponse.Result(report=report, tool_output=b"2 leaks")
    )


def _sample(elapsed_ms: int) -> ProfileResponse:
    return ProfileResponse(sample=ProfileResourceSample(pid=42, elapsed_ms=elapsed_ms))


def _artifact(files: dict[str, bytes]) -> list[ProfileResponse]:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    data = gzip.compress(buffer.getvalue())
    middle = len(data) // 2
    return [
        ProfileResponse(artifact=Payload(data=data[:middle])),
        ProfileResponse(artifact=Payload(data=data[middle:])),
    ]


class ProfileRequestTests(TestCase):
    def test_unset_values_are_sent_as_zero_for_the_companion_default(self) -> None:
        request = start_request(TraceProfile(), ProfilePid(pid=42), False)

        self.assertEqual(request.start.WhichOneof("kind"), "trace")
        self.assertEqual(request.start.trace.template, "")
        self.assertEqual(request.start.trace.duration_seconds, 0)
        self.assertEqual(request.start.trace.row_limit, 0)

    def test_each_target_and_option_reaches_the_request(self) -> None:
        trace = start_request(
            TraceProfile(template="Hangs", schemas=("potential-hangs",), duration=2.5),
            ProfileLaunch(bundle_id="com.example"),
            True,
        )
        resources = start_request(
            ResourcesProfile(
                interval_ms=250, scope=ResourceSampleScope.APP_AND_HELPERS
            ),
            ProfileBundleID(bundle_id="com.example"),
            False,
        )

        self.assertEqual(trace.start.target.launch_bundle_id, "com.example")
        self.assertEqual(list(trace.start.trace.schemas), ["potential-hangs"])
        self.assertEqual(trace.start.trace.duration_seconds, 2.5)
        self.assertTrue(trace.start.include_artifact)
        self.assertEqual(resources.start.target.bundle_id, "com.example")
        self.assertEqual(resources.start.resources.interval_ms, 250)
        self.assertEqual(
            resources.start.resources.scope, ProfileRequest.Resources.APP_AND_HELPERS
        )


class ProfileJSONTests(TestCase):
    def test_zero_and_large_integers_stay_numbers(self) -> None:
        report = message_to_json(_leaks_result().result.report)

        self.assertEqual(report["leaks"]["leakCount"], 2)
        self.assertEqual(report["leaks"]["leakedBytes"], 2**40)
        self.assertEqual(report["leaks"]["groups"][0]["roots"], 0)
        self.assertEqual(report["leaks"]["allocationStacks"], [])

    def test_enums_are_lowercase_names(self) -> None:
        report = message_to_json(_leaks_result().result.report)

        self.assertEqual(report["leaks"]["groups"][0]["kind"], "cycle")

    def test_unset_optional_and_oneof_fields_are_left_out(self) -> None:
        sample = message_to_json(ProfileResourceSample(pid=42))
        values = [
            message_to_json(ProfileTraceReport.Value(empty=True)),
            message_to_json(ProfileTraceReport.Value(text="Main Thread")),
        ]

        self.assertNotIn("cpuPct", sample)
        self.assertEqual(values, [{"empty": True}, {"text": "Main Thread"}])

    def test_reads_no_descriptor_attribute_protobuf_7_removed(self) -> None:
        # protobuf 6 deprecates `FieldDescriptor.label` and protobuf 7, which the open-source package requires, removes
        # it, so a conversion that reads it warns here and raises AttributeError there.
        with warnings.catch_warnings():
            warnings.simplefilter("error", DeprecationWarning)
            message_to_json(_leaks_result().result.report)


class RepeatedFieldTests(TestCase):
    def test_a_descriptor_without_is_repeated_is_read_by_its_label(self) -> None:
        # The C++ implementation of protobuf 3, which some builds still bundle, has no `is_repeated`.
        self.assertTrue(_is_repeated(SimpleNamespace(label=3)))
        self.assertFalse(_is_repeated(SimpleNamespace(label=1)))
        self.assertFalse(_is_repeated(SimpleNamespace(label=2)))

    def test_is_repeated_wins_over_label(self) -> None:
        self.assertTrue(_is_repeated(SimpleNamespace(is_repeated=True, label=1)))
        self.assertFalse(_is_repeated(SimpleNamespace(is_repeated=False, label=3)))


class _ProfileStream:
    """Answers with `initial`, then with `after_end` once the client ends its requests, as the companion does."""

    def __init__(
        self,
        *initial: ProfileResponse | None,
        after_end: tuple[ProfileResponse, ...] = (),
        trailing_error: GRPCError | None = None,
    ) -> None:
        self.sent: list[ProfileRequest] = []
        self.ended = False
        self._trailing_error = trailing_error
        self._after_end = after_end
        self._responses: asyncio.Queue[ProfileResponse | None] = asyncio.Queue()
        for response in initial:
            self._responses.put_nowait(response)

    async def __aenter__(self) -> _ProfileStream:
        return self

    async def __aexit__(
        self, _exc_type: object, exception: BaseException | None, _traceback: object
    ) -> None:
        # grpclib only reads the trailing status when the block exits without an exception, and refuses to read it
        # for a call whose requests were never ended.
        if exception is not None:
            return
        if not self.ended:
            raise ProtocolError("Outgoing stream was not ended")
        if self._trailing_error is not None:
            raise self._trailing_error

    def __aiter__(self) -> _ProfileStream:
        return self

    async def __anext__(self) -> ProfileResponse:
        response = await self.recv_message()
        if response is None:
            raise StopAsyncIteration
        return response

    async def recv_message(self) -> ProfileResponse | None:
        return await self._responses.get()

    async def send_message(self, message: ProfileRequest, *, end: bool = False) -> None:
        self.sent.append(message)
        if end:
            await self.end()

    async def end(self) -> None:
        self.ended = True
        for response in self._after_end:
            self._responses.put_nowait(response)
        self._responses.put_nowait(None)


class ProfileClientTests(TestCase):
    async def test_a_profile_that_runs_to_completion_ends_its_requests_with_start(
        self,
    ) -> None:
        stream = _ProfileStream(after_end=(_leaks_result(),))
        client, _ = make_client("profile", stream)
        stop = asyncio.Event()
        stop.set()

        result = await client.profile(LeaksProfile(), ProfilePid(pid=42), stop)

        self.assertEqual([r.WhichOneof("control") for r in stream.sent], ["start"])
        self.assertTrue(stream.ended)
        self.assertEqual(result.tool_output, b"2 leaks")
        self.assertEqual(result.report["leaks"]["leakCount"], 2)
        self.assertIsNone(result.artifact)

    async def test_stop_sends_stop_and_samples_arrive_as_they_are_taken(
        self,
    ) -> None:
        stream = _ProfileStream(
            _sample(0),
            _sample(100),
            after_end=(ProfileResponse(result=ProfileResponse.Result()),),
        )
        client, _ = make_client("profile", stream)
        stop = asyncio.Event()
        samples: list[dict[str, object]] = []

        def on_sample(sample: dict[str, object]) -> None:
            samples.append(sample)
            if len(samples) == 2:
                stop.set()

        result = await asyncio.wait_for(
            client.profile(
                ResourcesProfile(), ProfilePid(pid=42), stop, None, on_sample
            ),
            timeout=5,
        )

        self.assertEqual([sample["elapsedMs"] for sample in samples], [0, 100])
        self.assertEqual(
            [r.WhichOneof("control") for r in stream.sent], ["start", "stop"]
        )
        self.assertIsNone(result.report)

    async def test_a_stream_ending_without_a_result_is_an_error(self) -> None:
        stream = _ProfileStream(_sample(0), None)
        client, _ = make_client("profile", stream)

        with self.assertRaises(ProfileException):
            await client.profile(
                ResourcesProfile(), ProfilePid(pid=42), asyncio.Event()
            )

    async def test_a_failed_profile_reports_the_companions_error(self) -> None:
        stream = _ProfileStream(
            trailing_error=GRPCError(Status.INTERNAL, "leaks exited with code 255")
        )
        client, _ = make_client("profile", stream)
        stop = asyncio.Event()
        stop.set()

        with self.assertRaisesRegex(IdbException, "^leaks exited with code 255$"):
            await client.profile(LeaksProfile(), ProfilePid(pid=42), stop)

    async def test_a_failed_stoppable_profile_reports_the_companions_error(
        self,
    ) -> None:
        stream = _ProfileStream(
            None,
            trailing_error=GRPCError(Status.INTERNAL, "xctrace exited with code 1"),
        )
        client, _ = make_client("profile", stream)

        with self.assertRaisesRegex(IdbException, "^xctrace exited with code 1$"):
            await client.profile(TraceProfile(), ProfilePid(pid=42), asyncio.Event())

    async def test_a_single_file_artifact_is_written_to_the_path(self) -> None:
        stream = _ProfileStream(
            after_end=(_leaks_result(), *_artifact({"profile-1.memgraph": b"graph"}))
        )
        client, _ = make_client("profile", stream)

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "app.memgraph")
            result = await client.profile(
                MemgraphProfile(), ProfilePid(pid=42), asyncio.Event(), path
            )

            self.assertTrue(stream.sent[0].start.include_artifact)
            self.assertEqual(result.artifact, path)
            with open(path, "rb") as f:
                self.assertEqual(f.read(), b"graph")

    async def test_a_directory_artifact_becomes_the_directory_at_the_path(
        self,
    ) -> None:
        artifact = _artifact({"./form.template": b"t", "./instrument_data/run": b"r"})
        stream = _ProfileStream(_leaks_result(), *artifact, None)
        client, _ = make_client("profile", stream)

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "app.trace")
            await client.profile(
                TraceProfile(), ProfilePid(pid=42), asyncio.Event(), path
            )

            self.assertEqual(
                sorted(os.listdir(path)), ["form.template", "instrument_data"]
            )
