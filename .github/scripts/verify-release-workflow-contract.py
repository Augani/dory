#!/usr/bin/env python3
"""Static regression contract for the one-command public release path."""

import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import re
import shutil
import tempfile
from pathlib import Path
from types import ModuleType


def require(text: str, value: str, message: str) -> None:
    if value not in text:
        raise SystemExit(f"release workflow contract: {message}")


def load_module(path: Path, name: str) -> ModuleType:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise SystemExit(f"release workflow contract: could not import {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def expect_failure(callback, expected: str, message: str) -> None:
    try:
        callback()
    except (RuntimeError, SystemExit) as error:
        if expected not in str(error):
            raise SystemExit(
                f"release workflow contract: {message}; unexpected error: {error}"
            ) from error
    else:
        raise SystemExit(f"release workflow contract: {message}")


workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
pages_workflow = Path(".github/workflows/pages.yml").read_text(encoding="utf-8")
publisher = Path("scripts/publish-release.sh").read_text(encoding="utf-8")
release_script = Path("scripts/release.sh").read_text(encoding="utf-8")
component_tests = Path("scripts/test-build-components.sh").read_text(encoding="utf-8")
identity_verifier_path = Path(".github/scripts/verify-release-identity.py")
identity_verifier_source = identity_verifier_path.read_text(encoding="utf-8")
pages_verifier_path = Path(".github/scripts/verify-pages-release-metadata.py")
pages_verifier_source = pages_verifier_path.read_text(encoding="utf-8")
release_publisher_path = Path(".github/scripts/publish-github-release.py")
release_publisher_source = release_publisher_path.read_text(encoding="utf-8")

for name, source in (("release", workflow), ("pages", pages_workflow)):
    if "assert " in source:
        raise SystemExit(
            f"release workflow contract: {name} workflow uses optimization-sensitive Python assert"
        )

candidate = workflow.split("      - name: Stage immutable public candidate", 1)[1].split(
    "\n  homebrew_install_certification:", 1
)[0]
publication = workflow.split("  publish_release:", 1)[1].split("\n  publish-pages:", 1)[0]
pages = workflow.split("  publish-pages:", 1)[1].split("\n  # Keeps the Homebrew", 1)[0]
bump = workflow.split("  bump-cask:", 1)[1].split("\n  verify-public-release:", 1)[0]
final = workflow.split("  verify-public-release:", 1)[1]
guest_upload = workflow.split("      - name: Upload same-commit arm64 guest payload", 1)[1].split(
    "\n\n  prepublication-quality:", 1
)[0]
guest_download_verification = workflow.split(
    "      - name: Independently verify every downloaded guest payload", 1
)[1].split("\n      - name: Prove the tracked release source exactly matches the commit", 1)[0]

if "github.run_number" in workflow:
    raise SystemExit(
        "release workflow contract: workflow run number is used as release artifact metadata"
    )
require(workflow, "build:\n        description: 'Monotonic CURRENT_PROJECT_VERSION", "release dispatch has no explicit monotonic build input")
require(workflow, "release-metadata:", "release identity is not validated before artifact work")
require(
    workflow,
    ".github/scripts/verify-release-identity.py",
    "release workflow does not run the shared complete-history identity verifier",
)
release_metadata = re.search(
    r"(?ms)^  release-metadata:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow
)
if release_metadata is None:
    raise SystemExit("release workflow contract: missing release-metadata job")
release_metadata_source = release_metadata.group(1)
require(
    release_metadata_source,
    'test "$GITHUB_SHA" = "$(git rev-parse origin/main)"',
    "release identity accepts an ancestor instead of the exact current main commit",
)
if "merge-base --is-ancestor" in release_metadata_source:
    raise SystemExit("release workflow contract: release identity still accepts stale main ancestry")
require(
    release_metadata_source,
    "'^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$'",
    "release workflow does not reject leading-zero semantic versions",
)
require(identity_verifier_source, "?per_page=100&page={page}", "identity verifier does not paginate every release")
require(identity_verifier_source, "page > 100", "identity verifier has no fail-closed pagination bound")
require(identity_verifier_source, "appcast_floor", "identity verifier trusts only one mutable appcast")
require(identity_verifier_source, "digest != f\"sha256:{actual_digest}\"", "identity verifier does not authenticate release appcasts")
require(identity_verifier_source, "previous_version={previous_text}", "identity verifier does not expose the maximum stable release")
require(workflow, 'git show-ref --verify --quiet "refs/tags/v$RELEASE_VERSION"', "release identity does not reject an existing tag")
require(workflow, 'releases/tags/v$RELEASE_VERSION', "release identity does not prove the GitHub Release is absent")
require(workflow, 'could not prove release v$RELEASE_VERSION is absent', "release identity treats an indeterminate GitHub response as absence")
release_configuration = re.search(
    r"(?ms)^  release-configuration:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow
)
if release_configuration is None:
    raise SystemExit("release workflow contract: missing release-configuration job")
require(
    release_configuration.group(1),
    "needs: release-metadata",
    "credential/infrastructure preflight can run before release identity is proven",
)
for job in ("rust-workspace", "guest-assets-arm64", "prepublication-quality"):
    match = re.search(
        rf"(?ms)^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
    )
    if match is None:
        raise SystemExit(f"release workflow contract: missing job {job}")
    section = match.group(1)
    require(section, "release-metadata", f"{job} can start before release identity validation")
guest_job = re.search(
    r"(?ms)^  guest-assets-arm64:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow
)
if guest_job is None:
    raise SystemExit("release workflow contract: missing guest-assets-arm64 job")
for prerequisite in (
    "binutils-aarch64-linux-gnu",
    "protobuf-compiler",
    "command -v protoc",
    "command -v aarch64-linux-gnu-readelf",
    "DORY_AARCH64_READELF: /usr/bin/aarch64-linux-gnu-readelf",
):
    require(
        guest_job.group(1),
        prerequisite,
        f"guest build does not fail fast on required toolchain prerequisite {prerequisite}",
    )
require(workflow, 'scripts/release.sh "${{ inputs.version }}" "${{ inputs.build }}"', "release build does not use validated dispatch metadata")
require(workflow, 'BUILD: ${{ inputs.build }}', "downstream evidence is not bound to the dispatch build")
if "releases/latest/download/appcast.xml" in workflow:
    raise SystemExit("release workflow contract: candidate history trusts the mutable latest release")
require(
    workflow,
    "releases/download/v$PREVIOUS_RELEASE_VERSION/appcast.xml",
    "candidate history is not loaded from the maximum stable release",
)

identity_verifier = load_module(identity_verifier_path, "dory_release_identity_contract")


def fixture_appcast(version: str, build: int) -> bytes:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f"<channel><item><sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        f"<sparkle:version>{build}</sparkle:version></item></channel></rss>\n"
    ).encode("utf-8")


