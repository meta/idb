# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Exercise the prelink check against compiled weak and strong Swift imports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .check_coredevice_imports import check_imports, ImportCheckError


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--stub", required=True, type=Path)
    parser.add_argument("--archive", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--nm", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if len(args.archive) != 2:
        raise ImportCheckError("expected exactly the weak and strong fixture archives")
    weak, strong = args.archive
    result = check_imports(args.nm, args.architecture, args.stub, [weak])
    try:
        check_imports(args.nm, args.architecture, args.stub, [strong])
    except ImportCheckError as error:
        if "strong undefined references" not in str(
            error
        ) or "_$s10CoreDevice22DigitizerHIDCapabilityVMa" not in str(error):
            raise
        result["negative_fixture_rejection"] = str(error)
    else:
        raise ImportCheckError(
            "plain import fixture incorrectly passed prelink validation"
        )
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
