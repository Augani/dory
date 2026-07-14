#!/bin/bash
# Install the immutable candidate through Homebrew under normal quarantine, launch it once, and
# prove that uninstall removes integration without removing the durable data drive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_DIR=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-homebrew-install"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/homebrew-install-gate.sh [required options]

  --candidate-dir DIR    Downloaded immutable release candidate
  --version VERSION      Candidate marketing version
  --build BUILD          Candidate CFBundleVersion
  --source-commit SHA    Candidate's full Git commit
  --workroot DIR         Private work and retained evidence root
  --confirm TOKEN        Must be CLEAN-RELEASE-USER-HOMEBREW-INSTALL
EOF
}

die() { echo "Homebrew install gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-dir) need_value "$1" "$#"; CANDIDATE_DIR="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$CANDIDATE_DIR" ] || die "--candidate-dir is required"
[ -n "$VERSION" ] || die "--version is required"
case "$BUILD" in ''|*[!0-9]*) die "--build must be a positive integer" ;; esac
[ "$BUILD" -gt 0 ] || die "--build must be a positive integer"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
[ "$CONFIRM" = CLEAN-RELEASE-USER-HOMEBREW-INSTALL ] \
  || die "--confirm CLEAN-RELEASE-USER-HOMEBREW-INSTALL is required"
[ "${DORY_RELEASE_CLEAN_USER:-0}" = 1 ] || die "DORY_RELEASE_CLEAN_USER=1 is required"

case "$CANDIDATE_DIR" in /*) ;; *) CANDIDATE_DIR="$ROOT/$CANDIDATE_DIR" ;; esac
CANDIDATE_DIR="$(cd "$CANDIDATE_DIR" && pwd)"
case "$WORKROOT" in
  /*) ;;
  *) die "--workroot must be absolute" ;;
esac
case "$WORKROOT" in /|"$HOME"|"$ROOT"|"$CANDIDATE_DIR") die "unsafe --workroot: $WORKROOT" ;; esac

[ "$(uname -s)" = Darwin ] || die "physical macOS is required"
[ "$(uname -m)" = arm64 ] || die "physical Apple Silicon is required"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested virtualization does not qualify"
case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
  VirtualMac*) die "a physical Mac is required" ;;
esac
command -v brew >/dev/null || die "Homebrew is required"
command -v python3 >/dev/null || die "python3 is required"

ZIP="$CANDIDATE_DIR/Dory-$VERSION.zip"
SBOM="$CANDIDATE_DIR/Dory-$VERSION.cdx.json"
MANIFEST="$CANDIDATE_DIR/release-manifest.json"
[ -s "$ZIP" ] || die "candidate Homebrew ZIP is missing"
[ -s "$SBOM" ] || die "candidate SBOM is missing"
[ -s "$MANIFEST" ] || die "candidate release manifest is missing"
manifest_commit="$(python3 "$ROOT/scripts/validate-release-metadata.py" "$CANDIDATE_DIR" "$VERSION" "$BUILD")" \
  || die "candidate metadata is invalid"
[ "$manifest_commit" = "$SOURCE_COMMIT" ] || die "candidate source commit mismatch"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

APP="/Applications/Dory.app"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/Dory"
DRIVE="$APP_SUPPORT/Dory.dorydrive"
SELECTION="$APP_SUPPORT/data-drive-selection.json"
PREF_DOMAIN="com.pythonxi.Dory"
BREW_BIN="$(brew --prefix)/bin/dory"
TAP="doryci/release-install"
CASK="$TAP/dory"
PROFILE_NAMES=(.zprofile .zshrc .bash_profile .bashrc .profile)

[ ! -e "$APP" ] || die "$APP already exists"
[ ! -e "$STATE" ] || die "$STATE already exists"
[ ! -e "$APP_SUPPORT" ] || die "$APP_SUPPORT already exists"
[ ! -e "$PLIST" ] || die "$PLIST already exists"
[ ! -e "$BREW_BIN" ] && [ ! -L "$BREW_BIN" ] || die "$BREW_BIN already exists"
launchctl print "$SERVICE" >/dev/null 2>&1 && die "dev.dory.doryd is already loaded"
defaults export "$PREF_DOMAIN" - >/dev/null 2>&1 && die "Dory preferences already exist"
brew list --cask 2>/dev/null | grep -qx dory && die "a Dory cask is already installed"
python3 - "$HOME/.docker/contexts/meta" <<'PY' || die "Docker context 'dory' already exists"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for path in root.glob("*/meta.json"):
    try:
        if json.loads(path.read_text(encoding="utf-8")).get("Name") == "dory":
            raise SystemExit(1)
    except (OSError, ValueError):
        continue
