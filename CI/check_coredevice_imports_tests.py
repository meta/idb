# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from . import check_coredevice_imports
from .check_coredevice_imports import check_imports, ImportCheckError


class CoreDeviceWeakImportsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.stub = Path(self.directory.name) / "CoreDevice.tbd"
        self.archive = Path(self.directory.name) / "libFBDeviceHID.a"
        self.stub.touch()
        self.archive.touch()

    def run_check(self, exports: str, strong: str) -> dict[str, object]:
        results = [
            subprocess.CompletedProcess([], 0, exports, ""),
            subprocess.CompletedProcess([], 0, strong, ""),
        ]
        with patch.object(
            check_coredevice_imports.subprocess, "run", side_effect=results
        ) as run:
            result = check_imports(["nm"], "arm64", self.stub, [self.archive])
        self.assertIn("--add-inlinedinfo", run.call_args_list[0].args[0])
        self.assertIn("--no-weak", run.call_args_list[1].args[0])
        return result

    def test_rejects_strong_reference(self) -> None:
        with self.assertRaisesRegex(ImportCheckError, "strong undefined references"):
            self.run_check(
                "_$s10CoreDevice12HIDDigitizerMp\n", "_$s10CoreDevice12HIDDigitizerMp\n"
            )

    def test_archive_member_heading_preserves_strong_reference(self) -> None:
        symbol = "_$s10CoreDevice12HIDDigitizerMp\n"
        with self.assertRaisesRegex(ImportCheckError, "strong undefined references"):
            self.run_check(symbol, "FBDeviceHID.swift.o:\n" + symbol)

    def test_includes_associated_type_manglings(self) -> None:
        symbol = "_$s12ProtocolType10CoreDevice0D10CapabilityPTl\n"
        with self.assertRaisesRegex(ImportCheckError, "ProtocolType"):
            self.run_check(symbol, symbol)

    def test_accepts_unrelated_strong_reference(self) -> None:
        result = self.run_check("_$s10CoreDevice12HIDDigitizerMp\n", "_malloc\n")
        self.assertEqual(result["exports"], 1)

    def test_empty_export_set_is_not_success(self) -> None:
        with self.assertRaisesRegex(ImportCheckError, "no exports"):
            self.run_check("", "")

    def test_invalid_nm_output_is_not_success(self) -> None:
        with self.assertRaisesRegex(ImportCheckError, "invalid nm symbol output"):
            self.run_check("unexpected output\n", "")

    def test_missing_archive_is_not_success(self) -> None:
        self.archive.unlink()
        with self.assertRaisesRegex(ImportCheckError, "missing symbol-check input"):
            self.run_check("_$s10CoreDevice12HIDDigitizerMp\n", "")

    def test_no_inputs_is_not_success(self) -> None:
        with self.assertRaisesRegex(ImportCheckError, "at least one prelink"):
            check_imports(["nm"], "arm64", self.stub, [])

    def test_nm_failure_is_not_success(self) -> None:
        error = subprocess.CalledProcessError(1, ["nm"], stderr="malformed archive")
        with patch.object(
            check_coredevice_imports.subprocess, "run", side_effect=error
        ):
            with self.assertRaisesRegex(ImportCheckError, "malformed archive"):
                check_imports(["nm"], "arm64", self.stub, [self.archive])
