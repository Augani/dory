import Foundation

public enum DoryVMMGuestDisplayScale {
    public static let supportedScaleFactors: ClosedRange<UInt8> = 1...2

    /// Returns an argument-separated command that atomically publishes the resolved UI scale in
    /// the managed guest. The value is never interpolated into shell source.
    public static func persistenceCommand(scaleFactor: UInt8) -> [String]? {
        guard supportedScaleFactors.contains(scaleFactor) else { return nil }
        return [
            "/bin/sh",
            "-c",
            """
            set -eu
            umask 022
            mkdir -p /var/lib/dory
            temporary="/var/lib/dory/.guest-ui-scale.$$"
            trap 'rm -f "$temporary"' EXIT HUP INT TERM
            printf '%s\n' "$1" > "$temporary"
            chmod 0644 "$temporary"
            mv -f "$temporary" /var/lib/dory/guest-ui-scale
            trap - EXIT HUP INT TERM
            """,
            "dory-guest-display-scale",
            String(scaleFactor),
        ]
    }
}
