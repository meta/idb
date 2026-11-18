# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Assemble the published libraries package from a Release build.

    python3 -m CI.library_package <build-directory> <output-directory>

The package holds everything a consumer of idb's libraries needs, as
`LibraryPackage.json` describes it:

    <output>/
      <Library>.xcframework   the static archive, with its Swift module (and
                              module interface) or, for a C library, its headers
      PrivateHeaders/         the vendored private frameworks' module maps, and
                              the TBD stubs the linker flags name
      Resources/              the guest bridges and shims the libraries run
      manifest.json           LibraryPackage.json: what each library links and needs
      Package.swift           the same, for SwiftPM: a product per library, usable
                              from a path or from a versioned URL
      <Framework>Stub.xcframework
                              a stand-in for each private framework the simulator
                              libraries link: a small library re-exporting the real
                              one, linked as a binary target rather than through
                              linker flags SwiftPM refuses from a versioned dependency
      IDBPrivateHeaders.xcframework
                              the private frameworks' modules again, as a binary
                              target's headers, where SwiftPM and Xcode both find them

Stdlib only: CI runs it with the runner's own python3.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = SOURCE_ROOT / "LibraryPackage.json"
# Where each SDK's Release products land under the build directory's Products/.
# `Release` comes first, so a library built for macOS and a simulator alike comes
# from macOS.
PRODUCT_DIRECTORIES = (
    "Release",
    "Release-iphonesimulator",
    "Release-appletvsimulator",
    "Release-watchsimulator",
)

Runner = Callable[[Sequence[str]], None]


class PackageError(Exception):
    pass


def _run(command: Sequence[str]) -> None:
    subprocess.run(command, check=True)


def _find_product(products: Path, name: str) -> Path:
    for directory in PRODUCT_DIRECTORIES:
        candidate = products / directory / name
        if candidate.exists():
            return candidate
    raise PackageError(f"{name} was not built; run './build.sh build libraries' first")


def _xcframework(name: str, products: Path, output: Path, run: Runner) -> Path:
    """One library's XCFramework: its archive, then its module or headers in the slice."""
    archive = _find_product(products, f"lib{name}.a")
    xcframework = output / f"{name}.xcframework"
    command = ["xcodebuild", "-create-xcframework", "-library", str(archive)]
    headers = SOURCE_ROOT / name / "include"
    if headers.is_dir():
        command += ["-headers", str(headers)]
    run(command + ["-output", str(xcframework)])
    module = archive.parent / f"{name}.swiftmodule"
    if module.is_dir():
        # A library slice's Swift module sits beside its archive, where SwiftPM and
        # Xcode look for it. Recent Xcodes copy it there themselves; older ones copy
        # only the archive and headers.
        slice_directory = _single_slice(xcframework)
        if not (slice_directory / module.name).exists():
            shutil.copytree(module, slice_directory / module.name)
    return xcframework


PRIVATE_HEADERS_TARGET = "IDBPrivateHeaders"


TARGET = "arm64-apple-macos15.0"

FRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>{name}</string>
  <key>CFBundleIdentifier</key>
  <string>com.facebook.idb.{name}</string>
  <key>CFBundleName</key>
  <string>{name}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
