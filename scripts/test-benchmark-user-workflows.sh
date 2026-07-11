#!/usr/bin/env bash
# Offline tests for benchmark-user-workflows.sh image-fairness metadata. No Docker socket is accessed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/benchmark-user-workflows.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-workflow-bench-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
fail() { echo "user-workflow benchmark test failed: $*" >&2; exit 1; }

bash -n "$HARNESS"
for template in '{{.Id}}' '{{join .RepoDigests ","}}' '{{.Os}}' '{{.Architecture}}' \
                '{{.Variant}}' '{{.Created}}' '{{.Size}}' '{{json .RootFS.Layers}}'; do
  grep -Fq -- "--format '$template'" "$HARNESS" || fail "missing independent inspect for $template"
done
grep -Fq 'resolved_repo_digest\timage_id\trepo_digests\tos\tarch\tvariant' "$HARNESS" || \
  fail 'image provenance does not retain RepoDigest, diagnostic image ID, and full platform'
grep -Fq 'rootfs_layers\trootfs_fingerprint_sha256' "$HARNESS" || \
  fail 'image provenance does not retain ordered RootFS evidence and fingerprint'
if grep -Fq 'canonical[image]' "$HARNESS" || grep -Fq 'identical image IDs' "$HARNESS"; then
  fail 'store-dependent Docker image ID was reintroduced as a fairness identity'
fi
grep -Fq 'orb config get machine.docker.cpu' "$HARNESS" || \
  fail 'OrbStack Docker-specific CPU override is absent from provenance'
grep -Fq 'orb config get machine.docker.memory_mib' "$HARNESS" || \
  fail 'OrbStack Docker-specific memory override is absent from provenance'
grep -Fq 'npm_clear_bind_tree() {' "$HARNESS" || \
  fail 'npm setup does not clear node_modules through the engine bind mount'
grep -Fq 'fs.rmSync("/app/node_modules"' "$HARNESS" || \
  fail 'npm bind-tree cleanup does not retry removal of the guest-visible node_modules path'
if grep -Fq 'print NR > 0 ?' "$HARNESS"; then
  fail 'benchmark ledger count uses an awk print expression that macOS parses as redirection'
fi
grep -Fq 'print (NR > 0 ? NR - 1 : 0)' "$HARNESS" || \
  fail 'benchmark ledger count does not use a portable parenthesized awk expression'

extract_function() {
  local signature="$1"
  awk -v signature="$signature" '
    $0 == signature { copying=1 }
    copying { print }
    copying && $0 == "}" { exit }
  ' "$HARNESS"
}

# Run the exact helpers from the harness rather than duplicating their logic in the test.
eval "$(extract_function 'normal_image_variant() {')"
eval "$(extract_function 'valid_rootfs_layers() {')"
eval "$(extract_function 'unique_repo_digest() {')"
eval "$(extract_function 'validate_image_fairness() {')"

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
LAYER_A="sha256:$(printf '1%.0s' {1..64})"
LAYER_B="sha256:$(printf '2%.0s' {1..64})"
ROOTFS_A="$(printf '3%.0s' {1..64})"
ROOTFS_B="$(printf '4%.0s' {1..64})"

[ "$(normal_image_variant arm64 v8)" = v8 ] || fail 'arm64/v8 variant normalization failed'
[ "$(normal_image_variant amd64 '')" = none ] || fail 'amd64 omitted-variant normalization failed'
if normal_image_variant arm64 '' >/dev/null 2>&1; then fail 'missing arm64 variant was accepted'; fi
valid_rootfs_layers "[\"$LAYER_A\",\"$LAYER_B\"]" || fail 'valid ordered RootFS layers were rejected'
if valid_rootfs_layers '[]'; then fail 'empty RootFS layers were accepted'; fi
[ "$(unique_repo_digest "node@$DIGEST_A,alias/node@$DIGEST_A")" = "$DIGEST_A" ] || \
  fail 'same-digest repository aliases were not normalized'
if unique_repo_digest "node@$DIGEST_A,node@$DIGEST_B" >/dev/null 2>&1; then
  fail 'ambiguous RepoDigests were accepted'
fi
if unique_repo_digest '' >/dev/null 2>&1; then fail 'missing RepoDigest was accepted'; fi

WORK="$TMP_ROOT/work"
engine_count=3
mkdir -p "$WORK"
write_fixture() {
  local mode="$1" image engine digest variant rootfs repo image_id
  printf 'engine\trequested_image\tresolved_repo_digest\timage_id\trepo_digests\tos\tarch\tvariant\tcreated\tbytes\trootfs_layers\trootfs_fingerprint_sha256\n' \
    > "$WORK/image-provenance.tsv"
  for image in node:22-alpine alpine:3.21 postgres:16-alpine redis:7-alpine; do
    for engine in dory orbstack colima; do
      digest="$DIGEST_A"
      variant=v8
      rootfs="$ROOTFS_A"
      if [ "$mode" = digest-mismatch ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        digest="$DIGEST_B"
      fi
      if [ "$mode" = platform-mismatch ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        variant=v9
      fi
      if [ "$mode" = rootfs-mismatch ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        rootfs="$ROOTFS_B"
      fi
      if [ "$mode" = missing-digest ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        digest=""
      fi
      if [ "$mode" = missing-platform ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        variant=""
      fi
      if [ "$mode" = missing-rootfs ] && [ "$image" = node:22-alpine ] && [ "$engine" = colima ]; then
        rootfs=""
      fi
      repo="${image%%:*}@${digest:-missing}"
      # Intentionally different IDs prove that store-specific `.Id` values are diagnostic only.
      image_id="sha256:${engine}-${image}"
      printf '%s\t%s\t%s\t%s\t%s\tlinux\tarm64\t%s\t2026-01-01T00:00:00Z\t1\t%s\t%s\n' \
        "$engine" "$image" "$digest" "$image_id" "$repo" "$variant" \
        "[\"$LAYER_A\"]" "$rootfs" >> "$WORK/image-provenance.tsv"
    done
  done
}

write_fixture pass
validate_image_fairness || fail 'different diagnostic image IDs rejected identical immutable content'
for mode in digest-mismatch platform-mismatch rootfs-mismatch missing-digest missing-platform missing-rootfs; do
  write_fixture "$mode"
  if validate_image_fairness >"$TMP_ROOT/$mode.out" 2>"$TMP_ROOT/$mode.err"; then
    fail "$mode fixture was accepted"
  fi
done

echo 'user-workflow benchmark offline tests passed'
