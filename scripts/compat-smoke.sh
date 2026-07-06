#!/bin/bash
# Compatibility CI harness (Track 4).
#
# Two tiers:
#   1. Structural — every registered tool is checked and every recipe carries a verification
#      command. Needs no engine, so it runs in plain CI to guard the compatibility surface.
#   2. Engine-backed — when a live Dory socket is present (release readiness), run the real
#      docker/act smoke tests against it. Absent an engine or a tool, that tier is skipped, never
#      failed, so this script is safe to run anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

DOCTOR="${DORY_DOCTOR_BIN:-scripts/dory-doctor}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

"$DOCTOR" compat --recipe --json > "$WORKDIR/recipes.json"
python3 - "$WORKDIR/recipes.json" <<'PY'
import json
import sys

tools = json.load(open(sys.argv[1], encoding="utf-8"))["tools"]
assert tools, "compat exposed no recipes"
for name, recipe in tools.items():
    assert recipe.get("title"), f"{name}: recipe has no title"
    assert recipe.get("steps"), f"{name}: recipe has no steps"
    assert recipe.get("verify"), f"{name}: recipe has no verification command"
print(f"compat-smoke: {len(tools)} recipes, all carry a verification command")
PY

"$DOCTOR" compat --json > "$WORKDIR/compat.json" || true
python3 - "$WORKDIR/compat.json" <<'PY'
import json
import sys

results = json.load(open(sys.argv[1], encoding="utf-8"))["results"]
checked = {r["id"].split(".")[1] for r in results}
required = {"docker", "compose", "testcontainers", "act", "kubernetes", "vscode", "cursor", "supabase", "localstack"}
missing = required - checked
assert not missing, f"compat did not check: {sorted(missing)}"
for result in results:
    assert result["status"] in {"pass", "warn", "fail", "skip"}, result
    if result["status"] in {"fail", "warn"}:
        assert result.get("action") or result.get("detail"), f"{result['id']} has no actionable message"
print(f"compat-smoke: checked {len(checked)} tools, non-pass results are all actionable")
PY

ENGINE_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
if [ -S "$ENGINE_SOCK" ] && curl -fsS --max-time 3 --unix-socket "$ENGINE_SOCK" http://d/_ping >/dev/null 2>&1; then
  export DOCKER_HOST="unix://$ENGINE_SOCK"
  DOCKER_BIN="${DORY_DOCKER_BIN:-$(command -v docker || echo docker)}"

  "$DOCKER_BIN" run --rm alpine:latest true
  echo "compat-smoke: docker run against the Dory socket OK (Testcontainers/LocalStack host detection path)"

  if command -v act >/dev/null 2>&1; then
    ACT_DIR="$WORKDIR/act"
    mkdir -p "$ACT_DIR/.github/workflows"
    cat > "$ACT_DIR/.github/workflows/smoke.yml" <<'YAML'
name: smoke
on: [push]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML
    ( cd "$ACT_DIR" && act --container-daemon-socket "unix://$ENGINE_SOCK" -l >/dev/null )
    echo "compat-smoke: act enumerated workflows against the Dory socket"
  else
    echo "compat-smoke: act not installed; skipped its engine smoke"
  fi
else
  echo "compat-smoke: no live Dory socket; ran structural checks only (CI mode)"
fi

echo "compat-smoke: PASS"
