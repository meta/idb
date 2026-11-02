#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# The shebang is python3, not fbpython: this runs from a facebook/idb checkout,
# where fbpython does not exist, so PATTERNLINT's shebang-python warning is
# expected. Pattern Lint suppressions cannot reach line 1.

"""List, install and inspect idb builds through Homebrew.

The release the meta/fb tap carries, and any commit with a successful CI
run, can be installed:

    ./homebrew.py builds               releases and recent CI builds of main
    ./homebrew.py install v1.6.2       a release, if meta/fb carries it
    ./homebrew.py install 1a2b3c4      the CI build of a commit
    ./homebrew.py install pr:123       ... of a pull request's head
    ./homebrew.py install run:456      ... of one CI run
    ./homebrew.py status               what is installed, from which build
    ./homebrew.py uninstall --restore  back to meta/fb/idb
    ./homebrew.py                      interactive picker

A release installs from meta/fb itself. A CI build installs from a local
tap, idb-local/builds, whose formulae each install replaces; the meta/fb tap
is never modified. Downloading CI artifacts needs a GitHub token:
GITHUB_TOKEN or GH_TOKEN, or a logged-in `gh`. Standard library only, Python
3.9 or later.
"""

from __future__ import annotations

import argparse
import curses
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Mapping, Optional, Tuple, Union

REPO = "facebook/idb"
API = "https://api.github.com"
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"

TAP = "idb-local/builds"
TAP_PATH = Path("Library/Taps/idb-local/homebrew-builds")
STABLE_TAP = "meta/fb"
# GitHub renamed the facebook organization to meta. Homebrew moves a clone
# tapped as facebook/fb to meta/fb on its next `brew update`; until then the
# clone keeps its old name, and tapping meta/fb beside it would clone the tap
# a second time.
RENAMED_STABLE_TAP = "facebook/fb"
STABLE_FORMULA = f"{STABLE_TAP}/idb"
# Every tap bump commits the render manifest of its release beside the
# formulae, so its tag names the one release meta/fb can install.
STABLE_MANIFEST_URL = (
    "https://raw.githubusercontent.com/facebook/homebrew-fb/main/idb-release.json"
)
BUILD_RECORD = "build.json"

# `idb` is left out of installs: its unqualified `depends_on "idb-cli"` is
# ambiguous once meta/fb is tapped too. It is still reported by `status` and
# removed when it pins a meta/fb install in place.
FORMULAE = ("idb-companion", "idb-cli", "idb")
INSTALLABLE = {"companion": "idb-companion", "cli": "idb-cli"}

CI_MANIFEST = "manifest.json"
CI_FORMULAE_ARTIFACT = "formulae"
CI_ASSET_ARTIFACTS = ("idb-companion", "fb-idb-dist")

TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:\.(?:a|b|rc)\d+)?$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
FILE_URL_RE = re.compile(r'"(file://[^"]+)"')

TOKEN_HELP = (
    "downloading CI artifacts needs a GitHub token, even for a public "
    "repository: set GITHUB_TOKEN or GH_TOKEN, or log in with `gh auth login`"
)


class HomebrewError(Exception):
    pass


# --- GitHub -----------------------------------------------------------------


@dataclass(frozen=True)
class Response:
    status: int
    headers: Mapping[str, str]  # lower-cased names
    body: bytes


Transport = Callable[[str, Mapping[str, str], bool], Response]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def urllib_transport(url, headers, follow_redirects):
    handlers = () if follow_redirects else (_NoRedirect(),)
    request = urllib.request.Request(url, headers=dict(headers))
    try:
        with urllib.request.build_opener(*handlers).open(request, timeout=120) as r:
            return Response(r.status, _lower(r.headers), r.read())
    except urllib.error.HTTPError as error:
        return Response(error.code, _lower(error.headers or {}), error.read())
    except urllib.error.URLError as error:
        raise HomebrewError(f"{url}: {error.reason}") from error


def _lower(headers):
    return {k.lower(): v for k, v in dict(headers).items()}


@dataclass(frozen=True)
class Release:
    tag: str
    prerelease: bool
    published_at: str
    url: str


