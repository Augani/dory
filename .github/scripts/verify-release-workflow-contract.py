#!/usr/bin/env python3
"""Static regression contract for the one-command public release path."""

from pathlib import Path


def require(text: str, value: str, message: str) -> None:
    if value not in text:
        raise SystemExit(f"release workflow contract: {message}")


workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
publisher = Path("scripts/publish-release.sh").read_text(encoding="utf-8")

candidate = workflow.split("      - name: Stage immutable public candidate", 1)[1].split(
    "\n  homebrew_install_certification:", 1
)[0]
publication = workflow.split("  publish_release:", 1)[1].split("\n  publish-pages:", 1)[0]
pages = workflow.split("  publish-pages:", 1)[1].split("\n  # Keeps the Homebrew", 1)[0]
bump = workflow.split("  bump-cask:", 1)[1].split("\n  verify-public-release:", 1)[0]
final = workflow.split("  verify-public-release:", 1)[1]

require(candidate, "release-build/components/arm64/*", "candidate omits component payloads")
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

require(publisher, 'gh workflow run "$WORKFLOW"', "publisher does not dispatch the release workflow")
require(publisher, 'gh run watch "$RUN_ID"', "publisher does not wait for the complete workflow")
require(publisher, ".github/scripts/verify-public-release.py", "publisher skips independent live verification")

print("release workflow contract: PASS")
