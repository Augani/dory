#!/usr/bin/env python3
"""Static regression contract for the one-command public release path."""

from pathlib import Path


def require(text: str, value: str, message: str) -> None:
    if value not in text:
        raise SystemExit(f"release workflow contract: {message}")


workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
pages_workflow = Path(".github/workflows/pages.yml").read_text(encoding="utf-8")
publisher = Path("scripts/publish-release.sh").read_text(encoding="utf-8")

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
):
    require(desktop_gate, proof, f"desktop live gate omits required proof: {proof}")

require(candidate, "release-build/components/arm64/*", "candidate omits component payloads")
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
require(publisher, 'gh run watch "$RUN_ID"', "publisher does not wait for the complete workflow")
require(publisher, ".github/scripts/verify-public-release.py", "publisher skips independent live verification")

print("release workflow contract: PASS")
