# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Render the facebook/homebrew-fb tap formulae for a facebook/idb release.

The templates in .github/formulae/ are the source of truth for the three idb
formulae; `render` turns them plus a release's inputs (tag, companion tarball,
wheel, optional `brew bottle --json` output) into the finished formulae and a
manifest. It also renders the tap's Package.swift, which offers idb's libraries
to SwiftPM, each XCFramework fetched from the release by URL and checksum. The
Release workflow renders idb-cli.rb to bottle from, then renders everything for
publication as a run artifact and release assets; CI renders against locally
built assets to install-test them. Standard library only, so
it runs anywhere a python3 exists.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import io
import json
import re
import string
import sys
import tarfile
from pathlib import Path

# The release workflow also invokes this file directly, outside Python's module path.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from CI import package_linkage  # noqa: E402

IDB_REPO = "facebook/idb"

COMPANION_ASSET = "idb-companion.macos-arm64.tar.gz"
FORMULAE = ("idb-companion.rb", "idb-cli.rb", "idb.rb")
PACKAGE = "Package.swift"
# Everything a full render writes into the tap.
RENDERED = (*FORMULAE, PACKAGE)
ALLOWED_OUTPUTS = (*RENDERED, *package_linkage.SOURCE_FILES)
XCFRAMEWORK_ZIP_SUFFIX = ".xcframework.zip"

TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:\.(?:a|b|rc)\d+)?$")
PRERELEASE_RE = re.compile(r"\.(?:a|b|rc)\d+$")


class FormulaError(Exception):
    pass


def version_from_tag(tag):
    if not TAG_RE.match(tag):
        raise FormulaError(f"tag {tag!r} does not look like vX.Y.Z or vX.Y.Z.<a|b|rc>N")
    return tag[1:]


def is_prerelease(version):
    return PRERELEASE_RE.search(version) is not None


def pep440(version):
    # PyPI normalizes 1.5.0.b4 to 1.5.0b4; the wheel filename uses that form
    # while the formulae keep the release's own dotted form.
    return re.sub(r"\.((?:a|b|rc)\d+)$", r"\1", version)


def wheel_asset(version):
    return f"fb_idb-{pep440(version)}-py3-none-any.whl"


def companion_version(text):
    """The version idb-companion.rb currently declares. A prerelease carries an
    explicit stanza; a stable release carries the version only in its url."""
    match = re.search(r'(?m)^  version "([^"]+)"$', text)
    if match is not None:
        return match.group(1)
    match = re.search(
        r'(?m)^  url "https://github\.com/facebook/idb/releases/download/(v[^/"]+)/'
        r'idb-companion\.macos-arm64\.tar\.gz"$',
        text,
    )
    if match is None:
        raise FormulaError(
            "idb-companion.rb: neither a version stanza nor a companion tarball "
            "url — cannot tell what version this formula is on"
        )
    return version_from_tag(match.group(1))


def cellar_dsl(cellar):
    """`brew bottle --json` reports symbolic cellars without the leading
    colon (observed live: "any_skip_relocation"); the formula DSL needs them
    as symbols — a string cellar means a literal cellar path and makes the
    bottle silently unpourable everywhere."""
    text = str(cellar)
    if text.lstrip(":") in ("any", "any_skip_relocation"):
        return f":{text.lstrip(':')}"
    return f'"{text}"'


def bottle_block_lines(bottle):
    """Render a formula `bottle do` block (2-space base indent) from one
    entry of `brew bottle --json` output. Values come from the JSON only."""
    lines = ["  bottle do", f'    root_url "{bottle["root_url"]}"']
    if bottle.get("rebuild"):
        lines.append(f"    rebuild {bottle['rebuild']}")
    for tag_name, tag_info in bottle["tags"].items():
        cellar = tag_info.get("cellar", bottle.get("cellar"))
        sha = tag_info["sha256"]
        if cellar is None:
            lines.append(f'    sha256 {tag_name}: "{sha}"')
        else:
            lines.append(
                f'    sha256 cellar: {cellar_dsl(cellar)}, {tag_name}: "{sha}"'
            )
    lines.append("  end")
    return "\n".join(lines)


