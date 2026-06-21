import Foundation

/// Manages full Linux machines (Ubuntu, Debian, Fedora, …) via Apple `container machine` — the
/// analog of OrbStack's Linux machines: persistent VMs with real init systems and SSH. Independent
/// of the container-engine backend, since machines are always provided by Apple's `container`.
struct MachineProvider: Sendable {
    private var binary: String? {
        Shell.find("container", candidates: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])
    }

    var isAvailable: Bool { binary != nil }

    func list() async -> [Machine] {
        guard let binary else { return [] }
        let result = await Shell.runAsyncResult(binary, ["machine", "ls", "--format", "json"])
        guard result.exit == 0,
              let start = result.output.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(result.output[start...]).data(using: .utf8),
              let machines = try? JSONDecoder().decode([ACMachine].self, from: data) else { return [] }
        return machines.map(Self.map)
    }

    func create(image: String, name: String) async throws {
        guard let binary else { throw MachineError.cliUnavailable }
        let result = await Shell.runAsyncResult(binary, ["machine", "create", image, "--name", name])
        guard result.exit == 0 else { throw MachineError.command(result.output) }
    }

    func start(name: String) async throws { try await runThrowing(["machine", "start", name]) }
    func stop(name: String) async throws { try await runThrowing(["machine", "stop", name]) }

    func delete(name: String) async {
        _ = await run(["machine", "stop", name])
        _ = await run(["machine", "delete", name])
    }

    private func runThrowing(_ arguments: [String]) async throws {
        guard let binary else { throw MachineError.cliUnavailable }
        let result = await Shell.runAsyncResult(binary, arguments)
        guard result.exit == 0 else { throw MachineError.command(result.output) }
    }

    @discardableResult
    private func run(_ arguments: [String]) async -> Bool {
        guard let binary else { return false }
        return await Shell.runAsyncResult(binary, arguments).exit == 0
    }

    static func map(_ machine: ACMachine) -> Machine {
        let running = machine.status?.lowercased() == "running"
        let (distro, letter, hex) = AppleContainerRuntime.distroInfo(machine.id)
        return Machine(
            name: machine.id, distro: distro, version: machine.`default` == true ? "default" : "",
            status: running ? .running : .stopped, cpuPercent: 0,
            memoryDisplay: DockerFormat.bytes(machine.memory), ip: machine.ipAddress ?? "—",
            letter: letter, badgeHex: hex
        )
    }

    enum MachineError: Error, Sendable { case cliUnavailable, command(String) }
}
