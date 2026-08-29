#!/bin/bash
# The single operator-facing entrypoint for Dory release work. Build, qualification, catalog,
# publication, Pages, and Homebrew implementations remain independently testable behind this
# command; release operators should not dispatch their workflows or call those internals directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

REPOSITORY="Augani/dory"
CANDIDATE_WORKFLOW="release-candidate.yml"
PUBLIC_WORKFLOW="release.yml"
RUN_ID=""
HEAD_SHA=""
PROJECT_BUILD=""
RELEASE_METADATA_TMP=""

cleanup() {
  if [ -n "$RELEASE_METADATA_TMP" ] && [ -d "$RELEASE_METADATA_TMP" ] \
      && [ ! -L "$RELEASE_METADATA_TMP" ]; then
    rm -rf "$RELEASE_METADATA_TMP"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  scripts/dory-release.sh check [VERSION]
  scripts/dory-release.sh candidate VERSION [--no-wait]
  scripts/dory-release.sh status [RUN_ID]
  scripts/dory-release.sh publish VERSION [--no-wait]

Actions:
  check       Verify the release pipeline contract. With VERSION, also prove that the clean,
              exact main checkout has the matching version/build and no existing release.
  candidate   Build every modular component, Developer ID-sign, notarize, staple, and stage one
              private immutable candidate. Waits and downloads it to release-build/candidates/.
  status      Show one run, or the latest private-candidate and public-release runs.
  publish     Run the complete qualification-gated GitHub release, Pages, appcast, component
              catalog, and Homebrew publication. Waits and independently verifies the result.

Examples:
  scripts/dory-release.sh check 0.4.6
  scripts/dory-release.sh candidate 0.4.6
  scripts/dory-release.sh status
  scripts/dory-release.sh publish 0.4.6

Only candidate and publish mutate remote release state. --no-wait returns after dispatch and prints
the exact Actions URL. Public publication remains fail-closed on physical qualification evidence.
EOF
}

die() {
  echo "dory release: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

validate_version() {
  local version="$1"
  printf '%s\n' "$version" \
    | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || die "VERSION must be a stable semantic version such as 0.4.6"
}

verify_operator_context() {
  local version="$1" project_versions tag_status release_status
  validate_version "$version"
  for command in curl git gh python3; do require_command "$command"; done
  gh auth status >/dev/null 2>&1 || die "authenticate first with: gh auth login"
  [ "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" = "$REPOSITORY" ] \
    || die "this checkout is not $REPOSITORY"

  python3 .github/scripts/verify-release-workflow-contract.py
  git fetch --quiet origin main
  [ "$(git branch --show-current)" = main ] || die "release actions must start from main"
  [ -z "$(git status --porcelain --untracked-files=normal)" ] \
    || die "the working tree must be clean"
  HEAD_SHA="$(git rev-parse HEAD)"
  [ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] \
    || die "local main must exactly match origin/main"

  project_versions="$(sed -n -E \
    's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' \
    Dory.xcodeproj/project.pbxproj | sort -u)"
  [ "$project_versions" = "$version" ] \
    || die "project MARKETING_VERSION is '${project_versions:-missing}', expected $version"
  PROJECT_BUILD="$(sed -n -E \
    's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' \
    Dory.xcodeproj/project.pbxproj | sort -u)"
  case "$PROJECT_BUILD" in
    ''|0|0[0-9]*|*[!0-9]*)
      die "project CURRENT_PROJECT_VERSION must be one positive integer, found '${PROJECT_BUILD:-missing}'"
      ;;
  esac

  RELEASE_METADATA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-release-check.XXXXXX")"
  GH_TOKEN="$(gh auth token)" python3 .github/scripts/verify-release-identity.py \
    --repository "$REPOSITORY" \
    --project Dory.xcodeproj/project.pbxproj \
    --version "$version" \
    --build "$PROJECT_BUILD"

  set +e
  git ls-remote --exit-code --tags origin "refs/tags/v$version" \
    >"$RELEASE_METADATA_TMP/tag-ref.txt" 2>"$RELEASE_METADATA_TMP/tag-ref.err"
  tag_status=$?
  set -e
  case "$tag_status" in
    0) die "tag v$version already exists" ;;
    2) ;;
    *)
      local lookup_error
      lookup_error="$(<"$RELEASE_METADATA_TMP/tag-ref.err")"
      die "could not prove tag v$version is absent: $lookup_error"
      ;;
  esac

  release_status="$(curl -sS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $(gh auth token)" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "$RELEASE_METADATA_TMP/requested-release.json" -w '%{http_code}' \
    "https://api.github.com/repos/$REPOSITORY/releases/tags/v$version")"
  cleanup
  RELEASE_METADATA_TMP=""
  case "$release_status" in
    404) ;;
    200) die "release v$version already exists" ;;
    *) die "could not prove release v$version is absent (GitHub HTTP $release_status)" ;;
  esac
}

