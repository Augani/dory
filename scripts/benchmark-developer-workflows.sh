#!/usr/bin/env bash
# Position-balanced Rails/Bundler, pnpm, and Composer installs on host bind mounts. Lock generation
# and cache population are untimed. Every measured install is offline, starts from an absent install
# tree, verifies the lock and runtime autoload, and retains a byte-level tree manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ENGINES_CSV="${BENCH_DEV_ENGINES:-dory,orbstack,colima}"
ROUNDS="${BENCH_DEV_ROUNDS:-9}"
RUBY_IMAGE="${BENCH_DEV_RUBY_IMAGE:-}"
NODE_IMAGE="${BENCH_DEV_NODE_IMAGE:-}"
COMPOSER_IMAGE="${BENCH_DEV_COMPOSER_IMAGE:-}"
PNPM_VERSION="${BENCH_DEV_PNPM_VERSION:-10.13.1}"
RAILS_VERSION="${BENCH_DEV_RAILS_VERSION:-7.2.2.1}"
COMPOSER_PACKAGE="${BENCH_DEV_COMPOSER_PACKAGE:-symfony/console}"
COMPOSER_PACKAGE_VERSION="${BENCH_DEV_COMPOSER_PACKAGE_VERSION:-7.2.1}"
CONTAINER_CPUS="${BENCH_DEV_CONTAINER_CPUS:-2}"
CONTAINER_MEMORY="${BENCH_DEV_CONTAINER_MEMORY:-1800m}"
MEMORY_TOLERANCE_PCT="${BENCH_DEV_MEMORY_TOLERANCE_PCT:-5}"
WORK="${BENCH_DEV_WORK:-$HOME/.dory-developer-bench/$RUN_ID}"
DRY_RUN=0
CURRENT_ENGINE=""
CURRENT_CONTAINER=""

usage() {
  cat <<'EOF'
Usage: scripts/benchmark-developer-workflows.sh [required options] [options]

Required:
  --ruby-image REF       Ruby/Bundler image pinned with @sha256:<64 hex>.
  --node-image REF       Node/Corepack image pinned with @sha256:<64 hex>.
  --composer-image REF   Composer image pinned with @sha256:<64 hex>.

Options:
  --engines CSV          dory,orbstack,colima[,docker-desktop] (default: first three)
  --rounds N             Multiple of engine count (default: 9)
  --pnpm-version V       Exact pnpm semantic version (default: 10.13.1)
  --rails-version V      Exact Rails gem version (default: 7.2.2.1)
  --composer-package P   Exact package name (default: symfony/console)
  --composer-version V   Exact package version (default: 7.2.1)
  --container-cpus N     Identical per-container CPU limit (default: 2)
  --container-memory S   Identical per-container memory limit (default: 1800m)
  --memory-tolerance P   Maximum guest-memory spread percentage (default: 5)
  --work DIR             Fresh raw-result directory
  --dry-run              Validate static arguments and print the balanced schedule only
  -h, --help             Show this help

Images must already exist in every engine. Live runs use --pull never. Fixture lock generation and
cache warming use only the first requested engine and are explicitly outside the timer; the exact
locks and cache inventories are retained. Timed commands run with Docker networking disabled.
EOF
}

die() { echo "benchmark-developer-workflows: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) need_value "$1" "$#"; ENGINES_CSV="$2"; shift 2 ;;
    --rounds) need_value "$1" "$#"; ROUNDS="$2"; shift 2 ;;
    --ruby-image) need_value "$1" "$#"; RUBY_IMAGE="$2"; shift 2 ;;
    --node-image) need_value "$1" "$#"; NODE_IMAGE="$2"; shift 2 ;;
    --composer-image) need_value "$1" "$#"; COMPOSER_IMAGE="$2"; shift 2 ;;
    --pnpm-version) need_value "$1" "$#"; PNPM_VERSION="$2"; shift 2 ;;
    --rails-version) need_value "$1" "$#"; RAILS_VERSION="$2"; shift 2 ;;
    --composer-package) need_value "$1" "$#"; COMPOSER_PACKAGE="$2"; shift 2 ;;
    --composer-version) need_value "$1" "$#"; COMPOSER_PACKAGE_VERSION="$2"; shift 2 ;;
    --container-cpus) need_value "$1" "$#"; CONTAINER_CPUS="$2"; shift 2 ;;
    --container-memory) need_value "$1" "$#"; CONTAINER_MEMORY="$2"; shift 2 ;;
    --memory-tolerance) need_value "$1" "$#"; MEMORY_TOLERANCE_PCT="$2"; shift 2 ;;
    --work) need_value "$1" "$#"; WORK="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}
