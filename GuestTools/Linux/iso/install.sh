#!/bin/sh
set -eu

action="${1:-install}"
if [ "$#" -gt 1 ]; then
  echo "Usage: sudo ./install.sh [install|rollback|uninstall]" >&2
  exit 64
fi
case "$action" in
  install|rollback|uninstall) ;;
  *) echo "Usage: sudo ./install.sh [install|rollback|uninstall]" >&2; exit 64 ;;
esac
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root (for example: sudo ./install.sh)." >&2
  exit 77
fi
# apt/dnf serialize their package database, but two Dory installers could publish the same
# temporary dnf repository ID from different mounted ISOs before either manager acquires that
# lock. Keep one installer-owned advisory lock through repository setup, the package transaction,
# service activation and cleanup. Never unlink the lock file: a waiting process could otherwise
# lock a different inode while the first installer is still running.
command -v flock >/dev/null 2>&1 || {
  echo "flock is required to serialize Dory Guest Tools transactions" >&2
  exit 69
}
umask 077
lock_path=/run/dory-guest-tools-installer.lock
[ ! -L "$lock_path" ] && { [ ! -e "$lock_path" ] || [ -f "$lock_path" ]; } || {
  echo "Dory Guest Tools installer lock is not a direct regular file" >&2
  exit 73
}
exec 9>"$lock_path"
flock -n 9 || {
  echo "Another Dory Guest Tools transaction is already running" >&2
  exit 75
}
root="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
key="$root/dory-repository-key.asc"
[ "$action" = uninstall ] || [ -f "$key" ] \
  || { echo "Dory repository key is missing" >&2; exit 66; }

uri_path="$(printf '%s' "$root" | sed 's/%/%25/g; s/ /%20/g')"
legacy_repo=""
legacy_backup=""
legacy_retire_committed=0
apt_lists=""
retire_legacy_repository() {
  legacy_repo="$1"
  [ -e "$legacy_repo" ] || [ -L "$legacy_repo" ] || return 0
  [ -f "$legacy_repo" ] && [ ! -L "$legacy_repo" ] || {
    echo "Existing Dory repository configuration is indirect: $legacy_repo" >&2
    return 65
  }
  case "$legacy_repo" in
    *.list)
      [ "$(wc -l < "$legacy_repo")" -eq 1 ] \
        && grep -Eq '^deb \[signed-by=/usr/share/keyrings/dory-guest-tools\.asc\] file:.*/apt \./$' "$legacy_repo" || {
        echo "Existing Dory apt repository was modified; review it before continuing" >&2
        return 65
      } ;;
    *.repo)
      # The earlier installer wrote exactly these seven lines. A file with extra options,
      # another repository, or a different key is administrator-owned configuration, even if
      # it retains Dory's name and base URL; never silently retire it on an upgrade.
      legacy_lines="$(wc -l < "$legacy_repo")"
      legacy_baseurl="$(sed -n '3p' "$legacy_repo")"
      case "$legacy_baseurl" in
        baseurl=file://*/rpm) legacy_uri="${legacy_baseurl#baseurl=file://}";
          legacy_uri="${legacy_uri%/rpm}" ;;
        *) legacy_uri="" ;;
      esac
      [ "$legacy_lines" -eq 7 ] \
        && [ "$(sed -n '1p' "$legacy_repo")" = '[dory-guest-tools]' ] \
        && [ "$(sed -n '2p' "$legacy_repo")" = 'name=Dory Guest Tools' ] \
        && [ -n "$legacy_uri" ] \
        && [ "$(sed -n '4p' "$legacy_repo")" = 'enabled=1' ] \
        && [ "$(sed -n '5p' "$legacy_repo")" = 'gpgcheck=1' ] \
        && [ "$(sed -n '6p' "$legacy_repo")" = 'repo_gpgcheck=1' ] \
        && [ "$(sed -n '7p' "$legacy_repo")" = "gpgkey=file://$legacy_uri/dory-repository-key.asc" ] || {
        echo "Existing Dory dnf repository was modified; review it before continuing" >&2
        return 65
      } ;;
  esac
  temporary_backup="$(mktemp "$(dirname "$legacy_repo")/.dory-legacy.XXXXXX")"
  if ! mv "$legacy_repo" "$temporary_backup"; then
    rm -f "$temporary_backup"
    return 73
  fi
  legacy_backup="$temporary_backup"
}

cleanup_repository() {
  status=$?
  [ -z "${repo:-}" ] || rm -f "$repo" || :
  [ -z "${keyring:-}" ] || rm -f "$keyring" || :
  [ -z "${preferences:-}" ] || rm -f "$preferences" || :
  [ -z "$apt_lists" ] || rm -r "$apt_lists" || :
  if [ -n "$legacy_backup" ]; then
    if [ "$status" -eq 0 ] || [ "$legacy_retire_committed" -eq 1 ]; then
      rm -f "$legacy_backup"
    else
      [ ! -e "$legacy_repo" ] && [ ! -L "$legacy_repo" ] || {
        echo "Legacy Dory repository backup was retained at $legacy_backup" >&2
        exit 73
      }
      mv "$legacy_backup" "$legacy_repo"
    fi
  fi
}
trap cleanup_repository EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

