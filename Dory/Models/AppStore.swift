import SwiftUI
import Observation
import ServiceManagement
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppStore {
    var appearance: DoryAppearance = .dark
    var section: AppSection = .containers {
        didSet { if oldValue != section { filter = "" } }
    }
    var selectedContainerID: String? = "c1"
    var detailTab: DetailTab = .overview
    var settingsTab: SettingsTab = .general
    var menuOpen = false
    var onboarding = false
    var filter = ""
    var activeSheet: AppSheet?
    var actionError: String?
    var inspectedImage: DockerImage?
    var inspectedNetwork: DoryNetwork?

    var launchAtLogin = false
    var showMenuBarIcon = true
    var autoUpdate = false

    var containers: [Container] = MockData.containers
    var images: [DockerImage] = MockData.images
    var volumes: [Volume] = MockData.volumes
    var networks: [DoryNetwork] = MockData.networks
    var pods: [Pod] = []
    var machines: [Machine] = MockData.machines
    var engineRunning = true
    var engineVersion = "1.4.0"

    var kubernetesReachable = false
    var kubernetesInfo = "Cluster not running"
    private let kubernetes = KubernetesProvider()

    private var runtime: any ContainerRuntime
    var runtimeKind: RuntimeKind { runtime.kind }

    init(runtime: any ContainerRuntime = MockRuntime()) {
        self.runtime = runtime
        let table = domainTable
        reverseProxy = DoryReverseProxy { host in table.backend(for: host) }
        let env = ProcessInfo.processInfo.environment
        let realLaunch = env["DORY_SECTION"] == nil && env["DORY_APPEARANCE"] == nil && env["XCTestConfigurationFilePath"] == nil
        if realLaunch {
            if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let saved = DoryAppearance(rawValue: raw) {
                appearance = saved
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if let v = UserDefaults.standard.object(forKey: Self.menuBarIconKey) as? Bool { showMenuBarIcon = v }
            if let v = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool { autoUpdate = v }
        }
        if let raw = env["DORY_SECTION"], let parsed = AppSection(rawValue: raw) { section = parsed }
        if let raw = env["DORY_SETTINGS_TAB"], let parsed = SettingsTab(rawValue: raw) { settingsTab = parsed }
        if let raw = env["DORY_DETAIL_TAB"], let parsed = DetailTab(rawValue: raw) { detailTab = parsed }
        if env["DORY_APPEARANCE"] == "light" { appearance = .light }
        if let raw = env["DORY_SHEET"], let parsed = AppSheet(rawValue: raw) {
            activeSheet = parsed
            if parsed == .inspectImage { inspectedImage = images.first }
            if parsed == .inspectNetwork { inspectedNetwork = networks.first(where: { $0.containerCount > 0 }) ?? networks.first }
        }
        let snapshotMode = env["DORY_SECTION"] != nil || env["DORY_SHEET"] != nil || env["DORY_DETAIL_TAB"] != nil
        let testMode = env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
        if env["DORY_ONBOARDING"] == "1" {
            onboarding = true
        } else if !UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) && !snapshotMode && !testMode {
            onboarding = true
        }
    }

    static let onboardingDoneKey = "dory.hasCompletedOnboarding"
    static let appearanceKey = "dory.appearance"
    static let menuBarIconKey = "dory.showMenuBarIcon"
    static let autoUpdateKey = "dory.autoUpdate"

    func setAutoUpdate(_ on: Bool) {
        autoUpdate = on
        UserDefaults.standard.set(on, forKey: Self.autoUpdateKey)
    }

    func setAppearance(_ value: DoryAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.appearanceKey)
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            actionError = "Could not update the login item: \(error.localizedDescription)"
        }
    }

    func setShowMenuBarIcon(_ on: Bool) {
        showMenuBarIcon = on
        UserDefaults.standard.set(on, forKey: Self.menuBarIconKey)
    }

    func completeOnboarding() {
        onboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
    }

    var palette: DoryPalette { appearance.palette }

    private var shimServer: ShimHTTPServer?
    var shimSocketPath: String { DockerShim.defaultSocketPath }
    private(set) var shimRunning = false

    func connectBackend() async {
        switch ProcessInfo.processInfo.environment["DORY_RUNTIME"] {
        case "mock":
            break
        case "apple":
            if let apple = await AppleContainerRuntime.detect() { runtime = apple; await reload() }
        case "docker":
            if let docker = await DockerEngineRuntime.detect() { runtime = docker; await reload() }
        case "shared":
            if let shared = await SharedVMProvisioner.runtime() { runtime = shared; await reload() }
        case "docker-proxy":
            if let docker = await DockerEngineRuntime.detect() { runtime = docker; await reload() }
        default:
            // Dory's own shared VM is the default engine — a standalone, OrbStack-style daemon.
            // Fall back to fronting an existing Docker/OrbStack socket, then Apple per-container.
            sharedVMStatus = "Starting Dory's engine…"
            if let shared = await SharedVMProvisioner.runtime() {
                runtime = shared; sharedVMStatus = "Running on Dory's shared VM"; await reload()
            } else if let docker = await DockerEngineRuntime.detect() {
                runtime = docker; sharedVMStatus = ""; await reload()
            } else if let apple = await AppleContainerRuntime.detect() {
                runtime = apple; sharedVMStatus = ""; await reload()
            } else {
                sharedVMStatus = ""
            }
        }
        await loadKubernetes()
        await loadMachines()
        startShim()
        startPortForwarding()
    }

    var sharedVMStatus = ""

    /// Provisions (or reuses) Dory's own single shared Linux VM and switches the live engine to it,
    /// making Dory a standalone, OrbStack-style daemon that no longer depends on Docker/OrbStack.
    func useSharedVM() async {
        guard runtimeKind != .sharedVM else { return }
        sharedVMStatus = "Starting Dory's shared VM…"
        guard let shared = await SharedVMProvisioner.runtime() else {
            sharedVMStatus = "Shared VM unavailable (needs Apple `container`)"
            return
        }
        runtime = shared
        await reload()
        restartShim()
        startPortForwarding()
        sharedVMStatus = "Running on Dory's shared VM"
    }

    private func restartShim() {
        shimServer?.stop()
        shimServer = nil
        shimRunning = false
        startShim()
    }

    let domainSuffix = "dory.local"
    private let portForwarder = HostPortForwarder(
        targetHost: "127.0.0.1",
        containerBinary: SharedVMProvisioner.containerBinary(),
        engineName: SharedVMProvisioner.engineName
    )
    private let domainTable = DomainTable()
    private let dns = DoryDNS()
    @ObservationIgnored private let reverseProxy: DoryReverseProxy
    private var networkingStarted = false
    private var portForwardingTask: Task<Void, Never>?


    /// On the shared VM, published container ports live on the VM's IP, not the host. This keeps a
    /// host-side forwarder + `*.dory.local` reverse proxy reconciled so every published port is
    /// reachable at `localhost:port` AND `http://<name>.dory.local` — OrbStack behavior. A no-op
    /// (and torn down) on other backends, where the host already owns the ports.
    func startPortForwarding() {
        portForwardingTask?.cancel()
        guard runtimeKind == .sharedVM else { portForwarder.stopAll(); stopLocalNetworking(); return }
        startLocalNetworking()
        let runtime = self.runtime
        let forwarder = self.portForwarder
        let table = self.domainTable
        let suffix = self.domainSuffix
        portForwardingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                if let ip = await SharedVMProvisioner.engineIP(), ip != "127.0.0.1" {
                    forwarder.updateTarget(ip)
                    let endpoints = await Self.containerEndpoints(runtime, suffix: suffix)
                    forwarder.sync(ports: Set(endpoints.values))
                    table.replaceContainers(endpoints)
                    if FileManager.default.fileExists(atPath: KubernetesProvisioner.kubeconfigPath) {
                        await self?.ensureKubeProxy()
                        table.replaceKube(await KubeServiceProxy.backends(suffix: suffix))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static let dnsPort: UInt16 = 15353
    static let httpProxyPort: UInt16 = 8080
    static let httpsProxyPort: UInt16 = 8443
    @ObservationIgnored private var tlsProxy: DoryTLSProxy?

    private func startLocalNetworking() {
        guard !networkingStarted else { return }
        // DNS on a high port (mDNSResponder owns :53/:5353); a consent-gated /etc/resolver entry
        // with a `port` directive points the system resolver here, so DNS needs no root.
        try? dns.start(port: Self.dnsPort)
        try? reverseProxy.start(httpPort: Self.httpProxyPort)
        networkingStarted = true
        startTLS()
        Task.detached { await SharedVMProvisioner.ensureEmulation() }
    }

    private func startTLS() {
        let table = domainTable
        let suffix = domainSuffix
        let port = Self.httpsProxyPort
        // TLS wildcards match one label, so `*.dory.local` doesn't cover multi-level k8s Service
        // domains like `web.default.k8s.dory.local`. Per-namespace wildcards (issued once at
        // startup) cover the common namespaces without fragile live cert reloads.
        let extraSANs = ["*.k8s.\(suffix)", "*.default.k8s.\(suffix)", "*.kube-system.k8s.\(suffix)"]
        Task { [weak self] in
            let proxy = await Task.detached { () -> DoryTLSProxy? in
                guard let p12 = try? LocalCA().issuePKCS12(domain: suffix, password: "dory", extraSANs: extraSANs) else { return nil }
                return DoryTLSProxy(p12Path: p12.path, password: "dory", resolve: { table.backend(for: $0) })
            }.value
            guard let self, let proxy else { return }
            try? proxy.start(port: port)
            self.tlsProxy = proxy
        }
    }

    @ObservationIgnored private var kubeProxy: Process?

    /// Starts a local `kubectl proxy` once a Dory cluster exists, so `*.k8s.dory.local` Service
    /// domains route through the API server. Idempotent.
    func ensureKubeProxy() {
        guard kubeProxy == nil || kubeProxy?.isRunning == false else { return }
        kubeProxy = KubeServiceProxy.startProxy()
    }

    private func stopLocalNetworking() {
        guard networkingStarted else { return }
        dns.stop(); reverseProxy.stop(); tlsProxy?.stop(); tlsProxy = nil
        if let proxy = kubeProxy, proxy.isRunning { proxy.terminate() }
        kubeProxy = nil
        networkingStarted = false
    }

    /// `<name>.dory.local` → the published host port that reaches the container. Containers without a
    /// published port are skipped (their domain has no web endpoint to route to yet).
    private static func containerEndpoints(_ runtime: any ContainerRuntime, suffix: String) async -> [String: Int] {
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/json", headers: [], body: Data()),
              response.isSuccess else { return [:] }
        struct Entry: Decodable { let Names: [String]?; let Ports: [PortItem]? }
        struct PortItem: Decodable { let PublicPort: Int? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: response.body) else { return [:] }
        var result: [String: Int] = [:]
        for entry in entries {
            guard let port = (entry.Ports ?? []).compactMap(\.PublicPort).min() else { continue }
            for raw in entry.Names ?? [] {
                let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
                guard !name.isEmpty else { continue }
                result["\(name).\(suffix)".lowercased()] = port
            }
        }
        return result
    }

    func loadKubernetes() async {
        guard runtimeKind != .mock else { kubernetesReachable = false; return }
        let status = await kubernetes.status()
        kubernetesReachable = status.reachable
        kubernetesInfo = status.info
        pods = status.pods
    }

    var kubernetesBusy = false

    /// One-click Kubernetes: bootstraps k3s inside Dory's shared VM and wires the host kubeconfig.
    func enableKubernetes() async {
        guard runtimeKind == .sharedVM else { kubernetesInfo = "Kubernetes needs Dory's shared VM engine"; return }
        guard !kubernetesBusy else { return }
        kubernetesBusy = true
        defer { kubernetesBusy = false }
        do {
            try await KubernetesProvisioner.enable(runtime: runtime) { message in
                Task { @MainActor in self.kubernetesInfo = message }
            }
        } catch {
            kubernetesInfo = "Kubernetes failed to start"
        }
        await loadKubernetes()
    }

    func disableKubernetes() async {
        guard !kubernetesBusy else { return }
        kubernetesBusy = true
        defer { kubernetesBusy = false }
        await KubernetesProvisioner.disable(runtime: runtime)
        kubernetesReachable = false
        await loadKubernetes()
    }

    func startShim() {
        guard shimServer == nil else { return }
        let shim = DockerShim(runtime: runtime)
        let runtime = self.runtime
        let rawProxy: ShimHTTPServer.RawProxy?
        if runtime.supportsRawProxy {
            rawProxy = { (fd: Int32, initial: Data) in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        } else {
            rawProxy = nil
        }
        let server = ShimHTTPServer(socketPath: DockerShim.defaultSocketPath, rawProxy: rawProxy) { request in await shim.handle(request) }
        do {
            try server.start()
            shimServer = server
            shimRunning = true
        } catch {
            shimRunning = false
        }
    }

    func reload() async {
        guard let snap = try? await runtime.snapshot() else { return }
        containers = snap.containers
        images = snap.images
        volumes = snap.volumes
        networks = snap.networks
        pods = snap.pods
        engineRunning = snap.engineRunning
        engineVersion = snap.engineVersion
        if selectedContainerID == nil || !containers.contains(where: { $0.id == selectedContainerID }) {
            selectedContainerID = containers.first?.id
        }
    }

    var selectedContainer: Container? {
        containers.first { $0.id == selectedContainerID } ?? containers.first
    }

    var runningCount: Int { containers.filter(\.isRunning).count }

    var totalCPU: Double { containers.reduce(0) { $0 + $1.cpuPercent } }
    var totalCPUDisplay: String { String(format: "%.1f%%", totalCPU) }
    var cpuMeterFraction: Double { min(100, totalCPU * 9) / 100 }
    var totalMemoryBytes: Int64 { containers.filter(\.isRunning).reduce(0) { $0 + max(0, $1.memoryBytes) } }
    var memMeterFraction: Double {
        let host = Double(ProcessInfo.processInfo.physicalMemory)
        guard host > 0 else { return 0 }
        return min(1, Double(totalMemoryBytes) / host)
    }
    var totalMemoryDisplay: String { totalMemoryBytes > 0 ? DockerFormat.bytes(totalMemoryBytes) : "—" }

    func subtitle(for section: AppSection) -> String {
        switch section {
        case .containers: "\(runningCount) of \(containers.count) running"
        case .images: "\(images.count) image\(images.count == 1 ? "" : "s")"
        case .volumes: "\(volumes.count) volume\(volumes.count == 1 ? "" : "s")"
        case .networks: "\(networks.count) network\(networks.count == 1 ? "" : "s")"
        case .compose:
            { let n = Set(containers.compactMap(\.composeProject)).count; return "\(n) project\(n == 1 ? "" : "s")" }()
        case .kubernetes:
            pods.isEmpty ? "Cluster not enabled" : "\(pods.count) pods across \(Set(pods.map(\.namespace)).count) namespaces"
        case .machines:
            "\(machines.count) machine\(machines.count == 1 ? "" : "s") · \(machines.filter { $0.status == .running }.count) running"
        case .settings: "Dory v\(AppInfo.version)"
        }
    }

    var filteredContainers: [Container] {
        guard !filter.isEmpty else { return containers }
        return containers.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.image.localizedCaseInsensitiveContains(filter) }
    }

    var filteredImages: [DockerImage] {
        guard !filter.isEmpty else { return images }
        return images.filter { $0.repository.localizedCaseInsensitiveContains(filter) || $0.tag.localizedCaseInsensitiveContains(filter) }
    }

    var filteredVolumes: [Volume] {
        guard !filter.isEmpty else { return volumes }
        return volumes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var filteredNetworks: [DoryNetwork] {
        guard !filter.isEmpty else { return networks }
        return networks.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var filteredMachines: [Machine] {
        guard !filter.isEmpty else { return machines }
        return machines.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    func overviewRows(for c: Container) -> [(key: String, value: String)] {
        [
            ("Domain", c.domain),
            ("IP address", c.ipAddress),
            ("Ports", c.ports),
            ("Command", c.command),
            ("Restart policy", c.restartPolicy),
            ("Created", c.created),
            ("Uptime", c.uptime),
        ]
    }

    func statMetrics(for c: Container) -> [StatMetric] {
        let p = palette
        return [
            StatMetric(label: "CPU", value: "\(c.cpuPercent.formatted())%", fraction: c.cpuFraction, tint: p.accent),
            StatMetric(label: "Memory", value: "\(c.memoryDisplay) / \(c.memoryLimitDisplay)", fraction: max(0.04, c.memoryFraction), tint: p.green),
        ]
    }

    func fetchLogs(_ id: String) async -> [LogLine] { (try? await runtime.logs(containerID: id)) ?? [] }
    func fetchEnv(_ id: String) async -> [EnvVar] { (try? await runtime.env(containerID: id)) ?? [] }
    func sampleCPU(_ id: String) async -> Double? { await runtime.sampleCPU(containerID: id) }
    func streamLogs(_ id: String) -> AsyncStream<LogLine> { runtime.streamLogs(containerID: id) }

    func inspect(_ image: DockerImage) {
        inspectedImage = image
        activeSheet = .inspectImage
    }

    func inspect(_ network: DoryNetwork) {
        inspectedNetwork = network
        activeSheet = .inspectNetwork
    }

    func fetchImageDetail(_ image: DockerImage) async -> ImageDetail {
        if let detail = await runtime.inspectImage(id: image.id) { return detail }
        let reference = "\(image.repository):\(image.tag)"
        return ImageDetail(
            reference: reference, id: image.imageID, tags: [reference], digest: nil,
            created: image.created, architecture: "—", os: "—", size: image.size,
            entrypoint: "—", command: "—", workingDir: "/", exposedPorts: [], env: [], labels: []
        )
    }

    func fetchNetworkDetail(_ network: DoryNetwork) async -> NetworkDetail {
        if let detail = await runtime.inspectNetwork(name: network.name) { return detail }
        return NetworkDetail(
            name: network.name, id: "—", driver: network.driver, scope: network.scope,
            subnet: network.subnet, gateway: "—", isInternal: false, attachable: false,
            options: [], containers: []
        )
    }

    func toggle(_ container: Container) {
        guard let idx = containers.firstIndex(where: { $0.id == container.id }) else { return }
        let wasRunning = container.status == .running
        var c = containers[idx]
        if wasRunning {
            c.status = .stopped
            c.cpuPercent = 0
            c.memoryDisplay = "0 MB"
            c.memoryFraction = 0
            c.memoryBytes = 0
            c.uptime = "—"
        } else {
            c.status = .running
            c.cpuPercent = runtimeKind == .mock ? 1.2 : 0
            c.memoryDisplay = c.memoryLimitDisplay == "2 GB" ? "128 MB" : "96 MB"
            c.memoryFraction = 0.08
            c.memoryBytes = c.memoryLimitDisplay == "2 GB" ? 134_217_728 : 100_663_296
            c.uptime = "just now"
        }
        containers[idx] = c
        let id = container.id
        Task {
            do {
                if wasRunning { try await runtime.stop(containerID: id) }
                else { try await runtime.start(containerID: id) }
            } catch {
                actionError = "Couldn't \(wasRunning ? "stop" : "start") \(container.name): \(error.localizedDescription)"
            }
            if runtimeKind != .mock { await reload() }
        }
    }

    func restart(_ container: Container) {
        let id = container.id
        perform("Couldn't restart \(container.name)") { try await self.runtime.restart(containerID: id) }
    }

    func remove(_ container: Container) {
        let id = container.id
        containers.removeAll { $0.id == id }
        if selectedContainerID == id { selectedContainerID = nil }
        perform("Couldn't remove \(container.name)") { try await self.runtime.remove(containerID: id) }
    }

    private func perform(_ errorPrefix: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { actionError = "\(errorPrefix): \(error.localizedDescription)" }
            if runtimeKind != .mock { await reload() }
        }
    }

    func removeImage(_ image: DockerImage) {
        let ref = image.id
        images.removeAll { $0.id == image.id }
        perform("Couldn't remove image") { try await self.runtime.removeImage(id: ref) }
    }

    func pruneImages() {
        perform("Prune failed") { try await self.runtime.pruneImages() }
    }

    func deleteVolume(_ volume: Volume) {
        let name = volume.name
        volumes.removeAll { $0.id == volume.id }
        perform("Couldn't delete volume") { try await self.runtime.removeVolume(name: name) }
    }

    func pruneVolumes() {
        perform("Prune failed") { try await self.runtime.pruneVolumes() }
    }

    func createVolume(name: String) async -> String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "Enter a volume name" }
        do { try await runtime.createVolume(name: name); await reload(); return nil }
        catch { return "Could not create volume: \(error.localizedDescription)" }
    }

    func deleteNetwork(_ network: DoryNetwork) {
        let name = network.name
        networks.removeAll { $0.id == network.id }
        perform("Couldn't delete network") { try await self.runtime.removeNetwork(name: name) }
    }

    func pruneNetworks() {
        perform("Prune failed") { try await self.runtime.pruneNetworks() }
    }

    func createNetwork(name: String) async -> String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "Enter a network name" }
        do { try await runtime.createNetwork(name: name, labels: [:]); await reload(); return nil }
        catch { return "Could not create network: \(error.localizedDescription)" }
    }

    var composeBusy = false
    var composeStatus = ""

    func openComposeFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.message = "Choose a Compose file (compose.yaml or docker-compose.yml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await composeUp(fileURL: url) }
    }

    func composeUp(fileURL: URL) async {
        guard runtimeKind.isDockerCompatible else { actionError = "Compose needs Dory's shared VM or a Docker engine"; return }
        composeBusy = true
        composeStatus = "Reading \(fileURL.lastPathComponent)…"
        defer { composeBusy = false }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            actionError = "Could not read \(fileURL.lastPathComponent)"; composeStatus = ""; return
        }
        let project: ComposeProject
        do {
            project = try ComposeParser.parse(text, projectName: Self.composeName(for: fileURL))
        } catch {
            actionError = "Invalid Compose file: \(error)"; composeStatus = ""; return
        }
        guard !project.services.isEmpty else { actionError = "No services found in the Compose file"; composeStatus = ""; return }
        do {
            let engine = ComposeEngine(runtime: runtime)
            _ = try await engine.up(project, pullImages: true) { progress in
                self.composeStatus = "\(progress.service): \(progress.message)"
            }
            composeStatus = "\(project.name): \(project.services.count) services up"
            await reload()
            section = .compose
        } catch {
            actionError = "Compose up failed: \(error)"; composeStatus = ""
        }
    }

    func composeDown(_ name: String) async {
        composeBusy = true
        composeStatus = "Stopping \(name)…"
        defer { composeBusy = false }
        let engine = ComposeEngine(runtime: runtime)
        try? await engine.down(ComposeProject(name: name, services: [], networks: [], volumes: []))
        await reload()
        composeStatus = ""
    }

    private static func composeName(for url: URL) -> String {
        let dir = url.deletingLastPathComponent().lastPathComponent
        let raw = dir.isEmpty ? "compose" : dir
        let filtered = String(raw.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return filtered.isEmpty ? "compose" : filtered
    }

    func buildImage(contextDir: URL, tag: String) -> AsyncStream<String> {
        AsyncStream { cont in
            Task { [weak self] in
                guard let self else { cont.finish(); return }
                guard self.runtimeKind.isDockerCompatible else {
                    cont.yield("Image build needs Dory's shared VM or a Docker engine"); cont.finish(); return
                }
                cont.yield("Packaging build context…")
                let tar = await Task.detached { AppStore.tarDirectory(contextDir) }.value
                guard let tar else { cont.yield("Could not read build context at \(contextDir.path)"); cont.finish(); return }
                let q = tag.isEmpty ? "" : "t=" + (tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag)
                var buffer = Data()
                for await chunk in self.runtime.build(contextTar: tar, query: q) {
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<nl])
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let text = AppStore.parseBuildLine(line) { cont.yield(text) }
                    }
                }
                if !buffer.isEmpty, let text = AppStore.parseBuildLine(buffer) { cont.yield(text) }
                await self.reload()
                cont.finish()
            }
        }
    }

    func applyKubernetesYAML(_ yaml: String) async -> String? {
        guard runtimeKind == .sharedVM else { return "Enable Kubernetes on Dory's shared VM first" }
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Paste or open a YAML manifest" }
        guard let kubectl = KubeServiceProxy.kubectl() else { return "kubectl not found — install it (brew install kubectl) to apply manifests" }
        let kubeconfig = NSHomeDirectory() + "/.kube/dory-config"
        let result: String? = await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: kubectl)
            proc.arguments = ["--kubeconfig", kubeconfig, "apply", "-f", "-"]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
            do { try proc.run() } catch { return "Could not run kubectl: \(error.localizedDescription)" }

            // Drain stdout/stderr concurrently with the stdin write: otherwise kubectl can block
            // writing output while we block writing the manifest (pipe deadlock). The throwing
            // write(contentsOf:) surfaces a broken pipe as a catchable error rather than the
            // uncatchable NSException the legacy write(_:) raises (which SIGPIPE ignore can't stop).
            let outHandle = stdout.fileHandleForReading
            let errHandle = stderr.fileHandleForReading
            nonisolated(unsafe) var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { _ = outHandle.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData = errHandle.readDataToEndOfFile(); group.leave() }
            do { try stdin.fileHandleForWriting.write(contentsOf: Data(yaml.utf8)) } catch {}
            try? stdin.fileHandleForWriting.close()
            group.wait()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 { return nil }
            let msg = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "kubectl apply failed" : msg
        }.value
        if result == nil { await reload() }
        return result
    }

    func registryLogin(registry: String, username: String, password: String) async -> String? {
        guard runtimeKind.isDockerCompatible else { return "Registry login needs a Docker engine or Dory's shared VM" }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return "Enter a username and password" }
        do { try await runtime.login(registry: registry, username: username, password: password); return nil }
        catch { return error.localizedDescription }
    }

    nonisolated static func tarDirectory(_ dir: URL) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-cf", "-", "-C", dir.path, "."]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }

    nonisolated static func parseBuildLine(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["stream"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let e = obj["errorDetail"] as? [String: Any], let m = e["message"] as? String { return "ERROR: \(m)" }
            if let e = obj["error"] as? String { return "ERROR: \(e)" }
            if let aux = obj["aux"] as? [String: Any], let id = aux["ID"] as? String { return "Built \(id)" }
            return nil
        }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    var migrationStatus = ""

    var migrationBusy = false

    var migrationInventory: MigrationInventory?

    /// Reads the host Docker/OrbStack engine (if any) without modifying it, to power the pre-flight
    /// "here's what will move, nothing will be deleted" screen.
    func loadMigrationPreflight() async {
        guard let source = await DockerEngineRuntime.detect() else {
            migrationInventory = nil
            return
        }
        migrationInventory = await MigrationAssistant.preflight(from: source)
    }

    /// Imports an existing Docker Desktop / OrbStack engine's images + containers into Dory's own
    /// shared VM — the "switch to Dory" flow. The target is Dory's standalone engine, so afterwards
    /// the source can be uninstalled.
    func importFromDocker() async {
        guard runtimeKind == .sharedVM else { migrationStatus = "Switch to Dory's shared VM first, then import"; return }
        guard !migrationBusy else { return }
        guard let source = await DockerEngineRuntime.detect() else {
            migrationStatus = "No Docker/OrbStack engine found to import from"; return
        }
        migrationBusy = true
        defer { migrationBusy = false }
        let target = runtime
        migrationStatus = "Starting import…"
        let summary = await MigrationAssistant.migrate(from: source, to: target) { message in
            Task { @MainActor in self.migrationStatus = message }
        }
        migrationStatus = "Imported \(summary.imagesPulled.count) images, \(summary.containersMigrated.count) containers"
        await reload()
    }

    func presentPrimary(for section: AppSection) {
        switch section {
        case .containers: activeSheet = .newContainer
        case .images: activeSheet = .pullImage
        case .volumes: activeSheet = .newVolume
        case .networks: activeSheet = .newNetwork
        case .compose: openComposeFile()
        default: break
        }
    }

    func createContainer(name: String, image: String, ports: [String], env: [String: String], volumes: [String] = []) async -> String? {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return "Image is required" }
        do {
            try await runtime.pull(image: trimmedImage)
            let finalName = name.isEmpty ? Self.defaultName(for: trimmedImage) : name
            let spec = ContainerSpec(name: finalName, image: trimmedImage, environment: env, ports: ports, volumes: volumes)
            let id = try await runtime.create(spec)
            try await runtime.start(containerID: id)
            await reload()
            selectedContainerID = id
            return nil
        } catch { return "\(error)" }
    }

    func pullImage(_ reference: String) async -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Image reference is required" }
        do { try await runtime.pull(image: trimmed); await reload(); return nil }
        catch { return "\(error)" }
    }

    private static func defaultName(for image: String) -> String {
        let base = image.split(separator: "/").last.map(String.init) ?? image
        let name = base.split(separator: ":").first.map(String.init) ?? base
        let suffix = UInt(bitPattern: image.hashValue) % 10000
        return "\(name)-\(suffix)"
    }

    func toggleTheme() {
        appearance = appearance == .dark ? .light : .dark
    }

    @ObservationIgnored private let machineProvider = MachineProvider()
    var machineBusy = false

    func loadMachines() async {
        guard runtimeKind != .mock, machineProvider.isAvailable else { return }
        machines = await machineProvider.list()
    }

    var browsingVolume: String?
    var volumeBrowsePath = ""
    var volumeEntries: [VolumeEntry] = []
    var volumeFilePreview: String?
    var volumeBrowseBusy = false

    func openVolumeBrowser(_ volume: String) {
        guard runtimeKind != .appleContainer else {
            actionError = "Volume file browsing needs Dory's shared VM — switch engines in Settings → Docker Engine."
            return
        }
        browsingVolume = volume
        volumeBrowsePath = ""
        volumeEntries = []
        volumeFilePreview = nil
        activeSheet = .volumeBrowser
        Task { await refreshVolumeBrowser() }
    }

    func enterVolumePath(_ entry: VolumeEntry) async {
        let next = volumeBrowsePath.isEmpty ? entry.name : "\(volumeBrowsePath)/\(entry.name)"
        if entry.isDirectory {
            volumeBrowsePath = next
            volumeFilePreview = nil
            await refreshVolumeBrowser()
        } else {
            guard let volume = browsingVolume else { return }
            volumeBrowseBusy = true
            volumeFilePreview = await VolumeBrowser(runtime: runtime).read(volume: volume, path: next) ?? "(binary or empty file)"
            volumeBrowseBusy = false
        }
    }

    func volumeBrowseUp() async {
        guard !volumeBrowsePath.isEmpty else { return }
        var components = volumeBrowsePath.split(separator: "/").map(String.init)
        components.removeLast()
        volumeBrowsePath = components.joined(separator: "/")
        volumeFilePreview = nil
        await refreshVolumeBrowser()
    }

    private func refreshVolumeBrowser() async {
        guard let volume = browsingVolume else { return }
        volumeBrowseBusy = true
        volumeEntries = await VolumeBrowser(runtime: runtime).list(volume: volume, path: volumeBrowsePath)
        volumeBrowseBusy = false
    }

    func toggleMachine(_ machine: Machine) {
        guard let idx = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        let wasRunning = machines[idx].status == .running
        machines[idx].status = wasRunning ? .stopped : .running
        let name = machine.name
        let provider = machineProvider
        Task {
            if wasRunning { _ = await provider.stop(name: name) } else { _ = await provider.start(name: name) }
            await loadMachines()
        }
    }

    func createMachine(image: String, name: String) async -> String? {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty, !trimmedName.isEmpty else { return "Image and name are required" }
        machineBusy = true
        defer { machineBusy = false }
        do { try await machineProvider.create(image: trimmedImage, name: trimmedName); await loadMachines(); return nil }
        catch { return "\(error)" }
    }

    func deleteMachine(_ machine: Machine) {
        let name = machine.name
        let provider = machineProvider
        machines.removeAll { $0.name == name }
        Task { await provider.delete(name: name); await loadMachines() }
    }

    func openMachineTerminal(_ machine: Machine) {
        guard let binary = SharedVMProvisioner.containerBinary() else { return }
        TerminalLauncher.openMachineShell(binary: binary, machine: machine.name)
    }

    func openContainerTerminal(_ container: Container) {
        TerminalLauncher.openContainerShell(socketPath: shimSocketPath, containerID: container.id)
    }
}
