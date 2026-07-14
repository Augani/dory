import Foundation

public struct HostCLICommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String

    public init(status: Int32, stdout: String = "") {
        self.status = status
        self.stdout = stdout
    }
}

public typealias HostCLICommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ environment: [String: String]
) -> HostCLICommandResult

struct HostDockerContextResult: Sendable, Equatable {
    var succeeded: Bool
    var error: String?
}

struct HostDockerContextManager: Sendable {
    var docker: String
    var socketPath: String
    var environment: [String: String]
    var commandRunner: HostCLICommandRunner

    func reconcile() -> HostDockerContextResult {
        let host = "unix://\(socketPath)"
        let inspect = commandRunner(
            docker,
            ["context", "inspect", "dory", "--format", "{{.Endpoints.docker.Host}}"],
            environment
        )
        if inspect.status == 0 {
            let existing = inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == host else {
                let owner = existing.isEmpty ? "an unknown endpoint" : existing
                return HostDockerContextResult(
                    succeeded: false,
                    error: "Docker context 'dory' is already owned by \(owner)"
                )
            }
            return HostDockerContextResult(succeeded: true)
        }

        let create = commandRunner(
            docker,
            ["context", "create", "dory", "--description", "Dory", "--docker", "host=\(host)"],
            environment
        )
        guard create.status == 0 else {
            return HostDockerContextResult(
                succeeded: false,
                error: "docker context create failed with status \(create.status)"
            )
        }
        let use = commandRunner(docker, ["context", "use", "dory"], environment)
        guard use.status == 0 else {
            return HostDockerContextResult(
                succeeded: false,
                error: "docker context use failed with status \(use.status)"
            )
        }
        return HostDockerContextResult(succeeded: true)
    }

    func remove() -> HostDockerContextResult {
        let host = "unix://\(socketPath)"
        let inspect = commandRunner(
            docker,
            ["context", "inspect", "dory", "--format", "{{.Endpoints.docker.Host}}"],
            environment
        )
        guard inspect.status == 0 else { return HostDockerContextResult(succeeded: false) }
        let existing = inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing == host else {
            return HostDockerContextResult(
                succeeded: false,
                error: "Docker context 'dory' is owned by another endpoint"
            )
        }

        let current = commandRunner(docker, ["context", "show"], environment)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == "dory" {
            let fallback = commandRunner(docker, ["context", "use", "default"], environment)
            guard fallback.status == 0 else {
                return HostDockerContextResult(
                    succeeded: false,
                    error: "docker context use default failed with status \(fallback.status)"
                )
            }
        }

        let remove = commandRunner(docker, ["context", "rm", "-f", "dory"], environment)
        guard remove.status == 0 else {
            return HostDockerContextResult(
                succeeded: false,
                error: "docker context removal failed with status \(remove.status)"
            )
        }
        return HostDockerContextResult(succeeded: true)
    }
}

func runHostCLICommand(
    executable: String,
    arguments: [String],
    environment: [String: String]
) -> HostCLICommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return HostCLICommandResult(status: 127)
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HostCLICommandResult(
        status: process.terminationStatus,
        stdout: String(bytes: output, encoding: .utf8) ?? ""
    )
}