def fixture_release(version: str, build: int | None) -> dict[str, object]:
    assets: list[dict[str, object]] = []
    if build is not None:
        payload = fixture_appcast(version, build)
        assets.append(
            {
                "name": "appcast.xml",
                "size": len(payload),
                "digest": f"sha256:{hashlib.sha256(payload).hexdigest()}",
                "fixture": payload,
            }
        )
    return {
        "tag_name": f"v{version}",
        "draft": False,
        "prerelease": False,
        "assets": assets,
    }


def fetch_fixture_asset(asset: dict[str, object], tag: str) -> bytes:
    payload = asset.get("fixture")
    if not isinstance(payload, bytes):
        raise SystemExit("release workflow contract: malformed identity fixture")
    return payload


identity_verifier.validate_release_history(
    [fixture_release("0.2.0", None), fixture_release("0.4.5", 49)],
    fetch_fixture_asset,
    "0.4.6",
    "52",
)
expect_failure(
    lambda: identity_verifier.validate_release_history([], fetch_fixture_asset, "00.4.6", "52"),
    "not a canonical stable semantic version",
    "identity verifier accepted leading-zero SemVer",
)
expect_failure(
    lambda: identity_verifier.validate_release_history(
        [{"tag_name": "v0.4.5", "draft": "false", "prerelease": False, "assets": []}],
        fetch_fixture_asset,
        "0.4.6",
        "52",
    ),
    "ambiguous draft/prerelease state",
    "identity verifier accepted ambiguous GitHub release state",
)
expect_failure(
    lambda: identity_verifier.validate_release_history(
        [fixture_release("0.4.5", 49)], fetch_fixture_asset, "0.4.5", "52"
    ),
    "already exists",
    "identity verifier accepted an existing release",
)
expect_failure(
    lambda: identity_verifier.validate_release_history(
        [fixture_release("0.4.5", 49), fixture_release("0.5.0", 51)],
        fetch_fixture_asset,
        "0.4.6",
        "52",
    ),
    "not newer than published version 0.5.0",
    "identity verifier trusted list order/latest instead of every stable release",
)
expect_failure(
    lambda: identity_verifier.validate_release_history(
        [fixture_release("0.4.5", 49), fixture_release("0.4.6", None)],
        fetch_fixture_asset,
        "0.4.7",
        "52",
    ),
    "missing its unique authoritative appcast.xml",
    "identity verifier tolerated a hole in the authoritative build ledger",
)

