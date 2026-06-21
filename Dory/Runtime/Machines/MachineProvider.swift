import Foundation

/// Manages full Linux machines (Ubuntu, Debian, Fedora, …) via Apple `container machine` — the
/// analog of OrbStack's Linux machines: persistent VMs with real init systems and SSH. Independent
/// of the container-engine backend, since machines are always provided by Apple's `container`.
struct MachineProvider: Sendable {
    private var binary: String? { SharedVMProvisioner.containerBinary() }

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

    func create(image: String, name: String, progress: @escaping @MainActor (String) -> Void) async throws {
        guard let binary else { throw MachineError.cliUnavailable }
        await progress("Using container binary at \(binary)")
        let status = await Shell.runAsyncResult(binary, ["system", "status"])
        await progress("System status: \(status.exit == 0 ? "running" : "not running")\n\(status.output)")
        if status.exit != 0 {
            await progress("Starting Apple Container system…")
            let start = await Shell.runAsyncResult(binary, ["system", "start"])
            await progress("system start exited \(start.exit)\n\(start.output)")
            guard start.exit == 0 else { throw MachineError.command("Failed to start Apple Container system:\n\(start.output)") }
        }
        await progress("Pulling \(image) and provisioning disk…")
        let result = await Shell.runAsyncResult(binary, ["machine", "create", image, "--name", name])
        await progress("machine create exited \(result.exit)")
        guard result.exit == 0 else { throw MachineError.command(result.output) }
        await progress("Starting \(name)…")
        let start = await Shell.runAsyncResult(binary, ["machine", "start", name])
        await progress("machine start exited \(start.exit)")
        guard start.exit == 0 else { throw MachineError.command(start.output) }
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
