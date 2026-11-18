# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Regression tests for validated rendered output reads and writes."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github" / "scripts"))
import tap_formulae  # noqa: E402

TAG: str = "v1.6.0"
COMPANION_SHA: str = "1" * 64
WHEEL_SHA: str = "2" * 64
RUN_URL: str = "https://github.com/facebook/idb/actions/runs/123456"
ASSET_BASE: str = tap_formulae.release_asset_base(TAG)
TEMPLATES: Path = Path(__file__).resolve().parents[1] / ".github" / "formulae"

SWIFTPM: dict[str, Any] = {
    "products": {"FBControlCore": ["FBControlCore"]},
    "checksums": {"FBControlCore": "a" * 64},
}


def _full_render(
    swiftpm: dict[str, Any] = SWIFTPM,
) -> tuple[dict[str, str], dict[str, Any]]:
    outputs = tap_formulae.render_formulae(
        TAG, COMPANION_SHA, WHEEL_SHA, asset_base=ASSET_BASE, templates_dir=TEMPLATES
    )
    outputs[tap_formulae.PACKAGE] = tap_formulae.render_package(
        TAG, ASSET_BASE, swiftpm
    )
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


class RenderValidationRejectsCorruptOutputTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.outputs, self.manifest = _full_render()
        self.rendered = self.root / "rendered"
        tap_formulae.write_rendered(self.rendered, self.outputs, self.manifest)

    def test_read_rendered_rejects_a_bad_digest(self) -> None:
        formula = self.rendered / "idb-cli.rb"
        formula.write_text(formula.read_text() + "\n# tampered\n")
        with self.assertRaisesRegex(
            tap_formulae.FormulaError, "does not match its own manifest"
        ):
            tap_formulae.read_rendered(self.rendered, self.manifest)


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


class GenericRendererBridgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.outputs, self.manifest = _full_render()

    def test_direct_reader_rejects_invalid_utf8(self) -> None:
        tap_formulae.write_rendered(self.root, self.outputs, self.manifest)
        path = self.root / "idb-cli.rb"
        path.write_bytes(b"\xff")
        before = {name: (self.root / name).read_bytes() for name in self.outputs}
        with self.assertRaisesRegex(tap_formulae.FormulaError, "not valid UTF-8"):
            tap_formulae.read_rendered(self.root, self.manifest)
        self.assertEqual(
            before, {name: (self.root / name).read_bytes() for name in self.outputs}
        )

    def test_flat_symlink_destination_is_preflighted_before_any_write(self) -> None:
        for broken in (False, True):
            with self.subTest(broken=broken):
                root = self.root / str(broken)
                root.mkdir()
                (root / "idb-companion.rb").write_bytes(b"previous companion")
                outside = self.root / f"outside-{broken}"
                if not broken:
                    outside.write_bytes(b"outside sentinel")
                (root / "idb-cli.rb").symlink_to(outside)
                with self.assertRaisesRegex(tap_formulae.FormulaError, "symlink"):
                    tap_formulae.write_rendered(root, self.outputs, self.manifest)
                self.assertEqual(
                    (root / "idb-companion.rb").read_bytes(), b"previous companion"
                )
                self.assertFalse((root / tap_formulae.MANIFEST).exists())
                if broken:
                    self.assertFalse(outside.exists())
                else:
                    self.assertEqual(outside.read_bytes(), b"outside sentinel")

    def test_direct_reader_rejects_flat_symlink(self) -> None:
        tap_formulae.write_rendered(self.root, self.outputs, self.manifest)
        original = self.root / "idb-cli.rb"
        outside = self.root / "outside"
        original.rename(outside)
        original.symlink_to(outside)
        with self.assertRaisesRegex(tap_formulae.FormulaError, "symlink"):
            tap_formulae.read_rendered(self.root, self.manifest)

    def test_full_formula_inventory_cannot_hide_a_declared_package(self) -> None:
        outputs = dict(self.outputs)
        manifest = json.loads(json.dumps(self.manifest))
        del outputs[tap_formulae.PACKAGE]
        del manifest["outputs"][tap_formulae.PACKAGE]
        with self.assertRaisesRegex(tap_formulae.FormulaError, "no Package.swift"):
            tap_formulae.write_rendered(self.root, outputs, manifest)
        with self.assertRaisesRegex(tap_formulae.FormulaError, "no Package.swift"):
            tap_formulae.render_from_manifest(manifest, templates_dir=TEMPLATES)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_inventory_mismatch_fails_before_creating_destination(self) -> None:
        outputs = dict(self.outputs)
        del outputs["idb-cli.rb"]
        destination = self.root / "absent"
        with self.assertRaisesRegex(tap_formulae.FormulaError, "output paths"):
            tap_formulae.write_rendered(destination, outputs, self.manifest)
        self.assertFalse(destination.exists())

    def test_reader_rejects_missing_flat_output(self) -> None:
        tap_formulae.write_rendered(self.root, self.outputs, self.manifest)
        (self.root / "idb-cli.rb").unlink()
        with self.assertRaisesRegex(tap_formulae.FormulaError, "missing rendered"):
            tap_formulae.read_rendered(self.root, self.manifest)

    def test_package_and_manifest_destination_conflicts_precede_writes(self) -> None:
        for name in (tap_formulae.PACKAGE, tap_formulae.MANIFEST):
            with self.subTest(name=name):
                root = self.root / name
                root.mkdir()
                (root / "idb-companion.rb").write_bytes(b"keep")
                (root / name).mkdir()
                with self.assertRaisesRegex(tap_formulae.FormulaError, "invalid file"):
                    tap_formulae.write_rendered(root, self.outputs, self.manifest)
                self.assertEqual((root / "idb-companion.rb").read_bytes(), b"keep")
                self.assertFalse((root / "idb-cli.rb").exists())

    def test_unchanged_outputs_and_manifest_are_not_rewritten(self) -> None:
        tap_formulae.write_rendered(self.root, self.outputs, self.manifest)
        with patch.object(Path, "write_text", side_effect=AssertionError("rewrite")):
            tap_formulae.write_rendered(self.root, self.outputs, self.manifest)
        self.assertEqual(
            tap_formulae.read_rendered(self.root, self.manifest), self.outputs
        )

    def test_binary_only_manifest_rerenders_exactly(self) -> None:
        self.assertEqual(
            tap_formulae.render_from_manifest(self.manifest, templates_dir=TEMPLATES),
            self.outputs,
        )