def bottle_blocks_from_dir(directory):
    blocks = {}
    for path in sorted(Path(directory).glob("*.bottle.json")):
        for name, entry in json.loads(path.read_text()).items():
            blocks[name.split("/")[-1] + ".rb"] = bottle_block_lines(entry["bottle"])
    if not blocks:
        raise FormulaError("the bottle-json artifact contains no *.bottle.json files")
    return blocks


MANIFEST = "manifest.json"
# The manifest as committed into the tap next to the formulae it describes,
# so the tap records which release run rendered them and from what.
RELEASE_MANIFEST = "idb-release.json"


def sha256_of_text(text):
    return hashlib.sha256(text.encode()).hexdigest()


def sha256_of_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_text(manifest):
    return json.dumps(manifest, indent=2, sort_keys=True) + "\n"


def rendered_paths(manifest):
    outputs = manifest.get("outputs") or {}
    unknown = set(outputs) - set(ALLOWED_OUTPUTS)
    if unknown:
        raise FormulaError(f"unexpected rendered output paths: {sorted(unknown)}")
    swiftpm = manifest.get("swiftpm") or {}
    products = swiftpm.get("products") or {}
    if set(FORMULAE).issubset(outputs) and products and PACKAGE not in outputs:
        raise FormulaError(
            "the full render declares libraries but has no Package.swift"
        )
    if PACKAGE in outputs:
        _validate_package_metadata(products, swiftpm.get("checksums") or {})
    sources = package_linkage.source_files(products) if PACKAGE in outputs else {}
    if set(outputs) & set(package_linkage.SOURCE_FILES) != set(sources):
        raise FormulaError("rendered outputs do not match the source linkage metadata")
    return tuple(outputs)


def verify_rendered(outputs, manifest):
    expected = rendered_paths(manifest)
    if set(outputs) != set(expected):
        raise FormulaError("rendered files do not match the manifest output paths")
    for name in expected:
        if sha256_of_text(outputs[name]) != manifest["outputs"][name]:
            raise FormulaError(f"{name} does not match its own manifest")
        if name in package_linkage.SOURCE_FILES and outputs[name] != "":
            raise FormulaError(f"source linkage file must be empty: {name}")


def _file_destination(root, name):
    path = root / name
    current = path
    while current != root:
        if current.is_symlink():
            raise FormulaError(f"rendered output path is a symlink: {current}")
        if current.exists():
            valid = current.is_file() if current == path else current.is_dir()
            if not valid:
                raise FormulaError(
                    f"invalid file or directory at output path: {current}"
                )
        current = current.parent
    for parent in (root, *root.parents):
        if parent.exists() and not parent.is_dir():
            raise FormulaError(f"output parent is not a directory: {parent}")
    return path


def _output_path(root, name):
    if name not in ALLOWED_OUTPUTS:
        raise FormulaError(f"unexpected rendered output path: {name}")
    return _file_destination(root, name)


def read_rendered(directory, manifest):
    root = Path(directory)
    outputs = {}
    for name in rendered_paths(manifest):
        path = _output_path(root, name)
        if not path.is_file():
            raise FormulaError(f"missing rendered output: {name}")
        try:
            outputs[name] = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError as error:
            raise FormulaError(f"rendered output is not valid UTF-8: {name}") from error
    verify_rendered(outputs, manifest)
    return outputs


def write_outputs(directory, outputs, *, manifest=None, release=False):
    root = Path(directory)
    paths = {name: _output_path(root, name) for name in outputs}
    texts = dict(outputs)
    if manifest is not None:
        verify_rendered(outputs, manifest)
        name = RELEASE_MANIFEST if release else MANIFEST
        paths[name] = _file_destination(root, name)
        texts[name] = manifest_text(manifest)
    stale = [
        _output_path(root, name)
        for name in package_linkage.SOURCE_FILES
        if PACKAGE in outputs and name not in outputs
    ]
    root.mkdir(parents=True, exist_ok=True)
    for name, path in paths.items():
        if path.is_file() and path.read_bytes() == texts[name].encode():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(texts[name], encoding="utf-8")
    for path in stale:
        if path.is_file():
            path.unlink()


