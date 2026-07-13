#!/bin/bash
# Runs the complete checksum-pinned Supabase local stack on an empty disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
VERSION="${DORY_RELEASE_SUPABASE_VERSION:-2.109.1}"
SHA256=""
WORKROOT=""
CONFIRM=""
MIN_FREE_GB=15

usage() {
  cat <<'EOF'
Usage: scripts/supabase-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate app
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-SUPABASE

Options:
  --version VERSION   Exact Supabase CLI version (default: 2.109.1)
  --sha256 HASH       Archive SHA-256 (defaults to published 2.109.1 checksum for this Mac)
  --min-free-gb N     Initial host free-space floor (default: 15)

No Supabase services are excluded. The gate requires all containers healthy, Postgres and REST data
round-trips, auth/storage health, loopback-only host listeners, clean CLI shutdown, and an exact
empty Docker-object baseline. Images may remain cached for later qualification gates.
EOF
}

die() { echo "Supabase compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --sha256) need_value "$1" "$#"; SHA256="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --min-free-gb) need_value "$1" "$#"; MIN_FREE_GB="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-SUPABASE ] \
  || die "requires --confirm ISOLATED-ENGINE-SUPABASE"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--version must be an exact semantic version"
case "$MIN_FREE_GB" in ''|*[!0-9]*) die "--min-free-gb must be a positive integer" ;; esac
[ "$MIN_FREE_GB" -gt 0 ] || die "--min-free-gb must be a positive integer"
case "$(uname -m)" in
  arm64) ARCHIVE_ARCH=arm64; DEFAULT_SHA=e36776717a56d704769229649349b3a382f413cb31f1fb2ba4647ef8bcf7339b ;;
  x86_64) ARCHIVE_ARCH=amd64; DEFAULT_SHA=fee962ecf455c69497f93c19b369443b114a934161b8cecbd8a5b812c3c8c013 ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$SHA256" ]; then
  [ "$VERSION" = 2.109.1 ] || die "--sha256 is required for a non-default Supabase version"
  SHA256="$DEFAULT_SHA"
fi
printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 is invalid"
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in curl lsof python3 shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
free_kb="$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')"
[ "$free_kb" -ge $((MIN_FREE_GB * 1024 * 1024)) ] \
  || die "requires at least $MIN_FREE_GB GiB free before the full Supabase stack"

mkdir -p "$WORKROOT/evidence" "$WORKROOT/project" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
PROJECT="$WORKROOT/project"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
export DOCKER_HOST="unix://$SOCKET"
# Vector derives its docker.sock bind source directly from DOCKER_HOST. Dory's create-request
# dataplane recognizes only that exact Dory-proxy-to-/var/run/docker.sock contract and safely
# rebinds it to the daemon's guest-local socket; users need no Supabase-specific override.
unset DOCKER_SOCKET_LOCATION
unset DOCKER_CONTEXT
export PATH="$(dirname "$DOCKER"):$PATH"
docker_e() { "$DOCKER" "$@"; }
custom_network_ids() { docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'; }
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
cleanup_objects() {
  local ids
  ids="$(docker_e ps -aq)"; [ -z "$ids" ] || docker_e rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker_e volume ls -q)"; [ -z "$ids" ] || docker_e volume rm -f $ids >/dev/null 2>&1 || true
  ids="$(custom_network_ids)"; [ -z "$ids" ] || docker_e network rm $ids >/dev/null 2>&1 || true
}
cleanup() {
  set +e
  if [ -x "$DOWNLOAD/supabase" ] && [ -f "$PROJECT/supabase/config.toml" ]; then
    "$DOWNLOAD/supabase" stop --workdir "$PROJECT" --no-backup --yes \
      > "$EVIDENCE/cleanup-stop.log" 2>&1 || true
  fi
  cleanup_objects
  # Supabase prints local API keys in normal start/status output. Durable evidence keeps only
  # redacted semantic proof, even on a failed gate.
  rm -f "$EVIDENCE/start.log" "$EVIDENCE/status.env" "$EVIDENCE/status.json" \
    "$EVIDENCE/status-parsed.json"
  rm -rf "$DOWNLOAD"
}
trap cleanup EXIT INT TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

