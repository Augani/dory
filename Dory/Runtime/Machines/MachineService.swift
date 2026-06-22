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
            "Labels": [label: distro.id, versionLabel: distro.version],
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
            guard let distroID = entry.Labels?[label], let distro = MachineDistro.forID(distroID) else { return nil }
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
}
