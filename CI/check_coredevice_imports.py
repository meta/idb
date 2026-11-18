# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Reject strong undefined optional-framework references before linking."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path


class ImportCheckError(Exception):
    pass


def symbols(command: Sequence[str], path: Path, options: Sequence[str]) -> set[str]:
    if not path.is_file():
        raise ImportCheckError(f"missing symbol-check input: {path}")
    try:
        result = subprocess.run(
            [*command, *options, str(path)],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = (
            error.stderr
            if isinstance(error, subprocess.CalledProcessError)
            else str(error)
        )
        raise ImportCheckError(f"nm failed for {path}: {detail}") from error
    names = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    if "--undefined-only" in options:
        # LLVM nm emits archive-member headings even in just-symbols mode.
        names = {name for name in names if not name.endswith((".o:", ".obj:"))}
    invalid = sorted(
        name for name in names if not re.fullmatch(r"_[A-Za-z0-9_$.]+", name)
    )
    if invalid:
        raise ImportCheckError(f"invalid nm symbol output for {path}: {invalid}")
    return names


def check_imports(
    nm: Sequence[str], architecture: str, stub: Path, archives: Sequence[Path]
) -> dict[str, object]:
    if not nm or not archives:
        raise ImportCheckError(
            "an nm command and at least one prelink input are required"
        )
    command = [*nm, "--arch=" + architecture]
    exports = symbols(command, stub, ["--export-symbols", "--add-inlinedinfo"])
    if not exports:
        raise ImportCheckError(
            f"nm returned no exports for optional framework stub {stub}"
        )
    checked = {}
    for archive in archives:
        strong = symbols(
            command, archive, ["--undefined-only", "--no-weak", "--format=just-symbols"]
        )
        invalid = sorted(exports & strong)
        if invalid:
            raise ImportCheckError(
                f"{archive} has strong undefined references to optional framework {stub}: "
                f"{', '.join(invalid)}; compile its imports as weak"
            )
        checked[str(archive)] = len(strong)
    return {
        "architecture": architecture,
        "stub": str(stub),
        "exports": len(exports),
        "inputs": checked,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--stub", required=True, type=Path)
    parser.add_argument("--archive", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--nm", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    try:
        result = check_imports(args.nm, args.architecture, args.stub, args.archive)
    except ImportCheckError as error:
        print(error, file=sys.stderr)
        return 1
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