for distro in ("debian", "ubuntu", "kali"):
    require(
        workflow,
        f'guest/desktop/build.sh arm64 "$distro"',
        f"release workflow does not build the {distro} desktop from its commit",
    )
    require(
        workflow,
        f"guest/out/dory-desktop-{distro}-rootfs-arm64.ext4.zst",
        f"same-commit guest artifact omits the {distro} desktop",
    )
    require(
        workflow,
        f'guest/desktop/verify-build.sh arm64 "$distro"',
        f"release candidate does not verify the {distro} desktop",
    )
require(workflow, "guest/out/Image-desktop.zst", "same-commit guest artifact omits the desktop kernel")
for mesa_artifact in (
    "guest/out/dory-mesa-venus-arm64.tar.zst",
    "guest/out/dory-mesa-venus-build-arm64.stamp",
):
    require(
        guest_upload,
        mesa_artifact,
        f"same-commit guest artifact omits required Mesa payload {mesa_artifact}",
    )
require(
    guest_download_verification,
    "guest/mesa/verify-build.sh arm64",
    "downloaded guest payload does not independently verify its exact Mesa runtime",
)
require(
    workflow,
    "DORY_KERNEL_PROFILE=accelerated-desktop guest/kernel/verify-build.sh arm64",
    "release candidate does not verify its desktop kernel",
)
require(
    workflow,
    "DORY_RELEASE_DESKTOP_KERNEL: ${{ github.workspace }}/guest/out/Image-desktop",
    "physical release gate does not receive its same-commit desktop kernel",
)
require(
    workflow,
    "DORY_RELEASE_COMPONENT_DIR: ${{ github.workspace }}/release-build/components/arm64",
    "physical release gate does not receive its signed component candidate",
)
live_smoke = Path("scripts/release-candidate-live-smoke.sh").read_text(encoding="utf-8")
desktop_gate_path = Path("scripts/desktop-linux-live-gate.sh")
if not desktop_gate_path.stat().st_mode & 0o100:
    raise SystemExit("release workflow contract: desktop live gate is not executable")
desktop_gate = desktop_gate_path.read_text(encoding="utf-8")
require(
    live_smoke,
    "scripts/desktop-linux-live-gate.sh",
    "physical release smoke does not boot and exercise the managed desktops",
)
for distro in ("debian", "ubuntu", "kali"):
    require(
        live_smoke,
        f'--{distro}-rootfs "$DESKTOP_{distro.upper()}_ROOTFS"',
        f"physical desktop gate omits {distro}",
    )
    require(
        live_smoke,
        f'--{distro}-update "$DESKTOP_{distro.upper()}_UPDATE"',
        f"physical desktop gate omits the {distro} in-place update payload",
    )
