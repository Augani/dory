#!/bin/bash
# Static/offline contract plus exact interrupted-upgrade evidence verifier. With no arguments this
# runs hermetic source and CLI regressions. Evidence mode is intentionally fail-closed and is used
# by release qualification after a physical signed-candidate interruption campaign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage:
  scripts/transactional-upgrade-gate.sh
  scripts/transactional-upgrade-gate.sh --record PATH --interruption-evidence PATH --expect-state rolledBack|recoveryRequired

No arguments runs the hermetic transaction, appcast, rollback, and CLI contract checks.
Evidence mode verifies a retained exact-candidate interrupted-update result. It never performs or
simulates a release-qualifying interruption by itself.
EOF
}

fail() { echo "transactional upgrade gate failed: $*" >&2; exit 1; }

static_gate() {
  local tmp root transaction recovery
  for needle in \
    'dev.dory.upgrade.transaction' \
    'validateReadyToInstall' \
    'restoreConfigurationAndComponents' \
    'durableDataWasRolledBack' \
    'archive.signature' \
    'DoryUpgradeRollbackHelper.launch' \
    'runUpgradeSmokeTests' \
    'volume.marker' \
    'published.ports' \
    'kubernetes.api'; do
    grep -R -F "$needle" \
      Dory/App/Updater.swift Dory/Models/AppStore.swift \
      dory-core-swift/Sources/DoryOperations/DoryUpgradeTransaction.swift >/dev/null \
      || fail "source contract omits $needle"
  done
  grep -F 'try store.restoreConfigurationAndComponents(transactionID)' Dory/App/Updater.swift >/dev/null \
    || fail "configuration/component restore is not delegated until after the failed app exits"
  if grep -F 'try transactionStore.restoreConfigurationAndComponents(record.id)' Dory/App/Updater.swift >/dev/null; then
    fail "failed app can still restore preferences before terminating"
  fi
  grep -F 'to: .installing' Dory/App/Updater.swift >/dev/null \
    || fail "journal is not armed before Sparkle installation"
  grep -F 'DoryComponentSelectionSnapshot' dory-core-swift/Sources/DoryOperations/DoryComponents.swift >/dev/null \
    || fail "component generation rollback snapshot is missing"
  grep -F 'Set([installationName, priorInstallation].compactMap { $0 })' \
    dory-core-swift/Sources/DoryOperations/DoryComponents.swift >/dev/null \
    || fail "component store no longer retains a prior verified generation"

  python3 - <<'PY'
import xml.etree.ElementTree as ET

dory = "https://augani.github.io/dory/appcast"
items = ET.parse("website/public/appcast.xml").getroot().findall("./channel/item")
if not items:
    raise SystemExit("bootstrap appcast has no release items")
for item in items:
    values = [item.findtext(f"{{{dory}}}{name}", "") for name in (
        "dataSchemaVersion", "minimumReadableDataSchema",
        "maximumReadableDataSchema", "componentCatalogSchema",
    )]
    if values != ["1", "1", "1", "1"]:
        raise SystemExit(f"bootstrap appcast schema contract is invalid: {values}")
PY

  bash -n scripts/dory scripts/generate-appcast.sh
  python3 -m py_compile scripts/validate-release-metadata.py

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dory-upgrade-gate.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  root="$tmp/upgrades"
  transaction="$root/11111111-1111-1111-1111-111111111111"
  recovery="$transaction/recovery"
  mkdir -p "$recovery"
  chmod 700 "$root" "$transaction" "$recovery"
  python3 - "$transaction" <<'PY'
import json
import os
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
transaction_id = directory.name
record = {
    "kind": "dev.dory.upgrade.transaction",
    "schemaVersion": 1,
    "id": transaction_id,
    "state": "recoveryRequired",
    "createdAt": "2026-07-18T00:00:00.000Z",
    "updatedAt": "2026-07-18T00:01:00.000Z",
    "priorVersion": "0.3.2",
    "priorBuild": "43",
    "candidate": {"version": "0.4.0", "build": "44"},
    "appSnapshot": {"build": "43"},
    "dataSnapshot": {"archivePath": "/tmp/last-good-data.dorybackup"},
    "smokeChecks": [{"id": "docker.api", "required": True, "passed": False}],
    "error": "fixture smoke failure",
    "recoveryDirectory": str(directory / "recovery"),
}
recovery = {
    "schema": "dev.dory.upgrade.recovery",
    "version": 1,
    "transactionID": transaction_id,
    "reason": "fixture smoke failure",
    "durableDataWasRolledBack": False,
    "exportCommand": "dory data verify /tmp/last-good-data.dorybackup",
    "restoreCommand": "dory data restore /tmp/last-good-data.dorybackup /tmp/new.dorydrive",
}
for path, payload in ((directory / "transaction.json", record), (directory / "recovery/recovery.json", recovery)):
    path.write_text(json.dumps(payload), encoding="utf-8")
    os.chmod(path, 0o600)
PY

  DORY_UPGRADE_ROOT="$root" scripts/dory upgrade status --json \
    | python3 -c 'import json,sys; p=json.load(sys.stdin); (p.get("schema") == "dev.dory.upgrade.status" and p.get("transaction", {}).get("state") == "recoveryRequired") or sys.exit("upgrade status projection is invalid")'
  DORY_UPGRADE_ROOT="$root" scripts/dory upgrade recovery --json \
    | python3 -c 'import json,sys; p=json.load(sys.stdin); p.get("recovery", {}).get("durableDataWasRolledBack") is False or sys.exit("upgrade recovery projection is invalid")'

  mv "$root" "$tmp/real-upgrades"
  ln -s "$tmp/real-upgrades" "$root"
  if DORY_UPGRADE_ROOT="$root" scripts/dory upgrade status --json >/dev/null 2>&1; then
    fail "CLI followed a symlinked upgrade journal root"
  fi
  rm -f "$root"
  mv "$tmp/real-upgrades" "$root"
  rm -f "$transaction/transaction.json"
  ln -s /etc/hosts "$transaction/transaction.json"
  if DORY_UPGRADE_ROOT="$root" scripts/dory upgrade status --json >/dev/null 2>&1; then
    fail "CLI followed a symlinked upgrade transaction"
  fi
  rm -rf "$tmp"
  trap - RETURN
  echo "transactional-upgrade-static: PASS"
}