@dataclass(frozen=True)
class CIRun:
    id: int
    sha: str
    branch: str
    event: str
    pull_requests: Tuple[int, ...]
    created_at: str
    url: str
    title: str

    @property
    def where(self):
        if self.pull_requests:
            return ", ".join(f"PR #{n}" for n in self.pull_requests)
        if self.event == "pull_request":
            return f"PR ({self.branch})"
        return self.branch


Build = Union[Release, CIRun]


@dataclass(frozen=True)
class Artifact:
    name: str
    expired: bool
    download_url: str


def release_from_json(data):
    return Release(
        tag=data["tag_name"],
        prerelease=bool(data.get("prerelease")),
        published_at=data.get("published_at") or "",
        url=data.get("html_url") or "",
    )


def run_from_json(data):
    return CIRun(
        id=data["id"],
        sha=data["head_sha"],
        branch=data.get("head_branch") or "",
        event=data.get("event") or "",
        pull_requests=tuple(p["number"] for p in data.get("pull_requests") or []),
        created_at=data.get("created_at") or "",
        url=data.get("html_url") or "",
        title=data.get("display_title") or "",
    )


class GitHub:
    def __init__(self, token=None, transport: Transport = urllib_transport, repo=REPO):
        self.token = token
        self.transport = transport
        self.repo = repo

    def _headers(self, auth=True):
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "idb-homebrew",
        }
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def api(self, path, missing=None, **params):
        query = urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None}
        )
        url = f"{API}/repos/{self.repo}/{path}" + (f"?{query}" if query else "")
        response = self.transport(url, self._headers(), True)
        if response.status == 200:
            return json.loads(response.body)
        if response.status == 404 and missing:
            raise HomebrewError(missing)
        raise self._error(url, response)

    def _error(self, url, response):
        if (
            response.status in (403, 429)
            and response.headers.get("x-ratelimit-remaining") == "0"
        ):
            return HomebrewError(
                "GitHub's API rate limit is used up; a token raises it: set "
                "GITHUB_TOKEN or GH_TOKEN, or log in with `gh auth login`"
            )
        if response.status == 401:
            return HomebrewError("GitHub rejected the token (401 Unauthorized)")
        try:
            detail = json.loads(response.body).get("message", "")
        except (ValueError, AttributeError):
            detail = ""
        return HomebrewError(f"{url}: HTTP {response.status} {detail}".rstrip())

    def releases(self, limit):
        # Drafts come first and are visible only to maintainers, and
        # releases/tags/<tag> 404s on them, so they are not installable builds.
        published = [
            release_from_json(r)
            for r in self.api("releases", per_page=100)
            if not r.get("draft")
        ]
        published.sort(key=lambda r: r.published_at, reverse=True)
        return published[:limit]

    def release(self, tag):
        return release_from_json(
            self.api(f"releases/tags/{tag}", missing=f"no release is tagged {tag}")
        )

    def latest_release(self):
        return release_from_json(
            self.api("releases/latest", missing="facebook/idb has no releases")
        )

    def stable_tag(self):
        """The release meta/fb carries."""
        return json.loads(self.download(STABLE_MANIFEST_URL))["tag"]

    def ci_runs(self, limit, branch=None, head_sha=None):
        data = self.api(
            "actions/workflows/ci.yml/runs",
            status="success",
            branch=branch,
            head_sha=head_sha,
            per_page=limit,
        )
        return [run_from_json(r) for r in data["workflow_runs"]]

    def ci_run(self, run_id):
        data = self.api(f"actions/runs/{run_id}", missing=f"no workflow run {run_id}")
        if data.get("path") != CI_WORKFLOW_PATH:
            raise HomebrewError(
                f"run {run_id} is {data.get('name')!r}, not a CI (ci.yml) run"
            )
        if data.get("conclusion") != "success":
            raise HomebrewError(
                f"run {run_id} did not succeed ({data.get('conclusion') or data.get('status')})"
            )
        return run_from_json(data)

    def artifacts(self, run_id):
        data = self.api(f"actions/runs/{run_id}/artifacts", per_page=100)
        return {
            a["name"]: Artifact(
                a["name"], bool(a["expired"]), a["archive_download_url"]
            )
            for a in data["artifacts"]
        }

    def commit_sha(self, ref):
        return self.api(f"commits/{ref}", missing=f"{ref}: no such commit or branch")[
            "sha"
        ]

    def pull_head_sha(self, number):
        return self.api(f"pulls/{number}", missing=f"no pull request #{number}")[
            "head"
        ]["sha"]

    def download(self, url):
        response = self.transport(url, {"User-Agent": "idb-homebrew"}, True)
        if response.status != 200:
            raise self._error(url, response)
        return response.body

    def download_artifact(self, artifact):
        if not self.token:
            raise HomebrewError(TOKEN_HELP)
        # The API answers with a redirect to pre-signed blob storage, which
        # rejects a request that also carries the GitHub token; follow it by
        # hand without one.
        first = self.transport(artifact.download_url, self._headers(), False)
        if first.status in (301, 302, 303, 307, 308):
            location = first.headers.get("location")
            if not location:
                raise HomebrewError(
                    f"{artifact.download_url}: HTTP {first.status} without a Location"
                )
            return self.download(location)
        if first.status == 200:
            return first.body
        raise self._error(artifact.download_url, first)