def write_rendered(out_dir, outputs, manifest):
    write_outputs(out_dir, outputs, manifest=manifest)


def archive_rendered(directory, destination):
    """The public release archive preserves the validated render's relative paths."""
    root = Path(directory)
    raw_manifest = _file_destination(root, MANIFEST).read_bytes()
    outputs = read_rendered(root, json.loads(raw_manifest))
    contents = {name: text.encode() for name, text in outputs.items()}
    contents[MANIFEST] = raw_manifest
    target = Path(destination)
    _file_destination(target.parent, target.name)
    with tarfile.open(target, "w:gz") as archive:
        for name, data in sorted(contents.items()):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(data))


def cmd_archive(args):
    archive_rendered(args.directory, args.out)
    return 0


TEMPLATE_SUFFIX = ".in"


def default_templates_dir():
    """Source/.github/formulae, next to this script's directory."""
    return Path(__file__).resolve().parent.parent / "formulae"


def release_asset_base(tag):
    return f"https://github.com/{IDB_REPO}/releases/download/{tag}"


def generated_header(name, tag):
    return (
        f"# Rendered for {tag} from facebook/idb's "
        f"Source/.github/formulae/{name}{TEMPLATE_SUFFIX};\n"
        "# edit the template, not this file."
    )


def render_formulae(
    tag,
    companion_sha,
    wheel_sha,
    bottle_blocks=None,
    asset_base=None,
    templates_dir=None,
    only=None,
):
    """The three formulae for a release, from the templates alone: nothing
    here depends on what the tap currently contains. `asset_base` overrides
    the release download URL prefix, which is how CI points the formulae at
    freshly built local copies of the assets (file://...) to install-test
    them before any release exists. `only` restricts the set, e.g. the bottle
    job renders just idb-cli.rb before the companion tarball exists, in
    which case `companion_sha` may be None."""
    version = version_from_tag(tag)
    names = tuple(only) if only else FORMULAE
    unknown = sorted(set(names) - set(FORMULAE))
    if unknown:
        raise FormulaError(f"{', '.join(unknown)}: not a tap formula this tool renders")
    if "idb-companion.rb" in names and not companion_sha:
        raise FormulaError("idb-companion.rb needs the companion tarball's sha256")
    base = (asset_base or release_asset_base(tag)).rstrip("/")
    blocks = dict(bottle_blocks or {})
    unknown = sorted(set(blocks) - set(names))
    if unknown:
        raise FormulaError(f"{', '.join(unknown)}: not a tap formula this tool renders")
    directory = Path(templates_dir or default_templates_dir())
    values = {
        "tag": tag,
        "version": version,
        "companion_url": f"{base}/{COMPANION_ASSET}",
        "companion_sha256": companion_sha or "",
        "wheel_url": f"{base}/{wheel_asset(version)}",
        "wheel_sha256": wheel_sha,
        # Homebrew scans the version from the url on a stable tag, and
        # `brew audit --strict` rejects a stanza that repeats it. A prerelease
        # needs the stanza: the scan drops or reshapes its suffix, and all
        # three formulae should carry the release's own dotted form.
        "version_stanza": (
            f'  version "{version}"\n' if is_prerelease(version) else ""
        ),
    }
    outputs = {}
    for name in names:
        path = directory / f"{name}{TEMPLATE_SUFFIX}"
        if not path.exists():
            raise FormulaError(f"missing formula template {path}")
        block = blocks.get(name)
        per_file = dict(
            values,
            bottle_block=f"\n{block}\n" if block else "",
            generated_header=generated_header(name, tag),
        )
        try:
            outputs[name] = string.Template(path.read_text()).substitute(per_file)
        except (KeyError, ValueError) as error:
            raise FormulaError(f"{path.name}: bad placeholder {error}") from error
    return outputs


