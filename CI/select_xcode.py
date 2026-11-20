# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Select an installed, non-beta Xcode 26 for protected build qualification."""

from __future__ import annotations

import logging
import os
import plistlib
import re
from pathlib import Path
from xml.parsers.expat import ExpatError

logger: logging.Logger = logging.getLogger(__name__)


def _candidate(app: Path) -> tuple[tuple[int, ...], Path] | None:
    if "beta" in app.name.lower():
        return None
    with (app / "Contents/version.plist").open("rb") as handle:
        metadata = plistlib.load(handle)
    version = (
        metadata.get("CFBundleShortVersionString")
        if isinstance(metadata, dict)
        else None
    )
    if not isinstance(version, str) or not re.fullmatch(
        r"[0-9]+(?:\.[0-9]+)*", version
    ):
        raise ValueError(
            "CFBundleShortVersionString must contain numeric version components"
        )
    parts = tuple(int(part) for part in version.split("."))
    if parts[0] != 26:
        return None
    developer = app / "Contents/Developer"
    if not developer.is_dir():
        raise ValueError("Contents/Developer is not an installed developer directory")
    return parts, developer


def select_xcode(applications: Path) -> Path:
    candidates = []
    for app in applications.glob("Xcode*.app"):
        try:
            candidate = _candidate(app)
        except (OSError, ValueError, ExpatError) as error:
            logger.warning("Skipping %s: %s", app, error)
            continue
        if candidate is not None:
            candidates.append(candidate)
    if not candidates:
        raise SystemExit(
            "Xcode 26 is not installed on this runner; qualification is incomplete"
        )
    return max(candidates)[1]


def write_environment(applications: Path, environment: Path) -> None:
    developer = select_xcode(applications)
    with environment.open("a") as handle:
        handle.write(f"DEVELOPER_DIR={developer}\n")


if __name__ == "__main__":
    write_environment(Path("/Applications"), Path(os.environ["GITHUB_ENV"]))
