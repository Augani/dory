#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Dory/Runtime/Machines/DoryOpenShim.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

# Extract the sh script literal between the ##""" and """## delimiters.
# Start capturing after the opener; stop at a line that is exactly """## (tolerant of any
# leading/trailing whitespace, so the extraction works regardless of the Swift file's indentation).
awk '/static let script = ##"""/{f=1;next} f && $0 ~ /^[[:space:]]*"""##[[:space:]]*$/{f=0;next} f' "$SRC" > "$WORK/dory-open"
chmod +x "$WORK/dory-open"
[ -s "$WORK/dory-open" ] && ok "extracted shim script" || no "extracted shim script"

BRIDGE="$WORK/bridge"
# Redirect the shim's fixed bridge path to our sandbox by editing a temp copy
# (anchor tolerates any leading whitespace on the BRIDGE= line).
sed "s#^[[:space:]]*BRIDGE=\"/opt/dory/bridge\"#BRIDGE=\"$BRIDGE\"#" "$WORK/dory-open" > "$WORK/dory-open.local"
chmod +x "$WORK/dory-open.local"

# Case 1: plain URL-embedded loopback port -> forward/<port>.json
( cd "$WORK" && "$WORK/dory-open.local" "http://127.0.0.1:53219/cb?code=abc" >/dev/null )
[ -f "$BRIDGE/forward/53219.json" ] && ok "url port -> forward file" || no "url port -> forward file"
grep -q '"port":53219' "$BRIDGE/forward/53219.json" 2>/dev/null && ok "forward json has port" || no "forward json has port"

# Case 1b: percent-encoded redirect_uri (127.0.0.1%3A<port>) is URL-decoded then extracted.
rm -rf "$BRIDGE"
( cd "$WORK" && "$WORK/dory-open.local" "https://auth.example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A61234%2Fcallback&code=1" >/dev/null )
[ -f "$BRIDGE/forward/61234.json" ] && ok "encoded redirect_uri -> forward file" || no "encoded redirect_uri -> forward file"

# Case 2: open request written atomically, no .tmp residue
ls "$BRIDGE/open/"*.json >/dev/null 2>&1 && ok "open request written" || no "open request written"
! ls "$BRIDGE"/open/*.tmp* >/dev/null 2>&1 && ok "no tmp residue (open)" || no "no tmp residue (open)"
! ls "$BRIDGE"/forward/*.tmp* >/dev/null 2>&1 && ok "no tmp residue (forward)" || no "no tmp residue (forward)"

# Case 3: /proc/net/tcp fixture — LISTEN (0A) loopback D2A4=53924 forwarded; ESTABLISHED (01) 1F90 skipped.
rm -rf "$BRIDGE"
PROC="$WORK/proc"; mkdir -p "$PROC"
cat > "$PROC/tcp" <<'EOF'
sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
 0: 0100007F:D2A4 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 ffff 100 0 0 10 0
 1: 0100007F:1F90 0100007F:C001 01 00000000:00000000 00:00000000 00000000  1000        0 12346 1 ffff 100 0 0 10 0
EOF
# Case 3b: /proc/net/tcp6 fixture — LISTEN (0A) loopback CFE7=53223 forwarded.
cat > "$PROC/tcp6" <<'EOF'
sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
 0: 00000000000000000000000001000000:CFE7 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22345 1 ffff 100 0 0 10 0
EOF
# Rewrite the shim to read our fixture proc files instead of /proc (tcp6 first so its substring isn't clobbered).
sed "s#/proc/net/tcp6#$PROC/tcp6#g; s#/proc/net/tcp#$PROC/tcp#g" "$WORK/dory-open.local" > "$WORK/dory-open.proc"
chmod +x "$WORK/dory-open.proc"
( cd "$WORK" && "$WORK/dory-open.proc" "https://example.com/login" >/dev/null )
[ -f "$BRIDGE/forward/53924.json" ] && ok "tcp LISTEN loopback -> forward file" || no "tcp LISTEN loopback -> forward file"
[ -f "$BRIDGE/forward/53223.json" ] && ok "tcp6 LISTEN loopback -> forward file" || no "tcp6 LISTEN loopback -> forward file"
# ESTABLISHED (st=01) socket on port 0x1F90 (8080) must NOT be forwarded.
[ ! -f "$BRIDGE/forward/8080.json" ] && ok "established socket skipped" || no "established socket skipped"

# Case 4: non-http scheme still writes an open request (host rejects; shim is dumb).
rm -rf "$BRIDGE"
( cd "$WORK" && "$WORK/dory-open.local" "vscode://x" >/dev/null )
ls "$BRIDGE/open/"*.json >/dev/null 2>&1 && ok "custom scheme still queued (host validates)" || no "custom scheme still queued (host validates)"

# Case 5: leading "open" arg (gio open <url>) is dropped, URL still parsed.
rm -rf "$BRIDGE"
( cd "$WORK" && "$WORK/dory-open.local" open "http://127.0.0.1:52001/cb" >/dev/null )
[ -f "$BRIDGE/forward/52001.json" ] && ok "leading open arg dropped" || no "leading open arg dropped"

echo "dory-open: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