start_guest_agent() {
  # Native package scriptlets can run during image construction. Only this explicit in-guest
  # installer requires a live desktop agent immediately after the verified transaction.
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || {
    echo "Dory Guest Tools were installed, but a running systemd guest is required to start the agent" >&2
    return 69
  }
  systemctl daemon-reload
  systemctl enable dory-agent.service
  systemctl restart dory-agent.service
  systemctl is-active --quiet dory-agent.service || {
    echo "Dory Guest Tools were installed, but dory-agent.service did not become active" >&2
    return 69
  }
}

# Bind the transaction to the native package on this ISO before changing any repository.
# These helpers are shared by preflight and post-transaction verification; a successful package
# manager exit is not proof that the selected native agent is installed and configured.
inspect_debian_package() {
  [ -f "$1" ] && [ ! -L "$1" ] || {
    echo "offline Debian package must be a direct regular file" >&2; return 65;
  }
  package_name="$(dpkg-deb --field "$1" Package)" || return 65
  package_version="$(dpkg-deb --field "$1" Version)" || return 65
  package_architecture="$(dpkg-deb --field "$1" Architecture)" || return 65
  native_architecture="$(dpkg --print-architecture)" || return 65
  [ "$package_name" = dory-guest-tools ] && [ -n "$package_version" ] \
    && [ "${#package_version}" -le 256 ] || {
    echo "offline Debian package has the wrong identity or version" >&2; return 65;
  }
  case "$package_version" in *[!A-Za-z0-9.+:~\-]*)
    echo "offline Debian package version is malformed" >&2; return 65 ;; esac
  case "$(uname -m):$native_architecture:$package_architecture" in
    aarch64:arm64:arm64|x86_64:amd64:amd64) ;;
    *) echo "offline Debian package does not match the native guest architecture" >&2; return 65 ;;
  esac
}

verify_installed_debian_package() {
  # One database observation; do not combine status/version/architecture from separate queries.
  installed_identity="$(dpkg-query --show --showformat='${Status}\n${Version}\n${Architecture}' dory-guest-tools)" || return 65
  expected_identity="$(printf 'install ok installed\n%s\n%s' "$package_version" "$package_architecture")"
  [ "$installed_identity" = "$expected_identity" ] || {
    echo "apt did not configure the exact native package from this tools ISO" >&2; return 65;
  }
}

inspect_rpm_package() {
  [ -f "$1" ] && [ ! -L "$1" ] || {
    echo "offline RPM package must be a direct regular file" >&2; return 65;
  }
  package_name="$(rpm -qp --queryformat '%{NAME}' "$1")" || return 65
  package_version="$(rpm -qp --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' "$1")" || return 65
  package_architecture="$(rpm -qp --queryformat '%{ARCH}' "$1")" || return 65
  native_architecture="$(rpm --eval '%{_arch}')" || return 65
  [ "$package_name" = dory-guest-tools ] && [ -n "$package_version" ] \
    && [ "${#package_version}" -le 256 ] || {
    echo "offline RPM package has the wrong identity or version" >&2; return 65;
  }
  case "$package_version" in *[!A-Za-z0-9._+:~\-]*)
    echo "offline RPM package version is malformed" >&2; return 65 ;; esac
  case "$(uname -m):$native_architecture:$package_architecture" in
    aarch64:aarch64:aarch64|x86_64:x86_64:x86_64) ;;
    *) echo "offline RPM package does not match the native guest architecture" >&2; return 65 ;;
  esac
  package_nevra="$package_name-$package_version"
}

verify_installed_rpm_package() {
  installed_version="$(rpm -q --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' dory-guest-tools)" || return 65
  [ "$installed_version" = "$package_version" ] || {
    echo "dnf did not install the exact native package epoch/version from this tools ISO" >&2; return 65;
  }
}

install_rpm_package() {
  if [ "$action" = rollback ]; then
    dnf --assumeyes --disablerepo='*' --enablerepo=dory-guest-tools-installer \
      downgrade "$package_nevra" || return $?
  elif [ "$(rpm -q --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' dory-guest-tools 2>/dev/null)" = "$package_version" ]; then
    # Like apt --reinstall, repair an already-selected version instead of a successful no-op.
    dnf --assumeyes --disablerepo='*' --enablerepo=dory-guest-tools-installer \
      reinstall "$package_nevra" || return $?
  else
    dnf --assumeyes --disablerepo='*' --enablerepo=dory-guest-tools-installer \
      repository-packages dory-guest-tools-installer \
      install "$package_nevra" || return $?
  fi
  verify_installed_rpm_package
}

