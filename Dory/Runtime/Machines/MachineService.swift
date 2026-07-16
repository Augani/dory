import Foundation

nonisolated struct MountPair: Sendable, Hashable { var host: String; var guest: String; var readOnly: Bool = false }
nonisolated struct PortPair: Sendable, Hashable { var host: Int; var guest: Int }
nonisolated enum MachineDisplayMode: String, Sendable, Hashable, CaseIterable {
    case headless
    case desktop
}
nonisolated struct MachineSettings: Sendable, Hashable {
    var cpus: Int?
    var memoryMB: Int?
    var mounts: [MountPair] = []
    var ports: [PortPair] = []
    var identity: MacIdentity? = nil
    var env: [String: String] = [:]
    var address: String? = nil
    var displayMode: MachineDisplayMode = .headless
    nonisolated static let `default` = MachineSettings(cpus: nil, memoryMB: nil)
}

struct MachineService: Sendable {
    let runtime: any ContainerRuntime

    nonisolated static let namePrefix = "dory-machine-"
    static let label = "dory.machine"
    static let versionLabel = "dory.machine.version"
    static let archLabel = "dory.machine.arch"
    static let userLabel = "dory.machine.user"
    static let uidLabel = "dory.machine.uid"
    static let homeLabel = "dory.machine.home"
    static let shellLabel = "dory.machine.shell"
    static let sshPortLabel = "dory.machine.sshPort"
    static let recipeLabel = "dory.recipe"
    static let keepalive = ["tail", "-f", "/dev/null"]
    static let snapshotRepoPrefix = "dory-snapshot/"

    nonisolated static func containerName(for name: String) -> String { namePrefix + name }

    static func bridgeHostDir(for name: String) -> String {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge").appendingPathComponent(name).path
    }

    static func distro(for recipe: DevRecipe) throws -> MachineDistro {
        guard let distro = MachineDistro.forImage(recipe.distro) else {
            throw MachineError.createFailed("unsupported recipe distro \(recipe.distro)")
        }
        return distro
    }

    static func arch(for recipe: DevRecipe) throws -> MachineArch {
        guard let arch = MachineArch(rawValue: recipe.arch) else {
            throw MachineError.createFailed("unsupported recipe arch \(recipe.arch)")
        }
        return arch
    }

    static func settings(
        from recipe: DevRecipe,
        hostUser: String = NSUserName(),
        uid: Int = Int(getuid()),
        homePath: String = NSHomeDirectory(),
        publicKeys: [String] = []
    ) throws -> MachineSettings {
        let recipe = recipe.substituted(hostUser: hostUser)
        let guestHome = recipe.user.name == "root"
            ? "/root"
            : (recipe.user.name == hostUser ? homePath : "/home/\(recipe.user.name)")
        var settings = MachineSettings(
            cpus: recipe.resources.cpus,
            memoryMB: memoryMB(from: recipe.resources.memory),
            mounts: try recipe.mounts.map { try parseMount($0, hostHome: homePath, guestHome: guestHome) },
            ports: recipe.ports.map { PortPair(host: $0, guest: $0) },
            identity: nil,
            env: recipe.env
        )
        if recipe.user.name != "root" {
            settings.identity = MacIdentity(
                username: recipe.user.name,
                uid: recipe.user.name == hostUser ? uid : 1000,
                homePath: guestHome,
                shell: recipe.user.shell,
                publicKeys: publicKeys
            )
        }
        return settings
    }

    func snapshot(machine: Machine, note: String, createdISO: String, tag: String) async throws -> MachineSnapshot {
        let labels = SnapshotLabels.make(machine: machine, note: note, createdISO: createdISO)
        let repo = Self.snapshotRepoPrefix + machine.name
        let id = try await runtime.commit(containerID: Self.containerName(for: machine.name), repo: repo, tag: tag, labels: labels)
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family ?? machine.distro.lowercased()
        let boot = MachineDistro.forFamily(family)?.boot.rawValue ?? "systemd"
        return MachineSnapshot(id: id, imageRef: "\(repo):\(tag)", machineName: machine.name, note: note,
                               createdISO: createdISO, sizeBytes: 0, distro: machine.distro, version: machine.version,
                               arch: machine.arch.isEmpty ? MachineArch.host.rawValue : machine.arch,
                               boot: boot, recipe: machine.recipe)
    }

