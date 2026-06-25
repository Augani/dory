import Foundation

struct AppleContainerRuntime: ContainerRuntime {
    let kind: RuntimeKind = .appleContainer
    let binary: String

    static func detect() async -> AppleContainerRuntime? {
        guard let binary = Shell.find("container", candidates: ["/opt/homebrew/bin/container", "/usr/local/bin/container"]),
              AppleContainerSupport.evaluate(platform: .current(), hasContainerCLI: true).isSupported else { return nil }
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
        let machines = ((await machinesRaw) ?? []).map { acm in
            let running = acm.status?.lowercased() == "running"
            let (distro, letter, hex) = Self.distroInfo(acm.id)
            return Machine(
                name: acm.id, distro: distro, version: acm.`default` == true ? "default" : "",
                status: running ? .running : .stopped, cpuPercent: 0,
                memoryDisplay: DockerFormat.bytes(acm.memory), ip: acm.ipAddress ?? "—",
                letter: letter, badgeHex: hex
            )
        }
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
        let networks = container.status?.networks?.compactMap { network -> String? in
            guard let name = network.network, !name.isEmpty else { return nil }
            return name
        } ?? []
        let networkEndpointSettings = Dictionary(uniqueKeysWithValues: networks.map { network in
            var endpoint = DockerEndpointSettings()
            if !ip.isEmpty, ip != "—" {
                endpoint.IPAddress = ip
            }
            return (network, endpoint)
        })
        let command = [config?.initProcess?.executable].compactMap { $0 }.joined()
            + (config?.initProcess?.arguments.map { $0.isEmpty ? "" : " " + $0.joined(separator: " ") } ?? "")
        let memLimit = stats?.memoryLimitBytes ?? config?.resources?.memoryInBytes
        let memUsage = stats?.memoryUsageBytes
        let fraction = (memUsage.flatMap { u in memLimit.map { l in l > 0 ? Double(u) / Double(l) : 0 } }) ?? 0
        let ports = (config?.publishedPorts ?? []).compactMap { port -> String? in
            guard let container = port.containerPort else { return nil }
            return ContainerPortDisplay.dockerDisplay(
                hostPort: port.hostPort,
                containerPort: container,
                proto: port.proto
            )
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
            memoryBytes: running ? (memUsage ?? 0) : 0,
            networks: networks,
            networkEndpointSettings: networkEndpointSettings,
            exitCode: container.status?.exitCode
        )
    }

