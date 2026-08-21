#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "test-destructive-action-contracts: $*" >&2
  exit 1
}

fixture="$(mktemp -d -t dory-destructive-contracts.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
fake_ctl="$fixture/dorydctl"
log="$fixture/calls.log"

cat > "$fake_ctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${DORY_DESTRUCTIVE_TEST_LOG:?}"
if [ "${1:-}" = machine ] && [ "${2:-}" = snapshot ]; then
  printf '%s\n' '{"id":"safety123","ok":true}'
else
  printf '%s\n' '{"ok":true}'
fi
SH
chmod +x "$fake_ctl"

run_cli() {
  DORYDCTL_BIN="$fake_ctl" DORY_DESTRUCTIVE_TEST_LOG="$log" bash scripts/dory "$@"
}

if run_cli machine delete dev >"$fixture/out" 2>"$fixture/err"; then
  fail "machine delete ran without exact confirmation"
fi
grep -Fq -- "--confirm 'dev'" "$fixture/err" || fail "machine delete did not explain exact confirmation"
test ! -s "$log" || fail "unconfirmed machine delete reached dorydctl"

if run_cli machine delete dev --confirm prod >"$fixture/out" 2>"$fixture/err"; then
  fail "machine delete accepted a different confirmation target"
fi
test ! -s "$log" || fail "wrong-target machine delete reached dorydctl"

run_cli machine delete dev --confirm dev >"$fixture/out"
grep -qx 'machine delete dev' "$log" || fail "confirmed machine delete did not preserve exact scope"
: > "$log"

if run_cli machine restore dev s-old >"$fixture/out" 2>"$fixture/err"; then
  fail "machine restore ran without exact confirmation"
fi
test ! -s "$log" || fail "unconfirmed machine restore created state"

run_cli machine restore dev s-old --confirm dev >"$fixture/out" 2>"$fixture/err"
grep -qx 'machine snapshot dev --note Automatic pre-restore safety snapshot' "$log" \
  || fail "confirmed restore did not create a safety snapshot first"
grep -qx 'machine restore-snapshot dev s-old' "$log" \
  || fail "confirmed restore did not target the selected snapshot"
test "$(wc -l < "$log" | tr -d ' ')" = 2 || fail "restore invoked an unexpected control operation"
grep -Fq 'safety123' "$fixture/err" || fail "restore did not report the undo snapshot"
: > "$log"

if run_cli machine delete-snapshot dev s-old --confirm dev >"$fixture/out" 2>"$fixture/err"; then
  fail "snapshot deletion accepted the machine name instead of the exact snapshot ID"
fi
test ! -s "$log" || fail "wrong-target snapshot deletion reached dorydctl"
run_cli machine delete-snapshot dev s-old --confirm s-old >"$fixture/out"
grep -qx 'machine delete-snapshot dev s-old' "$log" || fail "confirmed snapshot deletion changed scope"
: > "$log"

if run_cli component remove kubernetes >"$fixture/out" 2>"$fixture/err"; then
  fail "component removal ran without exact confirmation"
fi
test ! -s "$log" || fail "unconfirmed component removal reached dorydctl"
run_cli component remove kubernetes --confirm kubernetes --json >"$fixture/out"
grep -qx 'component remove kubernetes --json' "$log" || fail "confirmed component removal changed options"

if rg -n '\.keyboardShortcut\([^\n]*(delete|backspace)|\.onDeleteCommand' Dory --glob '*.swift' >"$fixture/keyboard"; then
  fail "a destructive keyboard shortcut bypasses the confirmation contract: $(tr '\n' ' ' < "$fixture/keyboard")"
fi

grep -Fq 'Automatic pre-restore safety snapshot' Dory/Models/AppStore.swift \
  || fail "the GUI restore path lost its automatic undo snapshot"
grep -Fq 'Create Safety Snapshot & Restore' Dory/Features/Machines/SnapshotsSheet.swift \
  || fail "snapshot restore no longer communicates confirmation and recoverability"
grep -Fq 'Stop & Remove Stack' Dory/Features/Containers/ContainersView.swift \
  || fail "container list Compose removal lacks confirmation"
grep -Fq 'Stop & Remove Stack' Dory/Features/Containers/ContainerDetailView.swift \
  || fail "container detail Compose removal lacks confirmation"
grep -Fq 'Stop & Remove Stack' Dory/Features/Compose/ComposeProjectsView.swift \
  || fail "Compose page removal lacks confirmation"
grep -Fq 'Disable & Remove Cluster' Dory/Features/Tables/KubernetesView.swift \
  || fail "Kubernetes removal lacks confirmation"

if rg -n 'Button\("Down [-—].*\{ Task \{ await store\.composeDown|Button\("Disable Kubernetes".*await store\.disableKubernetes' \
  Dory/App/DoryCommands.swift Dory/Features/MenuBar/MenuBarContentView.swift; then
  fail "a global or menu-bar action still performs destructive work without opening the confirming UI"
fi

echo "destructive action contract tests passed"
