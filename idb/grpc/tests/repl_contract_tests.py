#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import base64
import json
import pkgutil
import unittest
from collections.abc import Sequence
from typing import Any

from idb.grpc.idb_pb2 import ReplRequest, ReplResponse


def _reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _load_json(data: bytes) -> Any:
    return json.loads(data, object_pairs_hook=_reject_duplicate_keys)


class ReplContractTests(unittest.TestCase):
    def test_language_neutral_repl_transcript(self) -> None:
        fixture_data = pkgutil.get_data("idb.grpc", "tests/repl_transcript.v1.json")
        self.assertIsNotNone(fixture_data)
        with self.assertRaisesRegex(ValueError, "duplicate JSON key 'version'"):
            _load_json(b'{"version": 1, "version": 2}')
        fixture = _load_json(fixture_data)
        self.assertEqual(set(fixture), {"scope", "steps", "version"})
        self.assertEqual(fixture["version"], 1)
        self.assertEqual(fixture["scope"], "swift-protobuf-wire-contract")

        steps = fixture["steps"]
        self.assertEqual(
            [step["kind"] for step in steps],
            [
                "Start",
                "Ready",
                "Execute",
                "Result",
                "client_half_close",
                "Stopped",
            ],
        )

        expected_messages = {
            "Start": ReplRequest(
                start=ReplRequest.Start(
                    test_bundle_path="FixtureTests.xctest",
                    context=ReplRequest.Start.TEST,
                    probe_file_path="/tmp/idb-repl-fixture-probe",
                )
            ),
            "Ready": ReplResponse(
                ready=ReplResponse.Ready(
                    device_type="iphone",
                    generated_interfaces=[
                        ReplResponse.Ready.GeneratedInterface(
                            module_name="IDB",
                            contents="public struct Fixture {}",
                        )
                    ],
                    os_version="26.0",
                    next_run_index=0,
                    shared_filesystem=True,
                    session_id="fixture-session",
                )
            ),
            "Execute": ReplRequest(
                execute=ReplRequest.Execute(dylib=b"\xca\xfe", symbol="idb_repl_0")
            ),
            "Result": ReplResponse(
                result=ReplResponse.Result(
                    success=True,
                    output="ok",
                    next_run_index=1,
                    artifacts=[
                        ReplResponse.Result.Artifact(
                            host_path=(
                                "/tmp/idb-repl-artifacts/fixture-session/capture.png"
                            ),
                            container_path=(
                                "idb-repl-artifacts/fixture-session/capture.png"
                            ),
                        )
                    ],
                )
            ),
            "Stopped": ReplResponse(
                stopped=ReplResponse.Stopped(desc="REPL session ended")
            ),
        }
        inactive_fields = {
            "Start": ("execute", "stop"),
            "Ready": ("result", "stopped"),
            "Execute": ("start", "stop"),
            "Result": ("ready", "stopped"),
            "Stopped": ("ready", "result"),
        }
        messages = {}
        for step in steps:
            kind = step["kind"]
            if kind == "client_half_close":
                self.assertEqual(step, {"kind": "client_half_close"})
                continue

            self.assertEqual(set(step), {"kind", "protobuf_base64"})
            encoded = step["protobuf_base64"]
            payload = base64.b64decode(encoded, validate=True)
            self.assertEqual(base64.b64encode(payload).decode(), encoded)
            expected = expected_messages[kind]
            self.assertEqual(payload, expected.SerializeToString())
            message = type(expected).FromString(payload)
            self.assertEqual(message, expected)
            self.assertEqual(message.SerializeToString(), payload)
            for field in inactive_fields[kind]:
                self.assertFalse(
                    message.HasField(field), f"{kind}.{field} must be inactive"
                )
            messages[kind] = message

        start = messages["Start"]
        self.assertEqual(start.WhichOneof("control"), "start")
        self.assertEqual(start.start.test_bundle_path, "FixtureTests.xctest")
        self.assertEqual(start.start.context, ReplRequest.Start.TEST)
        self.assertEqual(start.start.probe_file_path, "/tmp/idb-repl-fixture-probe")

        ready = messages["Ready"]
        self.assertEqual(ready.WhichOneof("event"), "ready")
        self.assertEqual(ready.ready.device_type, "iphone")
        self.assertEqual(
            [
                (interface.module_name, interface.contents)
                for interface in ready.ready.generated_interfaces
            ],
            [("IDB", "public struct Fixture {}")],
        )
        self.assertEqual(ready.ready.os_version, "26.0")
        self.assertEqual(ready.ready.next_run_index, 0)
        self.assertTrue(ready.ready.shared_filesystem)
        self.assertEqual(ready.ready.session_id, "fixture-session")

        execute = messages["Execute"]
        self.assertEqual(execute.WhichOneof("control"), "execute")
        self.assertEqual(execute.execute.dylib, b"\xca\xfe")
        self.assertEqual(execute.execute.symbol, "idb_repl_0")

        result = messages["Result"]
        self.assertEqual(result.WhichOneof("event"), "result")
        self.assertTrue(result.result.success)
        self.assertEqual(result.result.output, "ok")
        self.assertEqual(result.result.next_run_index, 1)
        self.assertEqual(
            [
                (artifact.host_path, artifact.container_path)
                for artifact in result.result.artifacts
            ],
            [
                (
                    "/tmp/idb-repl-artifacts/fixture-session/capture.png",
                    "idb-repl-artifacts/fixture-session/capture.png",
                )
            ],
        )

        stopped = messages["Stopped"]
        self.assertEqual(stopped.WhichOneof("event"), "stopped")
        self.assertEqual(stopped.stopped.desc, "REPL session ended")