for proof in (
    "browser-running",
    "grep -q 'capture' /proc/asound/pcm",
    "grep -q 'playback' /proc/asound/pcm",
    "persistence-pass",
    "Dory Wired",
    "com.apple.security.device.audio-input",
    'grep -F "$VMM"',
    "machine desktop-update",
    'body.get("snapshotID")',
    '"provenance": "verified-update-bundle"',
    'machine snapshot "$machine"',
    'machine restore-snapshot "$machine"',
    "recovery-exact-bytes-restored",
    "restore reused the snapshot's stale launch plan",
    "snapshot_restore_exact_bytes=PASS",
):
    require(desktop_gate, proof, f"desktop live gate omits required proof: {proof}")

require(candidate, "release-build/components/arm64/*", "candidate omits component payloads")
require(
    release_script,
    "public component publication is blocked: no physical Linux VM campaign producer is wired after immutable candidate assembly and SBOM generation",
    "public component publication is not fail-closed on the missing physical producer",
)
require(
    release_script,
    "$BUILD_DIR/component-candidate-verification.receipt",
    "local component candidate assembly is not independently verified",
)
if "DORY_COMPONENT_QUALIFICATION_DIR" in workflow:
    raise SystemExit(
        "release workflow contract: workflow accepts pre-candidate component qualification evidence"
    )
if "scripts/build-components.py finalize" in release_script:
    raise SystemExit(
        "release workflow contract: monolithic release script finalizes before a post-candidate physical producer exists"
    )
release_execution = release_script.split(
    'if [ "${DORY_RELEASE_SOURCE_ONLY:-0}" = "1" ]; then', 1
)[1]
preflight_offset = release_execution.find("\npreflight_release\n")
assemble_offset = release_execution.find("scripts/build-components.py assemble")
verify_offset = release_execution.find("scripts/build-components.py verify-candidate")
if min(preflight_offset, assemble_offset, verify_offset) < 0:
    raise SystemExit("release workflow contract: release component/preflight orchestration is incomplete")
if not preflight_offset < assemble_offset < verify_offset:
    raise SystemExit(
        "release workflow contract: release preflight, candidate assembly, and candidate verification are out of order"
    )
require(
    component_tests,
    "dummy pre-candidate evidence bypassed the public stop line",
    "component preflight contract does not reject synthetic pre-candidate evidence",
)
require(
    component_tests,
    "pre-candidate or synthetic qualification evidence cannot authorize schema-2 finalization",
    "component preflight contract does not verify the stop-line reason",
)
require(
    component_tests,
    "public component stop line blocked a local non-public build",
    "component preflight contract does not preserve local non-public release builds",
)
require(
    workflow,
    "DORY_COMPONENT_CATALOG_SCHEMA: '2'",
    "signed release build does not stamp component catalog schema 2 into the appcast",
)
require(publication, "release-build/components/arm64/*", "GitHub release omits component payloads")
for name in ("catalog.json", "catalog.json.sha256", "catalog.json.sig"):
    require(publication, f"release-build/components/arm64/{name}", f"metadata artifact omits {name}")
    require(pages, f"component-catalog-artifact/{name}", f"Pages does not deploy {name}")
    require(pages, f"live/components/arm64/{name}", f"Pages does not verify live {name}")
    require(pages_workflow, name, f"normal Pages deploy does not enumerate live {name}")
