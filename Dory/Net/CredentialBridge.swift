enum DoryCredentialShim {
    static let bridgeGuestDir = "/opt/dory/bridge"
    static let guestSSHAuthSockPath = "/run/host-services/ssh-auth.sock"
    static let envPath = "/etc/profile.d/dory-credentials.sh"
    static let gitAskpassPath = "/usr/local/bin/dory-git-askpass"

    static let gitAskpassScript = ##"""
#!/bin/sh
SOCK="${DORY_GIT_ASKPASS_SOCK:-/opt/dory/bridge/credentials/git-askpass.sock}"
[ -S "$SOCK" ] || exit 1
prompt="${1:-Password:}"
if command -v socat >/dev/null 2>&1; then
  printf '%s\n' "$prompt" | socat - "UNIX-CONNECT:$SOCK"
else
  exit 1
fi
"""##

    static func installCommands() -> [String] {
        [
            "install -d /usr/local/bin /etc/profile.d /opt/dory/bridge/credentials",
            "cat > \(gitAskpassPath) <<'DORYGITASKPASSEOF'\n\(gitAskpassScript)\nDORYGITASKPASSEOF",
            "chmod +x \(gitAskpassPath)",
            "cat > \(envPath) <<'DORYCREDENTIALSEOF'\nexport SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock\nexport GIT_ASKPASS=/usr/local/bin/dory-git-askpass\nexport DORY_GIT_ASKPASS_SOCK=/opt/dory/bridge/credentials/git-askpass.sock\nDORYCREDENTIALSEOF",
            "chmod 644 \(envPath)",
        ]
    }
}
