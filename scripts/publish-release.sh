#!/bin/bash
# The only supported entrypoint for publishing a public Dory release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPOSITORY="Augani/dory"
WORKFLOW="release.yml"

usage() {
  cat <<'EOF'
Usage: scripts/publish-release.sh VERSION

Dispatches the complete release workflow from an exact, clean main branch and waits until GitHub
assets, Pages update metadata, the in-repository cask, and the Augani/homebrew-dory tap have all
been published and independently verified.

Example:
  scripts/publish-release.sh 0.4.5
EOF
}

die() {
  echo "release publication error: $*" >&2
  exit 1
}

if [ "${1:-}" = "--check" ]; then
  [ "$#" -eq 1 ] || { usage >&2; exit 64; }
  exec python3 .github/scripts/verify-release-workflow-contract.py
fi

[ "$#" -eq 1 ] || { usage >&2; exit 64; }
VERSION="$1"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "VERSION must be a stable semantic version such as 0.4.5"

for command in git gh python3; do
  command -v "$command" >/dev/null || die "$command is required"
done
gh auth status >/dev/null 2>&1 || die "authenticate first with: gh auth login"
[ "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" = "$REPOSITORY" ] \
  || die "this checkout is not $REPOSITORY"

python3 .github/scripts/verify-release-workflow-contract.py
git fetch --quiet origin main
[ "$(git branch --show-current)" = main ] || die "public releases must start from main"
[ -z "$(git status --porcelain --untracked-files=normal)" ] \
  || die "the working tree must be clean"
HEAD_SHA="$(git rev-parse HEAD)"
[ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] \
  || die "local main must exactly match origin/main"

PROJECT_VERSIONS="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' \
  Dory.xcodeproj/project.pbxproj | sort -u)"
[ "$PROJECT_VERSIONS" = "$VERSION" ] \
  || die "project MARKETING_VERSION is '${PROJECT_VERSIONS:-missing}', expected $VERSION"

if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
  die "tag v$VERSION already exists"
fi
if gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
  die "release v$VERSION already exists"
fi

BEFORE_RUN="$(gh run list --repo "$REPOSITORY" --workflow "$WORKFLOW" \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
echo "Dispatching the complete Dory $VERSION release from $HEAD_SHA..."
gh workflow run "$WORKFLOW" --repo "$REPOSITORY" --ref main --field "version=$VERSION"

RUN_ID=""
for attempt in $(seq 1 30); do
  RUN_ID="$(gh run list --repo "$REPOSITORY" --workflow "$WORKFLOW" \
    --event workflow_dispatch --branch main --limit 20 --json databaseId,headSha \
    --jq "map(select(.databaseId > $BEFORE_RUN and .headSha == \"$HEAD_SHA\")) | sort_by(.databaseId) | last | .databaseId // empty")"
  [ -n "$RUN_ID" ] && break
  [ "$attempt" -eq 30 ] || sleep 2
done
[ -n "$RUN_ID" ] || die "could not resolve the newly dispatched workflow run"

RUN_URL="https://github.com/$REPOSITORY/actions/runs/$RUN_ID"
echo "Release workflow: $RUN_URL"
gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status

PRIMARY_SHA256="$(gh api "repos/$REPOSITORY/releases/tags/v$VERSION" \
  --jq ".assets[] | select(.name == \"Dory-$VERSION.zip\") | .digest" \
  | sed 's/^sha256://')"
[ -n "$PRIMARY_SHA256" ] || die "published primary ZIP has no GitHub SHA-256 digest"

GH_TOKEN="$(gh auth token)" python3 .github/scripts/verify-public-release.py \
  --repository "$REPOSITORY" \
  --version "$VERSION" \
  --source-commit "$HEAD_SHA" \
  --expected-primary-sha256 "$PRIMARY_SHA256"

echo "Dory $VERSION is completely published: https://github.com/$REPOSITORY/releases/tag/v$VERSION"
