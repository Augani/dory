import Foundation

struct MachineService: Sendable {
    let runtime: any ContainerRuntime

    static let namePrefix = "dory-machine-"
    static let label = "dory.machine"
    static let versionLabel = "dory.machine.version"
    static let keepalive = ["tail", "-f", "/dev/null"]

    static func containerName(for name: String) -> String { namePrefix + name }

    static func displayName(fromContainerName raw: String) -> String? {
        let trimmed = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        guard trimmed.hasPrefix(namePrefix) else { return nil }
        let name = String(trimmed.dropFirst(namePrefix.count))
        return name.isEmpty ? nil : name
    }

    static func createBody(name: String, distro: MachineDistro, imageTag: String, keepaliveOnly: Bool) -> [String: Any] {
        let useInit = distro.boot == .systemd && !keepaliveOnly
        let cmd = useInit ? ["/sbin/init"] : keepalive
        return [
            "Hostname": name,
            "Image": imageTag,
            "Cmd": cmd,
            "Env": ["container=docker"],
            "StopSignal": "SIGRTMIN+3",
            "Labels": [label: distro.family, versionLabel: distro.version],
            "HostConfig": [
                "Privileged": true,
                "CgroupnsMode": "host",
                "Tmpfs": ["/run": "", "/run/lock": "", "/tmp": ""],
                "RestartPolicy": ["Name": "unless-stopped"],
            ] as [String: Any],
        ]
    }

    static func machines(fromContainersJSON data: Data) -> [Machine] {
        struct Net: Decodable { let IPAddress: String? }
        struct NetSettings: Decodable { let Networks: [String: Net]? }
        struct Entry: Decodable {
            let Id: String
            let Names: [String]?
            let State: String?
            let Labels: [String: String]?
            let NetworkSettings: NetSettings?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry -> Machine? in
            guard let rawName = entry.Names?.first, let name = displayName(fromContainerName: rawName) else { return nil }
            guard let distroID = entry.Labels?[label], let distro = MachineDistro.forFamily(distroID) else { return nil }
            let running = (entry.State ?? "").lowercased() == "running"
            let ip = entry.NetworkSettings?.Networks?.values.compactMap(\.IPAddress).first(where: { !$0.isEmpty }) ?? "—"
            return Machine(
                name: name,
                distro: distro.display,
                version: entry.Labels?[versionLabel] ?? distro.version,
                status: running ? .running : .stopped,
                cpuPercent: 0,
                memoryDisplay: "—",
                ip: ip,
                letter: distro.letter,
                badgeHex: distro.badgeHex,
                containerID: entry.Id
            )
        }
    }

    func list() async -> [Machine] {
        let filters = "{\"label\":[\"\(Self.label)\"]}"
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filters
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/json?all=1&filters=\(encoded)", headers: [], body: Data()),
            response.isSuccess else { return [] }
        return Self.machines(fromContainersJSON: response.body)
    }

    func containerID(for name: String) async -> String? {
        await list().first { $0.name == name }?.containerID
    }

    func create(name: String, distro: MachineDistro, progress: @escaping @Sendable (String) -> Void) async throws {
        let tag = try await MachineImageBuilder.ensureImage(distro, runtime: runtime, progress: progress)

        progress("Creating \(name)…")
        try await createContainer(name: name, distro: distro, imageTag: tag, keepaliveOnly: false)
        try await runtime.start(containerID: Self.containerName(for: name))
        progress("Starting \(name)…")

        if distro.boot == .systemd {
            try? await Task.sleep(for: .seconds(4))
            if await !isRunning(name: name) {
                progress("systemd did not come up on this image — falling back to a shell machine…")
                try? await runtime.remove(containerID: Self.containerName(for: name))
                try await createContainer(name: name, distro: distro, imageTag: tag, keepaliveOnly: true)
                try await runtime.start(containerID: Self.containerName(for: name))
            }
        }
        progress("Machine \(name) is ready.")
    }

    func start(name: String) async throws { try await runtime.start(containerID: Self.containerName(for: name)) }
    func stop(name: String) async throws { try await runtime.stop(containerID: Self.containerName(for: name)) }

    func delete(name: String) async throws {
        try? await runtime.stop(containerID: Self.containerName(for: name))
        try await runtime.remove(containerID: Self.containerName(for: name))
    }

    private func createContainer(name: String, distro: MachineDistro, imageTag: String, keepaliveOnly: Bool) async throws {
        let body = Self.createBody(name: name, distro: distro, imageTag: imageTag, keepaliveOnly: keepaliveOnly)
        let data = try JSONSerialization.data(withJSONObject: body)
        let path = "/containers/create?name=\(Self.containerName(for: name))"
        guard let response = await runtime.proxyRequest(
            method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: data) else {
            throw MachineError.createFailed("no response from engine")
        }
        guard response.isSuccess else {
            throw MachineError.createFailed(String(decoding: response.body, as: UTF8.self))
        }
    }

    private func isRunning(name: String) async -> Bool {
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/\(Self.containerName(for: name))/json", headers: [], body: Data()),
            response.isSuccess else { return false }
        struct State: Decodable { let Running: Bool? }
        struct Inspect: Decodable { let State: State? }
        let inspect = try? JSONDecoder().decode(Inspect.self, from: response.body)
        return inspect?.State?.Running ?? false
    }
}