if command -v apt-get >/dev/null 2>&1; then
  if [ "$action" != uninstall ]; then
    command -v dpkg-deb >/dev/null 2>&1 \
      || { echo "dpkg-deb is required to inspect the offline package" >&2; exit 69; }
    set -- "$root"/apt/pool/*.deb
    [ "$#" -eq 1 ] \
      || { echo "tools ISO must contain exactly one Debian package" >&2; exit 66; }
    inspect_debian_package "$1"
  fi
  if [ "$action" = uninstall ]; then
    # A locally edited repository file is not ours to delete, but it must not prevent package
    # removal. Leave it untouched and let its owner inspect it after uninstall.
    retire_legacy_repository /etc/apt/sources.list.d/dory-guest-tools.list ||
      echo "Preserving the customized Dory apt repository; package removal will continue" >&2
  else
    retire_legacy_repository /etc/apt/sources.list.d/dory-guest-tools.list
  fi
  if [ "$action" = uninstall ]; then
    apt-get -o 'Dir::Etc::sourcelist=/dev/null' -o 'Dir::Etc::sourceparts=-' \
      purge dory-guest-tools
  else
    keyring="$(mktemp /usr/share/keyrings/dory-guest-tools-installer.XXXXXX.asc)"
    repo="$(mktemp /etc/apt/sources.list.d/dory-guest-tools-installer.XXXXXX.list)"
    preferences="$(mktemp /etc/apt/preferences.d/dory-guest-tools-installer.XXXXXX.pref)"
    # A private package index is essential: changing only sources.list still leaves cached
    # indexes from unrelated repositories available to apt's dependency resolver.
    apt_lists="$(mktemp -d /var/lib/apt/lists/dory-guest-tools-installer.XXXXXX)"
    chmod 0755 "$apt_lists"
    install -m0644 "$key" "$keyring"
    printf 'deb [signed-by=%s] file:%s/apt ./\n' "$keyring" "$uri_path" > "$repo"
    chmod 0644 "$repo"
    printf 'Package: dory-guest-tools\nPin: release o=Dory\nPin-Priority: 1001\n' > "$preferences"
    chmod 0644 "$preferences"
    # Never consult the guest's configured or previously cached network repositories. If the
    # signed tools ISO lacks a dependency, fail instead of silently installing from the network.
    set -- \
      -o "Dir::Etc::sourcelist=$repo" \
      -o 'Dir::Etc::sourceparts=-' \
      -o "Dir::State::lists=$apt_lists" \
      -o 'APT::Get::List-Cleanup=0'
    apt-get "$@" update
    if [ "$action" = rollback ]; then
      apt-get "$@" install --reinstall --allow-downgrades "dory-guest-tools=$package_version"
    else
      apt-get "$@" install --reinstall "dory-guest-tools=$package_version"
    fi
    verify_installed_debian_package
    legacy_retire_committed=1
  fi
elif command -v dnf >/dev/null 2>&1; then
  if [ "$action" != uninstall ]; then
    command -v rpm >/dev/null 2>&1 \
      || { echo "rpm is required to inspect the offline package" >&2; exit 69; }
    set -- "$root"/rpm/*.rpm
    [ "$#" -eq 1 ] \
      || { echo "tools ISO must contain exactly one RPM package" >&2; exit 66; }
    inspect_rpm_package "$1"
  fi
  if [ "$action" = uninstall ]; then
    retire_legacy_repository /etc/yum.repos.d/dory-guest-tools.repo ||
      echo "Preserving the customized Dory dnf repository; package removal will continue" >&2
  else
    retire_legacy_repository /etc/yum.repos.d/dory-guest-tools.repo
  fi
  if [ "$action" = uninstall ]; then
    dnf --assumeyes --disablerepo='*' remove dory-guest-tools
  else
    repo="$(mktemp /etc/yum.repos.d/dory-guest-tools-installer.XXXXXX.repo)"
    cat > "$repo" <<EOF
[dory-guest-tools-installer]
name=Dory Guest Tools
baseurl=file://$uri_path/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$uri_path/dory-repository-key.asc
EOF
    chmod 0644 "$repo"
    install_rpm_package
    legacy_retire_committed=1
  fi
else
  echo "This tools image supports apt-based and Fedora dnf-based guests." >&2
  exit 69
fi

if [ "$action" != uninstall ]; then
  start_guest_agent
fi

case "$action" in
  install) echo "Dory Guest Tools installed. Log out and back in if clipboard sharing is not active yet." ;;
  rollback) echo "Dory Guest Tools rolled back to the version on this tools ISO." ;;
  uninstall) echo "Dory Guest Tools uninstalled." ;;
esac
