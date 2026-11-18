# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""The XCFramework zips and their checksums, from a fake libraries package."""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

from . import xcframework_zips


class FakeDitto:
    """Writes a stand-in zip whose bytes name the XCFramework it holds."""

    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(self, command: Sequence[str]) -> None:
        self.commands.append(list(command))
        source, archive = Path(command[-2]), Path(command[-1])
        archive.write_bytes(f"zip of {source.name}".encode())


class XCFrameworkZipsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.package = self.root / "Package"
        for name in ("FBControlCore", "CoreSimulatorStub"):
            (self.package / f"{name}.xcframework" / "macos-arm64").mkdir(parents=True)
        (self.package / "Resources").mkdir()
        (self.package / "manifest.json").write_text(
            json.dumps(
                {
                    "libraries": {
                        "FBControlCore": {
                            "archives": ["libFBControlCore.a"],
                            "frameworks": [],
                            "linker_flags": [],
                            "resources": [],
                            "search_paths": [],
                        }
                    }
                }
            )
        )
        self.output = self.root / "Zips"
        self.ditto = FakeDitto()

    def test_each_xcframework_is_zipped_keeping_its_parent_and_symlinks(self) -> None:
        xcframework_zips.zip_xcframeworks(self.package, self.output, self.ditto)
        self.assertEqual(
            self.ditto.commands,
            [
                [
                    "ditto",
                    "-c",
                    "-k",
                    "--norsrc",
                    "--noextattr",
                    "--noacl",
                    "--keepParent",
                    str(self.package / f"{name}.xcframework"),
                    str(self.output / f"{name}.xcframework.zip"),
                ]
                for name in ("CoreSimulatorStub", "FBControlCore")
            ],
        )

    def test_the_checksums_are_each_zips_sha256(self) -> None:
        xcframework_zips.zip_xcframeworks(self.package, self.output, self.ditto)
        checksums = json.loads((self.output / "checksums.json").read_text())
        self.assertEqual(
            checksums["FBControlCore"],
            {
                "file": "FBControlCore.xcframework.zip",
                "checksum": hashlib.sha256(
                    b"zip of FBControlCore.xcframework"
                ).hexdigest(),
            },
        )
        self.assertEqual(sorted(checksums), ["CoreSimulatorStub", "FBControlCore"])

    def test_the_products_are_the_packages_own(self) -> None:
        xcframework_zips.zip_xcframeworks(self.package, self.output, self.ditto)
        self.assertEqual(
            json.loads((self.output / "products.json").read_text()),
            {"FBControlCore": ["FBControlCore"]},
        )

    def test_source_target_is_product_metadata_not_a_checksum(self) -> None:
        manifest = json.loads((self.package / "manifest.json").read_text())
        manifest["libraries"]["FBControlCore"]["linker_flags"] = [
            "PrivateHeaders/CoreSimulator/CoreSimulator.tbd"
        ]
        (self.package / "manifest.json").write_text(json.dumps(manifest))
        checksums = xcframework_zips.zip_xcframeworks(
            self.package, self.output, self.ditto
        )
        products = json.loads((self.output / "products.json").read_text())
        self.assertEqual(
            products["FBControlCore"],
            ["CoreSimulatorStub", "FBControlCore", "IDBPackageLinkage"],
        )
        self.assertNotIn("IDBPackageLinkage", checksums)
        self.assertEqual(set(checksums), {"CoreSimulatorStub", "FBControlCore"})

    def test_a_package_without_xcframeworks_names_the_build_that_makes_them(
        self,
    ) -> None:
        with self.assertRaisesRegex(xcframework_zips.ZipError, "library-package"):
            xcframework_zips.zip_xcframeworks(
                self.root / "Empty", self.output, self.ditto
            )

    def test_previous_zips_are_replaced(self) -> None:
        (self.output / "Stale.xcframework.zip").parent.mkdir(parents=True)
        (self.output / "Stale.xcframework.zip").write_bytes(b"stale")
        xcframework_zips.zip_xcframeworks(self.package, self.output, self.ditto)
        self.assertFalse((self.output / "Stale.xcframework.zip").exists())


if __name__ == "__main__":
    unittest.main()
