# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import os
import plistlib
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from . import select_xcode


class SelectXcodeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.environment = self.root / "GITHUB_ENV"

    def _bundle(self, name: str, version: object = "26.1") -> Path:
        app = self.applications / name
        (app / "Contents/Developer").mkdir(parents=True)
        (app / "Contents/version.plist").write_bytes(
            plistlib.dumps({"CFBundleShortVersionString": version})
        )
        return app

    def _assert_skipped(self, bad: Path, good: Path) -> None:
        for apps in ([bad, good], [good, bad]):
            with (
                self.subTest(order=[app.name for app in apps]),
                patch.object(Path, "glob", return_value=iter(apps)),
                self.assertLogs(select_xcode.logger, level="WARNING") as logs,
            ):
                self.environment.write_text("EXISTING=value\n")
                select_xcode.write_environment(self.applications, self.environment)
                self.assertEqual(
                    f"EXISTING=value\nDEVELOPER_DIR={good / 'Contents/Developer'}\n",
                    self.environment.read_text(),
                )
                self.assertEqual(1, len(logs.output))
                self.assertIn(f"Skipping {bad}:", logs.output[0])

    def test_missing_plist_does_not_mask_a_valid_install_in_either_order(self) -> None:
        bad = self._bundle("Xcode_partial.app")
        (bad / "Contents/version.plist").unlink()
        good = self._bundle("Xcode_26.app")
        self._assert_skipped(bad, good)

    def test_invalid_versions_do_not_mask_a_valid_install_in_either_order(self) -> None:
        good = self._bundle("Xcode_26.app")
        for index, version in enumerate(
            ("27.0b1", "", "26..1", "26.", "-26.1", "26.+1", 26, ["26"])
        ):
            with self.subTest(version=version):
                bad = self._bundle(f"Xcode_bad_{index}.app", version)
                self._assert_skipped(bad, good)

    def test_malformed_plists_and_missing_version_are_skipped(self) -> None:
        good = self._bundle("Xcode_26.app")
        for index, data in enumerate(
            (
                b"not a plist",
                b"<?xml version='1.0'?><plist><dict>",
                plistlib.dumps({}),
                plistlib.dumps(["26.1"]),
            )
        ):
            with self.subTest(data=data):
                bad = self._bundle(f"Xcode_bad_{index}.app")
                (bad / "Contents/version.plist").write_bytes(data)
                self._assert_skipped(bad, good)

    def test_missing_developer_directory_is_skipped(self) -> None:
        bad = self._bundle("Xcode_partial.app", "26.11")
        (bad / "Contents/Developer").rmdir()
        good = self._bundle("Xcode_26.app", "26.10")
        self._assert_skipped(bad, good)

    def test_highest_numeric_xcode_26_is_selected_not_a_later_major(self) -> None:
        self._bundle("Xcode_26.9.app", "26.9")
        expected = self._bundle("Xcode_26.10.app", "26.10")
        self._bundle("Xcode_27.app", "27.1")
        with self.assertNoLogs(select_xcode.logger):
            self.assertEqual(
                expected / "Contents/Developer",
                select_xcode.select_xcode(self.applications),
            )

    def test_beta_named_bundle_is_ignored_without_reading_its_plist(self) -> None:
        (self.applications / "Xcode_BeTa.app").mkdir()
        good = self._bundle("Xcode_26.app")
        with self.assertNoLogs(select_xcode.logger):
            self.assertEqual(
                good / "Contents/Developer",
                select_xcode.select_xcode(self.applications),
            )

    def test_no_valid_xcode_26_fails_without_writing_environment(self) -> None:
        other_major = self._bundle("Xcode_27.app", "27.1")
        malformed = self._bundle("Xcode_bad.app", "27.0b1")
        for apps in ([], [other_major], [malformed, other_major]):
            with (
                self.subTest(apps=[app.name for app in apps]),
                patch.object(Path, "glob", return_value=iter(apps)),
                self.assertRaisesRegex(
                    SystemExit,
                    "Xcode 26 is not installed on this runner; qualification is incomplete",
                ),
            ):
                select_xcode.write_environment(self.applications, self.environment)
            self.assertFalse(self.environment.exists())

    def test_output_write_failure_is_not_treated_as_a_bad_candidate(self) -> None:
        self._bundle("Xcode_26.app")
        self.environment.mkdir()
        with (
            self.assertNoLogs(select_xcode.logger),
            self.assertRaises(IsADirectoryError),
        ):
            select_xcode.write_environment(self.applications, self.environment)

    def test_entry_point_appends_to_github_environment(self) -> None:
        good = self._bundle("Xcode 26.app")
        self.environment.write_text("EXISTING=value\n")
        with (
            patch.object(Path, "glob", return_value=iter([good])),
            patch.dict(os.environ, {"GITHUB_ENV": str(self.environment)}),
        ):
            runpy.run_path(str(Path(select_xcode.__file__)), run_name="__main__")
        self.assertEqual(
            f"EXISTING=value\nDEVELOPER_DIR={good / 'Contents/Developer'}\n",
            self.environment.read_text(),
        )
