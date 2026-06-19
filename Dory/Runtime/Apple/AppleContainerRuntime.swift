import Foundation

struct AppleContainerRuntime: ContainerRuntime {
    let kind: RuntimeKind = .appleContainer
    let binary: String

    static func detect() async -> AppleContainerRuntime? {
        guard let binary = Shell.find("container", candidates: ["/opt/homebrew/bin/container", "/usr/local/bin/container"]) else { return nil }
        let status = await Shell.runAsyncResult(binary, ["system", "status"])
        guard status.exit == 0 else { return nil }
        return AppleContainerRuntime(binary: binary)
    }

    private func runJSON<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let output = try await Shell.runAsync(binary, arguments)
        let jsonStart = output.firstIndex(where: { $0 == "[" || $0 == "{" }) ?? output.startIndex
        return try JSONDecoder().decode(T.self, from: Data(output[jsonStart...].utf8))
    }

    func snapshot() async throws -> RuntimeSnapshot {
        async let containersRaw = runJSON(["ls", "-a", "--format", "json"], as: [ACContainer].self)
        async let imagesRaw = try? runJSON(["image", "ls", "--format", "json"], as: [ACImage].self)
        async let volumesRaw = try? runJSON(["volume", "ls", "--format", "json"], as: [ACVolume].self)
        async let machinesRaw = try? runJSON(["machine", "ls", "--format", "json"], as: [ACMachine].self)
        async let versionRaw = try? Shell.runAsync(binary, ["--version"])

        let containerList = try await containersRaw
        let runningIDs = containerList.filter { $0.status?.state == "running" }.map(\.id)
        let stats = await statsByID(runningIDs)

        let imageList = (await imagesRaw) ?? []
        let imageRefCounts = Dictionary(grouping: containerList.compactMap { $0.configuration?.image?.reference }, by: { $0 }).mapValues(\.count)

        let containers = containerList.map { map($0, stats: stats[$0.id]) }
        let images = imageList.map { mapImage($0, usedBy: imageRefCounts[$0.configuration?.name ?? ""] ?? 0) }
        let volumes = ((await volumesRaw) ?? []).map(mapVolume)
        let machines = ((await machinesRaw) ?? []).map(MachineProvider.map)
        let networks = synthesizeNetworks(from: containerList)
        let version = ((await versionRaw) ?? "").components(separatedBy: " ").last(where: { $0.first?.isNumber == true }) ?? "1.0.0"

        return RuntimeSnapshot(containers: containers, images: images, volumes: volumes, networks: networks,
                               pods: [], machines: machines, engineRunning: true, engineVersion: version)
    }

    static func distroInfo(_ name: String) -> (distro: String, letter: String, hex: UInt32) {
        let lower = name.lowercased()
        if lower.contains("ubuntu") { return ("Ubuntu", "U", 0xE95420) }
        if lower.contains("debian") { return ("Debian", "D", 0xA80030) }
        if lower.contains("fedora") { return ("Fedora", "F", 0x3C6EB4) }
        if lower.contains("arch") { return ("Arch Linux", "A", 0x1793D1) }
        if lower.contains("alpine") { return ("Alpine", "A", 0x0D597F) }
        let letter = name.first.map { String($0).uppercased() } ?? "L"
        return ("Linux", letter, 0x2E9BF5)
    }

    func startMachine(name: String) async throws { _ = try await Shell.runAsync(binary, ["machine", "start", name]) }
    func stopMachine(name: String) async throws { _ = await Shell.runAsyncResult(binary, ["machine", "stop", name]) }

    private func statsByID(_ ids: [String]) async -> [String: ACStats] {
        guard !ids.isEmpty else { return [:] }
        guard let list = try? await runJSON(["stats", "--no-stream", "--format", "json"] + ids, as: [ACStats].self) else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func map(_ container: ACContainer, stats: ACStats?) -> Container {
        let config = container.configuration
        let running = container.status?.state == "running"
        let ip = container.status?.networks?.first?.ipv4Address.map { String($0.split(separator: "/").first ?? "") } ?? "—"
        let command = [config?.initProcess?.executable].compactMap { $0 }.joined()
            + (config?.initProcess?.arguments.map { $0.isEmpty ? "" : " " + $0.joined(separator: " ") } ?? "")
        let memLimit = stats?.memoryLimitBytes ?? config?.resources?.memoryInBytes
        let memUsage = stats?.memoryUsageBytes
        let fraction = (memUsage.flatMap { u in memLimit.map { l in l > 0 ? Double(u) / Double(l) : 0 } }) ?? 0
        let ports = (config?.publishedPorts ?? []).compactMap { port -> String? in
            guard let container = port.containerPort else { return nil }
            return port.hostPort.map { "\($0)→\(container)" } ?? "\(container)"
        }.joined(separator: ", ")

        return Container(
            id: container.id, name: container.id,
            image: config?.image?.reference ?? "—",
            status: running ? .running : .stopped,
            cpuPercent: 0,
            memoryDisplay: running ? DockerFormat.bytes(memUsage) : "0 MB",
            memoryLimitDisplay: memLimit.map(DockerFormat.bytes) ?? "—",
            memoryFraction: fraction,
            ports: ports.isEmpty ? "—" : ports,
            uptime: running ? DockerFormat.uptime(iso: container.status?.startedDate) : "—",
            created: DockerFormat.relative(iso: config?.creationDate),
            ipAddress: ip.isEmpty ? "—" : ip,
            domain: "\(container.id).dory.local",
            command: command.isEmpty ? "—" : command,
            restartPolicy: "—",
            createdEpoch: nil,
            labels: config?.labels ?? [:],
            memoryBytes: running ? (memUsage ?? 0) : 0
        )
    }

    private func mapImage(_ image: ACImage, usedBy: Int) -> DockerImage {
        let reference = image.configuration?.name ?? image.id
        let (repository, tag) = DockerRegistry.splitImageRef(reference)
        let shortID = image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)
        return DockerImage(repository: repository, tag: tag, imageID: String(shortID),
                           size: DockerFormat.bytes(image.configuration?.descriptor?.size),
                           created: DockerFormat.relative(iso: image.configuration?.creationDate),
                           usedByCount: usedBy)
    }

    private func mapVolume(_ volume: ACVolume) -> Volume {
        Volume(name: volume.configuration?.name ?? volume.id, size: "—",
               driver: volume.configuration?.driver ?? "local", usedBy: "—",
               created: DockerFormat.relative(iso: volume.configuration?.creationDate))
    }

    private func synthesizeNetworks(from containers: [ACContainer]) -> [DoryNetwork] {
        var byName: [String: (subnet: String, count: Int)] = [:]
        for container in containers {
            for network in container.status?.networks ?? [] {
                let name = network.network ?? "default"
                let subnet = network.ipv4Gateway.map { gateway in
                    gateway.split(separator: ".").dropLast().joined(separator: ".") + ".0/24"
                } ?? "—"
                byName[name, default: (subnet, 0)].count += 1
                byName[name]?.subnet = subnet
            }
        }
        return byName.keys.sorted().map { name in
            DoryNetwork(name: name, driver: "bridge", scope: "local", subnet: byName[name]?.subnet ?? "—", containerCount: byName[name]?.count ?? 0)
        }
    }

    func start(containerID: String) async throws { _ = try await Shell.runAsync(binary, ["start", containerID]) }
    func stop(containerID: String) async throws { _ = try await Shell.runAsync(binary, ["stop", containerID]) }
    func restart(containerID: String) async throws {
        _ = await Shell.runAsyncResult(binary, ["stop", containerID])
        _ = try await Shell.runAsync(binary, ["start", containerID])
    }
    func remove(containerID: String) async throws { _ = await Shell.runAsyncResult(binary, ["delete", "-f", containerID]) }
    func removeVolume(name: String) async throws { _ = await Shell.runAsyncResult(binary, ["volume", "delete", name]) }
    func pull(image: String) async throws { _ = try await Shell.runAsync(binary, ["image", "pull", image]) }

    func logs(containerID: String) async throws -> [LogLine] {
        let output = (try? await Shell.runAsync(binary, ["logs", containerID])) ?? ""
        return output.split(separator: "\n", omittingEmptySubsequences: true).map {
            LogLine(timestamp: "", level: .info, message: String($0))
        }
    }

    func streamLogs(containerID: String) -> AsyncStream<LogLine> {
        let binary = self.binary
        return AsyncStream { continuation in
            final class LineBuffer: @unchecked Sendable { var data = Data() }
            let buffer = LineBuffer()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["logs", "--follow", containerID]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.data.append(chunk)
                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    let lineData = buffer.data.subdata(in: buffer.data.startIndex..<newline)
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                    if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
                        continuation.yield(LogLine(timestamp: "", level: .info, message: text))
                    }
                }
            }
            process.terminationHandler = { _ in continuation.finish() }
            do { try process.run() } catch { continuation.finish() }
            continuation.onTermination = { _ in
                reader.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
        }
    }

    func env(containerID: String) async throws -> [EnvVar] {
        guard let list = try? await runJSON(["inspect", containerID, "--format", "json"], as: [ACContainer].self),
              let environment = list.first?.configuration?.initProcess?.environment else { return [] }
        return environment.map { entry in
            if let eq = entry.firstIndex(of: "=") {
                return EnvVar(key: String(entry[entry.startIndex..<eq]), value: String(entry[entry.index(after: eq)...]))
            }
            return EnvVar(key: entry, value: "")
        }
    }

    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        let result = await Shell.runAsyncResult(binary, ["exec", containerID] + command)
        return ExecResult(exitCode: Int(result.exit), output: result.output)
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        var arguments = ["create", "--name", spec.name]
        for (key, value) in spec.environment.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        for port in spec.ports { arguments += ["-p", port] }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        arguments.append("--")
        arguments.append(spec.image)
        arguments += spec.command
        let output = try await Shell.runAsync(binary, arguments)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sampleCPU(containerID: String) async -> Double? {
        guard let a = try? await runJSON(["stats", "--no-stream", "--format", "json", containerID], as: [ACStats].self).first?.cpuUsageUsec else { return nil }
        try? await Task.sleep(for: .milliseconds(800))
        guard let b = try? await runJSON(["stats", "--no-stream", "--format", "json", containerID], as: [ACStats].self).first?.cpuUsageUsec else { return nil }
        let deltaUsec = Double(b - a)
        let elapsedUsec = 800_000.0
        return max(0, min(100, deltaUsec / elapsedUsec * 100))
    }
}