require(
    pages_workflow,
    ".github/scripts/verify-pages-release-metadata.py",
    "normal Pages deploy does not use the shared release metadata verifier",
)
require(
    pages,
    ".github/scripts/verify-pages-release-metadata.py",
    "release-specific Pages deploy bypasses the shared release metadata verifier",
)
require(pages_verifier_source, '"openssl",\n                    "pkeyutl",\n                    "-verify"', "Pages verifier does not invoke Ed25519 verification for Sparkle")
require(pages_verifier_source, '"-in",\n                    str(update_path)', "Sparkle verification is not over the authoritative update archive")
require(pages_verifier_source, "appcast_bytes == authoritative", "Pages verifier does not bind appcast bytes to the exact release asset")
require(pages_verifier_source, "digest == f\"sha256:{actual}\"", "Pages verifier does not authenticate authoritative GitHub assets")
require(pages_verifier_source, "self.stable_ledger()", "Pages verifier does not compare against all stable release maxima")
require(pages_verifier_source, "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4=", "Pages verifier does not pin the production key")
require(pages_verifier_source, "catalog JSON repeats key", "Pages verifier does not reject duplicate catalog keys")
require(pages_verifier_source, "appcast and catalog versions differ", "Pages verifier does not bind appcast and catalog release identity")
require(pages_verifier_source, "Dory-{version}-app-update.zip", "Pages verifier does not constrain the Sparkle enclosure to the release asset")
require(pages_verifier_source, "equal release identity has two different signed metadata transactions", "equal release identity can preserve different bytes")
normal_build = pages_workflow.split("      - run: npm run build", 1)[1].split(
    "      - uses: actions/configure-pages", 1
)[0]
require(
    normal_build,
    "cmp website/public/appcast.xml docs-build/appcast.xml",
    "normal Pages build does not compare appcast.xml in its final artifact",
)
require(
    normal_build,
    "for name in catalog.json catalog.json.sha256 catalog.json.sig; do",
    "normal Pages build does not enumerate the complete signed catalog transaction",
)
require(
    normal_build,
    'cmp "website/public/components/arm64/$name" "docs-build/components/arm64/$name"',
    "normal Pages build does not compare every signed catalog file in its final artifact",
)
require(
    normal_build,
    'verify docs-build docs-build',
    "normal Pages build does not rerun signature and appcast/catalog binding verification",
)
post_deploy = pages_workflow.split(
    "      - name: Verify all live signed metadata converges to the deployed transaction", 1
)[1]
for relative in (
    "appcast.xml",
    "components/arm64/catalog.json",
    "components/arm64/catalog.json.sha256",
    "components/arm64/catalog.json.sig",
):
    require(
        post_deploy,
        f'docs-build/{relative}',
        f"normal Pages deploy does not prove live {relative} converged byte-for-byte",
    )
require(post_deploy, 'verify "$live" deployed', "post-deploy metadata is not cryptographically reverified")

pages_verifier = load_module(pages_verifier_path, "dory_pages_metadata_contract")
with tempfile.TemporaryDirectory(prefix="dory-pages-contract-") as temporary:
    temporary_root = Path(temporary)
    checked_root = temporary_root / "checked"
    shutil.copytree("website/public", checked_root)
    authoritative_appcast = (checked_root / "appcast.xml").read_bytes()

    def exact_fixture_authority(version, raw, signature, enclosure):
        if version != "0.4.5" or raw != authoritative_appcast:
            raise SystemExit("fixture appcast differs from authoritative release bytes")
        if len(signature) != 64 or enclosure.get("length") != "237419015":
            raise SystemExit("fixture Sparkle envelope is invalid")

    pages_verifier.verify_root(checked_root, "contract-fixture", exact_fixture_authority)

    catalog_tamper_root = temporary_root / "catalog-tamper"
    shutil.copytree(checked_root, catalog_tamper_root)
    catalog_path = catalog_tamper_root / "components" / "arm64" / "catalog.json"
    catalog_path.write_bytes(catalog_path.read_bytes() + b"\n")
    expect_failure(
        lambda: pages_verifier.verify_root(
            catalog_tamper_root, "catalog-tamper", exact_fixture_authority
        ),
        "does not authenticate catalog.json",
        "real Pages verifier accepted catalog tampering",
    )

    appcast_tamper_root = temporary_root / "appcast-tamper"
    shutil.copytree(checked_root, appcast_tamper_root)
    appcast_path = appcast_tamper_root / "appcast.xml"
    zero_signature = base64.b64encode(bytes(64))
    tampered_appcast, replacements = re.subn(
        rb'sparkle:edSignature="[^"]+"',
        b'sparkle:edSignature="' + zero_signature + b'"',
        appcast_path.read_bytes(),
        count=1,
    )
    if replacements != 1:
        raise SystemExit("release workflow contract: could not construct Sparkle tamper fixture")
    appcast_path.write_bytes(tampered_appcast)
    expect_failure(
        lambda: pages_verifier.verify_root(
            appcast_tamper_root, "appcast-tamper", exact_fixture_authority
        ),
        "differs from authoritative release bytes",
        "Pages verifier accepted a shape-correct random Sparkle signature",
    )
    expect_failure(
        lambda: pages_verifier.preserve_metadata(
            appcast_tamper_root, checked_root, lambda version, raw, signature, enclosure: None
        ),
        "equal release identity has two different signed metadata transactions",
        "Pages preservation accepted two byte-distinct equal-identity transactions",
    )


