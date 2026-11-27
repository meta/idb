# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Check that the documentation's links into this repository still resolve."""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
from pathlib import Path

logger: logging.Logger = logging.getLogger(__name__)

# Only `blob` and `tree` name a path in the repository; every other
# github.com/facebook/idb URL is the project itself, a release or an issue, and
# has nothing here to resolve.
REPOSITORY_LINK: re.Pattern[str] = re.compile(
    r"https://github\.com/facebook/idb/(?:blob|tree)/[^/\s]+/([^\s)\"'`>]+)"
)

DOCUMENT_SUFFIXES = frozenset({".md", ".mdx"})
# The website's dependencies and its build output, neither of which is written
# here and both of which are large.
SKIPPED_DIRECTORIES = frozenset({"node_modules", "build", ".docusaurus"})

# The published repository is assembled from three directories of the monorepo.
# In the monorepo this one holds only the paths under neither prefix.
EXPORTED_ELSEWHERE: tuple[tuple[str, str], ...] = (
    ("idb/", "fbcode/idb"),
    ("proto/", "xplat/idb"),
)


def export_roots(published_root: Path) -> tuple[tuple[str, Path], ...]:
    """Where each prefix of a published path is checked out, longest prefix first.

    In a checkout of the published repository every path is under its root. In
    the monorepo the other two exported directories are found by the ancestor
    that holds both, which no checkout of the published repository has.
    """
    for ancestor in published_root.parents:
        elsewhere = tuple(
            (prefix, ancestor / location) for prefix, location in EXPORTED_ELSEWHERE
        )
        if all(path.is_dir() for _, path in elsewhere):
            return elsewhere + (("", published_root),)
    return (("", published_root),)


def documents(published_root: Path) -> list[Path]:
    found = []
    for directory, subdirectories, names in os.walk(published_root):
        subdirectories[:] = [
            name for name in subdirectories if name not in SKIPPED_DIRECTORIES
        ]
        found.extend(
            Path(directory, name)
            for name in names
            if Path(name).suffix in DOCUMENT_SUFFIXES
        )
    return sorted(found)


def broken_links(published_root: Path) -> list[str]:
    """Every link naming a path the repository no longer has."""
    roots = export_roots(published_root)
    broken = []
    for document in documents(published_root):
        for match in REPOSITORY_LINK.finditer(document.read_text(errors="replace")):
            # A fragment names a heading or a line range rather than a file, and
            # trailing punctuation belongs to the sentence rather than the path.
            path = match.group(1).split("#", 1)[0].rstrip(".,;:")
            prefix, root = next(entry for entry in roots if path.startswith(entry[0]))
            if not (root / path[len(prefix) :]).exists():
                broken.append(
                    f"{document.relative_to(published_root)}: "
                    f"{match.group(0)} names {path}, which does not exist"
                )
    return broken


def lint_message(path: str, broken: list[str]) -> dict[str, object]:
    """The problems as the one object a linter reads, attached to `path`."""
    return {
        "path": path,
        "line": None,
        "char": None,
        "severity": "error",
        "name": "broken-documentation-link",
        "original": None,
        "replacement": None,
        "description": (
            "The documentation links to paths this repository does not have. "
            "Update the link, or keep the path it names:\n"
            + "\n".join(f"  {problem}" for problem in broken)
        ),
        # The tree is checked whole, so the report rarely lands on a changed line.
        "bypassChangedLineFiltering": True,
    }


def main() -> int:
    # `@file` reads its lines as arguments, which is how a linter is handed the
    # paths a change touched.
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="the published tree to check; defaults to the one holding this file",
    )
    parser.add_argument(
        "--lint",
        nargs="+",
        metavar="PATH",
        help="report to a linter on stdout rather than to a reader on stderr. A "
        "link dies as easily by the path it names going away as by being "
        "written wrong, so the report is attached to the first of these "
        "changed paths rather than to the document holding the link.",
    )
    args = parser.parse_args()
    broken = broken_links(args.root.resolve())
    if args.lint is not None:
        if broken:
            print(json.dumps(lint_message(args.lint[0], broken)), flush=True)
        return 0
    for problem in broken:
        logger.error("%s", problem)
    return 1 if broken else 0


if __name__ == "__main__":
    raise SystemExit(main())