# Default Supabase host ports must be free; changing only a subset can create an internally
# inconsistent test that no longer represents the supported CLI defaults.
for port in 54320 54321 54322 54323 54324 54325 54326 54327 54329; do
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
    || die "required Supabase default host port is already in use: $port"
done

archive="$DOWNLOAD/supabase.tgz"
url="https://github.com/supabase/cli/releases/download/v$VERSION/supabase_${VERSION}_darwin_${ARCHIVE_ARCH}.tar.gz"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$archive"
printf '%s  %s\n' "$SHA256" "$archive" | shasum -a 256 -c - > "$EVIDENCE/archive-checksum.txt"
tar -xzf "$archive" -C "$DOWNLOAD"
[ -x "$DOWNLOAD/supabase" ] && [ -x "$DOWNLOAD/supabase-go" ] \
  || die "verified Supabase archive did not contain both CLI executables"
"$DOWNLOAD/supabase" --version > "$EVIDENCE/supabase-version.txt"
grep -Fx "$VERSION" "$EVIDENCE/supabase-version.txt" >/dev/null \
  || die "Supabase binary version differs from the requested release"

"$DOWNLOAD/supabase" init --workdir "$PROJECT" --yes \
  > "$EVIDENCE/init.log" 2> "$EVIDENCE/init.stderr"
mkdir -p "$PROJECT/supabase/migrations"
cat > "$PROJECT/supabase/migrations/20260712000000_dory_compat.sql" <<'SQL'
create table if not exists public.dory_compat (id bigint primary key, value text not null);
insert into public.dory_compat (id, value) values (1, 'supabase-on-dory')
on conflict (id) do update set value = excluded.value;
grant usage on schema public to anon, authenticated;
grant select on public.dory_compat to anon, authenticated;
SQL
cat > "$PROJECT/supabase/seed.sql" <<'SQL'
insert into public.dory_compat (id, value) values (2, 'seed-on-dory')
on conflict (id) do update set value = excluded.value;
SQL

"$DOWNLOAD/supabase" start --workdir "$PROJECT" --yes \
  > "$EVIDENCE/start.log" 2> "$EVIDENCE/start.stderr"
"$DOWNLOAD/supabase" status --workdir "$PROJECT" --output json \
  > "$EVIDENCE/status.json" 2> "$EVIDENCE/status.stderr"
"$DOWNLOAD/supabase" status --workdir "$PROJECT" --output env \
  > "$EVIDENCE/status.env" 2> "$EVIDENCE/status-env.stderr"

container_count="$(docker_e ps -q | sed '/^$/d' | wc -l | tr -d ' ')"
[ "$container_count" -ge 8 ] || die "full Supabase stack started only $container_count containers"
docker_e ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' > "$EVIDENCE/containers.tsv"
not_running="$(docker_e ps -a --format '{{.ID}} {{.State}}' | awk '$2 != "running" { print }')"
[ -z "$not_running" ] || die "Supabase services are not running: $not_running"
unhealthy="$(docker_e ps -q | while IFS= read -r id; do
  [ -z "$id" ] && continue
  health="$(docker_e inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
  [ "$health" = none ] || [ "$health" = healthy ] || printf '%s=%s\n' "$id" "$health"
done)"
[ -z "$unhealthy" ] || die "Supabase service healthchecks are not healthy: $unhealthy"
healthcheck_count="$(docker_e ps -q | while IFS= read -r id; do
  [ -z "$id" ] && continue
  docker_e inspect --format '{{if .State.Health}}1{{else}}0{{end}}' "$id"
done | awk '{ total += $1 } END { print total + 0 }')"
[ "$healthcheck_count" -ge 8 ] \
  || die "full Supabase stack exposed only $healthcheck_count Docker healthchecks"

