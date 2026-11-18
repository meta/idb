# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Zip each XCFramework of a libraries package, as SwiftPM binary targets take them.

    python3 -m CI.xcframework_zips <package-directory> <output-directory>

A SwiftPM binary target fetched by URL is a zip holding one XCFramework, named by
its checksum. For each `<Name>.xcframework` in the package this writes
`<Name>.xcframework.zip`, and `checksums.json` maps each zip to the checksum a
`Package.swift` names it by:

    {"FBControlCore": {"file": "FBControlCore.xcframework.zip", "checksum": "..."}}

`products.json` gives each library's SwiftPM product members, including the
reserved source linkage member when needed, as the package's own `Package.swift`
has them. Only binary members have XCFramework zips and checksums:

    {"FBControlCore": ["FBControlCore", "FBControlCoreObjC"]}

Zipped with `ditto`, which keeps the symlinks a macOS framework's versioned layout
is made of, as the stub frameworks' is. The checksum is the zip's SHA-256, which
is what `swift package compute-checksum` reports.

Stdlib only: CI runs it with the runner's own python3.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path

from . import library_package

Runner = Callable[[Sequence[str]], None]


class ZipError(Exception):
    pass


def _run(command: Sequence[str]) -> None:
    subprocess.run(command, check=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def zip_xcframeworks(
    package: Path, output: Path, run: Runner = _run
) -> dict[str, dict[str, str]]:
    xcframeworks = sorted(package.glob("*.xcframework"))
    if not xcframeworks:
        raise ZipError(
            f"{package} holds no XCFrameworks; run './build.sh build library-package' first"
        )
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    checksums: dict[str, dict[str, str]] = {}
    for xcframework in xcframeworks:
        archive = output / f"{xcframework.name}.zip"
        # Without --norsrc and --noextattr, ditto stores extended attributes as `._*`
        # AppleDouble files, which unpack beside the headers and read as headers.
        run(
            [
                "ditto",
                "-c",
                "-k",
                "--norsrc",
                "--noextattr",
                "--noacl",
                "--keepParent",
                str(xcframework),
                str(archive),
            ]
        )
        checksums[xcframework.stem] = {
            "file": archive.name,
            "checksum": _sha256(archive),
        }
    (output / "checksums.json").write_text(
        json.dumps(checksums, indent=2, sort_keys=True) + "\n"
    )
    libraries = json.loads((package / "manifest.json").read_text())["libraries"]
    (output / "products.json").write_text(
        json.dumps(library_package.product_targets(libraries), indent=2, sort_keys=True)
        + "\n"
    )
    return checksums


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    try:
        checksums = zip_xcframeworks(args.package, args.output)
    except ZipError as error:
        print(f"error: {error}")
        return 1
    print(f"Zipped {len(checksums)} XCFrameworks into {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