record=""
evidence=""
expected=""
if [ "$#" -eq 0 ]; then
  static_gate
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --record) [ "$#" -ge 2 ] || fail "$1 requires a path"; record="$2"; shift 2 ;;
    --interruption-evidence) [ "$#" -ge 2 ] || fail "$1 requires a path"; evidence="$2"; shift 2 ;;
    --expect-state) [ "$#" -ge 2 ] || fail "$1 requires a state"; expected="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ -f "$record" ] && [ ! -L "$record" ] || fail "transaction record is missing or indirect"
[ -f "$evidence" ] && [ ! -L "$evidence" ] || fail "interruption evidence is missing or indirect"
record_logical="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$record")"
evidence_logical="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$evidence")"
record="$(cd "$(dirname "$record")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$record")")"
evidence="$(cd "$(dirname "$evidence")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$evidence")")"
[ "$record" = "$record_logical" ] || fail "transaction record has an indirect ancestor"
[ "$evidence" = "$evidence_logical" ] || fail "interruption evidence has an indirect ancestor"
case "$expected" in rolledBack|recoveryRequired) ;; *) fail "expected state must be rolledBack or recoveryRequired" ;; esac

python3 - "$record" "$evidence" "$expected" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

record_path = pathlib.Path(sys.argv[1])
evidence_path = pathlib.Path(sys.argv[2])
expected = sys.argv[3]
def require(condition, message):
    if not condition:
        raise SystemExit(message)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result

require(record_path.stat().st_size <= 2 * 1024 * 1024, "transaction record is too large")
require(evidence_path.stat().st_size <= 2 * 1024 * 1024, "interruption evidence is too large")
record_bytes = record_path.read_bytes()
record = json.loads(record_bytes, object_pairs_hook=unique_object)
evidence = json.loads(evidence_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)

require(record.get("kind") == "dev.dory.upgrade.transaction" and record.get("schemaVersion") == 1, "invalid transaction schema")
require(record.get("state") == expected, f"transaction ended in {record.get('state')}, expected {expected}")
require(record.get("appSnapshot") and record.get("configurationSnapshots") is not None, "last-good app/config evidence is incomplete")
require(record.get("dataSnapshot") and record.get("markerVolume"), "verified data snapshot/runtime marker is incomplete")
selection = record.get("componentSelection") or {}
require(selection.get("kind") == "dev.dory.component-selection-snapshot" and selection.get("schemaVersion") == 1, "component selection snapshot is invalid")
candidate = record.get("candidate") or {}
require(candidate.get("archiveSignatureValidated") is True and candidate.get("enclosureSignatureDeclared") is True, "Sparkle enclosure signature declaration and archive validation were not both recorded")
failed = [check for check in record.get("smokeChecks", []) if check.get("required", True) and not check.get("passed")]
require(failed, "interrupted campaign did not retain a required smoke failure")
require(record.get("error"), "rollback has no failure reason")

require(evidence.get("schema") == "dev.dory.upgrade.interruption-evidence" and evidence.get("version") == 1, "invalid interruption evidence schema")
require(evidence.get("transactionID") == str(record.get("id")).lower(), "evidence transaction mismatch")
require(evidence.get("transactionSHA256") == hashlib.sha256(record_bytes).hexdigest(), "evidence transaction digest mismatch")
require(re.fullmatch(r"[0-9a-f]{40}", evidence.get("sourceCommit", "")) is not None, "source commit is not exact")
require(re.fullmatch(r"[0-9a-f]{64}", evidence.get("candidateAppSHA256", "")) is not None, "candidate app digest is not exact")
require(evidence.get("priorBuild") == record.get("priorBuild") and evidence.get("candidateBuild") == candidate.get("build"), "build identity mismatch")
require(evidence.get("failureInjection") in {"post-install-smoke", "component-activation-interruption"}, "failure injection is not an allowed exact scenario")
require(evidence.get("automaticRollback") is (expected == "rolledBack"), "automatic rollback result mismatch")
require(evidence.get("durableDataWasRolledBack") is False, "campaign downgraded durable data")
require(evidence.get("durableSentinelBeforeSHA256") == evidence.get("durableSentinelAfterSHA256"), "durable data changed during app rollback")
if expected == "rolledBack":
    require(record.get("candidate", {}).get("schema", {}).get("priorMaximumReadableSchema", 0) >= record.get("candidate", {}).get("schema", {}).get("targetDataSchema", 1), "rollback was not schema-safe")
    require(evidence.get("finalAppBuild") == record.get("priorBuild"), "last-good app was not restored")
else:
    require(record.get("recoveryDirectory") and evidence.get("recoveryExportVerified") is True, "unsafe schema path has no verified recovery export")
print("transactional-upgrade-evidence: PASS")
PY