def _validate_package_metadata(products, checksums):
    if any(
        not isinstance(targets, list)
        or any(not isinstance(target, str) for target in targets)
        for targets in products.values()
    ):
        raise FormulaError("SwiftPM products must list their target names")
    referenced = {target for targets in products.values() for target in targets}
    for name in [*products, *checksums, *referenced]:
        if not isinstance(name, str) or not re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_-]*", name
        ):
            raise FormulaError(f"invalid SwiftPM product or target name: {name!r}")
    if package_linkage.TARGET in checksums:
        raise FormulaError(
            f"{package_linkage.TARGET} is a source target, not a binary checksum"
        )
    for name, checksum in checksums.items():
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise FormulaError(f"invalid binary checksum for {name}")
    missing = sorted(referenced - set(checksums) - {package_linkage.TARGET})
    if missing:
        raise FormulaError(f"no checksum for binary target(s) {', '.join(missing)}")


def _package_targets(products, checksums, base):
    _validate_package_metadata(products, checksums)
    targets = [
        f'    .binaryTarget(name: "{name}", url: "{base}/{name}{XCFRAMEWORK_ZIP_SUFFIX}", '
        f'checksum: "{checksums[name]}"),'
        for name in sorted(checksums)
    ]
    linkage = package_linkage.target_declaration(products)
    if linkage:
        targets.append(linkage)
    return targets


def render_package(tag, asset_base=None, swiftpm=None):
    """The tap's binary library products and optional source linkage member.

    Binary targets keep their release URLs/checksums. The reserved source member
    uses the same fixed recipe as the local package; older metadata needs none.
    """
    base = (asset_base or release_asset_base(tag)).rstrip("/")
    products = dict((swiftpm or {}).get("products") or {})
    checksums = dict((swiftpm or {}).get("checksums") or {})
    target_lines = _package_targets(products, checksums, base)
    lines = [
        "// swift-tools-version:6.0",
        # The tap's license, as its formulae carry it.
        "/*",
        " * Copyright (c) Meta Platforms, Inc. and affiliates.",
        " * All rights reserved.",
        " *",
        " * This source code is licensed under the BSD-style license found in the",
        " * LICENSE file in the root directory of this source tree.",
        " */",
        "",
        f"// Rendered for {tag} by facebook/idb's .github/scripts/tap_formulae.py;",
        "// each binary target is that release's asset. Edit nothing here.",
        "import PackageDescription",
        "",
        "let package = Package(",
        '  name: "idb",',
        # No trailing comma before the closing parenthesis: not every Swift accepts one.
        "  platforms: [.macOS(.v15)]" + ("," if products else ""),
    ]
    if products:
        lines.append("  products: [")
        for name in sorted(products):
            quoted = ", ".join(json.dumps(target) for target in products[name])
            lines.append(f'    .library(name: "{name}", targets: [{quoted}]),')
        lines += ["  ],", "  targets: ["]
        lines.extend(target_lines)
        lines.append("  ]")
    lines += [")", ""]
    return "\n".join(lines)


def render_package_files(tag, asset_base=None, swiftpm=None):
    products = (swiftpm or {}).get("products") or {}
    return {
        PACKAGE: render_package(tag, asset_base, swiftpm),
        **package_linkage.source_files(products),
    }


def swiftpm_inputs(products_path, checksums_path):
    """`render_package`'s input from the release's products.json and checksums.json."""
    checksums = json.loads(Path(checksums_path).read_text())
    return {
        "products": json.loads(Path(products_path).read_text()),
        "checksums": {name: entry["checksum"] for name, entry in checksums.items()},
    }