    private func mapImage(_ image: ACImage, usedBy: Int) -> DockerImage {
        let reference = image.configuration?.name ?? image.id
        let (repository, tag) = DockerRegistry.splitImageRef(reference)
        let shortID = image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)
        return DockerImage(repository: repository, tag: tag, imageID: String(shortID),
                           size: DockerFormat.bytes(image.configuration?.descriptor?.size),
                           created: DockerFormat.relative(iso: image.configuration?.creationDate),
                           usedByCount: usedBy,
                           sizeBytes: image.configuration?.descriptor?.size ?? 0,
                           labels: image.configuration?.labels ?? [:])
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
    func createNetwork(name: String, labels: [String: String]) async throws {
        var arguments = ["network", "create"]
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            arguments += ["--label", "\(key)=\(value)"]
        }
        arguments.append(name)
        _ = try await Shell.runAsync(binary, arguments)
    }
    func removeNetwork(name: String) async throws {
        _ = try await Shell.runAsync(binary, ["network", "delete", name])
    }
    func pruneNetworks() async throws {
        _ = try await Shell.runAsync(binary, ["network", "prune"])
    }
    func pull(image: String) async throws { _ = try await Shell.runAsync(binary, ["image", "pull", image]) }
    func tagImage(source: String, repo: String, tag: String) async throws {
        let target = tag.isEmpty ? repo : "\(repo):\(tag)"
        _ = try await Shell.runAsync(binary, ["image", "tag", source, target])
    }
    func pushImage(reference: String) async throws -> AsyncStream<Data> {
        let binary = self.binary
        return AsyncStream { continuation in
            Task {
                do {
                    let output = try await Shell.runAsync(binary, ["image", "push", "--progress", "plain", reference])
                    for line in Self.pushProgressLines(output: output, reference: reference) {
                        continuation.yield(line)
                    }
                } catch {
                    continuation.yield(Self.pushLine(error: "\(error)"))
                }
                continuation.finish()
            }
        }
    }

    func logs(containerID: String) async throws -> [LogLine] {
        let stamped = await Shell.runAsyncResult(binary, ["logs", "--timestamps", containerID])
        let output: String
        if stamped.exit == 0 {
            output = stamped.output
        } else {
            output = (try? await Shell.runAsync(binary, ["logs", containerID])) ?? ""
        }
        return AppleLogParse.parse(output)
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
                        continuation.yield(AppleLogParse.line(text))
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

    func containerExitCode(_ id: String) async -> Int? {
        guard let list = try? await runJSON(["inspect", id, "--format", "json"], as: [ACContainer].self) else { return nil }
        return list.first?.status?.exitCode
    }

    private func configuredCPUCount(containerID: String) async -> Int? {
        guard let list = try? await runJSON(["inspect", containerID, "--format", "json"], as: [ACContainer].self),
              let cpus = list.first?.configuration?.resources?.cpus,
              cpus > 0 else { return nil }
        return cpus
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        let output = try await Shell.runAsync(binary, Self.createArguments(for: spec))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func createArguments(for spec: ContainerSpec) -> [String] {
        var arguments = ["create", "--name", spec.name]
        if let platform = spec.platform?.trimmingCharacters(in: .whitespacesAndNewlines), !platform.isEmpty {
            arguments += ["--platform", platform]
        }
        if let containerIDFile = spec.containerIDFile, !containerIDFile.isEmpty { arguments += ["--cidfile", containerIDFile] }
        if let runtimeName = spec.runtimeName, !runtimeName.isEmpty { arguments += ["--runtime", runtimeName] }
        for (key, value) in spec.environment.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        for port in spec.ports { arguments += ["-p", port] }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        if let user = spec.user, !user.isEmpty { arguments += ["--user", user] }
        if let workingDir = spec.workingDir, !workingDir.isEmpty { arguments += ["--workdir", workingDir] }
        if !spec.entrypoint.isEmpty { arguments += ["--entrypoint", spec.entrypoint.joined(separator: " ")] }
        if spec.openStdin { arguments.append("--interactive") }
        if spec.tty { arguments.append("--tty") }
        if spec.autoRemove == true { arguments.append("--rm") }
        if spec.initProcessEnabled == true || spec.resources.initProcessEnabled == true { arguments.append("--init") }
        if spec.readonlyRootfs == true { arguments.append("--read-only") }
        if let cpus = Self.cpuCount(from: spec.resources.nanoCPUs ?? spec.nanoCPUs) { arguments += ["--cpus", cpus] }
        if let memory = spec.resources.memoryLimitBytes ?? spec.memoryLimitBytes { arguments += ["--memory", "\(memory)"] }
        for cap in spec.capAdd { arguments += ["--cap-add", cap] }
        for cap in spec.capDrop { arguments += ["--cap-drop", cap] }
        for server in spec.dns { arguments += ["--dns", server] }
        if let domainname = spec.domainname, !domainname.isEmpty { arguments += ["--dns-domain", domainname] }
        for option in spec.dnsOptions { arguments += ["--dns-option", option] }
        for domain in spec.dnsSearch { arguments += ["--dns-search", domain] }
        if spec.networkDisabled == true { arguments.append("--no-dns") }
        for network in Self.appleNetworks(spec) { arguments += ["--network", network] }
        for volume in spec.volumes { arguments += ["--volume", volume] }
        for mount in spec.mounts.compactMap(Self.appleMount) { arguments += ["--mount", mount] }
        if let shmSize = spec.shmSize { arguments += ["--shm-size", "\(shmSize)"] }
        for path in spec.tmpfs.keys.sorted() { arguments += ["--tmpfs", path] }
        for ulimit in spec.resources.ulimits ?? [] {
            if let encoded = Self.appleUlimit(ulimit) { arguments += ["--ulimit", encoded] }
        }
        arguments.append("--")
        arguments.append(spec.image)
        arguments += spec.command
        return arguments
    }

    private nonisolated static func cpuCount(from nanoCPUs: Int64?) -> String? {
        guard let nanoCPUs, nanoCPUs > 0 else { return nil }
        let cpus = Double(nanoCPUs) / 1_000_000_000
        return cpus == floor(cpus) ? String(Int(cpus)) : String(cpus)
    }

    private nonisolated static func appleNetworks(_ spec: ContainerSpec) -> [String] {
        if spec.networkDisabled == true { return ["none"] }
        let explicit = [spec.networkMode].compactMap { $0 }.filter { !$0.isEmpty && $0 != "default" }
        return explicit.isEmpty ? spec.networks : explicit
    }

    private nonisolated static func appleMount(_ mount: ContainerMount) -> String? {
        guard !mount.type.isEmpty, !mount.target.isEmpty else { return nil }
        var parts = ["type=\(mount.type)", "target=\(mount.target)"]
        if let source = mount.source, !source.isEmpty { parts.append("source=\(source)") }
        if mount.readOnly { parts.append("readonly") }
        return parts.joined(separator: ",")
    }

    private nonisolated static func appleUlimit(_ limit: DockerUlimit) -> String? {
        guard let name = limit.Name, !name.isEmpty else { return nil }
        guard let soft = limit.Soft else { return nil }
        if let hard = limit.Hard { return "\(name)=\(soft):\(hard)" }
        return "\(name)=\(soft)"
    }

    private static func pushProgressLines(output: String, reference: String) -> [Data] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let statuses = lines.isEmpty ? ["Pushed \(reference)"] : lines
        return statuses.map { pushLine(status: $0) }
    }

    private static func pushLine(status: String) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: ["status": status])) ?? Data(#"{"status":"push progress unavailable"}"#.utf8)
        return data + Data("\n".utf8)
    }

    private static func pushLine(error: String) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(#"{"error":"push failed"}"#.utf8)
        return data + Data("\n".utf8)
    }

    func sampleCPU(containerID: String) async -> Double? {
        guard let first = try? await runJSON(["stats", "--no-stream", "--format", "json", containerID], as: [ACStats].self).first,
              let a = first.cpuUsageUsec else { return nil }
        try? await Task.sleep(for: .milliseconds(800))
        guard let second = try? await runJSON(["stats", "--no-stream", "--format", "json", containerID], as: [ACStats].self).first,
              let b = second.cpuUsageUsec else { return nil }
        let inspectedCPUs: Int?
        if second.cpus == nil, first.cpus == nil {
            inspectedCPUs = await configuredCPUCount(containerID: containerID)
        } else {
            inspectedCPUs = nil
        }
        let cpus = second.cpus ?? first.cpus ?? inspectedCPUs ?? 1
        return AppleStatsMath.cpuPercent(deltaUsec: b - a, elapsedUsec: 800_000, cpus: cpus)
    }
}
