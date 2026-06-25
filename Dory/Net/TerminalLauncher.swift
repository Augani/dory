import Foundation

/// Opens an interactive shell in Terminal.app — the GUI "open terminal / SSH" affordance OrbStack
/// provides for containers and Linux machines. Runs the right CLI against Dory's own socket/engine.
enum TerminalLauncher {
    static func open(command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\ndo script \"\(escaped)\"\nactivate\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    static func openContainerShell(socketPath: String, containerID: String) {
        open(command: dockerCommand(socketPath: socketPath, execArgs: execArgs(user: "root", shell: "/bin/sh", home: "/root", container: containerID)))
    }

    static func execArgs(user: String, shell: String, home: String, container: String) -> String {
        let container = shellQuote(container)
        if user == "root" {
            return "exec -it \(container) sh -c \(shellQuote(fallbackShellProbe))"
        }
        return "exec -it -u \(shellQuote(user)) -w \(shellQuote(home)) \(container) \(shellQuote(shell)) -l"
    }

    static func dockerCommand(socketPath: String, execArgs: String) -> String {
        "docker -H \(shellQuote("unix://\(socketPath)")) \(execArgs)"
    }

    static func openMachineShell(socketPath: String, containerID: String, user: String, shell: String, home: String) {
        open(command: dockerCommand(socketPath: socketPath, execArgs: execArgs(user: user, shell: shell, home: home, container: containerID)))
    }

    private static let fallbackShellProbe = "command -v bash >/dev/null && exec bash || exec sh"

    private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
