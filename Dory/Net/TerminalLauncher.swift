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
        open(command: "docker -H unix://\(socketPath) exec -it \(containerID) sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    static func openMachineShell(ip: String, keyPath: String) {
        open(command: "ssh -i \(keyPath) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dory@\(ip)")
    }
}
