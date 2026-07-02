import Foundation

enum DoryOpenShim {
    static let path = "/usr/local/bin/dory-open"
    static let bridgeGuestDir = "/opt/dory/bridge"

    static let script = ##"""
#!/bin/sh
BRIDGE="/opt/dory/bridge"
[ "$1" = "open" ] && shift
URL="$1"
[ -n "$URL" ] || exit 0
mkdir -p "$BRIDGE/forward/" "$BRIDGE/open/" 2>/dev/null || true
TS=$(date +%s 2>/dev/null || echo 0)

emit_forward() {
  p="$1"
  [ -n "$p" ] || return 0
  [ "$p" -ge 1024 ] 2>/dev/null || return 0
  [ "$p" -le 65535 ] 2>/dev/null || return 0
  f="$BRIDGE/forward/$p.json"
  t="$f.$$.tmp"
  printf '{"port":%s,"ts":%s,"ttlSec":300}\n' "$p" "$TS" > "$t" && mv "$t" "$f"
}

DECODED=$(printf '%s' "$URL" | sed 's/%3[Aa]/:/g; s/%2[Ff]/\//g')
URLPORT=$(printf '%s' "$DECODED" | grep -Eo '127\.0\.0\.1:[0-9]+|localhost:[0-9]+' | head -n1 | sed 's/.*://')
[ -n "$URLPORT" ] && emit_forward "$URLPORT"

for tcp in /proc/net/tcp /proc/net/tcp6; do
  [ -r "$tcp" ] || continue
  awk 'NR>1 && $4=="0A" {print $2}' "$tcp" | while read -r local; do
    addr=$(printf '%s' "$local" | cut -d: -f1)
    hexp=$(printf '%s' "$local" | cut -d: -f2)
    case "$addr" in
      0100007F|00000000000000000000000001000000|00000000000000000000000000000000) ;;
      *) continue ;;
    esac
    dp=$(printf '%d' "0x$hexp" 2>/dev/null)
    emit_forward "$dp"
  done
done

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$TS-$$")
of="$BRIDGE/open/$UUID.json"
ot="$of.$$.tmp"
ESC=$(printf '%s' "$URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
CWDESC=$(printf '%s' "$PWD" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"url":"%s","cwd":"%s","ts":%s}\n' "$ESC" "$CWDESC" "$TS" > "$ot" && mv "$ot" "$of"
printf 'Opening %s on your Mac…\n' "$URL"
exit 0
"""##

    static func installCommands() -> [String] {
        [
            "install -d /usr/local/bin",
            "cat > /usr/local/bin/dory-open <<'DORYOPENEOF'\n\(script)\nDORYOPENEOF",
            "chmod +x /usr/local/bin/dory-open",
            "ln -sf /usr/local/bin/dory-open /usr/local/bin/xdg-open",
            "ln -sf /usr/local/bin/dory-open /usr/local/bin/sensible-browser",
            "ln -sf /usr/local/bin/dory-open /usr/local/bin/www-browser",
            "command -v gio >/dev/null 2>&1 || ln -sf /usr/local/bin/dory-open /usr/local/bin/gio",
            "command -v socat >/dev/null 2>&1 || (apt-get install -y socat 2>/dev/null || dnf install -y socat 2>/dev/null || apk add socat 2>/dev/null || zypper -n install socat 2>/dev/null || pacman -Sy --noconfirm socat 2>/dev/null || true)",
        ]
    }
}
