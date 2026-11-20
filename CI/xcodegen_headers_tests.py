# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from .xcodegen_headers import rewrite_project


# XcodeGen's Swift static-library phase, with spaces standing in for tabs.
_PHASE = r"""        358A895B6AFD51A4A7B20269 /* Copy Swift Objective-C Interface Header */ = {
            isa = PBXShellScriptBuildPhase;
            buildActionMask = 2147483647;
            files = (
            );
            inputPaths = (
                "$(DERIVED_SOURCES_DIR)/$(SWIFT_OBJC_INTERFACE_HEADER_NAME)",
            );
            name = "Copy Swift Objective-C Interface Header";
            outputPaths = (
                "$(BUILT_PRODUCTS_DIR)/include/$(PRODUCT_MODULE_NAME)/$(SWIFT_OBJC_INTERFACE_HEADER_NAME)",
            );
            runOnlyForDeploymentPostprocessing = 0;
            shellPath = /bin/sh;
            shellScript = "ditto \"${SCRIPT_INPUT_FILE_0}\" \"${SCRIPT_OUTPUT_FILE_0}\"\n";
        };
"""

_GENERATE = r"""
source "$TEST_BUILD_SCRIPT"
python3() { "$TEST_PYTHON" "$@"; }
xcodegen() {
  local output=.
  if [ "$#" -eq 3 ] && [ "$2" = -p ]; then output="$3"; fi
  mkdir -p "$output/Fixture.xcodeproj"
  /bin/cp "$TEST_PROJECT" "$output/Fixture.xcodeproj/project.pbxproj"
}
ditto() {
  test "$1" = --noextattr || return 1
  /bin/cp -R "$2" "$3"
}
generate_xcodeproj "$TEST_PROJECT_DIR" Fixture
"""


class XcodegenHeadersTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.project = self.root / "project.pbxproj"

    def _write(self, *phases: str) -> str:
        text = "// !$*UTF8*$!\n{\n/* PBXProject */\n" + "".join(phases) + "}\n"
        self.project.write_text(text)
        return text

    def test_only_the_named_header_script_changes(self) -> None:
        unrelated = _PHASE.replace(
            "Copy Swift Objective-C Interface Header", "Copy Resources"
        )
        original = self._write(_PHASE, unrelated)
        rewrite_project(self.project)
        self.assertEqual(
            original.replace('shellScript = "ditto ', 'shellScript = "/bin/cp ', 1),
            self.project.read_text(),
        )

    def test_all_platform_variants_are_updated(self) -> None:
        phases = [
            _PHASE.replace("358A895B6AFD51A4A7B20269", f"{index:024X}").replace(
                "    ", "\t"
            )
            for index in range(9)
        ]
        original = self._write(*phases)
        rewrite_project(self.project)
        self.assertEqual(
            original.replace('shellScript = "ditto ', 'shellScript = "/bin/cp '),
            self.project.read_text(),
        )

    def test_safe_or_unrelated_projects_are_not_rewritten(self) -> None:
        for text in (
            _PHASE.replace('shellScript = "ditto ', 'shellScript = "/bin/cp '),
            _PHASE.replace('shellScript = "ditto ', 'shellScript = "cp '),
            _PHASE.replace("Copy Swift Objective-C Interface Header", "Copy Resources"),
            "",
        ):
            with self.subTest(text=text):
                original = self._write(text)
                os.utime(self.project, (100, 100))
                rewrite_project(self.project)
                self.assertEqual(original, self.project.read_text())
                self.assertEqual(100, self.project.stat().st_mtime)

    def test_unknown_later_script_leaves_the_whole_project_unchanged(self) -> None:
        changed = _PHASE.replace("358A895B6AFD51A4A7B20269", "FFFFFFFFFFFFFFFFFFFFFFFF")
        changed = changed.replace(
            'shellScript = "ditto ', 'shellScript = "ditto --new-option '
        )
        original = self._write(_PHASE, changed)
        with self.assertRaisesRegex(ValueError, "Unexpected.*script"):
            rewrite_project(self.project)
        self.assertEqual(original, self.project.read_text())

    def test_unknown_phase_structure_is_rejected_without_writing(self) -> None:
        for phase in (
            _PHASE.replace("PBXShellScriptBuildPhase", "PBXCopyFilesBuildPhase"),
            _PHASE.replace(
                "/* Copy Swift Objective-C Interface Header */", "/* Changed */"
            ),
            _PHASE.replace("shellScript =", "changedScript ="),
        ):
            with self.subTest(phase=phase):
                original = self._write(phase)
                with self.assertRaises(ValueError):
                    rewrite_project(self.project)
                self.assertEqual(original, self.project.read_text())

    def test_emitted_command_copies_the_header_without_touching_siblings(self) -> None:
        self._write(_PHASE)
        rewrite_project(self.project)
        encoded = (
            self.project.read_text().split("shellScript = ", 1)[1].split(";\n", 1)[0]
        )
        source = self.root / "Input header.h"
        directory = self.root / "Module headers"
        directory.mkdir()
        output = directory / "Output header.h"
        sibling = directory / "Existing header.h"
        sibling.write_bytes(b"unchanged")
        self.assertFalse(output.exists())
        for header in (
            b"// compatibility header\nint exposed_symbol(void);\n",
            b"// updated header\nvoid another_symbol(void);\n",
        ):
            source.write_bytes(header)
            result = subprocess.run(
                ["/bin/sh", "-c", json.loads(encoded)],
                env={
                    **os.environ,
                    "SCRIPT_INPUT_FILE_0": str(source),
                    "SCRIPT_OUTPUT_FILE_0": str(output),
                },
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(header, output.read_bytes())
            self.assertEqual(b"unchanged", sibling.read_bytes())
            self.assertEqual({output, sibling}, set(directory.iterdir()))

    def test_both_generation_paths_apply_the_fix(self) -> None:
        fixture = self._write(_PHASE)
        source_dir = Path(__file__).parent
        for xattrs in ("true", "false"):
            with self.subTest(xattrs=xattrs):
                root = self.root / xattrs
                (root / "CI").mkdir(parents=True)
                shutil.copyfile(
                    source_dir / "xcodegen_headers.py", root / "CI/xcodegen_headers.py"
                )
                project_dir = root / "Project with spaces"
                project_dir.mkdir()
                result = subprocess.run(
                    ["bash", "-c", _GENERATE],
                    cwd=root,
                    env={
                        **os.environ,
                        "PYTHONPATH": str(root),
                        "XATTRS_SUPPORTED": xattrs,
                        "TEST_BUILD_SCRIPT": str(source_dir.parent / "build.sh"),
                        "TEST_PYTHON": sys.executable,
                        "TEST_PROJECT": str(self.project),
                        "TEST_PROJECT_DIR": str(project_dir),
                    },
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(
                    fixture.replace('shellScript = "ditto ', 'shellScript = "/bin/cp '),
                    (project_dir / "Fixture.xcodeproj/project.pbxproj").read_text(),
                )