def render_manifest(
    tag,
    outputs,
    companion_sha,
    wheel_sha,
    asset_base,
    run_url=None,
    bottle_blocks=None,
    swiftpm=None,
):
    """What the rendered files were computed from, and their digests so
    whoever applies them can check they arrived intact. Enough to re-render
    the same files without the assets: tag, asset base, both asset digests
    and the bottle blocks; `run_url` names the workflow run that did it."""
    manifest = {
        "tag": tag,
        "asset_base": asset_base,
        "companion_sha256": companion_sha,
        "wheel_sha256": wheel_sha,
        "bottle_blocks": dict(bottle_blocks or {}),
        "outputs": {name: sha256_of_text(text) for name, text in outputs.items()},
    }
    if swiftpm:
        manifest["swiftpm"] = swiftpm
    if run_url:
        manifest["run_url"] = run_url
    return manifest


def render_from_manifest(manifest, templates_dir=None, only=None):
    """Re-render exactly what a manifest describes, from the templates alone.
    This is what lets a checked-in manifest prove that the tap's formulae are
    the render of a recorded release, with no network involved. The set of
    formulae defaults to the ones the manifest recorded, so a manifest from a
    partial render (the bottle job's, which has no companion digest) re-renders
    the same partial set."""
    rendered_paths(manifest)
    if only is None:
        recorded = manifest.get("outputs") or {}
        only = tuple(name for name in FORMULAE if name in recorded) or None
    outputs = render_formulae(
        manifest["tag"],
        manifest.get("companion_sha256"),
        manifest["wheel_sha256"],
        manifest.get("bottle_blocks") or None,
        asset_base=manifest.get("asset_base"),
        templates_dir=templates_dir,
        only=only,
    )
    if PACKAGE in (manifest.get("outputs") or {}):
        outputs.update(
            render_package_files(
                manifest["tag"], manifest.get("asset_base"), manifest.get("swiftpm")
            )
        )
    return outputs


def _recorded_release(directory):
    path = _file_destination(Path(directory), RELEASE_MANIFEST)
    try:
        manifest = json.loads(path.read_bytes())
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise FormulaError(
            "partial apply requires existing complete release provenance"
        ) from error
    if not isinstance(manifest, dict):
        raise FormulaError("partial apply requires a release manifest object")
    for name in ("tag", "asset_base", "run_url"):
        if not isinstance(manifest.get(name), str) or not manifest[name]:
            raise FormulaError(f"partial apply requires recorded {name} provenance")
    if not re.fullmatch(
        r"https://github\.com/(facebook|meta)/idb/actions/runs/\d+", manifest["run_url"]
    ):
        raise FormulaError("partial apply requires a recorded GitHub release run")
    if manifest["asset_base"].endswith("/"):
        raise FormulaError("partial apply requires a canonical asset base")
    outputs = read_rendered(directory, manifest)
    if not set(RENDERED).issubset(outputs):
        raise FormulaError(
            "partial apply requires complete formula and package provenance"
        )
    if render_from_manifest(manifest) != outputs:
        raise FormulaError(
            "existing release provenance does not describe the current tap"
        )
    return outputs, manifest


def merge_partial_render(directory, outputs, manifest):
    """Compose a same-release partial only when one manifest explains every byte."""
    verify_rendered(outputs, manifest)
    if not outputs or not set(outputs) < set(FORMULAE):
        raise FormulaError("a partial apply must contain a proper subset of formulae")
    existing, original = _recorded_release(directory)
    for name in ("tag", "asset_base", "run_url"):
        if manifest.get(name) != original[name]:
            raise FormulaError(f"partial {name} provenance differs or is missing")
    if manifest.get("swiftpm") is not None and manifest["swiftpm"] != original.get(
        "swiftpm"
    ):
        raise FormulaError(
            "partial package provenance differs from the retained package"
        )
    merged = dict(original)
    for name in ("companion_sha256", "wheel_sha256"):
        if manifest.get(name) is not None:
            merged[name] = manifest[name]
    blocks = dict(original.get("bottle_blocks") or {})
    incoming_blocks = manifest.get("bottle_blocks") or {}
    if set(incoming_blocks) - set(outputs):
        raise FormulaError("partial bottle provenance includes unchanged formulae")
    for name in outputs:
        blocks.pop(name, None)
    blocks.update(incoming_blocks)
    merged["bottle_blocks"] = blocks
    merged["outputs"] = {**original["outputs"], **manifest["outputs"]}
    complete = {**existing, **outputs}
    if render_from_manifest(merged) != complete:
        raise FormulaError(
            "partial provenance cannot describe all retained output bytes"
        )
    return complete, merged


