#!/usr/bin/env bash
# Offline tests for benchmark-external-network.sh. No Docker socket or endpoint is accessed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/benchmark-external-network.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-network-bench-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
fail() { echo "external-network benchmark test failed: $*" >&2; exit 1; }

IMAGE='example.invalid/curl@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
PROBE='https://network-bench.example/probe'
DOWNLOAD='https://network-bench.example/payload-1048576.bin'

bash -n "$HARNESS"
"$HARNESS" --help > "$TMP_ROOT/help.txt"
grep -q -- '--pull never' "$TMP_ROOT/help.txt"
grep -q -- '--dry-run' "$TMP_ROOT/help.txt"
grep -q -- '--globoff' "$HARNESS"

"$HARNESS" \
  --engines dory,orbstack,colima \
  --rounds 9 \
  --image "$IMAGE" \
  --probe-url "$PROBE" \
  --download-url "$DOWNLOAD" \
  --download-bytes 1048576 \
  --dry-run > "$TMP_ROOT/schedule.tsv" 2> "$TMP_ROOT/dry-run.err"

grep -q 'no engine, Docker API, image, or network endpoint was accessed' "$TMP_ROOT/dry-run.err"
grep -q 'planned_fixed_download_bytes_per_engine=386924544' "$TMP_ROOT/dry-run.err"
awk -F '\t' '
  NR == 1 {
    if ($0 != "round\tworkload\tposition\tengine\tconcurrency") exit 1
    next
  }
  {
    rows++
    count[$2 SUBSEP $4 SUBSEP $3]++
    if ($5 != 1 && $5 != 8 && $5 != 32) exit 1
  }
  END {
    if (rows != 108) exit 1
    for (key in count) if (count[key] != 3) exit 1
  }
' "$TMP_ROOT/schedule.tsv"

expect_rejected() {
  local label="$1"
  shift
  if "$HARNESS" "$@" > "$TMP_ROOT/$label.out" 2> "$TMP_ROOT/$label.err"; then
    fail "$label was accepted"
  fi
}
expect_rejected mutable-image \
  --image curl:latest --probe-url "$PROBE" --download-url "$DOWNLOAD" \
  --download-bytes 1 --dry-run
expect_rejected unbalanced-rounds \
  --engines dory,orbstack,colima --rounds 8 --image "$IMAGE" --probe-url "$PROBE" \
  --download-url "$DOWNLOAD" --download-bytes 1 --dry-run
expect_rejected duplicate-engine \
  --engines dory,dory --rounds 2 --image "$IMAGE" --probe-url "$PROBE" \
  --download-url "$DOWNLOAD" --download-bytes 1 --dry-run
expect_rejected plaintext-url \
  --image "$IMAGE" --probe-url http://network-bench.example/probe \
  --download-url "$DOWNLOAD" --download-bytes 1 --dry-run
expect_rejected username-only-userinfo \
  --image "$IMAGE" --probe-url https://token@network-bench.example/probe \
  --download-url "$DOWNLOAD" --download-bytes 1 --dry-run

# A live preflight failure must be terminal and auditable, not leave run-status falsely "running".
set +e
DORY_SOCK="$TMP_ROOT/missing.sock" "$HARNESS" \
  --engines dory --rounds 1 --image "$IMAGE" --probe-url "$PROBE" \
  --download-url "$DOWNLOAD" --download-bytes 1 \
  --work "$TMP_ROOT/preflight-failure" > "$TMP_ROOT/preflight.out" 2> "$TMP_ROOT/preflight.err"
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 2 ] || fail "missing-socket preflight returned $preflight_rc, expected 2"
grep -q $'^status\tfail$' "$TMP_ROOT/preflight-failure/run-status.tsv"
grep -q $'^reason\tunexpected_exit_2$' "$TMP_ROOT/preflight-failure/run-status.tsv"
grep -q $'^exit_code\t2$' "$TMP_ROOT/preflight-failure/run-status.tsv"

# Docker's Go-template formatter prints backslash-t literally. Image metadata must therefore use
# independent inspect calls, never a composite format that is split on an assumed tab character.
if grep -Fq '\t{{' "$HARNESS"; then
  fail 'image metadata reintroduced literal-backslash-t parsing'
fi
for template in '{{.Id}}' '{{join .RepoDigests ","}}' '{{.Os}}' '{{.Architecture}}' \
                '{{.Variant}}' '{{.Created}}' '{{json .RootFS.Layers}}'; do
  grep -Fq -- "--format '$template'" "$HARNESS" || fail "missing independent inspect for $template"
done
grep -Fq 'resolved_repo_digest\timage_id\trepo_digests\tos\tarch\tvariant' "$HARNESS" || \
  fail 'image provenance does not retain RepoDigest, diagnostic image ID, and full platform'
grep -Fq 'rootfs_layers\trootfs_fingerprint_sha256' "$HARNESS" || \
  fail 'image provenance does not retain ordered RootFS evidence and fingerprint'