    func listSnapshots() async -> [MachineSnapshot] {
        let filters = "{\"label\":[\"\(SnapshotLabels.ofKey)\"]}"
        let encoded = DockerImageOps.queryValue(filters)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/images/json?filters=\(encoded)", headers: [], body: Data()),
              response.isSuccess else { return [] }
        return SnapshotLabels.snapshots(fromImagesJSON: response.body)
            .sorted { $0.createdISO > $1.createdISO }
    }

    static func displayName(fromContainerName raw: String) -> String? {
        let trimmed = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        guard trimmed.hasPrefix(namePrefix) else { return nil }
        let name = String(trimmed.dropFirst(namePrefix.count))
        return name.isEmpty ? nil : name
    }

    static func createBody(name: String, distro: MachineDistro, arch: MachineArch, imageTag: String, keepaliveOnly: Bool, recipe: DevRecipe? = nil, settings: MachineSettings = .default) -> [String: Any] {
        let useInit = distro.boot == .systemd && !keepaliveOnly
        let cmd = useInit ? ["/sbin/init"] : keepalive
        var labels = [label: distro.family, versionLabel: distro.version, archLabel: arch.rawValue]
        if let recipe { labels[recipeLabel] = recipe.id }
        if let identity = settings.identity {
            labels.merge(identityLabels(identity)) { _, new in new }
        }
        if let sshPort = settings.ports.first(where: { $0.guest == 22 })?.host {
            labels[sshPortLabel] = "\(sshPort)"
        }
        let baseHostConfig: [String: Any] = [
            "Privileged": true,
            "CgroupnsMode": "host",
            "Tmpfs": ["/run": "", "/run/lock": "", "/tmp": ""],
            "ExtraHosts": ["host.docker.internal:host-gateway", "host.dory.internal:host-gateway"],
            "RestartPolicy": ["Name": "unless-stopped"],
        ]
        var hostConfig = self.hostConfig(base: baseHostConfig, settings: settings)
        var binds = (hostConfig["Binds"] as? [String]) ?? []
        binds.append("\(bridgeHostDir(for: name)):/opt/dory/bridge")
        hostConfig["Binds"] = binds
        hostConfig.removeValue(forKey: "ExposedPorts")
        var body: [String: Any] = [
            "Hostname": name,
            "Image": imageTag,
            "Cmd": cmd,
            "Env": Self.machineEnv(settings: settings),
            "StopSignal": "SIGRTMIN+3",
            "Labels": labels,
            "HostConfig": hostConfig,
        ]
        if !settings.ports.isEmpty { body["ExposedPorts"] = exposedPorts(for: settings) }
        return body
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
                containerID: entry.Id,
                arch: entry.Labels?[archLabel] ?? "",
                recipe: entry.Labels?[recipeLabel] ?? "",
                username: entry.Labels?[userLabel] ?? "root",
                loginShell: entry.Labels?[shellLabel] ?? "/bin/sh",
                uid: entry.Labels?[uidLabel].flatMap { Int($0) },
                homePath: entry.Labels?[homeLabel],
                sshPort: entry.Labels?[sshPortLabel].flatMap { Int($0) }
            )
        }
    }

    func list() async -> [Machine] {
        let filters = "{\"label\":[\"\(Self.label)\"]}"
        let encoded = DockerImageOps.queryValue(filters)
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/json?all=1&filters=\(encoded)", headers: [], body: Data()),
            response.isSuccess else { return [] }
        return Self.machines(fromContainersJSON: response.body)
    }

    func containerID(for name: String) async -> String? {
        await list().first { $0.name == name }?.containerID
    }

    func create(name: String, distro: MachineDistro, arch: MachineArch, recipe: DevRecipe? = nil, settings: MachineSettings = .default, progress: @escaping @Sendable (String) -> Void) async throws {
        if !arch.isNative { await ensureEmulation(for: arch, progress: progress) }
        let tag: String
        if let recipe {
            tag = try await MachineImageBuilder.ensureRecipeImage(distro: distro, arch: arch, recipe: recipe, runtime: runtime, progress: progress)
        } else {
            tag = try await MachineImageBuilder.ensureImage(distro, arch: arch, runtime: runtime, progress: progress)
        }

        let containerName = Self.containerName(for: name)
        var containerCreated = false
        do {
            progress("Creating \(name)…")
            try await createContainer(name: name, distro: distro, arch: arch, imageTag: tag,
                                      keepaliveOnly: false, recipe: recipe, settings: settings)
            containerCreated = true
            progress("Starting \(name)…")
            try await runtime.start(containerID: containerName)

            if distro.boot == .systemd {
                var exited = false
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(1))
                    if await !isRunning(name: name) { exited = true; break }
                }
                if exited {
                    progress("systemd did not come up on this image — falling back to a shell machine…")
                    try await runtime.remove(containerID: containerName)
                    containerCreated = false
                    try await createContainer(name: name, distro: distro, arch: arch, imageTag: tag,
                                              keepaliveOnly: true, recipe: recipe, settings: settings)
                    containerCreated = true
                    try await runtime.start(containerID: containerName)
                }
            }

            if let identity = settings.identity {
                progress("Setting up \(identity.username)…")
                let script = MachineProvisioner.script(identity: identity, pkg: distro.pkg,
                                                        isSystemd: distro.boot == .systemd,
                                                        includeSSH: true)
                let result = try await runtime.exec(
                    containerID: containerName,
                    command: ["/bin/sh", "-c", script]
                )
                try Self.requireSuccessfulSetup(result, stage: "Identity setup")
            }
            progress("Installing gh, claude, and socat (best-effort)…")
            let nodeProbe = try? await runtime.exec(
                containerID: containerName,
                command: ["/bin/sh", "-c", "command -v node >/dev/null 2>&1 && echo yes || echo no"]
            )
            let hasNode = (nodeProbe?.output ?? "").contains("yes")
            let toolScript = MachineProvisioner.toolInstallScript(pkg: distro.pkg, hasNode: hasNode)
            let toolResult = try? await runtime.exec(
                containerID: containerName,
                command: ["/bin/sh", "-c", toolScript]
            )
            if let toolResult, !toolResult.succeeded {
                progress("Tool install reported: \(toolResult.output)")
            }
            progress("Machine \(name) is ready.")
        } catch {
            var cleanupFailure: Error?
            if containerCreated {
                progress("Setup failed. Removing the incomplete machine…")
                try? await runtime.stop(containerID: containerName)
                do {
                    try await runtime.remove(containerID: containerName)
                } catch {
                    cleanupFailure = error
                }
            }
            if let cleanupFailure {
                throw MachineError.createFailed(
                    "\(error); cleanup of incomplete machine also failed: \(cleanupFailure)"
                )
            }
            throw error
        }
    }

    func create(name: String, recipe: DevRecipe, progress: @escaping @Sendable (String) -> Void) async throws {
        let recipe = recipe.substituted(hostUser: NSUserName())
        try recipe.validate()
        let distro = try Self.distro(for: recipe)
        let arch = try Self.arch(for: recipe)
        let settings = try Self.settings(
            from: recipe,
            publicKeys: MacIdentity.current(shell: recipe.user.shell).publicKeys
        )
        try await create(name: name, distro: distro, arch: arch, recipe: recipe, settings: settings, progress: progress)
    }

    func start(name: String) async throws {
        try await runtime.start(containerID: Self.containerName(for: name))
        _ = try? await runtime.exec(containerID: Self.containerName(for: name),
                                    command: ["/bin/sh", "-c", "command -v sshd >/dev/null 2>&1 && (pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null) || true"])
    }
    func stop(name: String) async throws { try await runtime.stop(containerID: Self.containerName(for: name)) }

    func delete(name: String) async throws {
        try? await runtime.stop(containerID: Self.containerName(for: name))
        try await runtime.remove(containerID: Self.containerName(for: name))
    }

    private func createContainer(name: String, distro: MachineDistro, arch: MachineArch, imageTag: String, keepaliveOnly: Bool, recipe: DevRecipe? = nil, settings: MachineSettings = .default) async throws {
        let body = Self.createBody(name: name, distro: distro, arch: arch, imageTag: imageTag, keepaliveOnly: keepaliveOnly, recipe: recipe, settings: settings)
        let data = try JSONSerialization.data(withJSONObject: body)
        let encodedName = DockerImageOps.queryValue(Self.containerName(for: name))
        let encodedPlatform = DockerImageOps.queryValue(arch.platform)
        let path = "/containers/create?name=\(encodedName)&platform=\(encodedPlatform)"
        guard let response = await runtime.proxyRequest(
            method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: data) else {
            throw MachineError.createFailed("no response from engine")
        }
        guard response.isSuccess else {
            throw MachineError.createFailed(String(decoding: response.body, as: UTF8.self))
        }
    }

    private func runFromImage(name: String, imageRef: String, snapshot: MachineSnapshot, settings: MachineSettings = .default) async throws {
        let distro = MachineDistro.forFamily(MachineDistro.all.first { $0.display == snapshot.distro }?.family ?? "")
        let cmd = snapshot.boot == "systemd" ? ["/sbin/init"] : Self.keepalive
        var effectiveSettings = Self.carryIdentity(settings,
                                                   username: snapshot.username,
                                                   uid: snapshot.uid,
                                                   homePath: snapshot.homePath,
                                                   loginShell: snapshot.loginShell)
        if let identity = effectiveSettings.identity,
           !effectiveSettings.mounts.contains(where: { $0.guest == identity.homePath }) {
            var copy = effectiveSettings
            copy.mounts.append(MountPair(host: identity.homePath, guest: identity.homePath, readOnly: false))
            effectiveSettings = copy
        }
        let baseHostConfig: [String: Any] = ["Privileged": true, "CgroupnsMode": "host",
                                             "Tmpfs": ["/run": "", "/run/lock": "", "/tmp": ""],
                                             "RestartPolicy": ["Name": "unless-stopped"]]
        var hostConfig = Self.hostConfig(base: baseHostConfig, settings: effectiveSettings)
        var binds = (hostConfig["Binds"] as? [String]) ?? []
        binds.append("\(Self.bridgeHostDir(for: name)):/opt/dory/bridge")
        hostConfig["Binds"] = binds
        hostConfig.removeValue(forKey: "ExposedPorts")
        var labels: [String: String] = [
            Self.label: distro?.family ?? snapshot.distro.lowercased(),
            Self.versionLabel: snapshot.version,
            Self.archLabel: snapshot.arch,
            "dory.machine.boot": snapshot.boot,
        ]
        if !snapshot.recipe.isEmpty { labels[Self.recipeLabel] = snapshot.recipe }
        if let identity = effectiveSettings.identity {
            labels.merge(Self.identityLabels(identity)) { _, new in new }
        }
        if let sshPort = effectiveSettings.ports.first(where: { $0.guest == 22 })?.host {
            labels[Self.sshPortLabel] = "\(sshPort)"
        }
        var body: [String: Any] = [
            "Hostname": name,
            "Image": imageRef,
            "Cmd": cmd,
            "Env": Self.machineEnv(settings: effectiveSettings),
            "StopSignal": "SIGRTMIN+3",
            "Labels": labels,
            "HostConfig": hostConfig,
        ]
        if !effectiveSettings.ports.isEmpty { body["ExposedPorts"] = Self.exposedPorts(for: effectiveSettings) }
        let data = try JSONSerialization.data(withJSONObject: body)
        let platform = (snapshot.arch.isEmpty ? MachineArch.host.rawValue : snapshot.arch)
        let encodedName = DockerImageOps.queryValue(Self.containerName(for: name))
        let encodedPlatform = DockerImageOps.queryValue("linux/\(platform)")
        guard let response = await runtime.proxyRequest(method: "POST",
            path: "/containers/create?name=\(encodedName)&platform=\(encodedPlatform)",
            headers: [(name: "Content-Type", value: "application/json")], body: data),
            response.isSuccess else {
            throw MachineError.createFailed("could not create machine from snapshot")
        }
        try await runtime.start(containerID: Self.containerName(for: name))
    }

    func cloneFromSnapshot(_ snapshot: MachineSnapshot, newName: String) async throws {
        try await runFromImage(name: newName, imageRef: snapshot.imageRef, snapshot: snapshot)
    }

    func restore(_ snapshot: MachineSnapshot) async throws {
        try? await runtime.stop(containerID: Self.containerName(for: snapshot.machineName))
        try? await runtime.remove(containerID: Self.containerName(for: snapshot.machineName))
        try await runFromImage(name: snapshot.machineName, imageRef: snapshot.imageRef, snapshot: snapshot)
    }

    func recreate(name: String, settings: MachineSettings) async throws {
        guard let machine = await list().first(where: { $0.name == name }) else {
            throw MachineError.notFound(name)
        }
        let settings = Self.carryIdentity(settings, username: machine.username, uid: machine.uid, homePath: machine.homePath, loginShell: machine.loginShell)
        let createdISO = ISO8601DateFormatter().string(from: Date())
        let tag = "edit\(Int(Date().timeIntervalSince1970))"
        let snapshot = try await self.snapshot(machine: machine, note: "pre-edit", createdISO: createdISO, tag: tag)

        try? await runtime.stop(containerID: Self.containerName(for: name))
        try? await runtime.remove(containerID: Self.containerName(for: name))

        do {
            try await runFromImage(name: name, imageRef: snapshot.imageRef, snapshot: snapshot, settings: settings)
            try? await runtime.removeImage(id: snapshot.imageRef)
        } catch {
            try? await runtime.stop(containerID: Self.containerName(for: name))
            try? await runtime.remove(containerID: Self.containerName(for: name))
            try await runFromImage(name: name, imageRef: snapshot.imageRef, snapshot: snapshot, settings: .default)
            throw error
        }
    }

    private func ensureEmulation(for arch: MachineArch, progress: @escaping @Sendable (String) -> Void) async {
        if MachineArch.host == .arm64, arch == .amd64 {
            progress("Using Dory's built-in FEX amd64 runtime…")
            return
        }
        progress("Enabling \(arch.shortLabel) emulation…")
        try? await runtime.pull(image: SharedVMProvisioner.pinnedBinfmtImage)
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "Image": SharedVMProvisioner.pinnedBinfmtImage,
            "Cmd": ["--install", arch.rawValue],
            "HostConfig": ["Privileged": true, "AutoRemove": true] as [String: Any],
        ]) else { return }
        guard let create = await runtime.proxyRequest(
            method: "POST", path: "/containers/create",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            create.isSuccess, let id = decodeId(create.body) else { return }
        let encodedID = DockerImageOps.pathComponent(id)
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data())
        try? await Task.sleep(for: .seconds(2))
    }

    private func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }

    func currentSettings(name: String) async -> MachineSettings {
        let encodedName = DockerImageOps.pathComponent(Self.containerName(for: name))
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
            response.isSuccess else { return .default }
        struct PortBinding: Decodable { let HostPort: String? }
        struct Mount: Decodable {
            let type: String?
            let source: String?
            let destination: String?
            let target: String?
            let readOnly: Bool?
            let rw: Bool?

            enum CodingKeys: String, CodingKey {
                case type = "Type", source = "Source", destination = "Destination", target = "Target"
                case readOnly = "ReadOnly", rw = "RW"
            }
        }
        struct HostConfig: Decodable {
            let NanoCpus: Int64?
            let Memory: Int64?
            let Binds: [String]?
            let PortBindings: [String: [PortBinding]?]?
        }
        struct Config: Decodable {
            let Env: [String]?
            let Labels: [String: String]?
        }
        struct Inspect: Decodable { let HostConfig: HostConfig?; let Mounts: [Mount]?; let Config: Config? }
        guard let inspect = try? JSONDecoder().decode(Inspect.self, from: response.body),
              let host = inspect.HostConfig else { return .default }
        let cpus = (host.NanoCpus ?? 0) > 0 ? Int((host.NanoCpus ?? 0) / 1_000_000_000) : nil
        let memoryMB = (host.Memory ?? 0) > 0 ? Int((host.Memory ?? 0) / (1024 * 1024)) : nil
        let bindMounts = (host.Binds ?? []).compactMap { Self.parseBind($0) }
        let inspectMounts = (inspect.Mounts ?? []).compactMap { mount -> MountPair? in
            guard (mount.type ?? "bind").lowercased() == "bind",
                  let source = mount.source,
                  let target = mount.destination ?? mount.target,
                  !source.isEmpty,
                  !target.isEmpty else { return nil }
            return MountPair(host: source, guest: target, readOnly: mount.readOnly ?? mount.rw.map { !$0 } ?? false)
        }
        let mounts = Self.uniqueMounts(bindMounts + inspectMounts)
        let ports: [PortPair] = (host.PortBindings ?? [:]).compactMap { key, bindings in
            let guestStr = key.split(separator: "/").first.map(String.init) ?? key
            guard let guest = Int(guestStr), let hostStr = bindings?.first?.HostPort ?? nil, let hostPort = Int(hostStr) else { return nil }
            return PortPair(host: hostPort, guest: guest)
        }
        let env = (inspect.Config?.Env ?? []).reduce(into: [String: String]()) { result, entry in
            guard let eq = entry.firstIndex(of: "=") else { return }
            let key = String(entry[entry.startIndex..<eq])
            guard key != "container" else { return }
            result[key] = String(entry[entry.index(after: eq)...])
        }
        let identity: MacIdentity? = {
            guard let labels = inspect.Config?.Labels,
                  let username = labels[Self.userLabel],
                  username != "root" else { return nil }
            let shell = labels[Self.shellLabel] ?? "/bin/sh"
            return MacIdentity(username: username,
                               uid: labels[Self.uidLabel].flatMap { Int($0) } ?? Self.fallbackUID(for: username),
                               homePath: labels[Self.homeLabel] ?? Self.fallbackHome(for: username),
                               shell: shell,
                               publicKeys: [])
        }()
        return MachineSettings(cpus: cpus, memoryMB: memoryMB, mounts: mounts, ports: ports, identity: identity, env: env)
    }

    private func isRunning(name: String) async -> Bool {
        let encodedName = DockerImageOps.pathComponent(Self.containerName(for: name))
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
            response.isSuccess else { return false }
        struct State: Decodable { let Running: Bool? }
        struct Inspect: Decodable { let State: State? }
        let inspect = try? JSONDecoder().decode(Inspect.self, from: response.body)
        return inspect?.State?.Running ?? false
    }

    static func isDoryMachineImage(loadedLabels: [String: String]) -> Bool {
        loadedLabels.keys.contains(label)
    }

    func export(_ snapshot: MachineSnapshot, to fileURL: URL) async throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw MachineError.createFailed("could not open \(fileURL.lastPathComponent) for writing")
        }
        do {
            for await chunk in runtime.saveImage(reference: snapshot.imageRef) {
                try handle.write(contentsOf: chunk)
            }
            try? handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func importMachine(from fileURL: URL) async throws -> String {
        guard let tar = try? Data(contentsOf: fileURL) else {
            throw MachineError.createFailed("could not read \(fileURL.lastPathComponent)")
        }
        let before = Set(await listSnapshots().map(\.id))
        try await runtime.loadImage(tar: tar)
        guard let loaded = Self.firstNew(before: before, after: await listSnapshots()) else {
            throw MachineError.createFailed("Not a Dory machine file")
        }
        return loaded.imageRef
    }

    static func firstNew(before: Set<String>, after: [MachineSnapshot]) -> MachineSnapshot? {
        after.first { !before.contains($0.id) }
    }
}