dispatch_workflow() {
  local workflow="$1" version="$2" before_run attempt
  before_run="$(gh run list --repo "$REPOSITORY" --workflow "$workflow" \
    --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
  gh workflow run "$workflow" --repo "$REPOSITORY" --ref main \
    --field "version=$version" \
    --field "build=$PROJECT_BUILD"

  for attempt in $(seq 1 30); do
    RUN_ID="$(gh run list --repo "$REPOSITORY" --workflow "$workflow" \
      --event workflow_dispatch --branch main --limit 20 --json databaseId,headSha \
      --jq "map(select(.databaseId > $before_run and .headSha == \"$HEAD_SHA\")) | sort_by(.databaseId) | last | .databaseId // empty")"
    [ -n "$RUN_ID" ] && break
    [ "$attempt" -eq 30 ] || sleep 2
  done
  [ -n "$RUN_ID" ] || die "could not resolve the newly dispatched $workflow run"
  echo "https://github.com/$REPOSITORY/actions/runs/$RUN_ID"
}

stage_candidate() {
  local version="$1" wait_mode="$2" run_attempt artifact_name destination
  verify_operator_context "$version"
  echo "Staging private Dory $version ($PROJECT_BUILD) candidate from $HEAD_SHA..."
  dispatch_workflow "$CANDIDATE_WORKFLOW" "$version"
  [ "$wait_mode" = wait ] || return 0
  gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status

  run_attempt="$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID" --jq .run_attempt)"
  artifact_name="dory-signed-release-candidate-$HEAD_SHA-$run_attempt"
  destination="$ROOT/release-build/candidates/$version-$HEAD_SHA-run-$RUN_ID"
  [ ! -e "$destination" ] || die "candidate destination already exists: $destination"
  mkdir -p "$destination"
  gh run download "$RUN_ID" --repo "$REPOSITORY" \
    --name "$artifact_name" --dir "$destination"
  echo "Private candidate downloaded to $destination"
  echo "It is not public. Install and physically qualify these exact bytes before publish."
}

publish_release() {
  local version="$1" wait_mode="$2" primary_sha256
  verify_operator_context "$version"
  echo "Publishing qualification-gated Dory $version ($PROJECT_BUILD) from $HEAD_SHA..."
  dispatch_workflow "$PUBLIC_WORKFLOW" "$version"
  [ "$wait_mode" = wait ] || return 0
  gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status

  primary_sha256="$(gh api "repos/$REPOSITORY/releases/tags/v$version" \
    --jq ".assets[] | select(.name == \"Dory-$version.zip\") | .digest" \
    | sed 's/^sha256://')"
  [ -n "$primary_sha256" ] || die "published primary ZIP has no GitHub SHA-256 digest"
  GH_TOKEN="$(gh auth token)" python3 .github/scripts/verify-public-release.py \
    --repository "$REPOSITORY" \
    --version "$version" \
    --source-commit "$HEAD_SHA" \
    --expected-primary-sha256 "$primary_sha256"
  echo "Dory $version is completely published: https://github.com/$REPOSITORY/releases/tag/v$version"
}

show_status() {
  local requested_run="${1:-}"
  require_command gh
  gh auth status >/dev/null 2>&1 || die "authenticate first with: gh auth login"
  if [ -n "$requested_run" ]; then
    printf '%s\n' "$requested_run" | grep -Eq '^[1-9][0-9]*$' \
      || die "RUN_ID must be a positive integer"
    gh run view "$requested_run" --repo "$REPOSITORY"
    return
  fi
  echo "Private signed candidates:"
  gh run list --repo "$REPOSITORY" --workflow "$CANDIDATE_WORKFLOW" --limit 5
  echo
  echo "Public releases:"
  gh run list --repo "$REPOSITORY" --workflow "$PUBLIC_WORKFLOW" --limit 5
}

ACTION="${1:-}"
case "$ACTION" in
  -h|--help|help) usage ;;
  check)
    [ "$#" -le 2 ] || { usage >&2; exit 64; }
    if [ "$#" -eq 2 ]; then
      verify_operator_context "$2"
      echo "Dory $2 ($PROJECT_BUILD) release preflight: PASS ($HEAD_SHA)"
    else
      python3 .github/scripts/verify-release-workflow-contract.py
    fi
    ;;
  candidate|publish)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 64; }
    wait_mode="wait"
    if [ "$#" -eq 3 ]; then
      [ "$3" = --no-wait ] || die "unknown option for $ACTION: $3"
      wait_mode="no-wait"
    fi
    if [ "$ACTION" = candidate ]; then
      stage_candidate "$2" "$wait_mode"
    else
      publish_release "$2" "$wait_mode"
    fi
    ;;
  status)
    [ "$#" -le 2 ] || { usage >&2; exit 64; }
    show_status "${2:-}"
    ;;
  '') usage >&2; exit 64 ;;
  *) die "unknown action: $ACTION (run scripts/dory-release.sh --help)" ;;
esac