if grep -Fq 'BASE_IMAGE_ID' "$HARNESS"; then
  fail 'store-dependent Docker image ID was reintroduced as a fairness identity'
fi

extract_function() {
  local signature="$1"
  awk -v signature="$signature" '
    $0 == signature { copying=1 }
    copying { print }
    copying && $0 == "}" { exit }
  ' "$HARNESS"
}

# Exercise the exact metadata helpers. Docker 29 can expose the same immutable image with a manifest
# digest as `.Id` in one store and a config digest in another, so only RepoDigest/platform/layers rank.
eval "$(extract_function 'normal_image_variant() {')"
eval "$(extract_function 'valid_rootfs_layers() {')"
eval "$(extract_function 'resolved_requested_repo_digest() {')"
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
LAYER_A="sha256:$(printf '1%.0s' {1..64})"
LAYER_B="sha256:$(printf '2%.0s' {1..64})"
[ "$(normal_image_variant arm64 v8)" = v8 ] || fail 'arm64/v8 variant normalization failed'
[ "$(normal_image_variant amd64 '')" = none ] || fail 'amd64 omitted-variant normalization failed'
if normal_image_variant arm64 '' >/dev/null 2>&1; then fail 'missing arm64 variant was accepted'; fi
valid_rootfs_layers "[\"$LAYER_A\",\"$LAYER_B\"]" || fail 'valid ordered RootFS layers were rejected'
if valid_rootfs_layers '[]'; then fail 'empty RootFS layers were accepted'; fi
if valid_rootfs_layers "[\"$LAYER_A\",\"not-a-digest\"]"; then
  fail 'malformed RootFS layers were accepted'
fi
[ "$(resolved_requested_repo_digest "curlimages/curl@$DIGEST_A,alias/curl@$DIGEST_B" "$DIGEST_A")" = "$DIGEST_A" ] || \
  fail 'exact requested RepoDigest was not resolved'
if resolved_requested_repo_digest "curlimages/curl@${DIGEST_A}0" "$DIGEST_A" >/dev/null 2>&1; then
  fail 'RepoDigest substring was accepted as an exact requested digest'
fi

# Extract and exercise the exact guest script using a fake curl function. This tests all 32 workers,
# raw-field positions, exact-byte validation, and failure preservation without using the network.
guest_start="$(grep -n "^GUEST_SCRIPT='" "$HARNESS" | cut -d: -f1)"
guest_end="$(awk -v start="$guest_start" 'NR > start && $0 == "\047" { print NR; exit }' "$HARNESS")"
[ -n "$guest_start" ] && [ -n "$guest_end" ] || fail 'could not locate embedded guest script'
guest_script="$(sed -n "$((guest_start + 1)),$((guest_end - 1))p" "$HARNESS")"
printf '%s\n' "$guest_script" | /bin/sh -n
guest_script="$(printf '%s\n' "$guest_script" | sed "s|/tmp/dory-net|$TMP_ROOT/dory-net|g")"

fake_success='curl() {
  found_globoff=0
  url_count=0
  for argument in "$@"; do
    [ "$argument" = --globoff ] && found_globoff=1
    case "$argument" in https://*) url_count=$((url_count + 1)) ;; esac
  done
  [ "$found_globoff" -eq 1 ] && [ "$url_count" -eq 1 ] || return 97
  printf "%s\n" "https://network-bench.example/file|203.0.113.9|200|2|1|1048576|8388608|0.001000|0.010000|0.020000|0.021000|0.030000|1.000000|0"
  return 0
}'
/bin/sh -c "$fake_success
$guest_script" -- download 'https://network-bench.example/{one,two}[1-2]' 1048576 200 32 10 60 > "$TMP_ROOT/guest-success.tsv"
awk -F '\t' '
  $1 == "CURL" {
    rows++
    if ($3 != 0 || $4 != "pass" || $12 != 1048576 ||
        $14 != "0.001000" || $19 != "1.000000") exit 1
  }
  END { if (rows != 32) exit 1 }
' "$TMP_ROOT/guest-success.tsv"

fake_failure='curl() { printf "%s\n" "https://network-bench.example/file||200|2|1|7|56|0.001000|0.010000|0.020000|0.021000|0.030000|1.000000|0"; return 0; }'
set +e
/bin/sh -c "$fake_failure
$guest_script" -- download "$DOWNLOAD" 1048576 200 1 10 60 > "$TMP_ROOT/guest-failure.tsv"
failure_rc=$?
set -e
[ "$failure_rc" -eq 1 ] || fail "invalid byte count returned $failure_rc, expected 1"
awk -F '\t' '
  $1 == "CURL" { found=1; if ($3 != 0 || $4 != "fail" || $5 != "byte_count" || $8 != "" || $12 != 7) exit 1 }
  END { if (!found) exit 1 }
' "$TMP_ROOT/guest-failure.tsv"

echo 'external-network benchmark offline tests passed'