extension MachineService {
    static func identityLabels(_ identity: MacIdentity) -> [String: String] {
        [
            userLabel: identity.username,
            uidLabel: "\(identity.uid)",
            homeLabel: identity.homePath,
            shellLabel: identity.shell,
        ]
    }

    static func requireSuccessfulSetup(_ result: ExecResult, stage: String) throws {
        guard result.succeeded else {
            let normalized = result.output
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = String(normalized.prefix(4_096))
            throw MachineError.createFailed(
                "\(stage) failed with exit code \(result.exitCode)\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
    }

    static func fallbackUID(for username: String) -> Int {
        username == NSUserName() ? Int(getuid()) : 501
    }

    static func fallbackHome(for username: String) -> String {
        username == NSUserName() ? NSHomeDirectory() : "/Users/\(username)"
    }

    static func carryIdentity(_ settings: MachineSettings, username: String, uid: Int? = nil, homePath: String? = nil, loginShell: String) -> MachineSettings {
        guard username != "root", settings.identity == nil else { return settings }
        var copy = settings
        copy.identity = MacIdentity(username: username,
                                    uid: uid ?? fallbackUID(for: username),
                                    homePath: homePath ?? fallbackHome(for: username),
                                    shell: loginShell,
                                    publicKeys: [])
        return copy
    }

    nonisolated static func bindString(_ m: MountPair) -> String { m.readOnly ? "\(m.host):\(m.guest):ro" : "\(m.host):\(m.guest)" }

    nonisolated static func parseBind(_ s: String) -> MountPair? {
        let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return MountPair(host: parts[0], guest: parts[1], readOnly: parts.count == 3 && parts[2] == "ro")
    }

    nonisolated static func parseMount(_ value: String, hostHome: String = NSHomeDirectory(), guestHome: String) throws -> MountPair {
        guard let mount = parseBind(value) else {
            throw MachineError.createFailed("invalid recipe mount \(value)")
        }
        let host = try expandTilde(mount.host, home: hostHome, mount: value)
        let guest = try expandTilde(mount.guest, home: guestHome, mount: value)
        return MountPair(host: host, guest: guest, readOnly: mount.readOnly)
    }

    nonisolated static func expandTilde(_ path: String, home: String, mount: String) throws -> String {
        guard !path.isEmpty else {
            throw MachineError.createFailed("invalid recipe mount \(mount)")
        }
        guard path.hasPrefix("~") else { return path }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else {
            throw MachineError.createFailed("cannot resolve home directory for recipe mount \(mount)")
        }
        if path == "~" { return trimmedHome }
        guard path.hasPrefix("~/") else {
            throw MachineError.createFailed("unsupported ~user expansion in recipe mount \(mount)")
        }
        return trimmedHome + String(path.dropFirst(1))
    }

    nonisolated static func memoryMB(from size: String) -> Int? {
        let units: [(suffix: String, multiplier: Int)] = [
            ("TiB", 1024 * 1024),
            ("GiB", 1024),
            ("MiB", 1),
        ]
        for unit in units where size.hasSuffix(unit.suffix) {
            let raw = String(size.dropLast(unit.suffix.count))
            return Int(raw).map { $0 * unit.multiplier }
        }
        return nil
    }

    nonisolated static func uniqueMounts(_ mounts: [MountPair]) -> [MountPair] {
        var seen = Set<MountPair>()
        return mounts.filter { seen.insert($0).inserted }
    }

    static func hostConfig(base: [String: Any], settings: MachineSettings) -> [String: Any] {
        var host = base
        if let cpus = settings.cpus { host["NanoCpus"] = Int64(cpus) * 1_000_000_000 }
        if let memoryMB = settings.memoryMB { host["Memory"] = Int64(memoryMB) * 1024 * 1024 }
        if !settings.mounts.isEmpty { host["Binds"] = settings.mounts.map(Self.bindString) }
        if !settings.ports.isEmpty {
            var exposed: [String: [String: String]] = [:]
            var bindings: [String: [[String: String]]] = [:]
            for port in settings.ports {
                exposed["\(port.guest)/tcp"] = [:]
                bindings["\(port.guest)/tcp"] = [["HostPort": "\(port.host)"]]
            }
            host["ExposedPorts"] = exposed
            host["PortBindings"] = bindings
        }
        return host
    }

    static func exposedPorts(for settings: MachineSettings) -> [String: [String: String]] {
        var exposed: [String: [String: String]] = [:]
        for port in settings.ports { exposed["\(port.guest)/tcp"] = [:] }
        return exposed
    }

    static func machineEnv(settings: MachineSettings) -> [String] {
        let credentialsDir = "\(DoryCredentialShim.bridgeGuestDir)/credentials"
        let credentialEnv = [
            "SSH_AUTH_SOCK=\(DoryCredentialShim.guestSSHAuthSockPath)",
            "GIT_ASKPASS=\(DoryCredentialShim.gitAskpassPath)",
            "DORY_GIT_ASKPASS_SOCK=\(credentialsDir)/git-askpass.sock",
        ]
        return (["container=docker", "BROWSER=dory-open"] + credentialEnv + settings.env.map { "\($0.key)=\($0.value)" }).sorted()
    }
}