def github_token(env=os.environ, run=subprocess.run, which=shutil.which):
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        if env.get(name):
            return env[name]
    if which("gh"):
        result = run(["gh", "auth", "token"], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return None


# --- Resolving a build --------------------------------------------------------


def resolve(github, spec):
    """A release or a CI run from what the user typed: a tag, `latest`,
    `run:<id>`, `pr:<n>`, a commit sha, or a branch."""
    if spec == "latest":
        return github.latest_release()
    if TAG_RE.match(spec):
        return github.release(spec)
    if spec.startswith("run:"):
        return github.ci_run(_number(spec, "run:"))
    if spec.startswith("pr:"):
        number = _number(spec, "pr:")
        return _run_for_sha(github, github.pull_head_sha(number), f"PR #{number}")
    if SHA_RE.match(spec):
        return _run_for_sha(github, github.commit_sha(spec), spec)
    runs = github.ci_runs(1, branch=spec)
    if not runs:
        raise HomebrewError(f"no successful CI run on branch {spec!r}")
    return runs[0]


def _number(spec, prefix):
    rest = spec[len(prefix) :]
    if not rest.isdigit():
        raise HomebrewError(f"{spec!r}: expected {prefix}<number>")
    return int(rest)


def _run_for_sha(github, sha, label):
    runs = github.ci_runs(1, head_sha=sha)
    if not runs:
        raise HomebrewError(
            f"no successful CI run for {label} ({sha[:10]}); only commits whose "
            "CI run passed have installable builds"
        )
    return runs[0]


# --- Fetching and verifying ---------------------------------------------------


@dataclass(frozen=True)
class Fetched:
    build: Build
    formulae: Mapping[str, str]  # "idb-cli.rb" -> text, ready for the tap


def sha256_text(text):
    return hashlib.sha256(text.encode()).hexdigest()


def verify(manifest, formulae):
    """Each formula must be the file its manifest recorded."""
    outputs = manifest.get("outputs") or {}
    for name in (f"{n}.rb" for n in FORMULAE):
        if name not in formulae:
            raise HomebrewError(f"{name} is missing from the build")
        if outputs.get(name) != sha256_text(formulae[name]):
            raise HomebrewError(
                f"{name} does not match the digest its manifest records; "
                "refusing to install it"
            )


def fetch_ci(github, run, directory, log=print):
    artifacts = github.artifacts(run.id)
    wanted = (CI_FORMULAE_ARTIFACT, *CI_ASSET_ARTIFACTS)
    unavailable = [n for n in wanted if n not in artifacts or artifacts[n].expired]
    if unavailable:
        raise HomebrewError(
            f"CI run {run.id} has no usable {', '.join(unavailable)} artifact "
            "(expired, or the run predates it)"
        )
    if directory.exists():
        shutil.rmtree(directory)
    formulae_dir = directory / "formulae"
    assets_dir = directory / "assets"
    for name in wanted:
        log(f"Downloading the {name} artifact of CI run {run.id}")
        archive = github.download_artifact(artifacts[name])
        target = formulae_dir if name == CI_FORMULAE_ARTIFACT else assets_dir
        with zipfile.ZipFile(io.BytesIO(archive)) as zf:
            zf.extractall(target)
    manifest_path = formulae_dir / CI_MANIFEST
    if not manifest_path.exists():
        raise HomebrewError(f"the formulae artifact of CI run {run.id} has no manifest")
    manifest = json.loads(manifest_path.read_text())
    formulae = {
        f"{n}.rb": (formulae_dir / f"{n}.rb").read_text()
        for n in FORMULAE
        if (formulae_dir / f"{n}.rb").exists()
    }
    verify(manifest, formulae)
    return Fetched(run, repoint(formulae, manifest["asset_base"], assets_dir))


def repoint(formulae, asset_base, assets_dir):
    """CI renders its formulae against file:// paths on the runner; point
    them at the downloaded copies of the same files instead."""
    old = asset_base.rstrip("/") + "/"
    new = assets_dir.resolve().as_uri() + "/"
    result = {}
    for name, text in formulae.items():
        if old not in text:
            raise HomebrewError(f"{name} does not reference its recorded asset base")
        text = text.replace(old, new)
        for url in FILE_URL_RE.findall(text):
            path = Path(urllib.parse.unquote(urllib.parse.urlparse(url).path))
            if not path.exists():
                raise HomebrewError(
                    f"{name} references {path.name}, which the build lacks"
                )
        result[name] = text
    return result


def build_record(build, now=None):
    fetched_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    if isinstance(build, Release):
        return {
            "kind": "release",
            "tag": build.tag,
            "url": build.url,
            "fetched_at": fetched_at,
        }
    return {
        "kind": "ci",
        "run_id": build.id,
        "commit": build.sha,
        "where": build.where,
        "title": build.title,
        "url": build.url,
        "fetched_at": fetched_at,
    }


def describe_record(record):
    if record["kind"] == "release":
        return f"release {record['tag']}  {record['url']}"
    return (
        f"CI run {record['run_id']} of {record['commit'][:10]} ({record['where']})"
        f"  {record['url']}"
    )


# --- Homebrew -----------------------------------------------------------------


@dataclass(frozen=True)
class Installed:
    name: str
    version: str
    tap: Optional[str]


class Brew:
    def __init__(self, run=subprocess.run, which=shutil.which, log=print):
        self.run = run
        self.which = which
        self.log = log

    def require(self):
        if not self.which("brew"):
            raise HomebrewError("Homebrew is not installed: see https://brew.sh")

    def output(self, *args):
        result = self.run(["brew", *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise HomebrewError(
                f"brew {' '.join(args)} failed:\n{result.stderr.strip()}"
            )
        return result.stdout.strip()

    def call(self, *args):
        self.log(f"+ brew {' '.join(args)}")
        if self.run(["brew", *args]).returncode != 0:
            raise HomebrewError(f"brew {' '.join(args)} failed")

    def trust(self, tap):
        # Current Homebrew refuses dependencies pulled from an untrusted tap;
        # a Homebrew that predates tap trust has nothing to grant.
        result = self.run(["brew", "trust", tap], capture_output=True, text=True)
        if result.returncode != 0 and "Unknown command" not in result.stderr:
            raise HomebrewError(f"brew trust {tap} failed:\n{result.stderr.strip()}")

    def tap_dir(self):
        return Path(self.output("--repository")) / TAP_PATH

    def stable_tap(self):
        """The name brew's clone of the stable tap goes by."""
        taps = Path(self.output("--repository")) / "Library" / "Taps"

        def cloned(name):
            user, repository = name.split("/")
            return (taps / user / f"homebrew-{repository}").is_dir()

        if cloned(RENAMED_STABLE_TAP) and not cloned(STABLE_TAP):
            return RENAMED_STABLE_TAP
        return STABLE_TAP

    def stable_version(self, formula):
        """The version brew's clone of the formula's tap would install."""
        info = json.loads(self.output("info", "--json=v2", formula))
        return info["formulae"][0]["versions"]["stable"]

    def installed(self):
        """The installed idb formulae, read from their kegs' install receipts."""
        prefix = Path(self.output("--prefix"))
        cellar = Path(self.output("--cellar"))
        result = {}
        for name in FORMULAE:
            keg = _linked_keg(prefix / "opt" / name, cellar / name)
            if keg is None:
                continue
            tap = None
            receipt = keg / "INSTALL_RECEIPT.json"
            if receipt.exists():
                tap = (json.loads(receipt.read_text()).get("source") or {}).get("tap")
            result[name] = Installed(name, keg.name, tap)
        return result


def _linked_keg(opt, rack):
    if opt.exists():
        return opt.resolve()
    if not rack.is_dir():
        return None
    kegs = sorted(p for p in rack.iterdir() if p.is_dir())
    return kegs[-1] if kegs else None


def read_record(tap_dir):
    path = tap_dir / BUILD_RECORD
    return json.loads(path.read_text()) if path.exists() else None


def stage(brew, fetched):
    tap_dir = brew.tap_dir()
    formula_dir = tap_dir / "Formula"
    formula_dir.mkdir(parents=True, exist_ok=True)
    for old in formula_dir.glob("*.rb"):
        old.unlink()
    for name, text in fetched.formulae.items():
        (formula_dir / name).write_text(text)
    (tap_dir / BUILD_RECORD).write_text(
        json.dumps(build_record(fetched.build), indent=2) + "\n"
    )
    brew.trust(TAP)


# --- Commands -----------------------------------------------------------------


def confirm_on_terminal(question):
    if not sys.stdin.isatty():
        return False
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


@dataclass
class Context:
    github: GitHub
    brew: Brew
    cache: Path
    confirm: Callable[[str], bool] = confirm_on_terminal
    log: Callable[[str], None] = print


def install(ctx, spec, only=None, assume_yes=False):
    ctx.brew.require()
    build = resolve(ctx.github, spec)
    names = [INSTALLABLE[only]] if only else list(INSTALLABLE.values())
    if isinstance(build, Release):
        tap = ctx.brew.stable_tap()
        require_stable_release(ctx, build, tap)
        removing = removals(ctx, names, tap, assume_yes)
    else:
        fetched = fetch_ci(ctx.github, build, ctx.cache / f"ci-{build.id}", ctx.log)
        # Every CI build is 0.0.0, so brew would keep an earlier one in place.
        removing = removals(ctx, names, None, assume_yes)
        stage(ctx.brew, fetched)
        tap = TAP
    if removing:
        ctx.brew.call("uninstall", "--ignore-dependencies", *removing)
    ctx.brew.call("install", *(f"{tap}/{n}" for n in names))
    ctx.log(f"Installed {', '.join(names)} from {describe_record(build_record(build))}")


def require_stable_release(ctx, release, tap):
    """A release installs from meta/fb, which carries only the newest bump;
    brew's clone of the tap, named `tap`, has to have caught up with it, or
    `brew install` would quietly install another."""
    carried = ctx.github.stable_tag()
    if release.tag != carried:
        raise HomebrewError(
            f"{STABLE_TAP} carries {carried}, the only release that can be installed"
        )
    ctx.brew.call("tap", tap)
    cloned = ctx.brew.stable_version(f"{tap}/idb-companion")
    if cloned != release.tag[1:]:
        raise HomebrewError(
            f"brew's clone of {tap} is at {cloned}, behind {carried}: "
            "run `brew update` and try again"
        )


def removals(ctx, names, keep_tap, assume_yes):
    """What has to be uninstalled before `names` install, once the user has
    agreed to replace anything not from the local tap. Installs from
    `keep_tap` stay, for `brew install` to upgrade in place."""
    current = ctx.brew.installed()
    removing = [n for n in names if n in current and current[n].tap != keep_tap]
    # meta/fb's idb metapackage holds its dependencies in place, so it
    # goes too whenever one of them is being replaced.
    if removing and "idb" in current and current["idb"].tap != keep_tap:
        removing.insert(0, "idb")
    foreign = [n for n in removing if current[n].tap != TAP]
    if foreign:
        summary = ", ".join(
            f"{n} {current[n].version} ({current[n].tap})" for n in foreign
        )
        if not (assume_yes or ctx.confirm(f"Replace {summary}?")):
            raise HomebrewError("left the installed idb formulae in place")
    return removing


def uninstall(ctx, restore=False):
    ctx.brew.require()
    ours = [i.name for i in ctx.brew.installed().values() if i.tap == TAP]
    if ours:
        ctx.brew.call("uninstall", "--ignore-dependencies", *ours)
    tap_dir = ctx.brew.tap_dir()
    if tap_dir.exists():
        shutil.rmtree(tap_dir)
        ctx.log(f"Removed the {TAP} tap")
    if restore:
        ctx.brew.call("install", f"{ctx.brew.stable_tap()}/idb")


def status(ctx):
    ctx.brew.require()
    installed = ctx.brew.installed()
    ours = any(i.tap == TAP for i in installed.values())
    return {
        "formulae": {
            name: (
                {"version": installed[name].version, "tap": installed[name].tap}
                if name in installed
                else None
            )
            for name in FORMULAE
        },
        "build": read_record(ctx.brew.tap_dir()) if ours else None,
    }


def format_status(report):
    lines = []
    for name, entry in report["formulae"].items():
        if entry is None:
            lines.append(f"{name:<15}not installed")
        else:
            lines.append(
                f"{name:<15}{entry['version']:<12}{entry['tap'] or 'unknown tap'}"
            )
    if report["build"]:
        lines.append(f"\n{TAP} holds {describe_record(report['build'])}")
    return "\n".join(lines)


@dataclass(frozen=True)
class Row:
    spec: str
    columns: Tuple[str, ...]
    installable: bool
    note: str = ""


def release_rows(github, limit):
    carried = github.stable_tag()
    return [
        Row(
            r.tag,
            (r.tag, r.published_at[:10], "prerelease" if r.prerelease else ""),
            r.tag == carried,
            "" if r.tag == carried else f"{STABLE_TAP} carries {carried}",
        )
        for r in github.releases(limit)
    ]


def ci_rows(github, limit, branch=None, head_sha=None):
    rows = []
    for run in github.ci_runs(limit, branch=branch, head_sha=head_sha):
        artifacts = github.artifacts(run.id)
        wanted = (CI_FORMULAE_ARTIFACT, *CI_ASSET_ARTIFACTS)
        missing = [n for n in wanted if n not in artifacts]
        expired = [n for n in wanted if n in artifacts and artifacts[n].expired]
        note = (
            "artifacts expired"
            if expired
            else ("missing " + ", ".join(missing) if missing else "")
        )
        rows.append(
            Row(
                f"run:{run.id}",
                (
                    f"run:{run.id}",
                    run.sha[:10],
                    run.created_at[:10],
                    run.where,
                    run.title[:50],
                ),
                not note,
                note,
            )
        )
    return rows


def format_rows(rows):
    if not rows:
        return "  (none)"
    widths = [max(len(r.columns[i]) for r in rows) for i in range(len(rows[0].columns))]
    lines = []
    for row in rows:
        text = "  ".join(c.ljust(w) for c, w in zip(row.columns, widths)).rstrip()
        lines.append(f"  {text}" + (f"  [{row.note}]" if row.note else ""))
    return "\n".join(lines)


# --- Interactive picker ---------------------------------------------------------


@dataclass
class Tab:
    title: str
    rows: List[Row] = field(default_factory=list)
    cursor: int = 0


@dataclass
class Picker:
    """The picker's state and key handling, apart from curses so it can be
    tested; `handle` returns the action for the caller to carry out."""

    tabs: List[Tab]
    active: int = 0
    message: str = ""

    @property
    def tab(self):
        return self.tabs[self.active]

    def selected(self):
        rows = self.tab.rows
        return rows[self.tab.cursor] if rows else None

    def handle(self, key):
        if key in ("q", "\x1b"):
            return ("quit",)
        if key in ("KEY_DOWN", "j"):
            self.tab.cursor = min(self.tab.cursor + 1, max(len(self.tab.rows) - 1, 0))
        elif key in ("KEY_UP", "k"):
            self.tab.cursor = max(self.tab.cursor - 1, 0)
        elif key in ("\t", "KEY_RIGHT", "KEY_LEFT"):
            self.active = (self.active + 1) % len(self.tabs)
        elif key == "r":
            return ("refresh",)
        elif key == "p":
            return ("pull-request",)
        elif key == "u":
            return ("uninstall",)
        elif key in ("\n", "KEY_ENTER"):
            row = self.selected()
            if row is None:
                return None
            if not row.installable:
                self.message = f"{row.spec} cannot be installed: {row.note}"
                return None
            return ("install", row.spec)
        return None


class Screen:  # pragma: no cover - drives a terminal
    """Draws a Picker with curses and carries out its actions."""

    HELP = (
        "↑↓ select  Enter install  Tab switch  p pull request  u uninstall"
        "  r refresh  q quit"
    )

    def __init__(self, ctx, stdscr):
        self.ctx = ctx
        self.stdscr = stdscr
        self.picker = Picker([Tab("Releases"), Tab("CI builds: main")])
        self.ci_filter = {"branch": "main", "head_sha": None}
        self.report = {}

    def run(self):
        curses.curs_set(0)
        self.stdscr.addstr(0, 0, "Loading builds from GitHub...")
        self.stdscr.refresh()
        self.load()
        while True:
            self.draw()
            action = self.picker.handle(self.stdscr.getkey())
            if action == ("quit",):
                return
            if action is None:
                continue
            try:
                self.perform(action)
            except HomebrewError as error:
                self.picker.message = f"error: {error}"

    def perform(self, action):
        kind = action[0]
        if kind == "refresh":
            self.load()
        elif kind == "pull-request":
            self.filter_pull_request(
                self.prompt("Pull request number (empty for main): ")
            )
        elif kind == "install" and self.confirm(f"Install {action[1]}?"):
            self.outside(lambda: install(self.ctx, action[1]))
        elif kind == "uninstall" and self.confirm(
            f"Uninstall builds from {TAP} and restore {STABLE_FORMULA}?"
        ):
            self.outside(lambda: uninstall(self.ctx, restore=True))

    def load(self):
        tabs = self.picker.tabs
        tabs[0].rows = release_rows(self.ctx.github, 20)
        tabs[1].rows = ci_rows(self.ctx.github, 15, **self.ci_filter)
        for tab in tabs:
            tab.cursor = min(tab.cursor, max(len(tab.rows) - 1, 0))
        self.report = status(self.ctx)

    def filter_pull_request(self, answer):
        ci = self.picker.tabs[1]
        if answer.isdigit():
            head = self.ctx.github.pull_head_sha(int(answer))
            self.ci_filter = {"branch": None, "head_sha": head}
            ci.title = f"CI builds: PR #{answer}"
        else:
            self.ci_filter = {"branch": "main", "head_sha": None}
            ci.title = "CI builds: main"
        ci.cursor = 0
        self.picker.active = 1
        self.load()

    def outside(self, action):
        """Runs `action` on the plain terminal, so brew's output shows."""
        curses.def_prog_mode()
        curses.endwin()
        try:
            action()
        except HomebrewError as error:
            print(f"error: {error}")
        input("\nPress Enter to return to the picker ")
        curses.reset_prog_mode()
        self.stdscr.clear()
        self.load()

    def confirm(self, question):
        return self.prompt(f"{question} [y/N] ").lower() in ("y", "yes")

    def prompt(self, question):
        height, _ = self.stdscr.getmaxyx()
        curses.echo()
        curses.curs_set(1)
        self.stdscr.addstr(height - 1, 0, question)
        self.stdscr.clrtoeol()
        answer = self.stdscr.getstr(height - 1, len(question)).decode().strip()
        curses.curs_set(0)
        curses.noecho()
        return answer

    def draw(self):
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        line = 0
        for text in format_status(self.report).splitlines():
            self.stdscr.addnstr(line, 0, text, width - 1)
            line += 1
        titles = "   ".join(
            f"[{t.title}]" if i == self.picker.active else f" {t.title} "
            for i, t in enumerate(self.picker.tabs)
        )
        self.stdscr.addnstr(line + 1, 0, titles, width - 1, curses.A_BOLD)
        self.draw_rows(line + 3, height - line - 5, width)
        self.stdscr.addnstr(height - 2, 0, self.picker.message or self.HELP, width - 1)
        self.picker.message = ""
        self.stdscr.refresh()

    def draw_rows(self, top, visible, width):
        tab = self.picker.tab
        if not tab.rows:
            self.stdscr.addnstr(top, 0, "  (none)", width - 1)
            return
        start = max(0, tab.cursor - visible + 1)
        rows = tab.rows[start : start + visible]
        for offset, (row, text) in enumerate(zip(rows, format_rows(rows).splitlines())):
            if start + offset == tab.cursor:
                attr = curses.A_REVERSE
            else:
                attr = 0 if row.installable else curses.A_DIM
            self.stdscr.addnstr(top + offset, 0, text, width - 1, attr)


def run_picker(ctx):  # pragma: no cover - drives a terminal
    curses.wrapper(lambda stdscr: Screen(ctx, stdscr).run())


# --- Entry point ----------------------------------------------------------------


def default_cache():
    return Path(
        os.environ.get("IDB_HOMEBREW_CACHE")
        or Path.home() / "Library" / "Caches" / "idb-homebrew"
    )


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command")

    builds = commands.add_parser("builds", help="list releases and CI builds")
    which = builds.add_mutually_exclusive_group()
    which.add_argument("--releases", action="store_true", help="only releases")
    which.add_argument("--ci", action="store_true", help="only CI builds")
    builds.add_argument(
        "--branch", default="main", help="CI builds of this branch (default: main)"
    )
    builds.add_argument("--pr", type=int, help="CI builds of this pull request's head")
    builds.add_argument("--limit", type=int, default=10)
    builds.add_argument("--json", action="store_true")

    install_cmd = commands.add_parser("install", help="install a release or a CI build")
    install_cmd.add_argument(
        "build", help="a tag, `latest`, `run:<id>`, `pr:<n>`, a commit sha or a branch"
    )
    install_cmd.add_argument(
        "--only", choices=sorted(INSTALLABLE), help="install one half"
    )
    install_cmd.add_argument(
        "--yes", action="store_true", help="replace other installs without asking"
    )

    status_cmd = commands.add_parser(
        "status", help="show the installed idb and its build"
    )
    status_cmd.add_argument("--json", action="store_true")

    uninstall_cmd = commands.add_parser(
        "uninstall", help=f"remove builds installed from {TAP}"
    )
    uninstall_cmd.add_argument(
        "--restore", action="store_true", help=f"then install {STABLE_FORMULA}"
    )
    return parser, parser.parse_args(argv)


def cmd_builds(ctx, args):
    sections = []
    if not args.ci:
        sections.append(("Releases", release_rows(ctx.github, args.limit)))
    if not args.releases:
        if args.pr:
            head = ctx.github.pull_head_sha(args.pr)
            sections.append(
                (
                    f"CI builds: PR #{args.pr}",
                    ci_rows(ctx.github, args.limit, head_sha=head),
                )
            )
        else:
            sections.append(
                (
                    f"CI builds: {args.branch}",
                    ci_rows(ctx.github, args.limit, branch=args.branch),
                )
            )
    if args.json:
        print(
            json.dumps(
                {
                    title: [
                        {
                            "build": r.spec,
                            "installable": r.installable,
                            "note": r.note,
                            "columns": r.columns,
                        }
                        for r in rows
                    ]
                    for title, rows in sections
                },
                indent=2,
            )
        )
        return
    print("\n\n".join(f"{title}\n{format_rows(rows)}" for title, rows in sections))


def main(argv=None, ctx=None):
    parser, args = parse_args(sys.argv[1:] if argv is None else argv)
    if ctx is None:
        ctx = Context(GitHub(github_token()), Brew(), default_cache())
    try:
        if args.command is None:
            if not (sys.stdin.isatty() and sys.stdout.isatty()):
                parser.print_help()
                return 2
            run_picker(ctx)
        elif args.command == "builds":
            cmd_builds(ctx, args)
        elif args.command == "install":
            install(ctx, args.build, args.only, args.yes)
        elif args.command == "status":
            report = status(ctx)
            print(json.dumps(report, indent=2) if args.json else format_status(report))
        elif args.command == "uninstall":
            uninstall(ctx, args.restore)
    except HomebrewError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
