#!/usr/bin/env python3
"""Create, fill, verify, and publish one GitHub Release as a private transaction."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


SEMVER_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
)
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


def fail(message: str) -> None:
    raise RuntimeError(f"GitHub release publication error: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def digest_handle(handle: object) -> str:
    digest = hashlib.sha256()
    handle.seek(0)
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
    handle.seek(0)
    return digest.hexdigest()


class GitHub:
    def __init__(self, repository: str, token: str) -> None:
        require(
            re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is not None,
            f"invalid repository {repository!r}",
        )
        require(bool(token), "GH_TOKEN is required")
        self.repository = repository
        self.token = token
        self.api_root = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "Dory-transactional-release-publisher",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def json_request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, object] | None = None,
        expected_status: int = 200,
    ) -> dict[str, object]:
        data = None
        headers = dict(self.headers)
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        url = f"{self.api_root}/{path.lstrip('/')}"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = response.read()
                require(
                    response.status == expected_status,
                    f"{method} {path} returned HTTP {response.status}, expected {expected_status}",
                )
        except urllib.error.HTTPError as error:
            detail = error.read(64 * 1024).decode("utf-8", errors="replace")
            fail(f"{method} {path} returned HTTP {error.code}: {detail}")
        except (OSError, urllib.error.URLError, TimeoutError) as error:
            fail(f"{method} {path} failed closed: {error}")
        if not payload:
            return {}
        try:
            value = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            fail(f"{method} {path} returned invalid JSON: {error}")
        require(isinstance(value, dict), f"{method} {path} returned a non-object")
        return value

    def release_for_tag(self, tag: str) -> dict[str, object] | None:
        encoded = urllib.parse.quote(tag, safe="")
        path = f"releases/tags/{encoded}"
        url = f"{self.api_root}/{path}"
        request = urllib.request.Request(url, headers=self.headers, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read()
                require(response.status == 200, f"GET {path} returned HTTP {response.status}")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            detail = error.read(64 * 1024).decode("utf-8", errors="replace")
            fail(f"GET {path} returned HTTP {error.code}: {detail}")
        except (OSError, urllib.error.URLError, TimeoutError) as error:
            fail(f"GET {path} failed closed: {error}")
        try:
            release = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            fail(f"GET {path} returned invalid JSON: {error}")
        require(isinstance(release, dict), f"GET {path} returned a non-object")
        return release

    def upload(
        self,
        upload_url: str,
        release_id: int,
        name: str,
        handle: object,
        expected_size: int,
    ) -> dict[str, object]:
        parsed = urllib.parse.urlsplit(upload_url.removesuffix("{?name,label}"))
        expected_path = f"/repos/{self.repository}/releases/{release_id}/assets"
        require(
            parsed.scheme == "https"
            and parsed.netloc == "uploads.github.com"
            and parsed.path == expected_path
            and not parsed.query
            and not parsed.fragment,
            "GitHub returned a non-canonical release upload URL",
        )
        url = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode({"name": name}), "")
        )
        with tempfile.NamedTemporaryFile(prefix="dory-upload-response-", suffix=".json") as response:
            command = [
                "curl",
                "--config",
                "-",
                "--silent",
                "--show-error",
                "--connect-timeout",
                "30",
                "--max-time",
                "1800",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "X-GitHub-Api-Version: 2022-11-28",
                "-H",
                "Content-Type: application/octet-stream",
                "--data-binary",
                f"@/dev/fd/{handle.fileno()}",
                "--output",
                response.name,
                "--write-out",
                "%{http_code}",
                url,
            ]
            upload_environment = dict(os.environ)
            upload_environment.pop("GH_TOKEN", None)
            result = subprocess.run(
                command,
                env=upload_environment,
                input=f'header = "Authorization: Bearer {self.token}"\n',
                pass_fds=(handle.fileno(),),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            response.seek(0)
            response_bytes = response.read()
        require(result.returncode == 0, f"upload of {name} failed closed: {result.stderr.strip()}")
        require(result.stdout == "201", f"upload of {name} returned HTTP {result.stdout}: {response_bytes[:65536].decode('utf-8', errors='replace')}")
        try:
            asset = json.loads(response_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            fail(f"upload of {name} returned invalid JSON: {error}")
        require(isinstance(asset, dict), f"upload of {name} returned a non-object")
        require(asset.get("name") == name, f"uploaded asset was renamed from {name}")
        require(asset.get("size") == expected_size, f"uploaded asset {name} has the wrong size")
        return asset


def exact_asset_inputs(paths: list[pathlib.Path]) -> dict[str, tuple[pathlib.Path, int, str]]:
    require(bool(paths), "no release assets were supplied")
    assets: dict[str, tuple[pathlib.Path, int, str]] = {}
    for path in paths:
        try:
            info = path.lstat()
        except OSError as error:
            fail(f"could not inspect publication input {path}: {error}")
        require(stat.S_ISREG(info.st_mode), f"publication input is not a direct regular file: {path}")
        require(info.st_size > 0, f"publication input is empty: {path}")
        require(path.name not in assets, f"release repeats asset name {path.name}")
        with path.open("rb") as handle:
            digest = digest_handle(handle)
            after = os.fstat(handle.fileno())
        require(
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            == (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns),
            f"publication input changed while hashing: {path}",
        )
        assets[path.name] = (path, info.st_size, digest)
    return assets


def exact_ref_target(github: GitHub, tag: str) -> str:
    encoded = urllib.parse.quote(tag, safe="")
    reference = github.json_request("GET", f"git/ref/tags/{encoded}")
    target = reference.get("object")
    require(isinstance(target, dict), f"tag {tag} has an invalid Git object")
    require(target.get("type") == "commit", f"tag {tag} is not the create-only lightweight ref")
    sha = target.get("sha")
    require(isinstance(sha, str), f"tag {tag} has no commit SHA")
    return sha


def release_asset_state(release: dict[str, object]) -> dict[str, tuple[int | None, str | None]]:
    assets = release.get("assets")
    require(
        isinstance(assets, list) and all(isinstance(asset, dict) for asset in assets),
        "GitHub release has an invalid asset list",
    )
    result: dict[str, tuple[int | None, str | None]] = {}
    for asset in assets:
        name = asset.get("name")
        require(isinstance(name, str) and name not in result, "GitHub release repeats an asset name")
        size = asset.get("size")
        digest = asset.get("digest")
        result[name] = (
            size if isinstance(size, int) else None,
            digest if isinstance(digest, str) else None,
        )
    return result


def revalidate_publication_authority(
    repository: str,
    version: str,
    build: str,
    project: pathlib.Path,
    source_commit: str,
) -> None:
    fetch = subprocess.run(
        ["git", "fetch", "--force", "origin", "main"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    require(fetch.returncode == 0, f"could not refresh main before publish: {fetch.stdout.strip()}")
    resolve = subprocess.run(
        ["git", "rev-parse", "origin/main"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    require(resolve.returncode == 0, f"could not resolve main before publish: {resolve.stdout.strip()}")
    require(
        resolve.stdout.strip() == source_commit,
        f"qualified commit {source_commit} is no longer exact current origin/main",
    )
    verifier = pathlib.Path(__file__).with_name("verify-release-identity.py")
    identity = subprocess.run(
        [
            sys.executable,
            str(verifier),
            "--repository",
            repository,
            "--project",
            str(project),
            "--version",
            version,
            "--build",
            build,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    require(
        identity.returncode == 0,
        f"release identity changed before private draft publication: {identity.stdout.strip()}",
    )


def report_unpublished_state(
    github: GitHub,
    tag: str,
    source_commit: str,
    release_id: int | None,
) -> None:
    messages = [
        "Automatic GitHub cleanup is disabled because the API has no conditional delete; "
        "reconcile this failed private publication explicitly."
    ]
    if release_id is not None:
        try:
            release = github.json_request("GET", f"releases/{release_id}")
            messages.append(
                f"release_id={release_id} tag={release.get('tag_name')!r} "
                f"draft={release.get('draft')!r}"
            )
        except Exception as error:
            messages.append(f"release_id={release_id} state lookup failed closed: {error}")
    try:
        tag_release = github.release_for_tag(tag)
        messages.append(
            f"tag={tag} release_id="
            f"{None if tag_release is None else tag_release.get('id')!r}"
        )
    except Exception as error:
        messages.append(f"tag={tag} release lookup failed closed: {error}")
    try:
        target = exact_ref_target(github, tag)
        messages.append(
            f"tag={tag} target={target} expected_target={source_commit}"
        )
    except Exception as error:
        messages.append(f"tag={tag} ref lookup failed closed: {error}")
    print("WARNING: " + " ".join(messages), file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--project", type=pathlib.Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--body-file", type=pathlib.Path, required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    parser.add_argument("assets", nargs="+", type=pathlib.Path)
    arguments = parser.parse_args()

    require(SEMVER_PATTERN.fullmatch(arguments.version) is not None, "version is not canonical SemVer")
    require(re.fullmatch(r"[1-9][0-9]*", arguments.build) is not None, "build is not canonical")
    require(COMMIT_PATTERN.fullmatch(arguments.source_commit) is not None, "source commit is not canonical")
    try:
        body = arguments.body_file.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"could not read release body: {error}")
    require(bool(body.strip()), "release body is empty")
    inputs = exact_asset_inputs(arguments.assets)
    expected_assets = {
        name: (size, f"sha256:{digest}")
        for name, (_, size, digest) in inputs.items()
    }
    github = GitHub(arguments.repository, os.environ.get("GH_TOKEN", ""))
    tag = f"v{arguments.version}"
    release_id: int | None = None
    published = False
    publish_ambiguous = False
    try:
        reference = github.json_request(
            "POST",
            "git/refs",
            body={"ref": f"refs/tags/{tag}", "sha": arguments.source_commit},
            expected_status=201,
        )
        require(reference.get("ref") == f"refs/tags/{tag}", "GitHub created the wrong tag ref")
        require(exact_ref_target(github, tag) == arguments.source_commit, "created tag targets another commit")

        release = github.json_request(
            "POST",
            "releases",
            body={
                "tag_name": tag,
                "target_commitish": arguments.source_commit,
                "name": arguments.name,
                "body": body,
                "draft": True,
                "prerelease": False,
                "generate_release_notes": True,
            },
            expected_status=201,
        )
        release_id_value = release.get("id")
        require(isinstance(release_id_value, int) and release_id_value > 0, "draft release has no ID")
        release_id = release_id_value
        require(release.get("draft") is True, "new release was exposed before asset verification")
        require(release.get("tag_name") == tag, "draft release has the wrong tag")
        require(release.get("target_commitish") == arguments.source_commit, "draft release has the wrong target")
        upload_url = release.get("upload_url")
        require(isinstance(upload_url, str), "draft release has no upload URL")

        for name, (path, expected_size, expected_digest) in inputs.items():
            with path.open("rb") as handle:
                before = os.fstat(handle.fileno())
                require(before.st_size == expected_size, f"publication input changed before upload: {path}")
                require(digest_handle(handle) == expected_digest, f"publication input changed before upload: {path}")
                github.upload(upload_url, release_id, name, handle, expected_size)
                after_digest = digest_handle(handle)
                after = os.fstat(handle.fileno())
            require(
                after.st_size == expected_size and after_digest == expected_digest,
                f"publication input changed during upload: {path}",
            )

        for attempt in range(1, 25):
            release = github.json_request("GET", f"releases/{release_id}")
            require(release.get("draft") is True, "release became public before verification")
            require(release.get("tag_name") == tag, "draft release tag changed")
            require(release.get("target_commitish") == arguments.source_commit, "draft release target changed")
            actual_assets = release_asset_state(release)
            if actual_assets == expected_assets:
                break
            if attempt == 24:
                fail(f"draft release asset set differs: {actual_assets!r} != {expected_assets!r}")
            time.sleep(5)
        require(exact_ref_target(github, tag) == arguments.source_commit, "tag moved during upload")
        revalidate_publication_authority(
            arguments.repository,
            arguments.version,
            arguments.build,
            arguments.project,
            arguments.source_commit,
        )

        publish_ambiguous = True
        try:
            release = github.json_request(
                "PATCH", f"releases/{release_id}", body={"draft": False}, expected_status=200
            )
        except RuntimeError:
            try:
                observed = github.json_request("GET", f"releases/{release_id}")
            except RuntimeError:
                publish_ambiguous = True
            else:
                published = observed.get("id") == release_id and observed.get("draft") is False
                publish_ambiguous = observed.get("id") != release_id or not isinstance(
                    observed.get("draft"), bool
                )
            raise
        if release.get("draft") is True:
            publish_ambiguous = False
        elif release.get("draft") is False:
            published = True
            publish_ambiguous = False
        require(release.get("id") == release_id, "GitHub published another release")
        require(release.get("draft") is False, "GitHub did not publish the verified draft")

        public_release = github.json_request("GET", f"releases/{release_id}")
        require(public_release.get("draft") is False, "published release reverted to draft")
        require(public_release.get("tag_name") == tag, "published release tag changed")
        require(
            public_release.get("target_commitish") == arguments.source_commit,
            "published release target changed",
        )
        require(release_asset_state(public_release) == expected_assets, "published asset set changed")
        require(exact_ref_target(github, tag) == arguments.source_commit, "published tag moved")
        if arguments.github_output is not None:
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"id={release_id}\n")
        print(f"Published exact private draft {release_id} as {tag} with {len(inputs)} assets.")
    finally:
        if not published and not publish_ambiguous:
            report_unpublished_state(
                github, tag, arguments.source_commit, release_id
            )
        elif publish_ambiguous:
            print(
                f"WARNING: publication state for release {release_id} is ambiguous; "
                "refusing destructive cleanup",
                file=sys.stderr,
            )
            report_unpublished_state(
                github, tag, arguments.source_commit, release_id
            )


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