def pages_authority_fixture(releases):
    serializable = []
    appcasts = {}
    for release in releases:
        release_copy = dict(release)
        copied_assets = []
        for asset in release.get("assets", []):
            asset_copy = dict(asset)
            fixture = asset_copy.pop("fixture", None)
            if isinstance(fixture, bytes):
                appcasts[release["tag_name"][1:]] = fixture
            copied_assets.append(asset_copy)
        release_copy["assets"] = copied_assets
        serializable.append(release_copy)
    authority = pages_verifier.GitHubReleaseAuthority.__new__(
        pages_verifier.GitHubReleaseAuthority
    )
    authority.repository = "Augani/dory"
    authority.token = "fixture"
    authority.cache = {}
    authority.appcast_cache = {}
    authority.ledger = None
    authority.request = lambda url, api, destination=None: json.dumps(serializable).encode(
        "utf-8"
    )
    authority.small_asset_bytes = lambda asset, version, name: appcasts[version]
    return authority


nonlatest_authority = pages_authority_fixture(
    [fixture_release("0.4.5", 49), fixture_release("0.5.0", 51)]
)
if nonlatest_authority.stable_ledger() != ((0, 5, 0), 51):
    raise SystemExit(
        "release workflow contract: Pages authority trusts release order/latest instead of maxima"
    )
missing_appcast_authority = pages_authority_fixture(
    [fixture_release("0.4.5", 49), fixture_release("0.5.0", None)]
)
expect_failure(
    missing_appcast_authority.stable_ledger,
    "lacks one appcast.xml",
    "Pages authority tolerated a hole in the stable appcast ledger",
)

if "softprops/action-gh-release" in publication:
    raise SystemExit(
        "release workflow contract: mutable find-or-update release action remains in publication"
    )
require(
    publication,
    "git fetch --force origin main",
    "publication does not refresh main immediately before creating public state",
)
require(
    publication,
    'test "$GITHUB_SHA" = "$(git rev-parse origin/main)"',
    "publication accepts a stale qualified commit after main advances",
)
require(
    publication,
    ".github/scripts/verify-release-identity.py",
    "publication does not revalidate complete release history after long-running gates",
)
require(
    publication,
    ".github/scripts/publish-github-release.py",
    "publication does not use the create-only private release transaction",
)
require(
    publication,
    "RELEASE_ID: ${{ steps.published_release.outputs.id }}",
    "post-publication verification is not bound to the newly created release ID",
)
require(release_publisher_source, '"POST",\n            "git/refs"', "publisher does not create the tag with create-only API semantics")
require(release_publisher_source, '"draft": True', "publisher exposes an incomplete release")
require(release_publisher_source, "expected_status=201", "publisher does not require GitHub create semantics")
require(release_publisher_source, 'body={"draft": False}', "publisher does not publish the exact verified draft")
require(release_publisher_source, "actual_assets == expected_assets", "publisher does not verify the exact private asset set")
require(release_publisher_source, "release_asset_state(public_release) == expected_assets", "publisher does not reverify assets after publication")
require(release_publisher_source, "exact_ref_target(github, tag) == arguments.source_commit", "publisher does not bind the release tag to the qualified source")
require(release_publisher_source, "revalidate_publication_authority(", "publisher does not revalidate main/history after uploading the private draft")
require(release_publisher_source, "Automatic GitHub cleanup is disabled", "publisher does not explain failed private state reconciliation")
if 'github.delete(' in release_publisher_source or '"DELETE"' in release_publisher_source:
    raise SystemExit(
        "release workflow contract: failure cleanup can destructively race another publisher"
    )