"""


def _single_slice(xcframework: Path) -> Path:
    slices = [path for path in xcframework.iterdir() if path.is_dir()]
    if len(slices) != 1:
        raise PackageError(f"{xcframework} has {len(slices)} slices, expected one")
    return slices[0]


def _empty_object(scratch: Path, run: Runner) -> Path:
    source = scratch / "empty.c"
    source.write_text("")
    obj = scratch / "empty.o"
    run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-c",
            "-target",
            TARGET,
            str(source),
            "-o",
            str(obj),
        ]
    )
    return obj


def _private_headers_xcframework(output: Path, scratch: Path, run: Runner) -> None:
    """An empty archive whose headers are the private frameworks' module directories.

    In its `Headers/`, which SwiftPM puts on its dependents' search paths and Xcode copies
    into the build's `include/`, so both find the modules a library's interface imports.
    """
    headers = scratch / "include"
    for module in sorted((SOURCE_ROOT / "PrivateHeaders").iterdir()):
        if module.is_dir():
            shutil.copytree(module, headers / module.name)
    archive = scratch / f"lib{PRIVATE_HEADERS_TARGET}.a"
    run(
        [
            "xcrun",
            "libtool",
            "-static",
            "-o",
            str(archive),
            str(_empty_object(scratch, run)),
        ]
    )
    run(
        [
            "xcodebuild",
            "-create-xcframework",
            "-library",
            str(archive),
            "-headers",
            str(headers),
            "-output",
            str(output / f"{PRIVATE_HEADERS_TARGET}.xcframework"),
        ]
    )


def _stub_frameworks(entry: dict[str, list[str]]) -> list[str]:
    """The private frameworks a library links through TBD stubs, from its linker flags."""
    return [Path(flag).stem for flag in entry["linker_flags"] if flag.endswith(".tbd")]


def _all_stub_frameworks(libraries: dict[str, dict[str, list[str]]]) -> list[str]:
    return sorted(
        {name for entry in libraries.values() for name in _stub_frameworks(entry)}
    )


def _nm_symbols(path: Path, options: Sequence[str]) -> set[str]:
    command = ["xcrun", "nm", *options, "--arch=" + TARGET.split("-", 1)[0], str(path)]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        raise PackageError(
            f"nm failed for {path} ({error.returncode}): {error.stderr}"
        ) from error
    except OSError as error:
        raise PackageError(f"could not run nm for {path}: {error}") from error
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def _weak_stub_exports(
    libraries: dict[str, dict[str, list[str]]], products: Path
) -> dict[str, set[str]]:
    """An optional runtime requires weak references in every consuming archive."""
    weak_stubs: set[str] = set()
    for name, entry in libraries.items():
        declared = set(entry.get("weak_stub_frameworks", []))
        missing = declared - set(_stub_frameworks(entry))
        if missing:
            raise PackageError(
                f"{name}: optional stubs have no linker input: {sorted(missing)}"
            )
        weak_stubs.update(declared)
    exports: dict[str, set[str]] = {}
    strong_references: dict[Path, set[str]] = {}
    for stub in sorted(weak_stubs):
        tbd = SOURCE_ROOT / "PrivateHeaders" / stub / f"{stub}.tbd"
        symbols = _nm_symbols(tbd, ["--export-symbols", "--add-inlinedinfo"])
        if not symbols:
            raise PackageError(f"nm returned no exports for optional runtime {tbd}")
        invalid = sorted(
            symbol
            for symbol in symbols
            if not re.fullmatch(r"_[A-Za-z0-9_$.]+", symbol)
        )
        if invalid:
            raise PackageError(f"nm returned invalid exports for {tbd}: {invalid}")
        exports[stub] = symbols
        archives = sorted(
            {
                _find_product(products, name)
                for entry in libraries.values()
                if stub in _stub_frameworks(entry)
                for name in entry["archives"]
            }
        )
        for archive in archives:
            if archive not in strong_references:
                strong_references[archive] = _nm_symbols(
                    archive,
                    ["--undefined-only", "--no-weak", "--format=just-symbols"],
                )
            strong = symbols & strong_references[archive]
            if strong:
                raise PackageError(
                    f"{archive} has strong undefined references to optional runtime "
                    f"{stub}: {', '.join(sorted(strong))}; compile its imports as weak"
                )
    return exports


def _stub_xcframework(
    name: str,
    output: Path,
    scratch: Path,
    run: Runner,
    weak_symbols: set[str] | None = None,
) -> None:
    """A private framework's stand-in, preserving optional-runtime linkage.

    SwiftPM links the binary target without unsafe flags. Optional runtimes export
    only the TBD's symbols over a weak dependency; legacy stubs re-export the dylib.
    """
    stub = f"{name}Stub"
    framework = scratch / f"{stub}.framework"
    version = framework / "Versions" / "A"
    (version / "Resources").mkdir(parents=True)
    tbd = SOURCE_ROOT / "PrivateHeaders" / name / f"{name}.tbd"
    link_flags = [f"-Wl,-reexport_library,{tbd}"]
    if weak_symbols is not None:
        symbol_list = scratch / "reexports.txt"
        symbol_list.write_text("\n".join(sorted(weak_symbols)) + "\n")
        link_flags = [
            "-Xlinker",
            "-weak_library",
            "-Xlinker",
            str(tbd),
            "-Xlinker",
            "-reexported_symbols_list",
            "-Xlinker",
            str(symbol_list),
        ]
    run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-dynamiclib",
            "-target",
            TARGET,
            "-install_name",
            f"@rpath/{stub}.framework/Versions/A/{stub}",
            *link_flags,
            str(_empty_object(scratch, run)),
            "-o",
            str(version / stub),
        ]
    )
    (version / "Resources" / "Info.plist").write_text(FRAMEWORK_PLIST.format(name=stub))
    (framework / "Versions" / "Current").symlink_to("A")
    (framework / stub).symlink_to(f"Versions/Current/{stub}")
    (framework / "Resources").symlink_to("Versions/Current/Resources")
    run(
        [
            "xcodebuild",
            "-create-xcframework",
            "-framework",
            str(framework),
            "-output",
            str(output / f"{stub}.xcframework"),
        ]
    )


def _swift_string(value: str) -> str:
    return json.dumps(value)


def product_targets(libraries: dict[str, dict[str, list[str]]]) -> dict[str, list[str]]:
    """Each library's SwiftPM product: the binary targets it is made of.

    Its stub frameworks, the private modules when its interface imports them, and its
    closure's archives. No source target is needed: the archives' objects autolink the
    SDK frameworks they import.
    """
    products: dict[str, list[str]] = {}
    for name, entry in libraries.items():
        targets = [f"{stub}Stub" for stub in _stub_frameworks(entry)]
        if entry["search_paths"]:
            targets.append(PRIVATE_HEADERS_TARGET)
        targets += [archive[len("lib") : -len(".a")] for archive in entry["archives"]]
        products[name] = targets
    return products


def binary_target_names(libraries: dict[str, dict[str, list[str]]]) -> list[str]:
    """Every binary target the package has: the stubs, the private modules, the libraries."""
    return (
        [f"{stub}Stub" for stub in _all_stub_frameworks(libraries)]
        + [PRIVATE_HEADERS_TARGET]
        + list(libraries)
    )


def _package_manifest(libraries: dict[str, dict[str, list[str]]]) -> str:
    """Package.swift: a product per library, each the binary targets it is made of."""
    products = [
        f'    .library(name: "{name}", targets: [{", ".join(_swift_string(t) for t in targets)}]),'
        for name, targets in product_targets(libraries).items()
    ]
    targets = [
        f'    .binaryTarget(name: "{name}", path: "{name}.xcframework"),'
        for name in binary_target_names(libraries)
    ]
    return "\n".join(
        [
            "// swift-tools-version:6.0",
            "// Generated by CI/library_package.py from LibraryPackage.json.",
            "import PackageDescription",
            "",
            "let package = Package(",
            '  name: "idb-libraries",',
            "  platforms: [.macOS(.v15)],",
            "  products: [",
            *products,
            "  ],",
            "  targets: [",
            *targets,
            "  ]",
            ")",
            "",
        ]
    )


def assemble(
    build_directory: Path, output: Path, run: Runner = _run
) -> dict[str, object]:
    manifest = json.loads(MANIFEST.read_text())
    libraries: dict[str, dict[str, list[str]]] = manifest["libraries"]
    products = build_directory / "Products"
    weak_exports = _weak_stub_exports(libraries, products)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for name in libraries:
        _xcframework(name, products, output, run)
    shutil.copytree(SOURCE_ROOT / "PrivateHeaders", output / "PrivateHeaders")
    resources = output / "Resources"
    resources.mkdir()
    for name in sorted(
        {item for entry in libraries.values() for item in entry["resources"]}
    ):
        product = _find_product(products, name)
        if product.is_dir():
            shutil.copytree(product, resources / name, symlinks=True)
        else:
            shutil.copy2(product, resources / name)
    shutil.copy2(MANIFEST, output / "manifest.json")
    scratch = build_directory / "LibraryPackageScratch"
    if scratch.exists():
        shutil.rmtree(scratch)
    (scratch / PRIVATE_HEADERS_TARGET).mkdir(parents=True)
    _private_headers_xcframework(output, scratch / PRIVATE_HEADERS_TARGET, run)
    for stub in _all_stub_frameworks(libraries):
        (scratch / stub).mkdir()
        _stub_xcframework(stub, output, scratch / stub, run, weak_exports.get(stub))
    (output / "Package.swift").write_text(_package_manifest(libraries))
    return manifest


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("build_directory", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = assemble(args.build_directory, args.output)
    except PackageError as error:
        print(f"error: {error}")
        return 1
    print(f"Packaged {len(manifest['libraries'])} libraries into {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
