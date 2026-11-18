# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Regression tests for source linkage in rendered SwiftPM packages."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github" / "scripts"))
import tap_formulae  # noqa: E402

TAG: str = "v1.6.0"
COMPANION_SHA: str = "1" * 64
WHEEL_SHA: str = "2" * 64
RUN_URL: str = "https://github.com/facebook/idb/actions/runs/123456"
ASSET_BASE: str = tap_formulae.release_asset_base(TAG)
TEMPLATES: Path = Path(__file__).resolve().parents[1] / ".github" / "formulae"

TARGET_NAME: str = "IDBPackageLinkage"
SOURCE_MEMBER: str = "Sources/IDBPackageLinkage/empty.c"
SOURCE_HEADER: str = "Sources/IDBPackageLinkage/include/IDBPackageLinkage.h"
SOURCE_DECLARATION: str = (
    '.target(name: "IDBPackageLinkage", path: "Sources/IDBPackageLinkage", '
    'sources: ["empty.c"], publicHeadersPath: "include"),'
)

SWIFTPM: dict[str, Any] = {
    "products": {"FBControlCore": ["FBControlCore", TARGET_NAME]},
    "checksums": {"FBControlCore": "a" * 64},
}


def _full_render(
    swiftpm: dict[str, Any] = SWIFTPM,
) -> tuple[dict[str, str], dict[str, Any]]:
    outputs = tap_formulae.render_formulae(
        TAG, COMPANION_SHA, WHEEL_SHA, asset_base=ASSET_BASE, templates_dir=TEMPLATES
    )
    outputs.update(tap_formulae.render_package_files(TAG, ASSET_BASE, swiftpm))
    manifest = tap_formulae.render_manifest(
        TAG,
        outputs,
        COMPANION_SHA,
        WHEEL_SHA,
        ASSET_BASE,
        run_url=RUN_URL,
        swiftpm=swiftpm,
    )
    return outputs, manifest


class PackageSourceLinkageRenderTest(unittest.TestCase):
    def test_full_render_declares_the_source_member_with_no_binary_checksum(
        self,
    ) -> None:
        outputs, manifest = _full_render()
        self.assertEqual(outputs[SOURCE_MEMBER], "")
        self.assertEqual(outputs[SOURCE_HEADER], "")
        package = outputs[tap_formulae.PACKAGE]
        self.assertEqual(package.count(SOURCE_DECLARATION), 1)
        self.assertNotIn(f"{TARGET_NAME}.xcframework", package)
        self.assertNotIn("unsafeFlags", package)
        self.assertNotIn(TARGET_NAME, manifest["swiftpm"]["checksums"])
        self.assertIn(SOURCE_MEMBER, manifest["outputs"])
        self.assertIn(SOURCE_HEADER, manifest["outputs"])

    def test_render_without_the_source_target_omits_the_source_files(self) -> None:
        swiftpm = {
            "products": {"FBControlCore": ["FBControlCore"]},
            "checksums": {"FBControlCore": "a" * 64},
        }
        outputs, _manifest = _full_render(swiftpm=swiftpm)
        self.assertNotIn(SOURCE_MEMBER, outputs)
        self.assertNotIn(SOURCE_HEADER, outputs)
        self.assertNotIn(TARGET_NAME, outputs[tap_formulae.PACKAGE])


class ArchiveRoundTripTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)

    def test_archive_and_unpack_preserve_relative_source_paths(self) -> None:
        outputs, manifest = _full_render()
        rendered = self.root / "rendered"
        tap_formulae.write_rendered(rendered, outputs, manifest)

        archive_path = self.root / "tap-formulae.tar.gz"
        tap_formulae.archive_rendered(rendered, archive_path)

        with tarfile.open(archive_path, "r:gz") as archive:
            names = set(archive.getnames())
            self.assertIn(SOURCE_MEMBER, names)
            self.assertIn(SOURCE_HEADER, names)
            unpacked = self.root / "unpacked"
            archive.extractall(unpacked, filter="data")

        self.assertEqual((unpacked / SOURCE_MEMBER).read_text(), "")
        self.assertEqual((unpacked / SOURCE_HEADER).read_text(), "")
        unpacked_manifest = json.loads((unpacked / tap_formulae.MANIFEST).read_text())
        self.assertEqual(
            tap_formulae.read_rendered(unpacked, unpacked_manifest), outputs
        )


class RenderValidationRejectsCorruptOutputTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.outputs, self.manifest = _full_render()
        self.rendered = self.root / "rendered"
        tap_formulae.write_rendered(self.rendered, self.outputs, self.manifest)

    def test_archive_rejects_a_missing_source_member(self) -> None:
        (self.rendered / SOURCE_MEMBER).unlink()
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "missing rendered output"
        ):
            tap_formulae.archive_rendered(self.rendered, self.root / "out.tar.gz")

    def test_archive_rejects_a_missing_header(self) -> None:
        (self.rendered / SOURCE_HEADER).unlink()
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "missing rendered output"
        ):
            tap_formulae.archive_rendered(self.rendered, self.root / "out.tar.gz")

    def test_read_rendered_rejects_a_bad_digest(self) -> None:
        formula = self.rendered / "idb-cli.rb"
        formula.write_text(formula.read_text() + "\n# tampered\n")
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "does not match its own manifest"
        ):
            tap_formulae.read_rendered(self.rendered, self.manifest)

    def test_archive_reports_invalid_utf8_without_writing(self) -> None:
        (self.rendered / "idb-cli.rb").write_bytes(b"\xff")
        for existing in (False, True):
            with self.subTest(existing=existing):
                archive = self.root / f"out-{existing}.tar.gz"
                if existing:
                    archive.write_bytes(b"previous archive")
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    result = tap_formulae.main(
                        [
                            "archive",
                            "--directory",
                            str(self.rendered),
                            "--out",
                            str(archive),
                        ]
                    )
                self.assertEqual(result, 1)
                self.assertEqual(
                    stderr.getvalue(),
                    "error: rendered output is not valid UTF-8: idb-cli.rb\n",
                )
                if existing:
                    self.assertEqual(archive.read_bytes(), b"previous archive")
                else:
                    self.assertFalse(archive.exists())

    def test_read_rendered_rejects_a_nonempty_source_member_even_with_a_matching_digest(
        self,
    ) -> None:
        tampered = "int unexpected;"
        (self.rendered / SOURCE_MEMBER).write_text(tampered)
        manifest = json.loads(json.dumps(self.manifest))
        manifest["outputs"][SOURCE_MEMBER] = tap_formulae.sha256_of_text(tampered)
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "source linkage file must be empty"
        ):
            tap_formulae.read_rendered(self.rendered, manifest)


class RenderedOutputPathSafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)

    def test_rendered_paths_rejects_an_unknown_output_name(self) -> None:
        manifest = {"tag": TAG, "outputs": {"../escape.rb": "d" * 64}}
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "unexpected rendered output paths"
        ):
            tap_formulae.rendered_paths(manifest)

    def test_write_outputs_rejects_an_unknown_output_path(self) -> None:
        outputs, _manifest = _full_render()
        outputs["../escape.rb"] = "evil"
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "unexpected rendered output path"
        ):
            tap_formulae.write_outputs(self.root, outputs)

    def test_write_outputs_rejects_a_symlinked_source_directory(self) -> None:
        outputs, manifest = _full_render()
        outside = self.root.parent / f"{self.root.name}-outside"
        outside.mkdir()
        self.addCleanup(shutil.rmtree, outside)
        (self.root / "Sources").mkdir(parents=True)
        (self.root / "Sources" / TARGET_NAME).symlink_to(
            outside, target_is_directory=True
        )
        with self.assertRaisesRegex(tap_formulae.FormulaError, "symlink"):
            tap_formulae.write_rendered(self.root, outputs, manifest)
        self.assertEqual(list(outside.iterdir()), [])

    def test_write_outputs_leaves_existing_bytes_unchanged_on_validation_failure(
        self,
    ) -> None:
        outputs, manifest = _full_render()
        tap_formulae.write_rendered(self.root, outputs, manifest)
        before = {
            path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
        }

        corrupt = json.loads(json.dumps(manifest))
        corrupt["outputs"]["idb-cli.rb"] = tap_formulae.sha256_of_text(
            "not the real text"
        )
        with self.assertRaises(tap_formulae.FormulaError):
            tap_formulae.write_rendered(self.root, outputs, corrupt)

        after = {
            path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
        }
        self.assertEqual(before, after)
