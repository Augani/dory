#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-sparkle-evidence-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCE_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SPARKLE_REVISION="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TEAM="864H636QW4"
VERSION="1.2.3"
BUILD="42"
for artifact in update.zip appcast.xml release-manifest.json gate.sh; do
  printf 'fixture:%s\n' "$artifact" > "$TMP/$artifact"
done
python3 - "$TMP/sbom.json" "$TMP/Package.resolved" "$SPARKLE_REVISION" <<'PY'
import json
import sys

sbom, resolved, revision = sys.argv[1:]
with open(sbom, "w", encoding="utf-8") as handle:
    json.dump({
        "metadata": {
            "component": {
                "properties": [{
                    "name": "dev.dory.app.tree.sha256",
                    "value": "c" * 64,
                }]
            }
        }
    }, handle)
with open(resolved, "w", encoding="utf-8") as handle:
    json.dump({
        "pins": [{
            "identity": "sparkle",
            "state": {"version": "2.9.4", "revision": revision},
        }]
    }, handle)
PY

write_manifest() {
  python3 - "$TMP/manifest.txt" "$TMP" "$SOURCE_COMMIT" "$SPARKLE_REVISION" \
    "$TEAM" "$VERSION" "$BUILD" <<'PY'
import hashlib
import pathlib
import sys

output, root_value, source, sparkle_revision, team, version, build = sys.argv[1:]
root = pathlib.Path(root_value)


def digest(name):
    return hashlib.sha256((root / name).read_bytes()).hexdigest()


rows = {
    "status": "PASS",
    "release_qualifying": "true",
    "run_id": "20260714T120000Z-1234",
    "workflow_run_id": "5678",
    "workflow_run_attempt": "2",
    "source_commit": source,
    "candidate_version": version,
    "candidate_build": build,
    "previous_fixture_build": str(int(build) - 1),
    "candidate_tree_sha256": "c" * 64,
    "update_zip_sha256": digest("update.zip"),
    "appcast_sha256": digest("appcast.xml"),
    "release_manifest_sha256": digest("release-manifest.json"),
    "sbom_sha256": digest("sbom.json"),
    "gate_script_sha256": digest("gate.sh"),
    "sparkle_version": "2.9.4",
    "sparkle_revision": sparkle_revision,
    "sparkle_cli_sha256": "d" * 64,
    "sparkle_framework_sha256": "e" * 64,
    "candidate_team": team,
    "sparkle_cli_team": team,
    "sparkle_autoupdate_team": team,
    "old_pid": "100",
    "relaunched_pid": "101",
    "old_process_terminated": "PASS",
    "different_relaunch_pid": "PASS",
    "loopback_appcast_fetched": "PASS",
    "exact_update_archive_fetched": "PASS",
    "ed25519_archive_verified": "PASS",
    "installed_tree_exact": "PASS",
    "installed_notarization_ticket": "PASS",
    "installed_gatekeeper": "PASS",
    "application_support_preserved": "PASS",
    "preferences_preserved": "PASS",
    "atomic_install_swap": "PASS",
    "sparkle_fallback_restoration_verified": "PASS",
    "qualification_fixture_restored": "PASS",
    "initial_clean_user_state_restored": "PASS",
    "completed_epoch": "1784030400",
}
with open(output, "w", encoding="utf-8") as handle:
    for key, value in rows.items():
        handle.write(f"{key}={value}\n")
PY
}

verify() {
  "$ROOT/scripts/verify-sparkle-install-evidence.py" \
    --manifest "$TMP/manifest.txt" \
    --app-update "$TMP/update.zip" \
    --appcast "$TMP/appcast.xml" \
    --release-manifest "$TMP/release-manifest.json" \
    --sbom "$TMP/sbom.json" \
    --gate-script "$TMP/gate.sh" \
    --package-resolved "$TMP/Package.resolved" \
    --candidate-team "$TEAM" \
    --source-commit "$SOURCE_COMMIT" \
    --run-id 5678 \
    --run-attempt 2 \
    --version "$VERSION" \
    --build "$BUILD"
}

write_manifest
verify >/dev/null

sed -i '' 's/atomic_install_swap=PASS/atomic_install_swap=FAIL/' "$TMP/manifest.txt"
if verify > "$TMP/invalid-pass.out" 2>&1; then
  echo "test-sparkle-install-evidence: accepted failed atomic replacement" >&2
  exit 1
fi
grep -Fq 'Sparkle evidence mismatch for atomic_install_swap' "$TMP/invalid-pass.out"

write_manifest
printf 'status=PASS\n' >> "$TMP/manifest.txt"
if verify > "$TMP/duplicate.out" 2>&1; then
  echo "test-sparkle-install-evidence: accepted duplicate evidence" >&2
  exit 1
fi
grep -Fq 'malformed Sparkle evidence' "$TMP/duplicate.out"

write_manifest
sed -i '' 's/relaunched_pid=101/relaunched_pid=100/' "$TMP/manifest.txt"
if verify > "$TMP/reused-pid.out" 2>&1; then
  echo "test-sparkle-install-evidence: accepted a reused app PID" >&2
  exit 1
fi
grep -Fq 'reused the previous app PID' "$TMP/reused-pid.out"

write_manifest
printf 'tampered\n' >> "$TMP/update.zip"
if verify > "$TMP/tampered.out" 2>&1; then
  echo "test-sparkle-install-evidence: accepted a different update archive" >&2
  exit 1
fi
grep -Fq 'Sparkle evidence mismatch for update_zip_sha256' "$TMP/tampered.out"

echo "test-sparkle-install-evidence: PASS"