PY
for process in Dory doryd dory-hv dory-vmm OrbStack colima limactl; do
  pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 && die "$process is already running"
done

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT/evidence" "$WORKROOT/private-profiles"
EVIDENCE="$WORKROOT/evidence"
python3 - "$HOME" "$WORKROOT/private-profiles" "$EVIDENCE/profile-baseline.json" \
  "${PROFILE_NAMES[@]}" <<'PY'
import hashlib, json, os, pathlib, shutil, stat, sys

home, private, evidence, *names = sys.argv[1:]
private_root = pathlib.Path(private)
rows = []
for index, name in enumerate(names):
    path = pathlib.Path(home, name)
    if path.is_symlink():
        kind = "symlink"
        link = os.readlink(path)
        target = path.resolve(strict=True)
    elif path.exists():
        kind = "file"
        link = None
        target = path
    else:
        rows.append({"name": name, "kind": "missing"})
        continue
    backup = private_root / str(index)
    shutil.copy2(target, backup)
    content = target.read_bytes()
    rows.append({
        "name": name,
        "kind": kind,
        "link": link,
        "target": str(target),
        "backup": str(backup),
        "sha256": hashlib.sha256(content).hexdigest(),
        "mode": stat.S_IMODE(target.stat().st_mode),
    })
pathlib.Path(private, "profiles.json").write_text(json.dumps(rows), encoding="utf-8")
public = [{key: value for key, value in row.items() if key not in {"target", "backup", "link"}} for row in rows]
pathlib.Path(evidence).write_text(json.dumps(public, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

SERVER_PID=""
MUTATION_STARTED=0
TRASH_MARKER=""
cleanup() {
  set +e
  if [ "$MUTATION_STARTED" -eq 1 ]; then
    if [ -x "$APP/Contents/Helpers/dory" ]; then
      "$APP/Contents/Helpers/dory" uninstall >/dev/null 2>&1 || true
    fi
    brew uninstall --cask --force "$CASK" >/dev/null 2>&1 || true
    osascript -e 'tell application id "com.pythonxi.Dory" to quit' >/dev/null 2>&1 || true
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    if [ -d "$APP" ] && [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$PREF_DOMAIN" ]; then
      rm -rf "$APP"
    fi
    rm -f "$PLIST"
    rm -rf "$STATE" "$APP_SUPPORT"
    defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
  fi
  brew untap --force "$TAP" >/dev/null 2>&1 || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  [ -z "$SERVER_PID" ] || wait "$SERVER_PID" >/dev/null 2>&1 || true
  if [ -n "$TRASH_MARKER" ] && [ -d "$HOME/.Trash" ]; then
    while IFS= read -r trashed; do
      case "$(basename "$trashed")" in
        .dory|.dory\ *|com.pythonxi.Dory.plist|com.pythonxi.Dory.plist\ *|com.pythonxi.Dory|com.pythonxi.Dory\ *)
          rm -rf "$trashed"
          ;;
      esac
    done < <(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -newer "$TRASH_MARKER" -print 2>/dev/null)
  fi
  python3 - "$HOME" "$WORKROOT/private-profiles/profiles.json" <<'PY'
import json, os, pathlib, shutil, sys

home = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
if not manifest.is_file():
    raise SystemExit(0)
for row in json.loads(manifest.read_text(encoding="utf-8")):
    path = home / row["name"]
    if row["kind"] == "missing":
        if path.is_symlink() or path.exists():
            path.unlink()
        continue
    if row["kind"] == "symlink" and (not path.is_symlink() or os.readlink(path) != row["link"]):
        if path.is_symlink() or path.exists():
            path.unlink()
        path.symlink_to(row["link"])
    elif row["kind"] == "file" and path.is_symlink():
        path.unlink()
    target = pathlib.Path(row["target"])
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(row["backup"], target)
PY
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MUTATION_STARTED=1
brew untap --force "$TAP" >/dev/null 2>&1 || true
brew tap-new "$TAP" >/dev/null
TAP_ROOT="$(brew --repository "$TAP")"
mkdir -p "$TAP_ROOT/Casks"
PORT_FILE="$WORKROOT/http-port"
python3 - "$CANDIDATE_DIR" "$PORT_FILE" >"$EVIDENCE/http.log" 2>&1 <<'PY' &
import functools, http.server, pathlib, sys

root, port_file = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
pathlib.Path(port_file).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
[ -s "$PORT_FILE" ] || die "loopback artifact server did not start"
PORT="$(cat "$PORT_FILE")"
LOCAL_URL="http://127.0.0.1:$PORT/$(basename "$ZIP")"

python3 - "$ROOT/Casks/dory.rb" "$TAP_ROOT/Casks/dory.rb" "$VERSION" "$ZIP_SHA" "$LOCAL_URL" <<'PY'
import pathlib, re, sys

source, target, version, digest, url = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
replacements = [
    (r'(?m)^  version "[^"]+"$', f'  version "{version}"'),
    (r'(?m)^  sha256 "[0-9a-f]+"$', f'  sha256 "{digest}"'),
    (r'(?m)^  url ".*"$', f'  url "{url}"'),
]
for pattern, replacement in replacements:
    text, count = re.subn(pattern, replacement, text)
    if count != 1:
        raise SystemExit(f"cask replacement count was {count}: {pattern}")
pathlib.Path(target).write_text(text, encoding="utf-8")
PY
cp "$ROOT/Casks/dory.rb" "$EVIDENCE/production-dory.rb"
cp "$TAP_ROOT/Casks/dory.rb" "$EVIDENCE/local-install-dory.rb"
brew style "$ROOT/Casks/dory.rb" >"$EVIDENCE/style.log" 2>&1

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
brew install --cask --require-sha --appdir=/Applications "$CASK" \
  >"$EVIDENCE/brew-install.log" 2>&1
[ -d "$APP" ] || die "Homebrew did not install Dory.app"
[ -L "$BREW_BIN" ] || die "Homebrew did not link the dory command"
[ "$(realpath "$BREW_BIN")" = "$APP/Contents/Helpers/dory" ] \
  || die "Homebrew linked dory to the wrong app"
for helper in docker docker-compose docker-buildx kubectl dory; do
  [ -L "$HOME/.dory/bin/$helper" ] || die "cask postflight did not install $helper"
done

codesign --verify --deep --strict "$APP" >"$EVIDENCE/codesign.log" 2>&1
xcrun stapler validate "$APP" >"$EVIDENCE/stapler.log" 2>&1
spctl --assess --type execute --verbose=4 "$APP" >"$EVIDENCE/gatekeeper.log" 2>&1
xattr -p com.apple.quarantine "$APP" >"$EVIDENCE/quarantine.txt" \
  || die "Homebrew installation did not preserve normal quarantine"
"$ROOT/scripts/verify-release-sbom.py" --sbom "$SBOM" --app "$APP" \
  --version "$VERSION" --source-commit "$SOURCE_COMMIT" >"$EVIDENCE/sbom.log"

defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool false
open -n "$APP"
READY=0
for _ in $(seq 1 360); do
  if [ -S "$STATE/dory.sock" ] \
     && curl -fsS --max-time 2 --unix-socket "$STATE/dory.sock" http://d/_ping >/dev/null 2>&1; then
    READY=1
    break
  fi
  pgrep -u "$(id -u)" -x Dory >/dev/null 2>&1 || die "Dory exited during first launch"
  sleep 0.5
done
[ "$READY" -eq 1 ] || die "Homebrew-installed Dory did not become ready"
"$APP/Contents/Helpers/docker" -H "unix://$STATE/dory.sock" version \
  >"$EVIDENCE/docker-version.txt"
[ -s "$DRIVE/drive.json" ] || die "first launch did not create the durable Dory drive"
[ -s "$SELECTION" ] || die "first launch did not record the selected Dory drive"
python3 - "$DRIVE/drive.json" <<'PY'
import json, pathlib, sys, uuid
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["kind"] == "dev.dory.data-drive"
assert data["schemaVersion"] == 1
assert data["product"] == "Dory"
uuid.UUID(data["id"])
PY
PRESERVATION_SENTINEL="$DRIVE/homebrew-uninstall-preservation.txt"
SELECTION_SHA="$(shasum -a 256 "$SELECTION" | awk '{print $1}')"
printf 'source_commit=%s\nzip_sha256=%s\n' "$SOURCE_COMMIT" "$ZIP_SHA" \
  > "$PRESERVATION_SENTINEL"
cp -p "$APP/Contents/Helpers/docker" "$WORKROOT/candidate-docker"

brew uninstall --cask "$CASK" >"$EVIDENCE/brew-uninstall.log" 2>&1
[ ! -e "$APP" ] || die "Homebrew uninstall left Dory.app installed"
[ ! -e "$BREW_BIN" ] && [ ! -L "$BREW_BIN" ] || die "Homebrew uninstall left its dory link"
launchctl print "$SERVICE" >/dev/null 2>&1 && die "Homebrew uninstall left doryd loaded"
[ ! -e "$PLIST" ] || die "Homebrew uninstall left the doryd LaunchAgent"
for _ in $(seq 1 120); do
  remaining=0
  for process in Dory doryd dory-hv dory-vmm; do
    pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 && remaining=1
  done
  [ "$remaining" -eq 1 ] || break
  sleep 0.25
done
for process in Dory doryd dory-hv dory-vmm; do
  pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
    && die "Homebrew uninstall left $process running"
done
if HOME="$HOME" "$WORKROOT/candidate-docker" context inspect dory >/dev/null 2>&1; then
  die "Homebrew uninstall left the Dory Docker context"
fi
[ "$(HOME="$HOME" "$WORKROOT/candidate-docker" context show 2>/dev/null)" = default ] \
  || die "Homebrew uninstall did not restore the default Docker context"
for helper in docker docker-compose docker-buildx kubectl dory; do
  [ ! -e "$HOME/.dory/bin/$helper" ] && [ ! -L "$HOME/.dory/bin/$helper" ] \
    || die "Homebrew uninstall left the $helper integration"
done
[ ! -e "$HOME/.docker/cli-plugins/docker-compose" ] \
  && [ ! -L "$HOME/.docker/cli-plugins/docker-compose" ] \
  || die "Homebrew uninstall left the owned Compose plugin"
[ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] \
  && [ ! -L "$HOME/.docker/cli-plugins/docker-buildx" ] \
  || die "Homebrew uninstall left the owned Buildx plugin"
[ -f "$PRESERVATION_SENTINEL" ] || die "Homebrew uninstall removed the durable Dory drive"
[ "$(shasum -a 256 "$SELECTION" | awk '{print $1}')" = "$SELECTION_SHA" ] \
  || die "Homebrew uninstall changed the selected-drive authority"
grep -qx "source_commit=$SOURCE_COMMIT" "$PRESERVATION_SENTINEL"
grep -qx "zip_sha256=$ZIP_SHA" "$PRESERVATION_SENTINEL"

python3 - "$HOME" "$WORKROOT/private-profiles/profiles.json" <<'PY'
import hashlib, json, os, pathlib, stat, sys

home = pathlib.Path(sys.argv[1])
for row in json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")):
    path = home / row["name"]
    if row["kind"] == "missing":
        assert not path.exists() and not path.is_symlink(), f"created profile remains: {path}"
        continue
    assert path.exists() or path.is_symlink(), f"profile is missing: {path}"
    if row["kind"] == "symlink":
        assert path.is_symlink() and os.readlink(path) == row["link"], f"profile symlink changed: {path}"
    else:
        assert not path.is_symlink(), f"profile became a symlink: {path}"
    target = path.resolve(strict=True)
    assert hashlib.sha256(target.read_bytes()).hexdigest() == row["sha256"], f"profile bytes changed: {path}"
    assert stat.S_IMODE(target.stat().st_mode) == row["mode"], f"profile mode changed: {path}"
PY

# Zap is intentionally stronger than uninstall, but the user's selected drive remains out of scope.
TRASH_MARKER="$WORKROOT/pre-zap-trash-marker"
touch "$TRASH_MARKER"
brew install --cask --require-sha --appdir=/Applications "$CASK" \
  >"$EVIDENCE/brew-reinstall-for-zap.log" 2>&1
[ -d "$APP" ] || die "Homebrew could not reinstall Dory for zap certification"
brew uninstall --cask --zap "$CASK" >"$EVIDENCE/brew-zap.log" 2>&1
[ ! -e "$APP" ] || die "Homebrew zap left Dory.app installed"
[ ! -e "$STATE" ] || die "Homebrew zap left transient Dory state"
[ ! -e "$HOME/Library/Preferences/$PREF_DOMAIN.plist" ] \
  || die "Homebrew zap left Dory preferences"
[ -f "$PRESERVATION_SENTINEL" ] || die "Homebrew zap removed the durable Dory drive"
[ "$(shasum -a 256 "$SELECTION" | awk '{print $1}')" = "$SELECTION_SHA" ] \
  || die "Homebrew zap changed the selected-drive authority"
HOME="$HOME" "$WORKROOT/candidate-docker" context inspect dory >/dev/null 2>&1 \
  && die "Homebrew zap left the Dory Docker context"
python3 - "$HOME" "$WORKROOT/private-profiles/profiles.json" <<'PY'
import hashlib, json, os, pathlib, stat, sys

home = pathlib.Path(sys.argv[1])
for row in json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")):
    path = home / row["name"]
    if row["kind"] == "missing":
        assert not path.exists() and not path.is_symlink(), f"created profile remains after zap: {path}"
        continue
    assert path.exists() or path.is_symlink(), f"profile is missing after zap: {path}"
    if row["kind"] == "symlink":
        assert path.is_symlink() and os.readlink(path) == row["link"], f"profile symlink changed after zap: {path}"
    else:
        assert not path.is_symlink(), f"profile became a symlink after zap: {path}"
    target = path.resolve(strict=True)
    assert hashlib.sha256(target.read_bytes()).hexdigest() == row["sha256"], f"profile bytes changed after zap: {path}"
    assert stat.S_IMODE(target.stat().st_mode) == row["mode"], f"profile mode changed after zap: {path}"
PY

brew --version > "$EVIDENCE/brew-version.txt"
sw_vers > "$EVIDENCE/macos-version.txt"
{
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'run_id=%s\n' "${GITHUB_RUN_ID:-local}"
  printf 'run_attempt=%s\n' "${GITHUB_RUN_ATTEMPT:-local}"
  printf 'version=%s\n' "$VERSION"
  printf 'build=%s\n' "$BUILD"
  printf 'zip_sha256=%s\n' "$ZIP_SHA"
  printf 'normal_quarantine=PASS\n'
  printf 'gatekeeper=PASS\n'
  printf 'sbom=PASS\n'
  printf 'first_launch=PASS\n'
  printf 'data_drive_preserved=PASS\n'
  printf 'zap_preserved_data=PASS\n'
  printf 'zap_removed_transient_state=PASS\n'
  printf 'profile_restoration=PASS\n'
  printf 'status=PASS\n'
} > "$EVIDENCE/manifest.txt"

echo "Homebrew install gate: PASS ($EVIDENCE/manifest.txt)"
