#!/bin/bash
# RustSec gate with one feature-aware exception. Cargo.lock records optional dependencies even when
# their features are disabled, so cargo-audit sees russh's vulnerable RSA implementation although
# Dory deliberately ships Ed25519-only SSH. Prove RSA is absent from every target graph before
# ignoring that lockfile-only advisory; any future feature activation fails closed here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

command -v cargo-audit >/dev/null 2>&1 \
  || { echo "rust security gate: cargo-audit 0.22.2 is required" >&2; exit 1; }

tree_output="$(mktemp "${TMPDIR:-/tmp}/dory-rust-security.XXXXXX")"
trap 'rm -f "$tree_output"' EXIT
cargo tree --manifest-path dory-core/Cargo.toml --target all -i rsa -e features \
  >"$tree_output" 2>&1 || true
if grep -Eq '^rsa v[0-9]' "$tree_output"; then
  cat "$tree_output" >&2
  echo "rust security gate: RSA entered a compiled target; RUSTSEC-2023-0071 is no longer ignorable" >&2
  exit 1
fi

cargo audit --file dory-core/Cargo.lock --deny warnings \
  --ignore RUSTSEC-2023-0071
echo "rust security gate: PASS (RSA feature absent; no actionable advisories)"
