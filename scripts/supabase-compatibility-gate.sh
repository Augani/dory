#!/bin/bash
# Runs the complete checksum- and image-inventory-pinned Supabase stack on a disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
VERSION="${DORY_RELEASE_SUPABASE_VERSION:-2.109.1}"
SHA256=""
INVENTORY=""
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
  --inventory PATH    Exact service-image inventory (defaults to the tracked 2.109.1 inventory)
  --min-free-gb N     Initial host free-space floor (default: 15)

No Supabase service is excluded. Before startup, the gate validates every enabled service tag
against its immutable public-ECR digest, preloads that digest, and assigns the exact tag locally.
It then requires the running 13-container default stack to equal that inventory, proves Postgres,
REST, auth, and storage behavior, removes only Supabase-labeled objects, and emits no API keys.
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
    --inventory) need_value "$1" "$#"; INVENTORY="$2"; shift 2 ;;
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
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--version must be an exact semantic version"
case "$MIN_FREE_GB" in ''|*[!0-9]*) die "--min-free-gb must be a positive integer" ;; esac
[ "$MIN_FREE_GB" -gt 0 ] || die "--min-free-gb must be a positive integer"
case "$(uname -m)" in
  arm64)
    ARCHIVE_ARCH=arm64
    DEFAULT_SHA=e36776717a56d704769229649349b3a382f413cb31f1fb2ba4647ef8bcf7339b
    ;;
  x86_64)
    ARCHIVE_ARCH=amd64
    DEFAULT_SHA=fee962ecf455c69497f93c19b369443b114a934161b8cecbd8a5b812c3c8c013
    ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$SHA256" ]; then
  [ "$VERSION" = 2.109.1 ] || die "--sha256 is required for a non-default Supabase version"
  SHA256="$DEFAULT_SHA"
fi
printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 is invalid"
if [ -z "$INVENTORY" ]; then
  [ "$VERSION" = 2.109.1 ] \
    || die "--inventory is required for a non-default Supabase version"
  INVENTORY="$(cd "$(dirname "$0")/.." && pwd)/.github/fixtures/supabase-cli-2.109.1-images.json"
