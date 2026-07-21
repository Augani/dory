public enum GuestDockerRestartCommand {
    public static func installerLines(dockerdArguments: String) -> [String] {
        [
            "mkdir -p /run/dory-corporate",
            "chmod 0700 /run/dory-corporate",
            "cat >/run/dory-restart-dockerd <<DORY_DOCKERD_SCRIPT",
            "#!/bin/sh",
            "[ -r /run/dory-corporate/dockerd.env ] && . /run/dory-corporate/dockerd.env",
            "set -- \(dockerdArguments)",
            // The outer, unquoted heredoc expands the boot-time runtime arguments. Escape the
            // restart helper's own positional arguments so they remain intact in the generated
            // script and are evaluated only when that helper runs.
            "if [ -r /run/dory-corporate/dockerd.args ]; then while IFS= read -r DORY_DOCKERD_ARG; do [ -z \"\\$DORY_DOCKERD_ARG\" ] || set -- \"\\$@\" \"\\$DORY_DOCKERD_ARG\"; done </run/dory-corporate/dockerd.args; fi",
            "exec \"\\$@\"",
            "DORY_DOCKERD_SCRIPT",
            "chmod 0700 /run/dory-restart-dockerd",
            "/run/dory-restart-dockerd >/var/log/dockerd.log 2>&1 & true",
        ]
    }
}