draft_verified_offset = release_publisher_source.find("actual_assets == expected_assets")
authority_recheck_offset = release_publisher_source.rfind("revalidate_publication_authority(")
publish_offset = release_publisher_source.find('"PATCH", f"releases/{release_id}"')
if min(draft_verified_offset, authority_recheck_offset, publish_offset) < 0:
    raise SystemExit("release workflow contract: private publication transaction is incomplete")
if not draft_verified_offset < authority_recheck_offset < publish_offset:
    raise SystemExit(
        "release workflow contract: main/history is not revalidated after upload and before publish"
    )

release_publisher = load_module(release_publisher_path, "dory_github_release_publisher_contract")
with tempfile.TemporaryDirectory(prefix="dory-release-publisher-contract-") as temporary:
    upload_fixture = Path(temporary) / "asset.zip"
    upload_fixture.write_bytes(b"release asset fixture")
    github_fixture = release_publisher.GitHub("Augani/dory", "fixture-token")
    with upload_fixture.open("rb") as handle:
        expect_failure(
            lambda: github_fixture.upload(
                "https://uploads.github.com/repos/Augani/dory/releases/999/assets{?name,label}",
                123,
                "asset.zip",
                handle,
                upload_fixture.stat().st_size,
            ),
            "non-canonical release upload URL",
            "publisher accepted an upload URL for a different release ID",
        )


class InterveningReleaseFixture:
    def release_for_tag(self, tag):
        return {"id": 9001, "tag_name": tag, "draft": False}

    def json_request(self, method, path):
        return {"object": {"type": "commit", "sha": "0" * 40}}


intervening_fixture = InterveningReleaseFixture()
cleanup_output = io.StringIO()
with contextlib.redirect_stderr(cleanup_output):
    release_publisher.report_unpublished_state(
        intervening_fixture,
        "v0.4.6",
        "0" * 40,
        None,
    )
if "Automatic GitHub cleanup is disabled" not in cleanup_output.getvalue():
    raise SystemExit("release workflow contract: failed publication does not fail closed")
if "release_id=9001" not in cleanup_output.getvalue():
    raise SystemExit("release workflow contract: failed publication omits intervening release ID")

require(bump, "needs: [publish_release, publish-pages]", "Homebrew can publish before assets/Pages")
require(bump, "git add Casks/dory.rb", "in-repository Homebrew cask is not updated")
require(bump, "git@github.com:Augani/homebrew-dory.git", "standalone Homebrew tap is not updated")
require(bump, 'grep -qF "sha256 \\"$S\\"" <<< "$remote"', "standalone tap checksum is not verified")
require(final, "needs: [publish_release, publish-pages, bump-cask]", "no terminal publication gate")
require(final, ".github/scripts/verify-public-release.py", "terminal publication verifier is not run")
require(
    pages,
    'componentCatalogSchema\") == \"2\"',
    "published appcast does not require component catalog schema 2",
)

require(publisher, 'gh workflow run "$WORKFLOW"', "publisher does not dispatch the release workflow")
require(publisher, "CURRENT_PROJECT_VERSION", "publisher does not parse the authoritative project build")
require(publisher, '--field "build=$PROJECT_BUILD"', "publisher does not dispatch the project build")
require(publisher, ".github/scripts/verify-release-identity.py", "publisher does not enforce complete-history monotonic identity")
require(
    publisher,
    "'^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$'",
    "publisher accepts leading-zero semantic versions",
)
require(publisher, "case \"$tag_status\" in", "publisher treats every git lookup failure as tag absence")
require(publisher, "could not prove release v$VERSION is absent", "publisher treats ambiguous GitHub responses as absence")
require(publisher, 'gh run watch "$RUN_ID"', "publisher does not wait for the complete workflow")
require(publisher, ".github/scripts/verify-public-release.py", "publisher skips independent live verification")

print("release workflow contract: PASS")