positive_number() {
  awk -v value="$2" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' \
    || die "$1 must be a positive number"
}
nonnegative_number() {
  awk -v value="$2" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }' \
    || die "$1 must be a non-negative number"
}
immutable_image() {
  printf '%s\n' "$2" | grep -Eq '^.+@sha256:[0-9a-fA-F]{64}$' \
    || die "$1 must include an immutable @sha256 digest"
}
safe_semver() {
  printf '%s\n' "$2" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$' \
    || die "$1 must be an exact semantic version"
}

positive_integer rounds "$ROUNDS"
positive_number container-cpus "$CONTAINER_CPUS"
nonnegative_number memory-tolerance "$MEMORY_TOLERANCE_PCT"
[ -n "$CONTAINER_MEMORY" ] || die "container memory must not be empty"
immutable_image ruby-image "$RUBY_IMAGE"
immutable_image node-image "$NODE_IMAGE"
immutable_image composer-image "$COMPOSER_IMAGE"
safe_semver pnpm-version "$PNPM_VERSION"
safe_semver rails-version "$RAILS_VERSION"
safe_semver composer-version "$COMPOSER_PACKAGE_VERSION"
printf '%s\n' "$COMPOSER_PACKAGE" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
  || die "composer-package must be a package/name"
case "$WORK" in /*) ;; *) die "--work must be absolute" ;; esac
case "$WORK" in /|"$HOME"|"$ROOT") die "unsafe --work path: $WORK" ;; esac

IFS=',' read -r -a ENGINES <<< "$ENGINES_CSV"
[ "${#ENGINES[@]}" -gt 0 ] || die "at least one engine is required"
VALIDATED=()
for engine in "${ENGINES[@]}"; do
  case "$engine" in dory|orbstack|colima|docker-desktop) ;; *) die "unsupported engine: $engine" ;; esac
  for seen in "${VALIDATED[@]:-}"; do
    [ "$engine" != "$seen" ] || die "duplicate engine: $engine"
  done
  VALIDATED+=("$engine")
done
[ $((ROUNDS % ${#ENGINES[@]})) -eq 0 ] \
  || die "rounds must be a multiple of engine count for position balance"

print_schedule() {
  local round position workflow engine_index
  printf 'workflow\tround\tposition\tengine\n'
  for workflow in rails pnpm composer; do
    for ((round = 1; round <= ROUNDS; round++)); do
      for ((position = 1; position <= ${#ENGINES[@]}; position++)); do
        engine_index=$(((round - 1 + position - 1) % ${#ENGINES[@]}))
        printf '%s\t%s\t%s\t%s\n' "$workflow" "$round" "$position" "${ENGINES[$engine_index]}"
      done
    done
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run only: no engine, image, registry, cache, or filesystem mutation was attempted" >&2
  print_schedule
  exit 0
fi

for command in docker perl python3 shasum; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
[ ! -e "$WORK" ] || die "result path already exists: $WORK"
mkdir -p "$WORK/fixtures/rails" "$WORK/fixtures/pnpm" "$WORK/fixtures/composer" \
  "$WORK/logs" "$WORK/trees" "$WORK/projects"
MANIFEST="$WORK/run-manifest.tsv"
ENGINE_PROVENANCE="$WORK/engine-provenance.tsv"
IMAGE_PROVENANCE="$WORK/image-provenance.tsv"
SAMPLES="$WORK/samples.tsv"
STATUS="$WORK/run-status.tsv"

sock_for() {
  case "$1" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    docker-desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
  esac
}
de() { local engine="$1"; shift; docker -H "unix://$(sock_for "$engine")" "$@"; }
tsv_field() { printf '%s' "${1:-}" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }

cleanup_current() {
  if [ -n "$CURRENT_ENGINE" ] && [ -n "$CURRENT_CONTAINER" ]; then
    de "$CURRENT_ENGINE" rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
  fi
  CURRENT_ENGINE=""
  CURRENT_CONTAINER=""
}
finalize() {
  local rc=$?
  trap - EXIT INT TERM
  cleanup_current
  if [ -n "${STATUS:-}" ] && [ -e "${WORK:-}/run-manifest.tsv" ]; then
    printf 'finished_utc\t%s\nexit_code\t%s\nstatus\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" \
      > "$STATUS"
  fi
  exit "$rc"
}
trap finalize EXIT INT TERM

printf 'engine\tserver_version\tarchitecture\tvcpus\tmemory_bytes\n' > "$ENGINE_PROVENANCE"
printf 'engine\tworkflow\trequested_image\timage_id\trepo_digests\tos\tarchitecture\tvariant\trootfs_layers\n' \
  > "$IMAGE_PROVENANCE"
for engine in "${ENGINES[@]}"; do
  [ -S "$(sock_for "$engine")" ] || die "$engine socket is absent"
  de "$engine" version >/dev/null 2>&1 || die "$engine Docker API is unavailable"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$engine" \
    "$(de "$engine" version --format '{{.Server.Version}}')" \
    "$(de "$engine" info --format '{{.Architecture}}')" \
    "$(de "$engine" info --format '{{.NCPU}}')" \
    "$(de "$engine" info --format '{{.MemTotal}}')" >> "$ENGINE_PROVENANCE"
  for pair in "rails=$RUBY_IMAGE" "pnpm=$NODE_IMAGE" "composer=$COMPOSER_IMAGE"; do
    workflow="${pair%%=*}"
    image="${pair#*=}"
    requested_digest="${image##*@}"
    inspect="$(de "$engine" image inspect "$image" --format \
      '{{.Id}}|{{json .RepoDigests}}|{{.Os}}|{{.Architecture}}|{{.Variant}}|{{json .RootFS.Layers}}' 2>/dev/null)" \
      || die "$engine does not already contain $image"
    case "$inspect" in *"$requested_digest"*) ;; *) die "$engine resolved the wrong digest for $image" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$engine" "$workflow" "$image" "$(printf '%s' "$inspect" | tr '|' '\t')" \
      >> "$IMAGE_PROVENANCE"
  done
done

engine_count="${#ENGINES[@]}"
awk -F '\t' -v expected="$engine_count" -v tolerance="$MEMORY_TOLERANCE_PCT" '
  NR == 1 { next }
  {
    rows++
    if ($3 == "arm64") $3="aarch64"
    if (rows == 1) { arch=$3; cpu=$4; min=max=$5 }
    if ($3 != arch || $4 != cpu) bad=1
    if ($5 < min) min=$5
    if ($5 > max) max=$5
  }
  END {
    if (rows != expected || min <= 0 || 100*(max-min)/min > tolerance) bad=1
    exit bad
  }' "$ENGINE_PROVENANCE" \
  || die "engine architecture/CPU/memory fairness preflight failed"
for workflow in rails pnpm composer; do
  rows="$(awk -F '\t' -v workflow="$workflow" 'NR > 1 && $2 == workflow {
    print $6 "\t" $7 "\t" $8 "\t" $9
  }' "$IMAGE_PROVENANCE" | sort -u | wc -l | tr -d ' ')"
  [ "$rows" -eq 1 ] || die "$workflow image platform or ordered RootFS layers differ"
done

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
FIXTURE_ENGINE="${ENGINES[0]}"
RAILS_FIXTURE="$WORK/fixtures/rails"
PNPM_FIXTURE="$WORK/fixtures/pnpm"
COMPOSER_FIXTURE="$WORK/fixtures/composer"

printf 'source "https://rubygems.org"\ngem "rails", "%s"\n' "$RAILS_VERSION" > "$RAILS_FIXTURE/Gemfile"
de "$FIXTURE_ENGINE" run --rm --pull never --user "$HOST_UID:$HOST_GID" \
  -e HOME=/tmp/dory-home -e BUNDLE_USER_HOME=/work/.bundle-user \
  -v "$RAILS_FIXTURE:/work" -w /work "$RUBY_IMAGE" sh -euc \
  'mkdir -p "$HOME"; bundle lock; bundle cache --all-platforms' \
  > "$WORK/logs/fixture-rails.log" 2>&1 \
  || die "Rails lock/cache preparation failed"
[ -s "$RAILS_FIXTURE/Gemfile.lock" ] && [ -d "$RAILS_FIXTURE/vendor/cache" ] \
  || die "Rails fixture is incomplete"
rm -rf "$RAILS_FIXTURE/vendor/bundle" "$RAILS_FIXTURE/.bundle"

python3 - "$PNPM_FIXTURE/package.json" "$PNPM_VERSION" <<'PY'
import json, pathlib, sys
path, pnpm = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "name": "dory-pnpm-benchmark",
    "private": True,
    "version": "1.0.0",
    "packageManager": f"pnpm@{pnpm}",
    "dependencies": {
        "@babel/core": "7.26.0",
        "esbuild": "0.24.2",
        "react": "19.0.0",
        "typescript": "5.7.3"
    }
}, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
de "$FIXTURE_ENGINE" run --rm --pull never --user "$HOST_UID:$HOST_GID" \
  -e HOME=/tmp/dory-home -e COREPACK_HOME=/work/.corepack -e PNPM_HOME=/work/.pnpm-home \
  -e PNPM_STORE_DIR=/work/.pnpm-store -v "$PNPM_FIXTURE:/work" -w /work "$NODE_IMAGE" sh -euc \
  'mkdir -p "$HOME" "$PNPM_HOME"; corepack enable --install-directory "$PNPM_HOME"; export PATH="$PNPM_HOME:$PATH"; corepack prepare "pnpm@'"$PNPM_VERSION"'" --activate; pnpm install --lockfile-only; pnpm fetch' \
  > "$WORK/logs/fixture-pnpm.log" 2>&1 \
  || die "pnpm lock/cache preparation failed"
[ -s "$PNPM_FIXTURE/pnpm-lock.yaml" ] && [ -d "$PNPM_FIXTURE/.pnpm-store" ] \
  || die "pnpm fixture is incomplete"

python3 - "$COMPOSER_FIXTURE/composer.json" "$COMPOSER_PACKAGE" "$COMPOSER_PACKAGE_VERSION" <<'PY'
import json, pathlib, sys
path, package, version = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "name": "dory/composer-benchmark",
    "type": "project",
    "require": {package: version},
    "config": {"sort-packages": True}
}, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
de "$FIXTURE_ENGINE" run --rm --pull never --user "$HOST_UID:$HOST_GID" --entrypoint sh \
  -e HOME=/tmp/dory-home -e COMPOSER_HOME=/work/.composer-home \
  -e COMPOSER_CACHE_DIR=/work/.composer-cache -v "$COMPOSER_FIXTURE:/work" -w /work \
  "$COMPOSER_IMAGE" -euc \
  'mkdir -p "$HOME"; composer update --no-interaction --no-install --prefer-dist; composer install --no-interaction --prefer-dist --no-progress; rm -rf vendor' \
  > "$WORK/logs/fixture-composer.log" 2>&1 \
  || die "Composer lock/cache preparation failed"
[ -s "$COMPOSER_FIXTURE/composer.lock" ] && [ -d "$COMPOSER_FIXTURE/.composer-cache" ] \
  || die "Composer fixture is incomplete"

tree_manifest() {
  local root="$1" output="$2"
  python3 - "$root" "$output" <<'PY'
import hashlib, os, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
rows = []
for path in sorted(root.rglob("*"), key=lambda value: os.fsencode(str(value.relative_to(root)))):
    rel = str(path.relative_to(root))
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        rows.append((rel, "link", os.readlink(path)))
    elif stat.S_ISREG(mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.append((rel, "file", f"{path.stat().st_size}:{digest}"))
    elif stat.S_ISDIR(mode):
        rows.append((rel, "dir", ""))
    else:
        raise SystemExit(f"unsupported installed-tree entry: {path}")
with out.open("w", encoding="utf-8") as handle:
    handle.write("path\tkind\tidentity\n")
    for row in rows:
        handle.write("\t".join(value.replace("\t", "\\t").replace("\n", "\\n") for value in row) + "\n")
PY
}

timed_run() {
  local timing="$1" log="$2"
  shift 2
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '
    use strict; use warnings;
    my ($timing, $log, @command) = @ARGV;
    open STDOUT, ">", $log or die "open log: $!\n";
    open STDERR, ">&", STDOUT or die "dup stderr: $!\n";
    my $start = clock_gettime(CLOCK_MONOTONIC);
    my $status = system { $command[0] } @command;
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    open my $out, ">", $timing or die "open timing: $!\n";
    printf {$out} "%.6f\n", $elapsed;
    close $out;
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit($status >> 8);
  ' "$timing" "$log" "$@"
}

printf 'workflow\tround\tposition\tengine\tseconds\tentry_count\ttree_sha256\tstatus\n' > "$SAMPLES"
sample=0
for workflow in rails pnpm composer; do
  case "$workflow" in
    rails) fixture="$RAILS_FIXTURE"; image="$RUBY_IMAGE"; install_dir=vendor/bundle ;;
    pnpm) fixture="$PNPM_FIXTURE"; image="$NODE_IMAGE"; install_dir=node_modules ;;
    composer) fixture="$COMPOSER_FIXTURE"; image="$COMPOSER_IMAGE"; install_dir=vendor ;;
  esac
  for ((round = 1; round <= ROUNDS; round++)); do
    for ((position = 1; position <= ${#ENGINES[@]}; position++)); do
      engine_index=$(((round - 1 + position - 1) % ${#ENGINES[@]}))
      engine="${ENGINES[$engine_index]}"
      sample=$((sample + 1))
      project="$WORK/projects/$sample-$workflow-$engine"
      cp -R "$fixture" "$project"
      rm -rf "$project/$install_dir"
      timing="$WORK/logs/$sample-$workflow-$engine.time"
      log="$WORK/logs/$sample-$workflow-$engine.log"
      verify_log="$WORK/logs/$sample-$workflow-$engine.verify.log"
      name="dory-dev-bench-$RUN_ID-$sample"
      CURRENT_ENGINE="$engine"
      CURRENT_CONTAINER="$name"
      case "$workflow" in
        rails)
          timed_run "$timing" "$log" docker -H "unix://$(sock_for "$engine")" run --rm \
            --name "$name" --pull never --network none --cpus "$CONTAINER_CPUS" \
            --memory "$CONTAINER_MEMORY" --user "$HOST_UID:$HOST_GID" \
            -e HOME=/tmp/dory-home -e BUNDLE_USER_HOME=/work/.bundle-user \
            -v "$project:/work" -w /work "$image" sh -euc \
            'mkdir -p "$HOME"; bundle config set --local path vendor/bundle; bundle install --local --jobs 2 --retry 0' \
            || die "Rails sample $sample failed"
          CURRENT_CONTAINER=""
          de "$engine" run --rm --pull never --network none --user "$HOST_UID:$HOST_GID" \
            -e HOME=/tmp/dory-home -e BUNDLE_USER_HOME=/work/.bundle-user \
            -e EXPECTED_RAILS="$RAILS_VERSION" \
            -v "$project:/work" -w /work "$image" sh -euc \
            'bundle check; bundle exec ruby -e '\''require "rails"; abort unless Rails.version == ENV.fetch("EXPECTED_RAILS")'\''' \
            > "$verify_log" 2>&1 \
            || die "Rails verification $sample failed"
          ;;
        pnpm)
          timed_run "$timing" "$log" docker -H "unix://$(sock_for "$engine")" run --rm \
            --name "$name" --pull never --network none --cpus "$CONTAINER_CPUS" \
            --memory "$CONTAINER_MEMORY" --user "$HOST_UID:$HOST_GID" \
            -e HOME=/tmp/dory-home -e COREPACK_HOME=/work/.corepack -e PNPM_HOME=/work/.pnpm-home \
            -e PNPM_STORE_DIR=/work/.pnpm-store -v "$project:/work" -w /work "$image" sh -euc \
            'mkdir -p "$HOME"; export PATH="/work/.pnpm-home:$PATH"; pnpm install --offline --frozen-lockfile' \
            || die "pnpm sample $sample failed"
          CURRENT_CONTAINER=""
          de "$engine" run --rm --pull never --network none --user "$HOST_UID:$HOST_GID" \
            -e HOME=/tmp/dory-home -e COREPACK_HOME=/work/.corepack -e PNPM_HOME=/work/.pnpm-home \
            -e PNPM_STORE_DIR=/work/.pnpm-store -v "$project:/work" -w /work "$image" sh -euc \
            'export PATH="/work/.pnpm-home:$PATH"; pnpm list --depth Infinity; node -e '\''for (const name of ["react","typescript","esbuild","@babel/core"]) require.resolve(name)'\''' \
            > "$verify_log" 2>&1 || die "pnpm verification $sample failed"
          ;;
        composer)
          timed_run "$timing" "$log" docker -H "unix://$(sock_for "$engine")" run --rm \
            --name "$name" --pull never --network none --cpus "$CONTAINER_CPUS" \
            --memory "$CONTAINER_MEMORY" --user "$HOST_UID:$HOST_GID" --entrypoint sh \
            -e HOME=/tmp/dory-home -e COMPOSER_HOME=/work/.composer-home \
            -e COMPOSER_CACHE_DIR=/work/.composer-cache -e COMPOSER_DISABLE_NETWORK=1 \
            -v "$project:/work" -w /work "$image" -euc \
            'mkdir -p "$HOME"; composer install --no-interaction --prefer-dist --no-progress' \
            || die "Composer sample $sample failed"
          CURRENT_CONTAINER=""
          de "$engine" run --rm --pull never --network none --user "$HOST_UID:$HOST_GID" \
            --entrypoint sh -e HOME=/tmp/dory-home -e COMPOSER_HOME=/work/.composer-home \
            -e COMPOSER_CACHE_DIR=/work/.composer-cache -e COMPOSER_DISABLE_NETWORK=1 \
            -e EXPECTED_CLASS=Symfony\\Component\\Console\\Application \
            -v "$project:/work" -w /work "$image" -euc \
            'composer validate --strict --no-interaction; composer check-platform-reqs; php -r '\''require "vendor/autoload.php"; exit(class_exists(getenv("EXPECTED_CLASS")) ? 0 : 1);'\''' \
            > "$verify_log" 2>&1 || die "Composer verification $sample failed"
          ;;
      esac
      lock_name="$(case "$workflow" in rails) echo Gemfile.lock ;; pnpm) echo pnpm-lock.yaml ;; composer) echo composer.lock ;; esac)"
      cmp "$fixture/$lock_name" "$project/$lock_name" || die "$workflow lock changed in sample $sample"
      tree="$WORK/trees/$sample-$workflow-$engine.tsv"
      tree_manifest "$project/$install_dir" "$tree"
      entry_count="$(( $(wc -l < "$tree") - 1 ))"
      [ "$entry_count" -gt 50 ] || die "$workflow sample $sample installed an implausibly small tree"
      tree_sha="$(shasum -a 256 "$tree" | awk '{print $1}')"
      seconds="$(awk 'NR == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ {print $1}' "$timing")"
      [ -n "$seconds" ] || die "sample $sample timing is invalid"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tPASS\n' \
        "$workflow" "$round" "$position" "$engine" "$seconds" "$entry_count" "$tree_sha" \
        >> "$SAMPLES"
      rm -rf "$project/$install_dir"
    done
  done
done

{
  printf 'key\tvalue\n'
  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'started_utc\t%s\n' "$STARTED_UTC"
  printf 'source_commit\t%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'script_sha256\t%s\n' "$(shasum -a 256 "$ROOT/scripts/benchmark-developer-workflows.sh" | awk '{print $1}')"
  printf 'engines\t%s\n' "$ENGINES_CSV"
  printf 'rounds\t%s\n' "$ROUNDS"
  printf 'ruby_image\t%s\nnode_image\t%s\ncomposer_image\t%s\n' \
    "$RUBY_IMAGE" "$NODE_IMAGE" "$COMPOSER_IMAGE"
  printf 'rails_version\t%s\npnpm_version\t%s\ncomposer_package\t%s\ncomposer_version\t%s\n' \
    "$RAILS_VERSION" "$PNPM_VERSION" "$COMPOSER_PACKAGE" "$COMPOSER_PACKAGE_VERSION"
  printf 'container_cpus\t%s\ncontainer_memory\t%s\n' "$CONTAINER_CPUS" "$CONTAINER_MEMORY"
  printf 'rails_lock_sha256\t%s\n' "$(shasum -a 256 "$RAILS_FIXTURE/Gemfile.lock" | awk '{print $1}')"
  printf 'pnpm_lock_sha256\t%s\n' "$(shasum -a 256 "$PNPM_FIXTURE/pnpm-lock.yaml" | awk '{print $1}')"
  printf 'composer_lock_sha256\t%s\n' "$(shasum -a 256 "$COMPOSER_FIXTURE/composer.lock" | awk '{print $1}')"
  printf 'timer\tCLOCK_MONOTONIC around complete Docker run\n'
  printf 'network_during_timing\tdisabled\n'
} > "$MANIFEST"

python3 - "$SAMPLES" "$WORK/summary.json" "$WORK/summary.md" <<'PY'
import csv, json, pathlib, statistics, sys
source, json_out, markdown_out = map(pathlib.Path, sys.argv[1:])
groups = {}
with source.open(encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        if row["status"] != "PASS":
            raise SystemExit("non-PASS sample")
        groups.setdefault((row["workflow"], row["engine"]), []).append(float(row["seconds"]))
summary = []
for (workflow, engine), values in sorted(groups.items()):
    mean = statistics.fmean(values)
    summary.append({
        "workflow": workflow,
        "engine": engine,
        "samples": len(values),
        "medianSeconds": statistics.median(values),
        "minimumSeconds": min(values),
        "maximumSeconds": max(values),
        "coefficientOfVariationPercent": 0 if mean == 0 else statistics.pstdev(values) * 100 / mean,
    })
json_out.write_text(json.dumps({"schemaVersion": 1, "status": "PASS", "results": summary}, indent=2) + "\n")
lines = ["# Developer workflow benchmark", "", "All samples passed offline install and correctness checks.", "", "| Workflow | Engine | Samples | Median (s) | Min | Max | CV |", "|---|---|---:|---:|---:|---:|---:|"]
for row in summary:
    lines.append(f"| {row['workflow']} | {row['engine']} | {row['samples']} | {row['medianSeconds']:.3f} | {row['minimumSeconds']:.3f} | {row['maximumSeconds']:.3f} | {row['coefficientOfVariationPercent']:.1f}% |")
markdown_out.write_text("\n".join(lines) + "\n")
PY

rm -rf "$WORK/projects"
echo "benchmark-developer-workflows: PASS ($WORK)"
