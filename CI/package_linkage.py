# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""The reserved source member shared by local and release SwiftPM packages.

An ordinary source member participates in SwiftPM's imparted build settings;
binary-only products do not take that path. No linker settings or runtime code
are supplied here, and installed toolchains still require separate validation.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from pathlib import Path

TARGET = "IDBPackageLinkage"
SOURCE_FILES = (
    "Sources/IDBPackageLinkage/empty.c",
    "Sources/IDBPackageLinkage/include/IDBPackageLinkage.h",
)


def source_files(products: Mapping[str, Sequence[str]]) -> dict[str, str]:
    if any(TARGET in targets for targets in products.values()):
        return dict.fromkeys(SOURCE_FILES, "")
    return {}


def target_declaration(products: Mapping[str, Sequence[str]]) -> str | None:
    if not source_files(products):
        return None
    return (
        '    .target(name: "IDBPackageLinkage", path: "Sources/IDBPackageLinkage", '
        'sources: ["empty.c"], publicHeadersPath: "include"),'
    )


def materialize(output: Path, products: Mapping[str, Sequence[str]]) -> None:
    for name, text in source_files(products).items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
