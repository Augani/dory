import Foundation

struct SSHConfigWriter: Sendable {
    var configURL: URL

    init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dory")
        .appendingPathComponent("ssh")
        .appendingPathComponent("config")) {
        self.configURL = configURL
    }

    nonisolated static func hostBlock(for machine: Machine) -> String {
        let host = shellSafeHost(machine.name)
        let user = machine.username.isEmpty ? "root" : machine.username
        var lines = [
            "Host \(host)",
            "  HostName 127.0.0.1",
            "  User \(user)",
            "  StrictHostKeyChecking accept-new",
        ]
        if let port = machine.sshPort {
            lines.append("  Port \(port)")
        } else {
            let container = MachineService.containerName(for: machine.name)
            let command = [
                "docker",
                "-H",
                "unix://$HOME/.dory/dory.sock",
                "exec",
                "-i",
                shellQuote(container),
                "sh",
                "-lc",
                shellQuote("exec nc 127.0.0.1 22"),
            ].joined(separator: " ")
            lines.append("  ProxyCommand \(command)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func config(for machines: [Machine]) -> String {
        machines
            .sorted { $0.name < $1.name }
            .map(hostBlock(for:))
            .joined(separator: "\n")
    }

    func write(machines: [Machine]) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.config(for: machines).write(to: configURL, atomically: true, encoding: .utf8)
    }

    nonisolated static var includeInstruction: String {
        "Include ~/.dory/ssh/config"
    }

    private nonisolated static func shellSafeHost(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "-" ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
