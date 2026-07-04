import Foundation
import os

enum CredentialBridgeLog {
    static let logger = Logger(subsystem: "dev.dory.app", category: "credential-bridge")
}

struct CredentialBridgePlan: Equatable, Sendable {
    enum PlanError: Error, Equatable {
        case invalidMachineName
        case missingSSHAuthSock
        case relativeSSHAuthSock
        case unsafeSSHAuthSock
    }

    let machine: String
    let bridgeRoot: URL
    let hostSSHAuthSock: String?

    init(machine: String, bridgeRoot: URL, hostSSHAuthSock: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]) throws {
        guard Self.isValidMachineName(machine) else { throw PlanError.invalidMachineName }
        if let hostSSHAuthSock, !hostSSHAuthSock.isEmpty {
            guard hostSSHAuthSock.hasPrefix("/") else { throw PlanError.relativeSSHAuthSock }
            guard Self.isSocatSafeAddress(hostSSHAuthSock) else { throw PlanError.unsafeSSHAuthSock }
            self.hostSSHAuthSock = hostSSHAuthSock
        } else {
            self.hostSSHAuthSock = nil
        }
        self.machine = machine
        self.bridgeRoot = bridgeRoot
    }

    var credentialDirectory: URL {
        bridgeRoot.appendingPathComponent(machine).appendingPathComponent("credentials")
    }

    var hostAgentProxySocket: URL {
        credentialDirectory.appendingPathComponent("ssh-agent.sock")
    }

    var hostGitAskpassSocket: URL {
        credentialDirectory.appendingPathComponent("git-askpass.sock")
    }

    var guestSSHAuthSock: String {
        "\(DoryCredentialShim.bridgeGuestDir)/credentials/ssh-agent.sock"
    }

    var guestGitAskpassSocket: String {
        "\(DoryCredentialShim.bridgeGuestDir)/credentials/git-askpass.sock"
    }

    var guestEnv: [String: String] {
        [
            "SSH_AUTH_SOCK": guestSSHAuthSock,
            "GIT_ASKPASS": DoryCredentialShim.gitAskpassPath,
            "DORY_GIT_ASKPASS_SOCK": guestGitAskpassSocket,
        ]
    }

    func validateHostAgent() throws {
        guard let hostSSHAuthSock, !hostSSHAuthSock.isEmpty else { throw PlanError.missingSSHAuthSock }
    }

    var sshAgentProxyCommand: [String]? {
        guard let hostSSHAuthSock else { return nil }
        return [
            "socat",
            "UNIX-LISTEN:\(hostAgentProxySocket.path),fork,unlink-early,mode=0600",
            "UNIX-CONNECT:\(hostSSHAuthSock)",
        ]
    }

    static func isValidMachineName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 63 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func isSocatSafeAddress(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        for character in value.unicodeScalars {
            if character == "," || character == "!" { return false }
            if CharacterSet.whitespacesAndNewlines.contains(character) { return false }
        }
        return true
    }
}

enum HostCredentialBridge {
    static func prepare(_ plan: CredentialBridgePlan) throws {
        try FileManager.default.createDirectory(at: plan.credentialDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: plan.hostAgentProxySocket)
        try? FileManager.default.removeItem(at: plan.hostGitAskpassSocket)
    }
}

final class CredentialProxyManager: @unchecked Sendable {
    private let bridgeRoot: URL
    private let lock = NSLock()
    private var processes: [String: Process] = [:]

    init(bridgeRoot: URL) {
        self.bridgeRoot = bridgeRoot
    }

    func start(machine: String) {
        lock.lock()
        let alreadyRunning = processes[machine]?.isRunning == true
        lock.unlock()
        guard !alreadyRunning else { return }

        guard let socat = Self.socatPath() else {
            CredentialBridgeLog.logger.error("credential forwarding for \(machine, privacy: .public) not started: socat not found in /opt/homebrew/bin, /usr/local/bin, or /usr/bin")
            return
        }

        let plan: CredentialBridgePlan
        do {
            plan = try CredentialBridgePlan(machine: machine, bridgeRoot: bridgeRoot)
        } catch {
            CredentialBridgeLog.logger.error("credential forwarding for \(machine, privacy: .public) not started: invalid plan: \(String(describing: error), privacy: .public)")
            return
        }

        guard var command = plan.sshAgentProxyCommand else {
            CredentialBridgeLog.logger.error("credential forwarding for \(machine, privacy: .public) not started: no SSH_AUTH_SOCK in the host environment (start Dory from a shell with a running ssh-agent)")
            return
        }

        do {
            try plan.validateHostAgent()
            try HostCredentialBridge.prepare(plan)
            command[0] = socat
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            lock.lock()
            processes[machine] = process
            lock.unlock()
        } catch {
            CredentialBridgeLog.logger.error("credential forwarding for \(machine, privacy: .public) failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func stop(machine: String) {
        lock.lock()
        let process = processes.removeValue(forKey: machine)
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func stopAll() {
        lock.lock()
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running.values where process.isRunning { process.terminate() }
    }

    func activeMachines() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(processes.keys.filter { processes[$0]?.isRunning == true })
    }

    static func socatPath(fileManager: FileManager = .default) -> String? {
        for path in ["/opt/homebrew/bin/socat", "/usr/local/bin/socat", "/usr/bin/socat"] where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

enum DoryCredentialShim {
    static let bridgeGuestDir = "/opt/dory/bridge"
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
            "cat > \(envPath) <<'DORYCREDENTIALSEOF'\nexport SSH_AUTH_SOCK=/opt/dory/bridge/credentials/ssh-agent.sock\nexport GIT_ASKPASS=/usr/local/bin/dory-git-askpass\nexport DORY_GIT_ASKPASS_SOCK=/opt/dory/bridge/credentials/git-askpass.sock\nDORYCREDENTIALSEOF",
            "chmod 644 \(envPath)",
        ]
    }
}
