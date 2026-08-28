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

Dispatches the complete release workflow from an exact, clean main branch using the project's
unique CURRENT_PROJECT_VERSION as its monotonic build. It waits until GitHub assets, Pages update
metadata, the in-repository cask, and the Augani/homebrew-dory tap have all been published and
independently verified.

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
printf '%s\n' "$VERSION" \
  | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || die "VERSION must be a stable semantic version such as 0.4.5"

for command in curl git gh python3; do
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
PROJECT_BUILD="$(sed -n -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' \
  Dory.xcodeproj/project.pbxproj | sort -u)"
case "$PROJECT_BUILD" in
  ''|0|0[0-9]*|*[!0-9]*)
    die "project CURRENT_PROJECT_VERSION must be one unique positive integer, found '${PROJECT_BUILD:-missing}'"
    ;;
esac

RELEASE_METADATA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-publish-release.XXXXXX")"
trap 'rm -rf "$RELEASE_METADATA_TMP"' EXIT
GH_TOKEN="$(gh auth token)" python3 .github/scripts/verify-release-identity.py \
  --repository "$REPOSITORY" \
  --project Dory.xcodeproj/project.pbxproj \
  --version "$VERSION" \
  --build "$PROJECT_BUILD"

set +e
git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" \
  >"$RELEASE_METADATA_TMP/tag-ref.txt" 2>"$RELEASE_METADATA_TMP/tag-ref.err"
tag_status=$?
set -e
case "$tag_status" in
  0) die "tag v$VERSION already exists" ;;
  2) ;;
  *) die "could not prove tag v$VERSION is absent: $(<"$RELEASE_METADATA_TMP/tag-ref.err")" ;;
esac

release_status="$(curl -sS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
  -H 'Accept: application/vnd.github+json' \
  -H "Authorization: Bearer $(gh auth token)" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -o "$RELEASE_METADATA_TMP/requested-release.json" -w '%{http_code}' \
  "https://api.github.com/repos/$REPOSITORY/releases/tags/v$VERSION")"
case "$release_status" in
  404) ;;
  200) die "release v$VERSION already exists" ;;
  *) die "could not prove release v$VERSION is absent (GitHub HTTP $release_status)" ;;
esac

BEFORE_RUN="$(gh run list --repo "$REPOSITORY" --workflow "$WORKFLOW" \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
echo "Dispatching the complete Dory $VERSION ($PROJECT_BUILD) release from $HEAD_SHA..."
gh workflow run "$WORKFLOW" --repo "$REPOSITORY" --ref main \
  --field "version=$VERSION" \
  --field "build=$PROJECT_BUILD"

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
