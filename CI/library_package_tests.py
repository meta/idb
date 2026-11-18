# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""The libraries package, assembled from a fake Release build."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from collections.abc import Sequence
from copy import deepcopy
from pathlib import Path
from unittest import mock

from . import library_package

MANIFEST = {
    "libraries": {
        "Swifty": {
            "archives": ["libSwifty.a", "libCish.a"],
            "frameworks": ["Foundation.framework"],
            "linker_flags": [],
            "resources": ["libShim-iOS.dylib", "Guest.app", "Guest-watchOS"],
            "search_paths": ["PrivateHeaders"],
        },
        "Cish": {
            "archives": ["libCish.a"],
            "frameworks": [],
            "linker_flags": [],
            "resources": [],
            "search_paths": [],
        },
    }
}


class FakeXcodebuild:
    """Writes what the tools would: an object or library, or an XCFramework with one slice."""

    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(self, command: Sequence[str]) -> None:
        if command[0] == "xcrun":
            Path(command[command.index("-o") + 1]).write_bytes(b"built")
            return
        self.commands.append(list(command))
        output = Path(command[command.index("-output") + 1])
        slice_directory = output / "macos-arm64"
        slice_directory.mkdir(parents=True)
        if "-framework" in command:
            framework = Path(command[command.index("-framework") + 1])
            shutil.copytree(framework, slice_directory / framework.name, symlinks=True)
            return
        archive = Path(command[command.index("-library") + 1])
        (slice_directory / archive.name).write_bytes(archive.read_bytes())
        if "-headers" in command:
            shutil.copytree(
                Path(command[command.index("-headers") + 1]),
                slice_directory / "Headers",
            )


class LibraryPackageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        source = self.root / "Source"
        (source / "Cish" / "include").mkdir(parents=True)
        (source / "Cish" / "include" / "module.modulemap").write_text("module Cish {}")
        (source / "PrivateHeaders" / "Private").mkdir(parents=True)
        (source / "PrivateHeaders" / "Private" / "module.modulemap").write_text(
            "module Private {}"
        )
        manifest = source / "LibraryPackage.json"
        manifest.write_text(json.dumps(MANIFEST))
        self.build = self.root / "Build"
        release = self.build / "Products" / "Release"
        simulator = self.build / "Products" / "Release-iphonesimulator"
        release.mkdir(parents=True)
        simulator.mkdir(parents=True)
        (release / "libSwifty.a").write_bytes(b"swifty")
        (release / "libCish.a").write_bytes(b"cish")
        (release / "Swifty.swiftmodule").mkdir()
        (
            release / "Swifty.swiftmodule" / "arm64-apple-macos.swiftinterface"
        ).write_text("// interface")
        (simulator / "libShim-iOS.dylib").write_bytes(b"shim")
        (simulator / "Guest.app").mkdir()
        (simulator / "Guest.app" / "Guest").write_bytes(b"guest")
        watch = self.build / "Products" / "Release-watchsimulator"
        watch.mkdir()
        (watch / "Guest-watchOS").write_bytes(b"watch guest")
        self.output = self.root / "Package"
        self.xcodebuild = FakeXcodebuild()
        patches = (
            mock.patch.object(library_package, "SOURCE_ROOT", source),
            mock.patch.object(library_package, "MANIFEST", manifest),
            mock.patch.object(
                library_package.subprocess,
                "run",
                side_effect=AssertionError("unexpected external tool"),
            ),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def _assemble(self) -> None:
        library_package.assemble(self.build, self.output, self.xcodebuild)

    def test_each_library_gets_an_xcframework_with_its_module_or_headers(self) -> None:
        self._assemble()
        swifty, cish = self.xcodebuild.commands[:2]
        self.assertNotIn("-headers", swifty)
        self.assertEqual(
            cish[cish.index("-headers") + 1],
            str(self.root / "Source" / "Cish" / "include"),
        )
        self.assertTrue(
            (
                self.output
                / "Swifty.xcframework/macos-arm64/Swifty.swiftmodule/arm64-apple-macos.swiftinterface"
            ).is_file()
        )

    def test_the_package_carries_private_headers_resources_and_the_manifest(
        self,
    ) -> None:
        self._assemble()
        self.assertTrue(
            (self.output / "PrivateHeaders/Private/module.modulemap").is_file()
        )
        self.assertTrue((self.output / "Resources/libShim-iOS.dylib").is_file())
        self.assertTrue((self.output / "Resources/Guest.app/Guest").is_file())
        self.assertTrue((self.output / "Resources/Guest-watchOS").is_file())
        self.assertEqual(
            json.loads((self.output / "manifest.json").read_text()), MANIFEST
        )

    def test_the_private_modules_are_also_a_binary_target_for_swiftpm(self) -> None:
        self._assemble()
        self.assertTrue(
            (
                self.output
                / "IDBPrivateHeaders.xcframework/macos-arm64/Headers/Private/module.modulemap"
            ).is_file()
        )

    def test_swiftpm_gets_a_product_per_library_made_of_binary_targets(self) -> None:
        self._assemble()
        package = (self.output / "Package.swift").read_text()
        self.assertIn(
            '.library(name: "Swifty", targets: ["IDBPrivateHeaders", "Swifty", "Cish"]),',
            package,
        )
        self.assertIn('.library(name: "Cish", targets: ["Cish"]),', package)
        self.assertIn(
            '.binaryTarget(name: "Swifty", path: "Swifty.xcframework"),', package
        )
        self.assertNotIn(".target(", package)
        self.assertFalse((self.output / "Linkage").exists())

    def test_a_private_frameworks_stub_is_a_binary_target_not_a_flag(self) -> None:
        MANIFEST["libraries"]["Swifty"]["linker_flags"] = [
            "-weak_library",
            "PrivateHeaders/Private/Private.tbd",
        ]
        self.addCleanup(MANIFEST["libraries"]["Swifty"].__setitem__, "linker_flags", [])
        (self.root / "Source" / "LibraryPackage.json").write_text(json.dumps(MANIFEST))
        (
            self.root / "Source" / "PrivateHeaders" / "Private" / "Private.tbd"
        ).write_text("--- !tapi-tbd\n")
        self._assemble()
        package = (self.output / "Package.swift").read_text()
        self.assertNotIn("unsafeFlags", package)
        self.assertIn(
            '.binaryTarget(name: "PrivateStub", path: "PrivateStub.xcframework"),',
            package,
        )
        self.assertIn(
            '.library(name: "Swifty", targets: ["PrivateStub", "IDBPrivateHeaders", "Swifty", "Cish"]),',
            package,
        )
        framework = (
            self.output / "PrivateStub.xcframework/macos-arm64/PrivateStub.framework"
        )
        self.assertTrue((framework / "Versions/A/PrivateStub").is_file())
        self.assertEqual((framework / "Versions/Current").readlink(), Path("A"))
        self.assertIn(
            "<string>PrivateStub</string>",
            (framework / "Versions/A/Resources/Info.plist").read_text(),
        )
        link = next(
            command for command in self.xcodebuild.commands if "-framework" in command
        )
        self.assertEqual(
            Path(link[link.index("-framework") + 1]).name, "PrivateStub.framework"
        )

    def test_a_stub_re_exports_the_private_framework_from_its_tbd(self) -> None:
        MANIFEST["libraries"]["Swifty"]["linker_flags"] = [
            "-weak_library",
            "PrivateHeaders/Private/Private.tbd",
        ]
        self.addCleanup(MANIFEST["libraries"]["Swifty"].__setitem__, "linker_flags", [])
        (self.root / "Source" / "LibraryPackage.json").write_text(json.dumps(MANIFEST))
        commands: list[list[str]] = []

        def record(command: Sequence[str]) -> None:
            commands.append(list(command))
            self.xcodebuild(command)

        library_package.assemble(self.build, self.output, record)
        dylib = next(command for command in commands if "-dynamiclib" in command)
        self.assertIn("@rpath/PrivateStub.framework/Versions/A/PrivateStub", dylib)
        self.assertIn(
            f"-Wl,-reexport_library,{self.root / 'Source/PrivateHeaders/Private/Private.tbd'}",
            dylib,
        )

    def _declare_optional_runtime(self) -> Path:
        manifest = deepcopy(MANIFEST)
        manifest["libraries"]["Swifty"].update(
            linker_flags=["-weak_library", "PrivateHeaders/Private/Private.tbd"],
            weak_stub_frameworks=["Private"],
        )
        (self.root / "Source" / "LibraryPackage.json").write_text(json.dumps(manifest))
        tbd = self.root / "Source" / "PrivateHeaders" / "Private" / "Private.tbd"
        tbd.write_text("SDK-parsed TBD fixture")
        return tbd

    def _nm_output(
        self, command: Sequence[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        self.assertEqual(kwargs, {"check": True, "capture_output": True, "text": True})
        if "--export-symbols" in command:
            self.assertEqual(
                list(command[:-1]),
                [
                    "xcrun",
                    "nm",
                    "--export-symbols",
                    "--add-inlinedinfo",
                    "--arch=arm64",
                ],
            )
            output = "_optional_getter\n_optional_metadata\n_utility_value\n"
        else:
            self.assertEqual(
                list(command[:-1]),
                [
                    "xcrun",
                    "nm",
                    "--undefined-only",
                    "--no-weak",
                    "--format=just-symbols",
                    "--arch=arm64",
                ],
            )
            output = "Module.o:\n_unrelated_strong_reference\n"
        return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

    def test_optional_runtime_uses_sdk_exports_and_preserves_the_product(self) -> None:
        tbd = self._declare_optional_runtime()
        commands: list[list[str]] = []

        def record(command: Sequence[str]) -> None:
            commands.append(list(command))
            self.xcodebuild(command)

        with mock.patch.object(
            library_package.subprocess, "run", side_effect=self._nm_output
        ) as nm:
            library_package.assemble(self.build, self.output, record)
        self.assertEqual(
            [Path(call.args[0][-1]).name for call in nm.call_args_list],
            ["Private.tbd", "libCish.a", "libSwifty.a"],
        )
        dylib = next(command for command in commands if "-dynamiclib" in command)
        flags = dylib[dylib.index("-Xlinker") : -3]
        symbol_list = Path(flags[-1])
        self.assertEqual(
            flags,
            [
                "-Xlinker",
                "-weak_library",
                "-Xlinker",
                str(tbd),
                "-Xlinker",
                "-reexported_symbols_list",
                "-Xlinker",
                str(symbol_list),
            ],
        )
        self.assertEqual(
            symbol_list.read_text(),
            "_optional_getter\n_optional_metadata\n_utility_value\n",
        )
        self.assertFalse(any("-reexport_library" in flag for flag in dylib))
        package = (self.output / "Package.swift").read_text()
        self.assertIn(
            '.library(name: "Swifty", targets: ["PrivateStub", "IDBPrivateHeaders", "Swifty", "Cish"]),',
            package,
        )
        self.assertIn('.library(name: "Cish", targets: ["Cish"]),', package)
        self.assertNotIn("unsafeFlags", package)

    def _declare_shared_optional_runtimes(self) -> None:
        self._declare_optional_runtime()
        manifest_path = self.root / "Source/LibraryPackage.json"
        manifest = json.loads(manifest_path.read_text())
        libraries = manifest["libraries"]
        for entry in libraries.values():
            entry["linker_flags"] = [
                "PrivateHeaders/Private/Private.tbd",
                "PrivateHeaders/Second/Second.tbd",
            ]
        libraries["Cish"]["weak_stub_frameworks"] = ["Second"]
        libraries["Swifty"]["archives"].append("libSwifty.a")
        manifest_path.write_text(json.dumps(manifest))
        second = self.root / "Source/PrivateHeaders/Second"
        second.mkdir()
        (second / "Second.tbd").write_text("SDK-parsed TBD fixture")

    def test_shared_archives_are_checked_once_across_optional_runtimes(self) -> None:
        self._declare_shared_optional_runtimes()
        with mock.patch.object(
            library_package.subprocess, "run", side_effect=self._nm_output
        ) as nm:
            self._assemble()
        self.assertEqual(
            [Path(call.args[0][-1]).name for call in nm.call_args_list],
            ["Private.tbd", "libCish.a", "libSwifty.a", "Second.tbd"],
        )

    def test_cached_archive_references_are_checked_against_each_runtime(self) -> None:
        self._declare_shared_optional_runtimes()

        def nm_output(
            command: Sequence[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            result = self._nm_output(command, **kwargs)
            if Path(command[-1]).name in ("Second.tbd", "libCish.a"):
                result.stdout = "_second_only\n"
            return result

        with mock.patch.object(
            library_package.subprocess, "run", side_effect=nm_output
        ) as nm:
            with self.assertRaisesRegex(
                library_package.PackageError, "libCish.a.*Second: _second_only"
            ):
                self._assemble()
        self.assertEqual(
            [Path(call.args[0][-1]).name for call in nm.call_args_list].count(
                "libCish.a"
            ),
            1,
        )
        self.assertFalse(self.output.exists())

    def test_archive_nm_failure_retains_its_path_and_diagnostic(self) -> None:
        self._declare_optional_runtime()

        def nm_output(
            command: Sequence[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            if Path(command[-1]).suffix == ".a":
                raise subprocess.CalledProcessError(
                    1, command, stderr="invalid archive fixture"
                )
            return self._nm_output(command, **kwargs)

        with mock.patch.object(
            library_package.subprocess, "run", side_effect=nm_output
        ):
            with self.assertRaisesRegex(
                library_package.PackageError, "libCish.a.*invalid archive fixture"
            ):
                self._assemble()
        self.assertFalse(self.output.exists())

    def test_strong_optional_references_in_any_archive_preserve_previous_output(
        self,
    ) -> None:
        self._declare_optional_runtime()
        self.output.mkdir()
        sentinel = self.output / "previous"
        sentinel.write_text("keep")
        for archive in ("libSwifty.a", "libCish.a"):
            with self.subTest(archive=archive):

                def nm_output(
                    command: Sequence[str],
                    archive_name: str = archive,
                    **kwargs: object,
                ) -> subprocess.CompletedProcess[str]:
                    result = self._nm_output(command, **kwargs)
                    if Path(command[-1]).name == archive_name:
                        result.stdout = "Module.o:\n_optional_metadata\n"
                    return result

                with mock.patch.object(
                    library_package.subprocess, "run", side_effect=nm_output
                ):
                    with self.assertRaisesRegex(
                        library_package.PackageError,
                        f"{archive}.*strong undefined references.*_optional_metadata",
                    ):
                        self._assemble()
                self.assertEqual(sentinel.read_text(), "keep")
                self.assertEqual(self.xcodebuild.commands, [])

    def test_optional_runtime_rejects_empty_sdk_exports(self) -> None:
        self._declare_optional_runtime()
        with mock.patch.object(
            library_package.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, stdout="", stderr=""),
        ):
            with self.assertRaisesRegex(
                library_package.PackageError, "no exports.*Private.tbd"
            ):
                self._assemble()
        self.assertFalse(self.output.exists())

    def test_optional_runtime_rejects_malformed_sdk_exports(self) -> None:
        self._declare_optional_runtime()
        self.output.mkdir()
        sentinel = self.output / "previous"
        sentinel.write_text("keep")
        for line in ("Private.tbd:", "00000000 T _optional_getter", "# comment"):
            with self.subTest(line=line):
                with mock.patch.object(
                    library_package.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(
                        [], 0, stdout=f"_optional_getter\n{line}\n", stderr=""
                    ),
                ):
                    with self.assertRaisesRegex(
                        library_package.PackageError, "invalid exports.*Private.tbd"
                    ):
                        self._assemble()
                self.assertEqual(sentinel.read_text(), "keep")
                self.assertEqual(self.xcodebuild.commands, [])

    def test_optional_runtime_reports_sdk_failure_before_packaging(self) -> None:
        self._declare_optional_runtime()
        with mock.patch.object(
            library_package.subprocess,
            "run",
            side_effect=subprocess.CalledProcessError(
                1, ["xcrun", "nm"], stderr="invalid SDK input"
            ),
        ):
            with self.assertRaisesRegex(
                library_package.PackageError, "Private.tbd.*invalid SDK input"
            ):
                self._assemble()
        self.assertFalse(self.output.exists())

    def test_optional_runtime_metadata_requires_a_linker_input(self) -> None:
        manifest = deepcopy(MANIFEST)
        manifest["libraries"]["Swifty"]["weak_stub_frameworks"] = ["Private"]
        (self.root / "Source" / "LibraryPackage.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(library_package.PackageError, "no linker input"):
            self._assemble()
        self.assertFalse(self.output.exists())

    def test_a_missing_product_names_the_build_that_makes_it(self) -> None:
        (self.build / "Products" / "Release" / "libCish.a").unlink()
        with self.assertRaisesRegex(library_package.PackageError, "build libraries"):
            self._assemble()

    def test_a_previous_package_is_replaced(self) -> None:
        (self.output / "Stale.xcframework").mkdir(parents=True)
        self._assemble()
        self.assertFalse((self.output / "Stale.xcframework").exists())


class PublishedManifestTests(unittest.TestCase):
    """What the checked-in manifest ships beside each library, for the libraries whose
    runtime resources a consumer cannot supply itself."""

    def setUp(self) -> None:
        manifest = Path(__file__).resolve().parents[1] / "LibraryPackage.json"
        self.libraries = json.loads(manifest.read_text())["libraries"]

    def test_code_injection_ships_what_each_target_injects_through(self) -> None:
        resources = set(self.libraries["FBSimulatorCodeInjection"]["resources"])
        # The shim injected into every host, the REPL included, and the guest bridge that
        # hosts `.simulator`.
        for item in (
            "SimulatorFrameworkBridge-iOS",
            "libShimulator-iOS.dylib",
        ):
            self.assertIn(item, resources)

    def test_code_injection_ships_nothing_only_idb_repl_uses(self) -> None:
        resources = self.libraries["FBSimulatorCodeInjection"]["resources"]
        # The idb command API is the companion's addition, not part of code injection.
        self.assertEqual(
            [item for item in resources if "ReplIDB" in item or "IDBAPI" in item], []
        )


if __name__ == "__main__":
    unittest.main()
