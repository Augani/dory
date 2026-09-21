#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root (for example: sudo ./install.sh)." >&2
  exit 77
fi
root="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
key="$root/dory-repository-key.asc"
[ -f "$key" ] || { echo "Dory repository key is missing" >&2; exit 66; }

uri_path="$(printf '%s' "$root" | sed 's/%/%25/g; s/ /%20/g')"
if command -v apt-get >/dev/null 2>&1; then
  command -v gpg >/dev/null 2>&1 \
    || { echo "gpg is required to enroll the Dory repository key" >&2; exit 69; }
  install -Dm0644 "$key" /usr/share/keyrings/dory-guest-tools.asc
  printf 'deb [signed-by=/usr/share/keyrings/dory-guest-tools.asc] file:%s/apt ./\n' \
    "$uri_path" > /etc/apt/sources.list.d/dory-guest-tools.list
  apt-get update
  apt-get install dory-guest-tools
elif command -v dnf >/dev/null 2>&1; then
  cat > /etc/yum.repos.d/dory-guest-tools.repo <<EOF
[dory-guest-tools]
name=Dory Guest Tools
baseurl=file://$uri_path/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$uri_path/dory-repository-key.asc
EOF
  dnf --assumeyes install dory-guest-tools
else
  echo "This tools image supports apt-based and Fedora dnf-based guests." >&2
  exit 69
fi

echo "Dory Guest Tools installed. Log out and back in if clipboard sharing is not active yet."