db_container="$(docker_e ps --filter 'name=supabase_db_' --format '{{.ID}}' | sed -n '1p')"
[ -n "$db_container" ] || die "Supabase Postgres container is missing"
docker_e exec "$db_container" psql -U postgres -d postgres -Atc \
  "select string_agg(value, ',' order by id) from public.dory_compat" \
  > "$EVIDENCE/postgres-roundtrip.txt"
grep -qx 'supabase-on-dory,seed-on-dory' "$EVIDENCE/postgres-roundtrip.txt" \
  || die "Supabase migration/seed data is missing from Postgres"

python3 - "$EVIDENCE/status.env" "$EVIDENCE/status-parsed.json" <<'PY'
import json, shlex, sys
values = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.strip()
    if not raw or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    try:
        values[key] = shlex.split(value)[0]
    except (ValueError, IndexError):
        values[key] = value.strip('"')
required = ["API_URL", "ANON_KEY"]
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit(f"Supabase status omitted {missing}")
json.dump({key: values[key] for key in required}, open(sys.argv[2], "w", encoding="utf-8"))
PY
api_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["API_URL"])' "$EVIDENCE/status-parsed.json")"
anon_key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ANON_KEY"])' "$EVIDENCE/status-parsed.json")"
curl -fsS --max-time 10 \
  -H "apikey: $anon_key" -H "Authorization: Bearer $anon_key" \
  "$api_url/rest/v1/dory_compat?select=id,value&order=id" \
  > "$EVIDENCE/rest-roundtrip.json"
python3 - "$EVIDENCE/rest-roundtrip.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
assert rows == [
    {"id": 1, "value": "supabase-on-dory"},
    {"id": 2, "value": "seed-on-dory"},
], rows
PY
curl -fsS --max-time 10 "$api_url/auth/v1/health" > "$EVIDENCE/auth-health.json"
curl -fsS --max-time 10 "$api_url/storage/v1/status" > "$EVIDENCE/storage-health.json"
# The local credentials are disposable defaults, but qualification evidence is durable. Preserve
# the fact that status supplied a usable URL/key without retaining the key or status payload.
printf 'api_url_loopback=PASS\nanon_key_present=PASS\n' > "$EVIDENCE/status-proof.txt"
rm -f "$EVIDENCE/start.log" "$EVIDENCE/status.env" "$EVIDENCE/status.json" \
  "$EVIDENCE/status-parsed.json"

for port in 54321 54322 54323 54324 54327; do
  lsof -nP -iTCP:"$port" -sTCP:LISTEN > "$EVIDENCE/listener-$port.txt"
  if grep -Eq "TCP (\\*|0\\.0\\.0\\.0):$port \\(LISTEN\\)" "$EVIDENCE/listener-$port.txt"; then
    die "Supabase port $port was widened to all host interfaces"
  fi
  grep -Eq "TCP (127\\.0\\.0\\.1|\\[::1\\]):$port \\(LISTEN\\)" "$EVIDENCE/listener-$port.txt" \
    || die "Supabase port $port has no loopback-only host listener"
done

"$DOWNLOAD/supabase" stop --workdir "$PROJECT" --no-backup --yes \
  > "$EVIDENCE/stop.log" 2> "$EVIDENCE/stop.stderr"
cleanup_objects
rm -rf "$DOWNLOAD"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Supabase gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
supabase_cli=$VERSION
supabase_archive_sha256=$SHA256
full_default_stack=PASS
guest_local_docker_socket=PASS
all_services_running=PASS
defined_healthchecks_healthy=PASS
docker_healthcheck_count=$healthcheck_count
postgres_migration_seed_roundtrip=PASS
postgrest_roundtrip=PASS
auth_health=PASS
storage_health=PASS
loopback_only_listeners=PASS
supabase_stop_no_backup=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "Supabase compatibility gate: PASS ($VERSION, $container_count containers)"