fi
case "$INVENTORY" in /*) ;; *) die "--inventory must be absolute" ;; esac
[ -f "$INVENTORY" ] && [ ! -L "$INVENTORY" ] \
  || die "Supabase image inventory is unavailable or indirect: $INVENTORY"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
[ -d "$(dirname "$WORKROOT")" ] || die "workroot parent does not exist"
for command in curl lsof python3 shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
free_kb="$(df -Pk "$(dirname "$WORKROOT")" | awk 'NR == 2 { print $4 }')"
printf '%s\n' "$free_kb" | grep -Eq '^[0-9]+$' || die "could not determine host free space"
[ "$free_kb" -ge $((MIN_FREE_GB * 1024 * 1024)) ] \
  || die "requires at least $MIN_FREE_GB GiB free before the full Supabase stack"

mkdir -p "$WORKROOT/evidence" "$WORKROOT/project" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
PROJECT="$WORKROOT/project"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
export DOCKER_HOST="unix://$SOCKET"
export INTERNAL_IMAGE_REGISTRY=public.ecr.aws
unset DOCKER_SOCKET_LOCATION DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
docker_e version > "$EVIDENCE/docker-version.txt" || die "Docker API is not ready"

custom_network_ids() {
  docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'
}
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" \
  || die "engine has pre-existing custom networks"

cleanup_owned() {
  local ids
  ids="$(docker_e ps -aq --filter 'label=com.supabase.cli.project')"
  [ -z "$ids" ] || docker_e rm -f -v $ids > "$EVIDENCE/container-cleanup.log" 2>&1 || true
  ids="$(docker_e volume ls -q --filter 'label=com.supabase.cli.project')"
  [ -z "$ids" ] || docker_e volume rm -f $ids > "$EVIDENCE/volume-cleanup.log" 2>&1 || true
  ids="$(docker_e network ls -q --filter 'label=com.supabase.cli.project')"
  [ -z "$ids" ] || docker_e network rm $ids > "$EVIDENCE/network-cleanup.log" 2>&1 || true
}
remove_secret_evidence() {
  rm -f "$EVIDENCE/start.stderr" "$EVIDENCE/status-env.stderr"
}
cleanup() {
  set +e
  if [ -x "$DOWNLOAD/supabase" ] && [ -f "$PROJECT/supabase/config.toml" ]; then
    "$DOWNLOAD/supabase" stop --workdir "$PROJECT" --no-backup --yes \
      > "$EVIDENCE/cleanup-stop.log" 2>&1 || true
  fi
  cleanup_owned
  remove_secret_evidence
  rm -rf "$DOWNLOAD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Validate the closed inventory and prove that every enabled tag still resolves to its pinned OCI
# digest immediately before preloading. The proof contains public image identities only.
python3 - "$INVENTORY" "$VERSION" "$EVIDENCE/approved-images.tsv" \
  "$EVIDENCE/registry-proof.json" <<'PY'
import json
import re
import sys
import urllib.parse
import urllib.request

with open(sys.argv[1], encoding="utf-8") as handle:
    inventory = json.load(handle)
if not isinstance(inventory, dict) or set(inventory) != {
    "schemaVersion", "cliVersion", "registry", "services"
}:
    raise SystemExit("Supabase image inventory has an unexpected top-level shape")
if inventory["schemaVersion"] != 1 or inventory["cliVersion"] != sys.argv[2] \
        or inventory["registry"] != "public.ecr.aws":
    raise SystemExit("Supabase image inventory authority does not match the requested CLI")
services = inventory["services"]
if not isinstance(services, list) or not services:
    raise SystemExit("Supabase image inventory has no services")
expected_keys = {"service", "source", "runtime", "digest", "enabledByDefault"}
names = set()
runtimes = set()
enabled = []
for service in services:
    if not isinstance(service, dict) or set(service) != expected_keys:
        raise SystemExit("Supabase service image entry has an unexpected shape")
    name = service["service"]
    source = service["source"]
    runtime = service["runtime"]
    digest = service["digest"]
    state = service["enabledByDefault"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name):
        raise SystemExit("Supabase service name is invalid")
    if not isinstance(source, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+", source):
        raise SystemExit("Supabase source image is invalid")
    if not isinstance(runtime, str) or not re.fullmatch(
        r"public\.ecr\.aws/supabase/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+", runtime
    ):
        raise SystemExit("Supabase runtime image is not in the exact public ECR namespace")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise SystemExit("Supabase service digest is invalid")
    if not isinstance(state, bool) or name in names or runtime in runtimes:
        raise SystemExit("Supabase service inventory is duplicate or has an invalid state")
    names.add(name)
    runtimes.add(runtime)
    if state:
        enabled.append(service)
if len(enabled) != 13:
    raise SystemExit("Supabase default stack must contain exactly 13 enabled service images")

proof = []
with open(sys.argv[3], "w", encoding="utf-8") as approved:
    for service in enabled:
        runtime = service["runtime"]
        digest = service["digest"]
        leaf = runtime.removeprefix("public.ecr.aws/supabase/")
        repository, tag = leaf.rsplit(":", 1)
        scope = f"repository:supabase/{repository}:pull"
        token_url = "https://public.ecr.aws/token/?" + urllib.parse.urlencode({
            "service": "public.ecr.aws", "scope": scope
        })
        with urllib.request.urlopen(token_url, timeout=30) as response:
            token_document = json.load(response)
        token = token_document.get("token") if isinstance(token_document, dict) else None
        if not isinstance(token, str) or not token:
            raise SystemExit(f"Supabase registry returned no token for {runtime}")
        manifest_url = f"https://public.ecr.aws/v2/supabase/{repository}/manifests/{tag}"
        request = urllib.request.Request(manifest_url, method="HEAD", headers={
            "Authorization": f"Bearer {token}",
            "Accept": ",".join([
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
            ]),
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            current = response.headers.get("Docker-Content-Digest")
        if current != digest:
            raise SystemExit(f"Supabase registry digest changed for {runtime}")
        approved.write(f"{service['service']}\t{runtime}\t{digest}\n")
        proof.append({"service": service["service"], "runtime": runtime, "digest": digest})
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    json.dump({"status": "PASS", "images": proof}, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY

while IFS=$'\t' read -r service runtime digest; do
  [ -n "$service" ] || continue
  docker_e pull "$runtime@$digest" > "$EVIDENCE/image-$service-pull.log"
  docker_e tag "$runtime@$digest" "$runtime"
  [ "$(docker_e image inspect --format '{{.Id}}' "$runtime@$digest")" = \
    "$(docker_e image inspect --format '{{.Id}}' "$runtime")" ] \
    || die "Supabase local tag is not bound to approved digest: $runtime"
done < "$EVIDENCE/approved-images.tsv"

archive="$DOWNLOAD/supabase.tgz"
url="https://github.com/supabase/cli/releases/download/v$VERSION/supabase_${VERSION}_darwin_${ARCHIVE_ARCH}.tar.gz"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$archive"
printf '%s  %s\n' "$SHA256" "$archive" \
  | shasum -a 256 -c - > "$EVIDENCE/archive-checksum.txt"
tar -xzf "$archive" -C "$DOWNLOAD" supabase supabase-go
for executable in supabase supabase-go; do
  [ -f "$DOWNLOAD/$executable" ] && [ ! -L "$DOWNLOAD/$executable" ] \
    && [ -x "$DOWNLOAD/$executable" ] \
    || die "verified Supabase archive did not contain direct CLI executables"
done
"$DOWNLOAD/supabase" --version > "$EVIDENCE/supabase-version.txt"
grep -Fxq "$VERSION" "$EVIDENCE/supabase-version.txt" \
  || die "Supabase binary version differs from the requested release"

# Default ports are part of this compatibility contract; remapping a subset would not exercise the
# standard local stack that editors and SDKs discover.
for port in 54320 54321 54322 54323 54324 54325 54326 54327 54329; do
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
    || die "required Supabase default host port is already in use: $port"
done

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
  > /dev/null 2> "$EVIDENCE/start.stderr"
printf 'supabase_start=PASS\n' > "$EVIDENCE/start-proof.txt"
remove_secret_evidence

owned_ids="$(docker_e ps -aq --filter 'label=com.supabase.cli.project')"
[ "$(printf '%s\n' "$owned_ids" | sed '/^$/d' | wc -l | tr -d ' ')" = 13 ] \
  || die "full Supabase default stack did not create exactly 13 owned containers"
: > "$EVIDENCE/runtime-containers.jsonl"
for id in $owned_ids; do
  docker_e inspect --format \
    '{"id":{{json .Id}},"runtime":{{json .Config.Image}},"project":{{json (index .Config.Labels "com.supabase.cli.project")}},"running":{{json .State.Running}},"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}"none"{{end}},"imageId":{{json .Image}}}' \
    "$id" >> "$EVIDENCE/runtime-containers.jsonl"
done
image_ids="$(docker_e inspect --format '{{.Image}}' $owned_ids | sort -u)"
: > "$EVIDENCE/runtime-images.jsonl"
for id in $image_ids; do
  docker_e image inspect --format \
    '{"id":{{json .Id}},"repoDigests":{{json .RepoDigests}}}' \
    "$id" >> "$EVIDENCE/runtime-images.jsonl"
done
python3 - "$INVENTORY" "$EVIDENCE/runtime-containers.jsonl" \
  "$EVIDENCE/runtime-images.jsonl" \
  "$EVIDENCE/runtime-image-proof.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    inventory = json.load(handle)
def load_json_lines(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]

containers = load_json_lines(sys.argv[2])
images = load_json_lines(sys.argv[3])
enabled = {entry["runtime"]: entry for entry in inventory["services"] if entry["enabledByDefault"]}
if not isinstance(containers, list) or len(containers) != len(enabled):
    raise SystemExit("Supabase running container inventory is incomplete")
if not isinstance(images, list):
    raise SystemExit("Supabase local image inventory is invalid")
image_by_id = {image.get("id"): image for image in images if isinstance(image, dict)}
actual = set()
project_labels = set()
proof = []
for container in containers:
    if not isinstance(container, dict):
        raise SystemExit("Supabase container inspect shape is invalid")
    runtime = container.get("runtime")
    if runtime not in enabled or runtime in actual:
        raise SystemExit("Supabase runtime image set is unexpected or duplicated")
    actual.add(runtime)
    project = container.get("project")
    if not isinstance(project, str) or not project:
        raise SystemExit("Supabase project ownership label is missing")
    project_labels.add(project)
    if container.get("running") is not True:
        raise SystemExit("Supabase service is not running")
    health = container.get("health")
    if health not in {"none", "healthy"}:
        raise SystemExit("Supabase defined healthcheck is not healthy")
    image = image_by_id.get(container.get("imageId"))
    repo_digests = image.get("repoDigests") if isinstance(image, dict) else None
    entry = enabled[runtime]
    repository = runtime.rsplit(":", 1)[0]
    exact = f"{repository}@{entry['digest']}"
    if not isinstance(repo_digests, list) or exact not in repo_digests:
        raise SystemExit("Supabase service image is not bound to its approved digest")
    proof.append({"service": entry["service"], "runtime": runtime, "digest": entry["digest"]})
if actual != set(enabled) or len(project_labels) != 1:
    raise SystemExit("Supabase exact default image/project authority does not match")
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    json.dump({"status": "PASS", "services": sorted(proof, key=lambda item: item["service"])},
              handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY

docker_e ps --filter 'label=com.supabase.cli.project' \
  --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' > "$EVIDENCE/containers.tsv"
healthcheck_count="$(docker_e ps -q --filter 'label=com.supabase.cli.project' | while IFS= read -r id; do
  [ -z "$id" ] && continue
  docker_e inspect --format '{{if .State.Health}}1{{else}}0{{end}}' "$id"
done | awk '{ total += $1 } END { print total + 0 }')"
[ "$healthcheck_count" -ge 8 ] \
  || die "full Supabase stack exposed only $healthcheck_count Docker healthchecks"

db_container="$(docker_e ps --filter 'name=supabase_db_' \
  --filter 'label=com.supabase.cli.project' --format '{{.ID}}' | sed -n '1p')"
[ -n "$db_container" ] || die "Supabase Postgres container is missing"
docker_e exec "$db_container" psql -U postgres -d postgres -Atc \
  "select string_agg(value, ',' order by id) from public.dory_compat" \
  > "$EVIDENCE/postgres-roundtrip.txt"
grep -qx 'supabase-on-dory,seed-on-dory' "$EVIDENCE/postgres-roundtrip.txt" \
  || die "Supabase migration/seed data is missing from Postgres"

cat > "$DOWNLOAD/verify-status.py" <<'PY'
import json
import shlex
import sys
import urllib.parse
import urllib.request

values = {}
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    try:
        parsed = shlex.split(value)
        values[key] = parsed[0] if parsed else ""
    except ValueError:
        values[key] = ""
required = ["API_URL", "ANON_KEY"]
if any(not isinstance(values.get(key), str) or not values[key] for key in required):
    raise SystemExit("Supabase status omitted required local connection evidence")
api_url = values["API_URL"]
anon_key = values["ANON_KEY"]
url = urllib.parse.urlparse(api_url)
if url.scheme != "http" or url.hostname not in {"127.0.0.1", "localhost"} or url.port != 54321 \
        or url.path not in {"", "/"} or url.params or url.query or url.fragment:
    raise SystemExit("Supabase API URL is not the standard loopback endpoint")
rest_url = api_url.rstrip("/") + "/rest/v1/dory_compat?select=id,value&order=id"
request = urllib.request.Request(rest_url, headers={
    "apikey": anon_key,
    "Authorization": f"Bearer {anon_key}",
})
with urllib.request.urlopen(request, timeout=10) as response:
    rows = json.load(response)
expected = [
    {"id": 1, "value": "supabase-on-dory"},
    {"id": 2, "value": "seed-on-dory"},
]
if rows != expected:
    raise SystemExit("Supabase REST round-trip returned unexpected rows")
for endpoint in ("/auth/v1/health", "/storage/v1/status"):
    with urllib.request.urlopen(api_url.rstrip("/") + endpoint, timeout=10) as response:
        if response.status != 200:
            raise SystemExit(f"Supabase health endpoint failed: {endpoint}")
with open(sys.argv[1] + "/rest-roundtrip.json", "w", encoding="utf-8") as handle:
    json.dump(rows, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
with open(sys.argv[1] + "/status-proof.txt", "w", encoding="utf-8") as handle:
    handle.write("api_url_loopback=PASS\nanon_key_present=PASS\n")
with open(sys.argv[1] + "/auth-health.json", "w", encoding="utf-8") as handle:
    handle.write('{"status":"PASS"}\n')
with open(sys.argv[1] + "/storage-health.json", "w", encoding="utf-8") as handle:
    handle.write('{"status":"PASS"}\n')
PY
"$DOWNLOAD/supabase" status --workdir "$PROJECT" --output env \
  2> "$EVIDENCE/status-env.stderr" \
  | python3 "$DOWNLOAD/verify-status.py" "$EVIDENCE"
remove_secret_evidence

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
cleanup_owned
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Supabase gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
supabase_cli=$VERSION
supabase_archive_sha256=$SHA256
supabase_binary_sha256=$(shasum -a 256 "$DOWNLOAD/supabase" | awk '{print $1}')
supabase_go_binary_sha256=$(shasum -a 256 "$DOWNLOAD/supabase-go" | awk '{print $1}')
image_inventory_sha256=$(shasum -a 256 "$INVENTORY" | awk '{print $1}')
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
full_default_stack=PASS
exact_service_image_inventory=PASS
registry_digest_preflight=PASS
approved_digest_preload=PASS
guest_local_docker_socket=PASS
all_services_running=PASS
defined_healthchecks_healthy=PASS
docker_healthcheck_count=$healthcheck_count
postgres_migration_seed_roundtrip=PASS
postgrest_roundtrip=PASS
auth_health=PASS
storage_health=PASS
loopback_only_listeners=PASS
secret_free_evidence=PASS
supabase_stop_no_backup=PASS
owned_project_cleanup=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
rm -rf "$DOWNLOAD"
trap - EXIT INT TERM
echo "Supabase compatibility gate: PASS ($VERSION, 13 containers)"