def cmd_render(args):
    only = tuple(args.only) if args.only else FORMULAE
    if "idb-companion.rb" in only and not args.companion:
        raise FormulaError(
            "--companion is required unless --only leaves out idb-companion.rb"
        )
    companion_sha = (
        sha256_of_file(_single_glob(args.companion, "companion tarball"))
        if args.companion
        else None
    )
    wheel_sha = sha256_of_file(_single_glob(args.wheel, "wheel"))
    blocks = bottle_blocks_from_dir(args.bottles) if args.bottles else None
    asset_base = (args.asset_base or release_asset_base(args.tag)).rstrip("/")
    if bool(args.swiftpm_products) != bool(args.xcframework_checksums):
        raise FormulaError("--swiftpm-products and --xcframework-checksums go together")
    swiftpm = (
        swiftpm_inputs(args.swiftpm_products, args.xcframework_checksums)
        if args.swiftpm_products
        else None
    )
    outputs = render_formulae(
        args.tag,
        companion_sha,
        wheel_sha,
        blocks,
        asset_base=asset_base,
        templates_dir=args.templates,
        only=only,
    )
    if set(only) == set(FORMULAE):
        outputs.update(render_package_files(args.tag, asset_base, swiftpm))
    manifest = render_manifest(
        args.tag,
        outputs,
        companion_sha,
        wheel_sha,
        asset_base,
        args.run_url,
        blocks,
        swiftpm,
    )
    write_rendered(args.out, outputs, manifest)
    for name in outputs:
        print(f"{name}: rendered")
    print(f"wrote {len(outputs)} files and {MANIFEST} to {args.out}")
    return 0


def _single_glob(pattern, what):
    matches = glob.glob(pattern)
    if len(matches) != 1:
        raise FormulaError(
            f"expected exactly one {what} matching {pattern!r}, found {matches}"
        )
    return matches[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    archive = subparsers.add_parser(
        "archive", help="package a validated render with its relative source paths"
    )
    archive.add_argument(
        "--directory", required=True, help="rendered files and manifest.json"
    )
    archive.add_argument("--out", required=True, help="tar.gz file to create")
    archive.set_defaults(func=cmd_archive)
    render = subparsers.add_parser(
        "render",
        help="render the tap formulae for a release from the templates, "
        "independent of the tap's current contents",
    )
    render.add_argument("--tag", required=True, help="release tag, e.g. v1.5.4")
    render.add_argument(
        "--companion",
        help="glob for the companion tarball asset (required unless --only "
        "leaves out idb-companion.rb)",
    )
    render.add_argument(
        "--wheel", required=True, help="glob for the fb-idb wheel asset"
    )
    render.add_argument(
        "--only",
        action="append",
        choices=FORMULAE,
        help="render only this formula (repeatable; default: all three)",
    )
    render.add_argument(
        "--bottles",
        help="directory of `brew bottle --json` output (omit for no bottle block)",
    )
    render.add_argument(
        "--asset-base",
        help="URL prefix for the asset urls (default: the tag's GitHub release "
        "download directory; CI passes a file:// directory of local builds)",
    )
    render.add_argument(
        "--templates",
        help="directory holding the *.rb.in templates (default: Source/.github/formulae)",
    )
    render.add_argument(
        "--run-url",
        help="URL of the workflow run doing the rendering, recorded in the manifest",
    )
    render.add_argument(
        "--swiftpm-products",
        help="the libraries' products.json, from CI/xcframework_zips.py (with "
        "--xcframework-checksums; omit for a Package.swift with no products)",
    )
    render.add_argument(
        "--xcframework-checksums",
        help="the libraries' checksums.json, from CI/xcframework_zips.py",
    )
    render.add_argument("--out", required=True, help="directory to write into")
    render.set_defaults(func=cmd_render)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except FormulaError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
