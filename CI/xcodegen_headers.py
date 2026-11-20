# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Keep XcodeGen's Swift compatibility-header copies inside their declared output."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


_PHASE_NAME = "Copy Swift Objective-C Interface Header"
_ARGUMENTS = '"${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"'


def _copy_header(match: re.Match[str]) -> str:
    phase = match.group(0)
    if not re.search(r"(?m)^[ \t]+isa = PBXShellScriptBuildPhase;$", phase):
        raise ValueError("Unexpected Swift compatibility-header phase type")
    scripts = list(
        re.finditer(r'(?m)^[ \t]+shellScript = ("(?:\\.|[^"\\])*");$', phase)
    )
    if len(scripts) != 1:
        raise ValueError("Expected one Swift compatibility-header copy script")
    value = scripts[0]
    script = json.loads(value.group(1))
    command = script.removesuffix("\n")
    if command in (f"/bin/cp {_ARGUMENTS}", f"cp {_ARGUMENTS}"):
        return phase
    if command != f"ditto {_ARGUMENTS}":
        raise ValueError(
            f"Unexpected Swift compatibility-header copy script: {script!r}"
        )
    # ditto creates temporary siblings outside the declared header output.
    replacement = json.dumps("/bin/cp" + script[len("ditto") :])
    return phase[: value.start(1)] + replacement + phase[value.end(1) :]


def rewrite_project(path: Path) -> None:
    text = path.read_text()
    pattern = (
        rf"(?ms)^(?P<indent>[ \t]*)[0-9A-Fa-f]{{24}} /\* {re.escape(_PHASE_NAME)} \*/ = \{{\n"
        r".*?^(?P=indent)\};"
    )
    updated, count = re.subn(pattern, _copy_header, text)
    expected = len(re.findall(rf'(?m)^[ \t]+name = "{re.escape(_PHASE_NAME)}";$', text))
    if count != expected:
        raise ValueError("Unrecognized Swift compatibility-header phase layout")
    if updated != text:
        path.write_text(updated)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    arguments = parser.parse_args()
    rewrite_project(arguments.project)


if __name__ == "__main__":
    main()
