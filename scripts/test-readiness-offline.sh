#!/bin/bash
# Offline regression tests for readiness fail-closed accounting and the non-native Node fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n scripts/readiness.sh
bash -n scripts/nonnative-build-smoke.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/docker"

# Exploratory mode retains a visible skip for an unavailable requested engine, while strict mode
# turns the exact same prerequisite into a failure. No live engine is contacted.
PATH="$TMP/bin:/usr/bin:/bin" \
  READINESS_WORKDIR="$TMP/exploratory" \
  DORY_SOCK="$TMP/missing-dory.sock" \
  RUN_MEMORY=0 RUN_NONNATIVE_ARCH=0 \
  scripts/readiness.sh --engines dory > "$TMP/exploratory.log"
exploratory_results="$(find "$TMP/exploratory" -name results.tsv -type f -print -quit)"
grep -F $'SKIP\tdory\tall checks\tREQUIRED BUT UNAVAILABLE' "$exploratory_results" >/dev/null

if PATH="$TMP/bin:/usr/bin:/bin" \
  READINESS_WORKDIR="$TMP/strict" \
  DORY_SOCK="$TMP/missing-dory.sock" \
  RUN_MEMORY=0 RUN_NONNATIVE_ARCH=0 \
  scripts/readiness.sh --strict --engines dory > "$TMP/strict.log" 2>&1; then
  echo "strict readiness unexpectedly passed with a missing requested engine socket" >&2
  exit 1
fi
strict_results="$(find "$TMP/strict" -name results.tsv -type f -print -quit)"
strict_summary="$(find "$TMP/strict" -name summary.json -type f -print -quit)"
grep -F $'FAIL\tdory\tall checks\tSTRICT REQUIRED' "$strict_results" >/dev/null
python3 - "$strict_summary" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
assert summary["strict"] is True
assert summary["requiredUnavailable"] >= 1
assert summary["fail"] >= 1
PY

# Directly exercise the requested-probe path without a socket. In strict mode an unavailable
# enabled probe cannot be counted as a harmless skip.
READINESS_SOURCE_ONLY=1 READINESS_STRICT=1 READINESS_WORKDIR="$TMP/source" \
  bash -c '
    set --
    source scripts/readiness.sh
    required_unavailable_case dory "requested probe" "unsupported in fixture"
    test "$FAIL_COUNT" -eq 1
    test "$SKIP_COUNT" -eq 0
    grep -F "STRICT REQUIRED" "$RESULTS"
  ' >/dev/null

READINESS_SOURCE_ONLY=1 READINESS_STRICT=1 READINESS_WORKDIR="$TMP/coverage" \
  READINESS_REQUIRE_COMPETITOR=1 \
  bash -c '
    set --
    source scripts/readiness.sh
    host_guest_arch() { printf "%s\n" arm64; }
    record_external_coverage
    grep -F "same-host competitor correctness gate" "$RESULTS" | grep -F "STRICT REQUIRED — EXTERNAL GATE NOT COVERED"
  ' >/dev/null

# Generate and execute the deterministic package fixture locally when Node/npm are available. The
# Docker smoke uses the same files under the requested non-native platform.
DORY_NONNATIVE_SMOKE_SOURCE_ONLY=1 FIXTURE_DIR="$TMP/node-fixture" \
  bash -c 'set --; source scripts/nonnative-build-smoke.sh; write_node_build_fixture "$FIXTURE_DIR"'
READINESS_SOURCE_ONLY=1 READINESS_WORKDIR="$TMP/readiness-source" \
  FIXTURE_DIR="$TMP/readiness-node-fixture" \
  bash -c 'set --; source scripts/readiness.sh; write_nonnative_node_fixture "$FIXTURE_DIR"'
diff -ru "$TMP/node-fixture" "$TMP/readiness-node-fixture"
grep -F '"build": "node scripts/build.mjs"' "$TMP/node-fixture/package.json" >/dev/null
grep -F '"test": "node --test test/*.test.mjs"' "$TMP/node-fixture/package.json" >/dev/null
grep -F 'npm ci --ignore-scripts --no-audit --no-fund' scripts/nonnative-build-smoke.sh >/dev/null
grep -F 'npm run build' scripts/nonnative-build-smoke.sh >/dev/null
grep -F 'npm test' scripts/nonnative-build-smoke.sh >/dev/null
grep -F 'npm ci --ignore-scripts --no-audit --no-fund' scripts/readiness.sh >/dev/null

if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  (
    cd "$TMP/node-fixture"
    npm ci --ignore-scripts --no-audit --no-fund >/dev/null
    npm run build >/dev/null
    EXPECTED_NODE_ARCH="$(node -p 'process.arch')" npm test >/dev/null
    node dist/app.mjs | grep -F "dory-nonnative-build-ok arch=$(node -p 'process.arch')" >/dev/null
  )
fi

echo "readiness offline tests: PASS"
