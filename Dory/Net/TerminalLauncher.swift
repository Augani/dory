import AppKit
import Foundation

enum TerminalLauncher {
    enum LaunchResult: Equatable {
        case launched
        case unavailable(String)
        case failed(String)
    }

    struct LaunchPlan: Equatable {
        var executable: String
        var arguments: [String]
        var temporaryCommandFile: URL?
    }

    @discardableResult
    static func open(
        command: String,
        preference: ExternalTerminalPreference = ExternalTerminalPreferenceStore.load()
    ) -> LaunchResult {
        let applicationURL = preference.terminal.applicationURL(
            customPath: preference.customApplicationPath
        )
        guard preference.terminal == .systemDefault || applicationURL != nil else {
            return .unavailable("\(preference.displayName) is not installed.")
        }
        let plan: LaunchPlan
        do {
            plan = try launchPlan(
                command: command,
                terminal: preference.terminal,
                applicationURL: applicationURL
            )
        } catch {
            return .failed("Could not prepare \(preference.displayName): \(error.localizedDescription)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        do {
            try process.run()
            return .launched
        } catch {
            if let temporaryCommandFile = plan.temporaryCommandFile {
                try? FileManager.default.removeItem(at: temporaryCommandFile)
            }
            return .failed("Could not open \(preference.displayName): \(error.localizedDescription)")
        }
    }

    static func launchPlan(
        command: String,
        terminal: ExternalTerminal,
        applicationURL: URL?,
        commandFileDirectory: URL? = nil
    ) throws -> LaunchPlan {
        switch terminal {
        case .terminal:
            let script = "tell application id \"com.apple.Terminal\"\ndo script \(appleScriptLiteral(command))\nactivate\nend tell"
            return LaunchPlan(executable: "/usr/bin/osascript", arguments: ["-e", script])
        case .iTerm2:
            let script = "tell application id \"com.googlecode.iterm2\"\ncreate window with default profile command \(appleScriptLiteral(command))\nactivate\nend tell"
            return LaunchPlan(executable: "/usr/bin/osascript", arguments: ["-e", script])
        case .ghostty:
            return try openApplicationPlan(
                applicationURL: applicationURL,
                applicationArguments: ["-e", "/bin/zsh", "-lc", command]
            )
        case .wezTerm:
            return try openApplicationPlan(
                applicationURL: applicationURL,
                applicationArguments: ["start", "--always-new-process", "--", "/bin/zsh", "-lc", command]
            )
        case .alacritty:
            return try openApplicationPlan(
                applicationURL: applicationURL,
                applicationArguments: ["-e", "/bin/zsh", "-lc", command]
            )
        case .kitty:
            return try openApplicationPlan(
                applicationURL: applicationURL,
                applicationArguments: ["/bin/zsh", "-lc", command]
            )
        case .systemDefault, .warp, .custom:
            let file = try makeCommandFile(command: command, directory: commandFileDirectory)
            var arguments = ["-n"]
            if let applicationURL {
                arguments.append(contentsOf: ["-a", applicationURL.path])
            }
            arguments.append(file.path)
            return LaunchPlan(executable: "/usr/bin/open", arguments: arguments, temporaryCommandFile: file)
        }
    }

    private static func openApplicationPlan(
        applicationURL: URL?,
        applicationArguments: [String]
    ) throws -> LaunchPlan {
        guard let applicationURL else { throw CocoaError(.fileNoSuchFile) }
        return LaunchPlan(
            executable: "/usr/bin/open",
            arguments: ["-na", applicationURL.path, "--args"] + applicationArguments
        )
    }

    private static func makeCommandFile(command: String, directory: URL?) throws -> URL {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dory/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("terminal-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        self=\(shellQuote(file.path))
        /bin/rm -f -- "$self"
        /bin/zsh -lc \(shellQuote(command))
        status=$?
        if [ "$status" -ne 0 ]; then
          printf '\\nDory command exited with status %s.\\n' "$status"
        fi
        exec "${SHELL:-/bin/zsh}" -l
        """
        try Data(script.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    @discardableResult
    static func openContainerShell(
        socketPath: String,
        containerID: String,
        preference: ExternalTerminalPreference = ExternalTerminalPreferenceStore.load()
    ) -> LaunchResult {
        open(
            command: dockerCommand(
                socketPath: socketPath,
                execArgs: execArgs(user: "root", shell: "/bin/sh", home: "/root", container: containerID)
            ),
            preference: preference
        )
    }

    nonisolated static func execArgs(user: String, shell: String, home: String, container: String) -> String {
        let container = shellQuote(container)
        if user == "root" {
            let fallbackShellProbe = "command -v bash >/dev/null && exec bash || exec sh"
            return "exec -it \(container) sh -c \(shellQuote(fallbackShellProbe))"
        }
        return "exec -it -u \(shellQuote(user)) -w \(shellQuote(home)) \(container) \(shellQuote(shell)) -l"
    }

    nonisolated static func dockerCommand(socketPath: String, execArgs: String) -> String {
        "docker -H \(shellQuote("unix://\(socketPath)")) \(execArgs)"
    }

    nonisolated static func machineShellCommand(target: MachineShellTarget) -> String {
        userFacingMachineShellCommand(target: UserFacingMachineShellTarget(machineID: target.machineID))
    }

    nonisolated static func userFacingMachineShellCommand(target: UserFacingMachineShellTarget) -> String {
        "dory machine shell \(shellQuote(target.machineID))"
    }

    @discardableResult
    static func openMachineShell(
        socketPath: String,
        containerID: String,
        user: String,
        shell: String,
        home: String,
        preference: ExternalTerminalPreference = ExternalTerminalPreferenceStore.load()
    ) -> LaunchResult {
        open(
            command: dockerCommand(
                socketPath: socketPath,
                execArgs: execArgs(user: user, shell: shell, home: home, container: containerID)
            ),
            preference: preference
        )
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
