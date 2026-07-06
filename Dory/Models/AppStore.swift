import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum LoadState: Sendable { case connecting, ready, engineOff }

enum ContainerFilter: String, CaseIterable, Sendable {
    case running, all, stopped
    var label: String {
        switch self {
        case .running: "Running"
        case .all: "All"
        case .stopped: "Stopped"
        }
    }
}

struct ContainerGroup: Identifiable, Sendable {
    let id: String
    let project: String?
    let containers: [Container]
}

@Observable
@MainActor
final class AppStore {
    var appearance: DoryAppearance = .dark
    var section: AppSection = .containers {
        didSet { if oldValue != section { filter = "" } }
    }
    var selectedContainerID: String? = nil
    var detailTab: DetailTab = .overview
    var settingsTab: SettingsTab = .general
    var menuOpen = false
    var onboarding = false
    var isConnecting = false
    var filter = ""
    var filterFocusToken = 0
    var imagesSort: TableSort?
    var volumesSort: TableSort?
    var networksSort: TableSort?
    var activeSheet: AppSheet?
    var actionError: String?
    var inspectedImage: DockerImage?
    var inspectedNetwork: DoryNetwork?

    var launchAtLogin = false
    var showMenuBarIcon = true
    var autoUpdate = false
    var routeDockerCLI = true
    var machineEnvAllowList: [String] = MachineEnvImport.defaultNames
    var openLoginsOnMac = true
    var dockerHostConflict: DockerHostConflict.Conflict?
    var dockerHostCleaned = false
    var dockerHostConflictDismissed = false
    var containerDetailWidth: Double = 372
    var containerScope: ContainerScope =
        ContainerScope(rawValue: UserDefaults.standard.string(forKey: "dory.containerScope") ?? "") ?? .all
    {
        didSet { UserDefaults.standard.set(containerScope.rawValue, forKey: Self.containerScopeKey) }
    }

    var containers: [Container] = []
    var images: [DockerImage] = []
    var volumes: [Volume] = []
    var networks: [DoryNetwork] = []
    var pods: [Pod] = []
    var machines: [Machine] = []
    var engineRunning = false
    var engineVersion = "1.4.0"

    var loadState: LoadState = .connecting
    var launchSplashComplete = false
    @ObservationIgnored private(set) var isSnapshotMode = false
    var containerFilter: ContainerFilter =
        ContainerFilter(rawValue: UserDefaults.standard.string(forKey: "containerFilter") ?? "") ?? .running
    {
        didSet { UserDefaults.standard.set(containerFilter.rawValue, forKey: "containerFilter") }
    }

    var healthSnapshot: HealthSnapshot?
    var healthLoading = false
    var healthActiveLoading = false
    var healthActionInFlight = false
    var healthActionError: String?
    @ObservationIgnored private var healthLoadToken = 0

    var kubernetesReachable = false
    var kubernetesInfo = "Cluster not running"
    var kubernetesVersionTag: String = KubeVersionCatalog.latest.tag
    private let kubernetes = KubernetesProvider()

    private let kubeClient = KubeClient()
    var kubeNamespace = "All Namespaces"
    var kubeResource: KubeResourceKind = .pods
    var kubeNamespaces: [String] = []
    var deployments: [KubeDeploymentRow] = []
    var kubeServices: [KubeServiceRow] = []
    var configMaps: [KubeConfigMapRow] = []
    var secrets: [KubeSecretRow] = []
    var ingresses: [KubeIngressRow] = []
    var selectedPodID: String? = nil
    var selectedDeploymentID: String? = nil
    var selectedConfigMap: KubeConfigMapRow?
    var selectedSecret: KubeSecretRow?
    var selectedIngress: KubeIngressRow?

    private var namespaceFilter: String? { kubeNamespace == "All Namespaces" ? nil : kubeNamespace }
    var kubeconfigHint: String { KubeContextHint.snippet(kubeconfigPath: KubernetesProvisioner.kubeconfigPath) }
    func selectedPod() -> Pod? { pods.first { $0.id == selectedPodID } }
    func selectedDeployment() -> KubeDeploymentRow? { deployments.first { $0.id == selectedDeploymentID } }

    private var runtime: any ContainerRuntime
    var runtimeKind: RuntimeKind { runtime.kind }

    init(runtime: (any ContainerRuntime)? = nil) {
        let env = ProcessInfo.processInfo.environment
        let realLaunch = env["DORY_SECTION"] == nil && env["DORY_APPEARANCE"] == nil
            && env["XCTestConfigurationFilePath"] == nil && env["DORY_UI_TEST"] != "1"
        // Every launch starts disconnected (empty, engine-off) until a real engine connects: the app
        // ships no demo data. Tests inject their own fixture runtime through the parameter.
        self.runtime = runtime ?? DisconnectedRuntime()
        let table = domainTable
        reverseProxy = DoryReverseProxy { host in table.backend(for: host) }
        if realLaunch {
            if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let saved = DoryAppearance(rawValue: raw) {
                appearance = saved
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if let v = UserDefaults.standard.object(forKey: Self.menuBarIconKey) as? Bool { showMenuBarIcon = v }
            if isAgentMode { showMenuBarIcon = true }
            if let v = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool { autoUpdate = v }
            if let v = UserDefaults.standard.object(forKey: Self.routeDockerKey) as? Bool { routeDockerCLI = v }
            if let raw = UserDefaults.standard.string(forKey: Self.machineEnvAllowListKey) {
                machineEnvAllowList = MachineEnvImport.parse(raw)
            }
            if let v = UserDefaults.standard.object(forKey: Self.openLoginsOnMacKey) as? Bool { openLoginsOnMac = v }
            if let saved = UserDefaults.standard.string(forKey: Self.kubernetesVersionKey) {
                kubernetesVersionTag = KubeVersionCatalog.version(forTag: saved).tag
            }
            if let v = UserDefaults.standard.object(forKey: Self.dnsPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { dnsPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.httpProxyPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { httpProxyPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.httpsProxyPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { httpsProxyPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.domainsEnabledKey) as? Bool { domainsEnabled = v }
            if let v = UserDefaults.standard.object(forKey: SharedVMProvisioner.Config.rosettaX86Key) as? Bool { rosettaX86Enabled = v }
            if let raw = UserDefaults.standard.string(forKey: Self.enginePreferenceKey),
               let saved = EnginePreference(rawValue: raw) { enginePreference = saved }
            if let socket = UserDefaults.standard.string(forKey: Self.customEngineSocketKey) { customEngineSocket = socket }
            if let v = UserDefaults.standard.object(forKey: SharedVMProvisioner.Config.gpuVenusKey) as? Bool { gpuVenusEnabled = v }
            dockerHostCleaned = DockerHostConflict.hasCleaned
            dockerHostConflictDismissed = UserDefaults.standard.bool(forKey: Self.dockerHostDismissedKey)
            if let width = UserDefaults.standard.object(forKey: Self.containerDetailWidthKey) as? Double, width >= 320 {
                containerDetailWidth = width
            }
        }
        if let raw = env["DORY_SECTION"], let parsed = AppSection(rawValue: raw) { section = parsed }
        if let raw = env["DORY_FILTER"] { filter = raw }
        if let raw = env["DORY_SORT"] {
            let parts = raw.split(separator: ":")
            if parts.count >= 2 {
                let sort = TableSort(key: String(parts[1]), ascending: parts.count < 3 || parts[2] != "desc")
                switch parts[0] {
                case "images": imagesSort = sort
                case "volumes": volumesSort = sort
                case "networks": networksSort = sort
                default: break
                }
            }
        }
        if let raw = env["DORY_SETTINGS_TAB"], let parsed = SettingsTab(rawValue: raw) { settingsTab = parsed }
        if let raw = env["DORY_DETAIL_TAB"], let parsed = DetailTab(rawValue: raw) { detailTab = parsed }
        if env["DORY_APPEARANCE"] == "light" { appearance = .light }
        if let raw = env["DORY_SHEET"], let parsed = AppSheet(rawValue: raw) {
            activeSheet = parsed
            if parsed == .inspectImage { inspectedImage = images.first }
            if parsed == .inspectNetwork { inspectedNetwork = networks.first(where: { $0.containerCount > 0 }) ?? networks.first }
        }
        let snapshotMode = env["DORY_SECTION"] != nil || env["DORY_SHEET"] != nil || env["DORY_DETAIL_TAB"] != nil
        let testMode = env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil || env["DORY_UI_TEST"] == "1"
        isSnapshotMode = snapshotMode
        if snapshotMode || testMode { launchSplashComplete = true }
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
    static let routeDockerKey = "dory.routeDockerCLI"
    static let machineEnvAllowListKey = "dory.machineEnvAllowList"
    static let openLoginsOnMacKey = "dory.openLoginsOnMac"
    static let dockerHostDismissedKey = "dory.dockerHostDismissed"
    static let containerDetailWidthKey = "dory.containerDetailWidth"
    static let containerScopeKey = "dory.containerScope"
    static let kubernetesVersionKey = "dory.kubernetesVersion"
    nonisolated static let dockerCompatibleEngineHint = "Start Dory's shared VM in Settings > Docker Engine, or run a local Docker-compatible engine such as Docker Desktop, Colima, Rancher Desktop, Podman, or OrbStack."
    nonisolated static var dockerCompatibleFallbackHint: String {
        if MacHostPlatform.current().isAppleSilicon {
            "Dory can still run on this Mac by proxying a local Docker-compatible engine such as Docker Desktop, Colima, Rancher Desktop, Podman, or OrbStack."
        } else {
            "Dory's built-in Intel engine needs bundled engine assets and Hypervisor.framework support. This install can still proxy a local Docker-compatible engine such as Colima, Docker Desktop, Rancher Desktop, Podman, or OrbStack."
        }
    }

    nonisolated static func dockerCompatibleEngineRequired(_ feature: String) -> String {
        "\(feature) needs Dory's shared VM or a Docker-compatible engine. \(dockerCompatibleEngineHint)"
    }

    nonisolated static func sharedVMUnavailableStatus(_ support: RuntimeSupport) -> String {
        let reason = support.reason.isEmpty ? "host requirements are not met" : support.reason
        return "Dory's shared VM is unavailable (\(reason)). \(dockerCompatibleFallbackHint)"
    }

    nonisolated static func engineFailureStatus() -> String {
        if let reason = SharedVMProvisioner.engineLogTail() {
            return "Dory's engine could not start: \(reason)"
        }
        return "Dory's engine could not start — see ~/.dory/engine.log"
    }

    func setContainerDetailWidth(_ width: Double) {
        let clamped = min(max(width, 320), 1400)
        containerDetailWidth = clamped
        UserDefaults.standard.set(clamped, forKey: Self.containerDetailWidthKey)
    }

    func setContainerScope(_ scope: ContainerScope) {
        containerScope = scope
    }

    func setAutoUpdate(_ on: Bool) {
        autoUpdate = on
        UserDefaults.standard.set(on, forKey: Self.autoUpdateKey)
        DoryUpdater.shared.automaticallyChecks = on
    }

    func setKubernetesVersion(_ version: KubeVersion) {
        kubernetesVersionTag = version.tag
        UserDefaults.standard.set(version.tag, forKey: Self.kubernetesVersionKey)
    }

    func setRouteDockerCLI(_ on: Bool) {
        routeDockerCLI = on
        UserDefaults.standard.set(on, forKey: Self.routeDockerKey)
        Task {
            if on, runtimeKind != .mock {
                await DockerContext.activate(socketPath: shimSocketPath)
                HostDockerCLI.install()
                await detectDockerHostConflict()
            } else if !on {
                DockerContext.deactivateSync()
                HostDockerCLI.remove()
                dockerHostConflict = nil
            }
        }
    }

    func setOpenLoginsOnMac(_ on: Bool) {
        openLoginsOnMac = on
        UserDefaults.standard.set(on, forKey: Self.openLoginsOnMacKey)
        hostBridge.setEnabled(on)
    }

    private var isAutomationContext: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || env["DORY_UI_TEST"] == "1"
            || env["DORY_SECTION"] != nil || env["DORY_SHEET"] != nil || env["DORY_DETAIL_TAB"] != nil
            || env["DORY_APPEARANCE"] != nil || env["DORY_ONBOARDING"] != nil
    }

    func detectDockerHostConflict() async {
        guard routeDockerCLI, runtimeKind != .mock, !isAutomationContext else {
            dockerHostConflict = nil
            return
        }
        dockerHostConflict = await DockerHostConflict.detect(dorySocketPath: shimSocketPath)
    }

    func resolveDockerHostConflict() async {
        guard let conflict = dockerHostConflict, conflict.isFixable else { return }
        if DockerHostConflict.resolve(conflict) {
            dockerHostCleaned = true
            await detectDockerHostConflict()
        } else {
            actionError = "Couldn't update your shell profile — remove the DOCKER_HOST line manually."
        }
    }

    func undoDockerHostCleanup() {
        DockerHostConflict.undo()
        dockerHostCleaned = false
        Task { await detectDockerHostConflict() }
    }

    func dismissDockerHostConflict() {
        dockerHostConflictDismissed = true
        UserDefaults.standard.set(true, forKey: Self.dockerHostDismissedKey)
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
        showMenuBarIcon = isAgentMode ? true : on
        UserDefaults.standard.set(showMenuBarIcon, forKey: Self.menuBarIconKey)
    }

    func setMachineEnvAllowList(_ names: [String]) {
        let normalized = MachineEnvImport.normalize(names)
        machineEnvAllowList = normalized
        UserDefaults.standard.set(MachineEnvImport.serialize(normalized), forKey: Self.machineEnvAllowListKey)
    }

    func completeOnboarding() {
        onboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
    }

    var palette: DoryPalette { appearance.palette }

    var isAgentMode: Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool { return value }
        if let number = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber { return number.boolValue }
        if let string = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? String { return string == "1" || string.lowercased() == "true" || string.lowercased() == "yes" }
        return false
    }

    var shouldOpenWindowOnLaunch: Bool { !isAgentMode || onboarding || isSnapshotMode }

    private var shimServer: ShimHTTPServer?
    var shimSocketPath: String { DockerShim.defaultSocketPath }
    private(set) var shimRunning = false
    /// Opt-in: run the Virtualization.framework engine with Rosetta so heavy amd64 images (SQL Server)
    /// run reliably. Trades away dory-hv's memory advantage while on, so it is a manual toggle (#3).
    var rosettaX86Enabled = false
    /// Opt-in experimental GPU acceleration (virtio-gpu/Venus → virglrenderer → MoltenVK → Metal) for
    /// Vulkan and AI compute inside containers. Applied on the next engine start; falls back to
    /// headless when the host Venus runtime is absent, so the Settings toggle gates on availability.
    var gpuVenusEnabled = false
    let gpuRuntimeAvailable = SharedVMProvisioner.venusRuntimeAvailable()

    /// Which backend the app connects to: Dory's bundled engine (default), an auto-detected existing
    /// engine (Colima, Docker Desktop, …), or a custom socket. Persisted; connectBackend honors it.
    var enginePreference: EnginePreference = .dory
    var customEngineSocket = ""
    static let enginePreferenceKey = "dory.enginePreference"
    static let customEngineSocketKey = "dory.customEngineSocket"

    @ObservationIgnored private(set) var backendStartRequested = false
    @ObservationIgnored var windowOpenRequested = false

    func startBackendIfNeeded() {
        guard !backendStartRequested else { return }
        backendStartRequested = true
        Task { await connectBackend() }
    }

    private func adoptSharedRuntime(_ shared: any ContainerRuntime) async {
        runtime = shared
        sharedVMStatus = "Running on Dory's engine"
        await reload()
    }

    /// Connects according to the persisted engine preference — Colima-style: Dory's bundled engine,
    /// an auto-detected existing engine, or a custom socket.
    private func connectPreferredBackend() async {
        switch enginePreference {
        case .external:
            if let docker = await DockerEngineRuntime.detect() {
                runtime = docker
                sharedVMStatus = "Using \(Self.externalEngineLabel(docker.socketPath))"
                await reload()
            } else {
                sharedVMStatus = "No running Docker-compatible engine found. Start it, or switch back to Dory's engine."
                loadState = .engineOff
            }
        case .custom:
            let path = customEngineSocket.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                sharedVMStatus = "Set a socket path to use a custom engine."
                loadState = .engineOff
                return
            }
            if let docker = await DockerEngineRuntime.detect(candidates: [path]) {
                runtime = docker
                sharedVMStatus = "Using custom engine at \(path)"
                await reload()
            } else {
                sharedVMStatus = "No Docker engine answered at \(path)."
                loadState = .engineOff
            }
        case .dory:
            // Dory's own engine is the default: a standalone, OrbStack-style daemon that ships
            // everything it needs. If the built-in engine cannot run on this host or install,
            // fall back to fronting an existing Docker-compatible socket.
            let support = refreshSharedVMSupport()
            if support.isSupported {
                sharedVMStatus = "Starting Dory's engine…"
                if let shared = await SharedVMProvisioner.runtime() {
                    await adoptSharedRuntime(shared)
                    return
                }
                sharedVMStatus = Self.engineFailureStatus()
            } else {
                sharedVMStatus = Self.sharedVMUnavailableStatus(support)
            }
            if let docker = await DockerEngineRuntime.detect() {
                runtime = docker; await reload()
            } else {
                loadState = .engineOff
            }
        }
    }

    nonisolated static func externalEngineLabel(_ socketPath: String) -> String {
        DockerEngineSocketDiscovery.engineLabel(for: socketPath, home: NSHomeDirectory())
    }

    /// Switches the backend (Dory / existing / custom socket), persists the choice, and reconnects.
    /// Leaving Dory's engine stops the VM so its memory returns to macOS.
    func setEnginePreference(_ preference: EnginePreference, customSocket: String? = nil) async {
        if let customSocket {
            customEngineSocket = customSocket
            UserDefaults.standard.set(customSocket, forKey: Self.customEngineSocketKey)
        }
        let changed = preference != enginePreference
        enginePreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.enginePreferenceKey)
        guard changed || preference == .custom, !isConnecting else { return }
        if preference != .dory {
            await SharedVMProvisioner.stopEngine()
            runtime = DisconnectedRuntime()
        }
        sharedVMStatus = "Switching engine…"
        await connectBackend()
    }

    func connectBackend() async {
        // Automation launches (UI tests, screenshot harnesses) never boot the real engine: they
        // exercise the app against the honest disconnected state unless they opt into a backend
        // with an explicit DORY_RUNTIME.
        if isAutomationContext, ProcessInfo.processInfo.environment["DORY_RUNTIME"] == nil {
            loadState = .engineOff
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        switch ProcessInfo.processInfo.environment["DORY_RUNTIME"] {
        case "docker", "docker-proxy":
            if let docker = await DockerEngineRuntime.detect() { runtime = docker; await reload() }
            else { loadState = .engineOff }
        case "shared":
            let support = refreshSharedVMSupport()
            guard support.isSupported else {
                sharedVMStatus = Self.sharedVMUnavailableStatus(support)
                loadState = .engineOff
                break
            }
            if let shared = await SharedVMProvisioner.runtime() {
                await adoptSharedRuntime(shared)
            }
            else {
                sharedVMStatus = Self.engineFailureStatus()
                loadState = .engineOff
            }
        default:
            await connectPreferredBackend()
        }
        // With no live engine there is nothing to proxy: don't stand up the shim or, worse, redirect
        // the user's `docker` CLI at a dead socket. Injected fixture runtimes still wire the shim so
        // shim tests can drive it.
        guard runtimeKind == .mock || loadState != .engineOff else { return }
        // Bring up the Docker-compatible socket before ancillary inventory work. Kubernetes and
        // machine discovery can involve external CLIs; they should never delay `docker` readiness.
        startShim()
        startPortForwarding()
        if routeDockerCLI && runtimeKind != .mock {
            await DockerContext.activate(socketPath: shimSocketPath)
            HostDockerCLI.install()
            await detectDockerHostConflict()
        }
        startAutoRefresh()
        Task { [weak self] in
            guard let self else { return }
            await self.loadKubernetes()
            self.loadMachines()
            self.offerLegacyMachineCleanup()
        }
    }

    var sharedVMStatus = ""
    var sharedVMSupport = SharedVMProvisioner.hostSupport()

    private func refreshSharedVMSupport() -> RuntimeSupport {
        let support = SharedVMProvisioner.hostSupport()
        sharedVMSupport = support
        return support
    }

    func retryEngine() async {
        guard !isConnecting else { return }
        await connectBackend()
    }

    /// Stops and re-provisions the shared engine so engine-level settings (GPU, Rosetta, memory) or a
    /// newly installed Venus runtime take effect. Running containers are recreated by the daemon on
    /// the fresh boot; the app itself never needs restarting.
    func restartEngine() async {
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = "Restarting the engine…"
        await SharedVMProvisioner.stopEngine()
        await connectBackend()
    }

    /// Toggles the opt-in Rosetta x86 engine and restarts the shared engine so the new mode takes
    /// effect. On → Virtualization.framework + Rosetta (heavy amd64 like SQL Server works, more
    /// memory). Off → dory-hv (the memory advantage). No-op unless the shared engine is active.
    func setRosettaX86(_ on: Bool) async {
        guard on != rosettaX86Enabled else { return }
        rosettaX86Enabled = on
        UserDefaults.standard.set(on, forKey: SharedVMProvisioner.Config.rosettaX86Key)
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = on ? "Switching to the Rosetta x86 engine…" : "Switching to Dory's engine…"
        await SharedVMProvisioner.stopEngine()
        await connectBackend()
    }

    /// Toggles experimental GPU acceleration (virtio-gpu/Venus) and restarts the shared engine so the
    /// virtio-gpu device is attached or removed at the next boot. No-op unless the shared engine is
    /// active; the engine falls back to headless if the host Venus runtime turns out to be missing.
    func setGPUVenus(_ on: Bool) async {
        guard on != gpuVenusEnabled else { return }
        gpuVenusEnabled = on
        UserDefaults.standard.set(on, forKey: SharedVMProvisioner.Config.gpuVenusKey)
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = on ? "Enabling GPU acceleration…" : "Disabling GPU acceleration…"
        await SharedVMProvisioner.stopEngine()
        await connectBackend()
    }

    /// Provisions (or reuses) Dory's own single shared Linux VM and switches the live engine to it,
    /// making Dory a standalone, OrbStack-style daemon that no longer depends on Docker/OrbStack.
    func useSharedVM() async {
        guard runtimeKind != .sharedVM else { return }
        let support = refreshSharedVMSupport()
        guard support.isSupported else {
            sharedVMStatus = Self.sharedVMUnavailableStatus(support)
            return
        }
        enginePreference = .dory
        UserDefaults.standard.set(EnginePreference.dory.rawValue, forKey: Self.enginePreferenceKey)
        sharedVMStatus = "Starting Dory's engine…"
        guard let shared = await SharedVMProvisioner.runtime() else {
            sharedVMStatus = "Dory's engine could not start — see ~/.dory/engine.log"
            return
        }
        runtime = shared
        await reload()
        restartShim()
        startPortForwarding()
        startAutoRefresh()
        sharedVMStatus = "Running on Dory's shared VM"
    }

    private func restartShim() {
        shimServer?.stop()
        shimServer = nil
        shimRunning = false
        startShim()
    }

    let domainSuffix = "dory.local"
    private let portForwarder = HostPortForwarder(targetHost: "127.0.0.1")
    @ObservationIgnored private lazy var hostBridge = HostBridgeWatcher(
        bridgeRoot: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge"),
        forwarder: portForwarder,
        enabled: openLoginsOnMac,
        open: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
    )
    @ObservationIgnored private lazy var credentialProxy = CredentialProxyManager(
        bridgeRoot: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge")
    )
    @ObservationIgnored private let usbAttachments = UsbAttachmentStore()
    @ObservationIgnored private var usbReplayedMachines: Set<String> = []
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
        // Dory's engine publishes container ports to the host through gvproxy, so published ports
        // are already reachable at 127.0.0.1. The app never binds them itself (that would race
        // gvproxy); it only points *.dory.local domains at those localhost ports.
        forwarder.updateTarget("127.0.0.1")
        portForwardingTask = Task { [weak self] in
            while !Task.isCancelled {
                let endpoints = await Self.containerEndpoints(runtime, suffix: suffix)
                table.replaceContainers(endpoints)
                if let self {
                    self.dns.replaceHostIPs(Self.machineDNSHosts(self.machines, suffix: suffix))
                }
                if FileManager.default.fileExists(atPath: KubernetesProvisioner.kubeconfigPath) {
                    self?.ensureKubeProxy()
                    table.replaceKube(await KubeServiceProxy.backends(suffix: suffix))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static let defaultDNSPort: UInt16 = 15353
    static let defaultHTTPProxyPort: UInt16 = 8080
    static let defaultHTTPSProxyPort: UInt16 = 8443
    static let dnsPortKey = "dory.dnsPort"
    static let httpProxyPortKey = "dory.httpProxyPort"
    static let httpsProxyPortKey = "dory.httpsProxyPort"
    static let domainsEnabledKey = "dory.domainsEnabled"
    // User-configurable: 8080 collides with common dev servers, and MDM-managed DNS can't be pointed
    // at Dory, so the whole *.dory.local feature is turn-off-able (GitHub #2).
    var dnsPort: UInt16 = AppStore.defaultDNSPort
    var httpProxyPort: UInt16 = AppStore.defaultHTTPProxyPort
    var httpsProxyPort: UInt16 = AppStore.defaultHTTPSProxyPort
    var domainsEnabled = true
    @ObservationIgnored private var tlsProxy: DoryTLSProxy?

    private func startLocalNetworking() {
        guard domainsEnabled else { return }
        guard !networkingStarted else { return }
        // DNS on a high port (mDNSResponder owns :53/:5353); the system resolver is pointed here via
        // an /etc/resolver entry with a `port` directive, so DNS needs no root.
        do {
            try dns.start(port: dnsPort)
            try reverseProxy.start(httpPort: httpProxyPort)
        } catch {
            actionError = "Local *.dory.local networking couldn't start (a port may be in use): \(error.localizedDescription)"
            return
        }
        networkingStarted = true
        for machine in machines where machine.status == .running { registerMachineBridge(machine.name) }
        startTLS()
        Task.detached { await SharedVMProvisioner.ensureEmulation() }
    }

    /// Applies changed networking settings (ports or the domains toggle): full teardown then restart
    /// so listeners rebind on the new ports and machine bridges are re-registered cleanly. Restarting
    /// through startPortForwarding cancels and re-drives the reconcile task, avoiding a double-register.
    func applyNetworkingSettings(dnsPort: UInt16? = nil, httpProxyPort: UInt16? = nil, httpsProxyPort: UInt16? = nil, domainsEnabled: Bool? = nil) {
        if let dnsPort { self.dnsPort = dnsPort; UserDefaults.standard.set(Int(dnsPort), forKey: Self.dnsPortKey) }
        if let httpProxyPort { self.httpProxyPort = httpProxyPort; UserDefaults.standard.set(Int(httpProxyPort), forKey: Self.httpProxyPortKey) }
        if let httpsProxyPort { self.httpsProxyPort = httpsProxyPort; UserDefaults.standard.set(Int(httpsProxyPort), forKey: Self.httpsProxyPortKey) }
        if let domainsEnabled { self.domainsEnabled = domainsEnabled; UserDefaults.standard.set(domainsEnabled, forKey: Self.domainsEnabledKey) }
        stopLocalNetworking()
        startPortForwarding()
    }

    private func startTLS() {
        let table = domainTable
        let suffix = domainSuffix
        let port = httpsProxyPort
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
            do {
                try proxy.start(port: port)
                self.tlsProxy = proxy
            } catch {
                self.actionError = "HTTPS for *.dory.local couldn't start (port \(port) may be in use): \(error.localizedDescription)"
            }
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
        dns.replaceHostIPs([:])
        dns.stop(); reverseProxy.stop(); tlsProxy?.stop(); tlsProxy = nil
        if let proxy = kubeProxy, proxy.isRunning { proxy.terminate() }
        kubeProxy = nil
        for machine in hostBridge.watchedMachines() { hostBridge.stopWatching(machine: machine) }
        credentialProxy.stopAll()
        networkingStarted = false
    }

    func registerMachineBridge(_ name: String) {
        try? FileManager.default.createDirectory(atPath: MachineService.bridgeHostDir(for: name), withIntermediateDirectories: true)
        hostBridge.startWatching(machine: name)
        credentialProxy.start(machine: name)
        replayRememberedUSB(machine: name)
    }

    func unregisterMachineBridge(_ name: String) {
        hostBridge.stopWatching(machine: name)
        credentialProxy.stop(machine: name)
        portForwarder.teardownLoopback(forMachine: name)
        usbReplayedMachines.remove(name)
    }

    private func replayRememberedUSB(machine: String) {
        guard !usbReplayedMachines.contains(machine) else { return }
        let commands = usbAttachments.reattachCommands(for: machine)
        usbReplayedMachines.insert(machine)
        guard !commands.isEmpty else { return }
        Task.detached(priority: .utility) {
            for arguments in commands {
                _ = await UsbDevicesView.runDory(arguments)
            }
        }
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

    nonisolated static func machineDNSHosts(_ machines: [Machine], suffix: String) -> [String: String] {
        var result: [String: String] = [:]
        for machine in machines where machine.status == .running {
            guard DoryDNS.ipv4Bytes(machine.ip) != nil else { continue }
            let host = DoryDNS.normalizeHost("\(machine.name).\(suffix)")
            result[host] = machine.ip
        }
        return result
    }

    nonisolated static func publicPorts(fromContainersJSON data: Data) -> Set<Int> {
        struct Entry: Decodable { let Ports: [PortItem]? }
        struct PortItem: Decodable { let PublicPort: Int? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Set(entries.flatMap { ($0.Ports ?? []).compactMap(\.PublicPort) })
    }

    nonisolated static func allPublishedPorts(_ runtime: any ContainerRuntime) async -> Set<Int> {
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/json", headers: [], body: Data()),
              response.isSuccess else { return [] }
        return publicPorts(fromContainersJSON: response.body)
    }

    func loadKubernetes() async {
        let status = await kubernetes.status()
        kubernetesReachable = status.reachable
        kubernetesInfo = status.info
        guard status.reachable else {
            pods = []; deployments = []; kubeServices = []; configMaps = []; secrets = []; ingresses = []; kubeNamespaces = []
            return
        }
        if case let .success(data) = await kubeClient.getJSON(kind: "namespaces", namespace: nil),
           let list = try? JSONDecoder().decode(KubeNamespaceList.self, from: data) {
            kubeNamespaces = KubeRowMapper.namespaces(list)
        }
        await loadKubeResource()
    }

    func loadKubeResource() async {
        guard kubernetesReachable else { return }
        let result = await kubeClient.getJSON(kind: kubeResource.apiKind, namespace: namespaceFilter)
        applyKubeResourceLoad(kind: kubeResource, result: result)
    }

    func applyKubeResourceLoad(kind: KubeResourceKind, result: Result<Data, KubeError>) {
        switch result {
        case .success(let data):
            applyKubeResourceData(kind: kind, data: data)
        case .failure(let error):
            clearKubeResource(kind)
            actionError = Self.kubeErrorText(error)
        }
    }

    private func applyKubeResourceData(kind: KubeResourceKind, data: Data) {
        let decoder = JSONDecoder()
        switch kind {
        case .pods:
            guard let list = try? decoder.decode(KubePodList.self, from: data) else { return decodeFailed(kind) }
            pods = KubeRowMapper.pods(list)
            if let selectedPodID, !pods.contains(where: { $0.id == selectedPodID }) { self.selectedPodID = nil }
            actionError = nil
        case .deployments:
            guard let list = try? decoder.decode(KubeDeploymentList.self, from: data) else { return decodeFailed(kind) }
            deployments = KubeRowMapper.deployments(list)
            if let selectedDeploymentID, !deployments.contains(where: { $0.id == selectedDeploymentID }) { self.selectedDeploymentID = nil }
            actionError = nil
        case .services:
            guard let list = try? decoder.decode(KubeServiceList.self, from: data) else { return decodeFailed(kind) }
            kubeServices = KubeRowMapper.services(list)
            actionError = nil
        case .configMaps:
            guard let list = try? decoder.decode(KubeConfigMapList.self, from: data) else { return decodeFailed(kind) }
            configMaps = KubeRowMapper.configMaps(list)
            if let selectedConfigMap, !configMaps.contains(where: { $0.id == selectedConfigMap.id }) { self.selectedConfigMap = nil }
            actionError = nil
        case .secrets:
            guard let list = try? decoder.decode(KubeSecretList.self, from: data) else { return decodeFailed(kind) }
            secrets = KubeRowMapper.secrets(list)
            if let selectedSecret, !secrets.contains(where: { $0.id == selectedSecret.id }) { self.selectedSecret = nil }
            actionError = nil
        case .ingresses:
            guard let list = try? decoder.decode(KubeIngressList.self, from: data) else { return decodeFailed(kind) }
            ingresses = KubeRowMapper.ingresses(list)
            if let selectedIngress, !ingresses.contains(where: { $0.id == selectedIngress.id }) { self.selectedIngress = nil }
            actionError = nil
        }
    }

    private func decodeFailed(_ kind: KubeResourceKind) {
        clearKubeResource(kind)
        actionError = Self.kubeErrorText(.decode)
    }

    private func clearKubeResource(_ kind: KubeResourceKind) {
        switch kind {
        case .pods:
            pods = []
            selectedPodID = nil
        case .deployments:
            deployments = []
            selectedDeploymentID = nil
        case .services:
            kubeServices = []
        case .configMaps:
            configMaps = []
            selectedConfigMap = nil
        case .secrets:
            secrets = []
            selectedSecret = nil
        case .ingresses:
            ingresses = []
            selectedIngress = nil
        }
    }

    func deletePod(_ pod: Pod) async {
        switch await kubeClient.delete(kind: "pod", name: pod.name, namespace: pod.namespace) {
        case .success: await loadKubeResource()
        case .failure(let error): actionError = Self.kubeErrorText(error)
        }
    }

    func scaleDeployment(_ deployment: KubeDeploymentRow, replicas: Int) async {
        switch await kubeClient.scale(deployment: deployment.name, namespace: deployment.namespace, replicas: replicas) {
        case .success: await loadKubeResource()
        case .failure(let error): actionError = Self.kubeErrorText(error)
        }
    }

    func restartDeployment(_ deployment: KubeDeploymentRow) async {
        switch await kubeClient.rolloutRestart(deployment: deployment.name, namespace: deployment.namespace) {
        case .success: await loadKubeResource()
        case .failure(let error): actionError = Self.kubeErrorText(error)
        }
    }

    func deleteResource(kind: KubeResourceKind, name: String, namespace: String) async {
        switch await kubeClient.delete(kind: kind.deleteKind, name: name, namespace: namespace) {
        case .success: await loadKubeResource()
        case .failure(let error): actionError = Self.kubeErrorText(error)
        }
    }

    func openService(_ service: KubeServiceRow) {
        guard !service.isHeadless else {
            actionError = "Headless services do not expose a cluster IP to open in the browser."
            return
        }
        let host = KubeServiceProxy.serviceHost(name: service.name, namespace: service.namespace, suffix: domainSuffix)
        let domainAvailable = domainTable.backend(for: host) != nil
        if !domainAvailable { ensureKubeProxy() }
        if let url = KubeServiceProxy.browserURL(
            name: service.name,
            namespace: service.namespace,
            ports: service.ports,
            suffix: domainSuffix,
            domainAvailable: domainAvailable
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func podLogs(_ pod: Pod) async -> [LogLine] {
        guard runtimeKind != .mock else { return [] }
        switch await kubeClient.logs(
            pod: pod.name,
            namespace: pod.namespace,
            container: pod.streamsAllContainerLogs ? nil : pod.primaryContainer,
            allContainers: pod.streamsAllContainerLogs
        ) {
        case .success(let data):
            return KubeLogParser.parse(String(data: data, encoding: .utf8) ?? "")
        case .failure(let error):
            actionError = Self.kubeErrorText(error)
            return []
        }
    }

    func streamPodLogs(_ pod: Pod) -> AsyncStream<LogLine> {
        guard runtimeKind != .mock else {
            return AsyncStream { $0.finish() }
        }
        guard let kubectl = kubeClient.kubectlPath else {
            return AsyncStream { $0.finish() }
        }
        let args = KubeClient.logsArgs(
            pod: pod.name,
            namespace: pod.namespace,
            container: pod.streamsAllContainerLogs ? nil : pod.primaryContainer,
            allContainers: pod.streamsAllContainerLogs,
            follow: true,
            since: "1s",
            kubeconfig: KubeClient.kubeconfig()
        )
        return AsyncStream { continuation in
            let buffer = KubeLogStreamBuffer()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kubectl)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                for line in buffer.append(chunk) { continuation.yield(line) }
            }
            process.terminationHandler = { _ in
                for line in buffer.flush() { continuation.yield(line) }
                continuation.finish()
            }
            do { try process.run() } catch { continuation.finish() }
            continuation.onTermination = { _ in
                reader.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
        }
    }

    static func kubeErrorText(_ error: KubeError) -> String {
        switch error {
        case .kubectlMissing: "kubectl not found — install it (brew install kubectl)."
        case .nonZero(_, let stderr): stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .decode: "Could not read the cluster response."
        }
    }

    var kubernetesBusy = false

    /// One-click Kubernetes: bootstraps k3s inside Dory's shared VM and wires the host kubeconfig.
    func enableKubernetes() async {
        guard runtimeKind == .sharedVM else { kubernetesInfo = "Kubernetes needs Dory's shared VM engine"; return }
        guard !kubernetesBusy else { return }
        kubernetesBusy = true
        defer { kubernetesBusy = false }
        do {
            try await KubernetesProvisioner.enable(
                runtime: runtime,
                image: KubeVersionCatalog.version(forTag: kubernetesVersionTag).image
            ) { message in
                Task { @MainActor in self.kubernetesInfo = message }
            }
        } catch {
            let message = "Kubernetes failed: \(error)"
            kubernetesInfo = message
            actionError = message
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

    func switchKubernetesVersion(_ version: KubeVersion) async {
        setKubernetesVersion(version)
        await disableKubernetes()
        await enableKubernetes()
    }

    func startShim() {
        guard shimServer == nil else { return }
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: DockerShim.defaultSocketPath) { request in await shim.handle(request) }
        do {
            try server.start()
            shimServer = server
            shimRunning = true
        } catch {
            shimRunning = false
            actionError = "Could not start Dory's Docker socket: \(error.localizedDescription)"
        }
    }

    func reload() async {
        guard let snap = try? await runtime.snapshot() else {
            if loadState != .engineOff { loadState = .engineOff }
            return
        }
        if containers != snap.containers { containers = snap.containers; syncMachineStats() }
        if images != snap.images { images = snap.images }
        if volumes != snap.volumes { volumes = snap.volumes }
        if networks != snap.networks { networks = snap.networks }
        if runtimeKind == .mock, pods != snap.pods { pods = snap.pods }
        if engineRunning != snap.engineRunning { engineRunning = snap.engineRunning }
        if engineVersion != snap.engineVersion { engineVersion = snap.engineVersion }
        if selectedContainerID == nil || !containers.contains(where: { $0.id == selectedContainerID }) {
            let first = containers.first?.id
            if selectedContainerID != first { selectedContainerID = first }
        }
        let liveIDs = Set(containers.map(\.id))
        for container in containers where container.isRunning {
            recordCPU(container.id, container.cpuPercent)
        }
        cpuHistory = cpuHistory.filter { liveIDs.contains($0.key) }
        let newState: LoadState = snap.engineRunning ? .ready : .engineOff
        if loadState != newState { loadState = newState }
    }

    private var refreshTask: Task<Void, Never>?
    private static let refreshInterval: Duration = .seconds(2)

    /// Polls the live engine so containers/images/etc. created outside the GUI (e.g. `docker run`
    /// from a terminal) appear on their own — the way Docker Desktop and OrbStack do. Idempotent:
    /// cancels any prior loop first, so it's safe to call on every (re)connect.
    func startAutoRefresh() {
        refreshTask?.cancel()
        guard runtimeKind != .mock, !isAutomationContext else { refreshTask = nil; return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                await self?.refreshIfIdle()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A background refresh that yields to anything the user is actively doing — never polls over an
    /// open sheet, an in-flight connect, onboarding, or the mock runtime.
    func refreshIfIdle() async {
        guard runtimeKind != .mock, !isConnecting, activeSheet == nil, !onboarding else { return }
        await reload()
        loadMachines()
        if runtimeKind == .sharedVM { await loadKubernetes() }
    }

    var selectedContainer: Container? {
        containers.first { $0.id == selectedContainerID } ?? containers.first
    }

    var runningCount: Int { containers.filter(\.isRunning).count }

    var pendingContainerIDs: Set<String> = []
    var cpuHistory: [String: [Double]] = [:]

    func recordCPU(_ id: String, _ value: Double) {
        var samples = cpuHistory[id] ?? []
        samples.append(value)
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        cpuHistory[id] = samples
    }

    func portURL(for container: Container, port: PublishedPort) -> URL {
        URL(string: "http://127.0.0.1:\(port.hostPort)") ?? URL(string: "http://127.0.0.1")!
    }

    func openPort(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var reclaimableImageBytes: Int64 {
        images.filter { !$0.isUsed }.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    var reclaimLabel: String? {
        let bytes = reclaimableImageBytes
        guard bytes > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Reclaim \(formatted)"
    }

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
        case .health: healthSubtitle
        case .settings: "Dory v\(AppInfo.version)"
        }
    }

    private var healthSubtitle: String {
        guard let snapshot = healthSnapshot else { return "Run diagnostics" }
        if snapshot.cliMissing { return "Diagnostics CLI unavailable" }
        if snapshot.failing > 0 {
            return "\(snapshot.failing) failing · \(snapshot.warning) warning"
        }
        if snapshot.warning > 0 {
            return "\(snapshot.warning) warning\(snapshot.warning == 1 ? "" : "s")"
        }
        return "All checks passing"
    }

    func loadHealth(active: Bool = false) async {
        if active {
            guard !healthActiveLoading else { return }
            healthActiveLoading = true
        } else {
            guard !healthLoading else { return }
            healthLoading = true
        }
        healthLoadToken &+= 1
        let token = healthLoadToken
        let snapshot = await HealthDiagnostics.load(active: active)
        // Only the most recently started load may publish; a slower passive run must not clobber a
        // fresher active snapshot (or vice versa).
        if token == healthLoadToken {
            healthSnapshot = snapshot
        }
        if active { healthActiveLoading = false } else { healthLoading = false }
    }

    func runHealthRepair() async {
        guard !healthActionInFlight else { return }
        healthActionInFlight = true
        healthActionError = nil
        let result = await HealthDiagnostics.runControl(["repair", "all", "--apply"])
        if !result.ok { healthActionError = result.output.isEmpty ? "Repair failed" : result.output }
        healthActionInFlight = false
        await loadHealth()
    }

    var canRestartEngineForHealth: Bool {
        (runtimeKind == .sharedVM || runtimeKind == .disconnected) && !isConnecting
    }

    func restartEngineForHealth() async {
        guard canRestartEngineForHealth else { return }
        healthActionInFlight = true
        healthActionError = nil
        await restartEngine()
        healthActionInFlight = false
        await loadHealth()
    }

    private func matchesSearch(_ c: Container) -> Bool {
        filter.isEmpty
            || c.name.localizedCaseInsensitiveContains(filter)
            || c.image.localizedCaseInsensitiveContains(filter)
            || (c.composeProject?.localizedCaseInsensitiveContains(filter) ?? false)
            || (c.composeService?.localizedCaseInsensitiveContains(filter) ?? false)
    }

    var filteredContainers: [Container] {
        containers.filter { c in
            let stateOK: Bool
            switch containerFilter {
            case .running: stateOK = c.isRunning
            case .stopped: stateOK = !c.isRunning
            case .all: stateOK = true
            }
            let scopeOK: Bool
            switch containerScope {
            case .all: scopeOK = true
            case .standalone: scopeOK = c.composeProject == nil
            case .compose: scopeOK = c.composeProject != nil
            }
            return stateOK && scopeOK && matchesSearch(c)
        }
    }

    func containers(inComposeProject name: String) -> [Container] {
        containers
            .filter { $0.composeProject == name }
            .sorted { lhs, rhs in
                (lhs.composeService ?? lhs.name).localizedCaseInsensitiveCompare(rhs.composeService ?? rhs.name) == .orderedAscending
            }
    }

    func composeRunningCount(_ name: String) -> Int {
        containers(inComposeProject: name).filter(\.isRunning).count
    }

    func startComposeProject(_ name: String) {
        for container in containers(inComposeProject: name) where !container.isRunning {
            toggle(container)
        }
    }

    func stopComposeProject(_ name: String) {
        for container in containers(inComposeProject: name) where container.isRunning {
            toggle(container)
        }
    }

    func restartComposeProject(_ name: String) {
        for container in containers(inComposeProject: name) where container.isRunning {
            restart(container)
        }
    }

    var groupedContainers: [ContainerGroup] {
        var order: [String] = []
        var byProject: [String: [Container]] = [:]
        var ungrouped: [Container] = []
        for c in filteredContainers {
            if let project = c.composeProject {
                if byProject[project] == nil { order.append(project) }
                byProject[project, default: []].append(c)
            } else {
                ungrouped.append(c)
            }
        }
        var groups = order.map { ContainerGroup(id: "proj:\($0)", project: $0, containers: byProject[$0] ?? []) }
        if !ungrouped.isEmpty { groups.append(ContainerGroup(id: "ungrouped", project: nil, containers: ungrouped)) }
        return groups
    }

    var filteredImages: [DockerImage] {
        var result = images
        if !filter.isEmpty {
            result = result.filter { $0.repository.localizedCaseInsensitiveContains(filter) || $0.tag.localizedCaseInsensitiveContains(filter) }
        }
        guard let s = imagesSort else { return result }
        let asc = result.sorted { a, b in
            switch s.key {
            case "size": return a.sizeBytes < b.sizeBytes
            case "created": return a.createdEpoch < b.createdEpoch
            case "used": return a.usedByCount < b.usedByCount
            default: return "\(a.repository):\(a.tag)".localizedCaseInsensitiveCompare("\(b.repository):\(b.tag)") == .orderedAscending
            }
        }
        return s.ascending ? asc : asc.reversed()
    }

    var filteredVolumes: [Volume] {
        var result = volumes
        if !filter.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        guard let s = volumesSort else { return result }
        let asc = result.sorted { a, b in
            switch s.key {
            case "driver": return a.driver.localizedCaseInsensitiveCompare(b.driver) == .orderedAscending
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return s.ascending ? asc : asc.reversed()
    }

    var filteredNetworks: [DoryNetwork] {
        var result = networks
        if !filter.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        guard let s = networksSort else { return result }
        let asc = result.sorted { a, b in
            switch s.key {
            case "driver": return a.driver.localizedCaseInsensitiveCompare(b.driver) == .orderedAscending
            case "scope": return a.scope.localizedCaseInsensitiveCompare(b.scope) == .orderedAscending
            case "containers": return a.containerCount < b.containerCount
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return s.ascending ? asc : asc.reversed()
    }

    func toggleSort(_ section: AppSection, _ key: String) {
        let next: (TableSort?) -> TableSort = { cur in
            cur?.key == key ? TableSort(key: key, ascending: !(cur?.ascending ?? true)) : TableSort(key: key, ascending: true)
        }
        switch section {
        case .images: imagesSort = next(imagesSort)
        case .volumes: volumesSort = next(volumesSort)
        case .networks: networksSort = next(networksSort)
        default: break
        }
    }

    func sortState(_ section: AppSection) -> TableSort? {
        switch section {
        case .images: return imagesSort
        case .volumes: return volumesSort
        case .networks: return networksSort
        default: return nil
        }
    }

    var filteredMachines: [Machine] {
        guard !filter.isEmpty else { return machines }
        return machines.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    func overviewRows(for c: Container) -> [(key: String, value: String)] {
        var rows: [(key: String, value: String)] = []
        if let project = c.composeProject {
            rows.append(("Compose project", project))
            rows.append(("Compose service", c.composeService ?? "—"))
        }
        rows.append(contentsOf: [
            ("Domain", c.domain),
            ("IP address", c.ipAddress),
            ("Ports", c.ports),
            ("Command", c.command),
            ("Restart policy", c.restartPolicy),
            ("Created", c.created),
            ("Uptime", c.uptime),
        ])
        return rows
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
        Task { await performToggle(container) }
    }

    func performToggle(_ container: Container) async {
        guard let idx = containers.firstIndex(where: { $0.id == container.id }) else { return }
        let wasRunning = container.status == .running
        pendingContainerIDs.insert(container.id)
        defer { pendingContainerIDs.remove(container.id) }

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

        do {
            if wasRunning { try await runtime.stop(containerID: container.id) }
            else { try await runtime.start(containerID: container.id) }
        } catch {
            actionError = "Couldn't \(wasRunning ? "stop" : "start") \(container.name): \(error.localizedDescription)"
        }
        if runtimeKind != .mock { await reload() }
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
    private(set) var composeProjects: [String: ComposeProject] = [:]

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
        let variables = Self.composeVariables(for: fileURL)
        let fileURLs = Self.composeFileURLs(for: fileURL, variables: variables)
        composeStatus = fileURLs.count == 1
            ? "Reading \(fileURLs[0].lastPathComponent)…"
            : "Reading \(fileURLs.count) Compose files…"
        var texts: [String] = []
        for url in fileURLs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                actionError = "Could not read \(url.lastPathComponent)"; composeStatus = ""; return
            }
            texts.append(text)
        }
        let project: ComposeProject
        let activeProfiles = ComposeParser.activeProfiles(from: variables["COMPOSE_PROFILES"])
        do {
            project = try ComposeParser.parse(
                texts,
                projectName: Self.composeName(for: fileURL),
                variables: variables,
                activeProfiles: activeProfiles
            )
        } catch {
            actionError = "Invalid Compose file: \(error)"; composeStatus = ""; return
        }
        guard !project.services.isEmpty else { actionError = "No services found in the Compose file"; composeStatus = ""; return }
        do {
            let engine = ComposeEngine(runtime: runtime)
            _ = try await engine.up(project, pullImages: true) { progress in
                self.composeStatus = "\(progress.service): \(progress.message)"
            }
            composeProjects[project.name] = project
            composeStatus = "\(project.name): \(project.services.count) services up"
            await reload()
            containerScope = .compose
            section = .containers
            selectedContainerID = containers(inComposeProject: project.name).first?.id ?? selectedContainerID
        } catch {
            actionError = "Compose up failed: \(error)"; composeStatus = ""
        }
    }

    func composeDown(_ name: String) async {
        composeBusy = true
        composeStatus = "Stopping \(name)…"
        defer { composeBusy = false }
        let engine = ComposeEngine(runtime: runtime)
        let project = await composeProject(named: name)
        do {
            try await engine.down(project)
        } catch {
            actionError = "Compose down failed: \(error)"
        }
        await reload()
        composeStatus = ""
    }

    private func composeProject(named name: String) async -> ComposeProject {
        if let project = composeProjects[name] { return project }
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot(containers: containers)
        let prefix = "\(name)-"
        let services = Dictionary(grouping: snapshot.containers.filter {
            $0.composeProject == name || $0.name.hasPrefix(prefix)
        }, by: { $0.composeService ?? serviceName(fromContainerName: $0.name, projectName: name) })
            .keys
            .filter { !$0.isEmpty }
            .sorted()
            .map { serviceName in
                ComposeService(name: serviceName, image: nil, build: nil, command: [], environment: [:],
                               ports: [], volumes: [], networks: [], dependsOn: [], restart: nil,
                               healthcheck: nil, profiles: [])
            }
        return ComposeProject(name: name, services: services, networks: [], volumes: [])
    }

    private func serviceName(fromContainerName name: String, projectName: String) -> String {
        let prefix = "\(projectName)-"
        guard name.hasPrefix(prefix), name.hasSuffix("-1") else { return "" }
        return String(name.dropFirst(prefix.count).dropLast(2))
    }

    private static func composeName(for url: URL) -> String {
        let dir = url.deletingLastPathComponent().lastPathComponent
        let raw = dir.isEmpty ? "compose" : dir
        let filtered = String(raw.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return filtered.isEmpty ? "compose" : filtered
    }

    private static func composeVariables(for fileURL: URL) -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        let dotEnvURL = fileURL.deletingLastPathComponent().appendingPathComponent(".env")
        guard let dotEnv = try? String(contentsOf: dotEnvURL, encoding: .utf8) else { return variables }
        for (key, value) in ComposeInterpolation.parseDotEnv(dotEnv) where variables[key] == nil {
            variables[key] = value
        }
        return variables
    }

    nonisolated static func composeFileURLs(for fileURL: URL, variables: [String: String]) -> [URL] {
        let baseDirectory = fileURL.deletingLastPathComponent()
        if let raw = variables["COMPOSE_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let separator = variables["COMPOSE_PATH_SEPARATOR"] ?? ":"
            let paths = raw.components(separatedBy: separator).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let urls = paths.map { resolveComposeFilePath($0, relativeTo: baseDirectory) }
            if !urls.isEmpty { return urls }
        }

        var urls = [fileURL]
        for candidate in defaultComposeOverrideURLs(for: fileURL) where FileManager.default.fileExists(atPath: candidate.path) {
            urls.append(candidate)
            break
        }
        return urls
    }

    nonisolated private static func defaultComposeOverrideURLs(for fileURL: URL) -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        switch fileURL.lastPathComponent {
        case "compose.yaml":
            return ["compose.override.yaml", "compose.override.yml"].map { directory.appendingPathComponent($0) }
        case "compose.yml":
            return ["compose.override.yml", "compose.override.yaml"].map { directory.appendingPathComponent($0) }
        case "docker-compose.yaml":
            return ["docker-compose.override.yaml", "docker-compose.override.yml"].map { directory.appendingPathComponent($0) }
        case "docker-compose.yml":
            return ["docker-compose.override.yml", "docker-compose.override.yaml"].map { directory.appendingPathComponent($0) }
        default:
            return []
        }
    }

    nonisolated private static func resolveComposeFilePath(_ path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return directory.appendingPathComponent(path)
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
                let q = tag.isEmpty ? "" : "t=" + DockerImageOps.queryValue(tag)
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
            Self.runKubectlApply(kubectl: kubectl, kubeconfig: kubeconfig, yaml: yaml)
        }.value
        if result == nil { await reload() }
        return result
    }

    nonisolated private static func runKubectlApply(kubectl: String, kubeconfig: String, yaml: String) -> String? {
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
        proc.arguments = ["--no-xattrs", "--no-mac-metadata", "-cf", "-", "-C", dir.path, "."]
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
    /// Every source engine found on this host (OrbStack, Docker Desktop, Colima, …), so the user
    /// picks which to import from instead of the app silently auto-selecting the top-priority socket.
    var migrationSources: [DockerSourceEngine] = []
    var selectedMigrationSourcePath: String?
    /// The last import result, so the UI can surface per-item failures instead of a bare count.
    var migrationSummary: MigrationSummary?

    private func selectedMigrationRuntime() async -> DockerEngineRuntime? {
        guard let path = selectedMigrationSourcePath else { return nil }
        return await DockerEngineRuntime.detect(candidates: [path])
    }

    func selectMigrationSource(_ path: String) async {
        selectedMigrationSourcePath = path
        await loadMigrationPreflight()
    }

    /// Reads the selected host engine (if any) without modifying it, to power the pre-flight
    /// "here's what will move, nothing will be deleted" screen.
    func loadMigrationPreflight() async {
        migrationSources = DockerEngineSocketDiscovery.availableSources()
        if selectedMigrationSourcePath == nil
            || !migrationSources.contains(where: { $0.socketPath == selectedMigrationSourcePath }) {
            selectedMigrationSourcePath = migrationSources.first?.socketPath
        }
        guard let source = await selectedMigrationRuntime() else {
            migrationInventory = nil
            return
        }
        migrationInventory = await MigrationAssistant.preflight(from: source)
    }

    /// Imports the selected engine's images + containers into Dory's own shared VM — the "switch to
    /// Dory" flow. The target is Dory's standalone engine, so afterwards the source can be uninstalled.
    func importFromDocker() async {
        guard runtimeKind == .sharedVM else { migrationStatus = "Switch to Dory's shared VM first, then import"; return }
        guard !migrationBusy else { return }
        guard let source = await selectedMigrationRuntime() else {
            migrationStatus = "Couldn't reach the selected source engine — is it running?"; return
        }
        migrationBusy = true
        defer { migrationBusy = false }
        let target = runtime
        migrationStatus = "Starting import…"
        let summary = await MigrationAssistant.migrate(from: source, to: target) { message in
            Task { @MainActor in self.migrationStatus = message }
        }
        migrationSummary = summary
        let base = "Imported \(summary.imagesImported.count) images, \(summary.containersMigrated.count) containers"
        migrationStatus = summary.failures.isEmpty ? base : "\(base) — \(summary.failures.count) failed"
        await reload()
    }

    func presentPrimary(for section: AppSection) {
        switch section {
        case .containers: activeSheet = .newContainer
        case .images: activeSheet = .pullImage
        case .volumes: activeSheet = .newVolume
        case .networks: activeSheet = .newNetwork
        case .compose: openComposeFile()
        case .machines: activeSheet = .newMachine
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

    private var machineService: MachineService { MachineService(runtime: runtime) }

    func machineSettings(_ name: String) async -> MachineSettings {
        await machineService.currentSettings(name: name)
    }

    private(set) var busyMachines: Set<String> = []
    var machineBusy: Bool { !busyMachines.isEmpty }
    func isMachineBusy(_ name: String) -> Bool { busyMachines.contains(name) }
    static let importBusyKey = "__dory_import__"
    var machineCreationTitle = ""
    var machineCreationLog = ""
    var machineCreationError: String?
    var machineCreated: Machine?

    func loadMachines() {
        guard runtimeKind.isDockerCompatible else { machines = []; return }
        Task { await refreshMachines() }
    }

    @discardableResult
    private func refreshMachines() async -> [Machine] {
        guard runtimeKind.isDockerCompatible else { machines = []; return [] }
        machines = await machineService.list()
        try? SSHConfigWriter().write(machines: machines)
        dns.replaceHostIPs(Self.machineDNSHosts(machines, suffix: domainSuffix))
        syncMachineStats()
        for machine in machines where machine.status == .running {
            registerMachineBridge(machine.name)
        }
        return machines
    }

    func syncMachineStats() {
        guard !machines.isEmpty else { return }
        for index in machines.indices {
            guard machines[index].status == .running,
                  let match = containers.first(where: { $0.id == machines[index].containerID }) else { continue }
            if machines[index].cpuPercent != match.cpuPercent { machines[index].cpuPercent = match.cpuPercent }
            if machines[index].memoryDisplay != match.memoryDisplay { machines[index].memoryDisplay = match.memoryDisplay }
        }
    }

    private static let legacyMachineCleanupKey = "dory.legacyMachineCleanupOffered"

    func offerLegacyMachineCleanup() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMachineCleanupKey) else { return }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/machines")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            UserDefaults.standard.set(true, forKey: Self.legacyMachineCleanupKey); return
        }
        UserDefaults.standard.set(true, forKey: Self.legacyMachineCleanupKey)
        try? FileManager.default.removeItem(at: dir)
        actionError = "Reclaimed disk space from the old machine cache (~/.dory/machines). New machines run inside Dory's engine now."
    }

    var browsingVolume: String?
    var volumeBrowsePath = ""
    var volumeEntries: [VolumeEntry] = []
    var volumeFilePreview: String?
    var volumeBrowseBusy = false

    func openVolumeBrowser(_ volume: String) {
        guard runtimeKind != .appleContainer else {
            actionError = Self.dockerCompatibleEngineRequired("Volume file browsing")
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

    func copyVolumePath(_ entry: VolumeEntry) {
        let path = volumeBrowsePath.isEmpty ? "/\(entry.name)" : "/\(volumeBrowsePath)/\(entry.name)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func exportVolumeFile(_ entry: VolumeEntry) {
        guard let volume = browsingVolume, !entry.isDirectory else { return }
        let relativePath = volumeBrowsePath.isEmpty ? entry.name : "\(volumeBrowsePath)/\(entry.name)"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        volumeBrowseBusy = true
        Task {
            let data = await VolumeBrowser(runtime: runtime).exportFile(volume: volume, path: relativePath)
            volumeBrowseBusy = false
            guard let data else { actionError = "Could not export \(entry.name)"; return }
            do { try data.write(to: url) } catch { actionError = "Could not save file: \(error.localizedDescription)" }
        }
    }

    func jumpToVolumePath(_ path: String) async {
        volumeBrowsePath = path
        volumeFilePreview = nil
        await refreshVolumeBrowser()
    }

    func toggleMachine(_ machine: Machine) {
        guard let idx = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        let wasRunning = machines[idx].status == .running
        let name = machine.name
        busyMachines.insert(name)
        let service = machineService
        Task {
            defer { busyMachines.remove(name) }
            do {
                if wasRunning { try await service.stop(name: name) } else { try await service.start(name: name) }
            } catch {
                actionError = "Could not \(wasRunning ? "stop" : "start") \(name): \(error)"
            }
            if wasRunning { unregisterMachineBridge(name) } else { registerMachineBridge(name) }
            loadMachines()
        }
    }

    nonisolated static func allocateFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return 0 }
        var result = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return 0 }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    nonisolated static func mergingEnv(_ settings: MachineSettings, resolved: [String: String]) -> MachineSettings {
        guard !resolved.isEmpty else { return settings }
        var copy = settings
        for (key, value) in resolved where copy.env[key] == nil && !value.isEmpty {
            copy.env[key] = value
        }
        return copy
    }

    nonisolated static func withIdentity(_ settings: MachineSettings, _ identity: MacIdentity) -> MachineSettings {
        var s = settings
        s.identity = identity
        if !s.mounts.contains(where: { $0.guest == identity.homePath }) {
            s.mounts.append(MountPair(host: identity.homePath, guest: identity.homePath, readOnly: false))
        }
        return s
    }

    nonisolated static func preservingHiddenMachineSettings(_ settings: MachineSettings, existing: MachineSettings) -> MachineSettings {
        var copy = settings
        if copy.env.isEmpty { copy.env = existing.env }
        if copy.identity == nil { copy.identity = existing.identity }
        return copy
    }

    func createMachine(image: String, name: String, arch: MachineArch = .host, recipe: DevRecipe? = nil, settings: MachineSettings = .default, identity: MacIdentity? = nil) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { actionError = "Name is required"; return "Name is required" }
        guard trimmedName.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]*/) != nil else {
            actionError = "Invalid machine name: use letters, digits, and _ . - (must start alphanumeric)"
            return "Invalid machine name"
        }
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Linux machines")
            return "Engine not available"
        }
        guard let distro = MachineDistro.forImage(image.trimmingCharacters(in: .whitespaces)) else {
            actionError = "Unsupported machine image: \(image)"
            return "Unsupported machine image"
        }
        guard !busyMachines.contains(trimmedName) else { return nil }
        busyMachines.insert(trimmedName)
        machineCreationTitle = "Creating \(trimmedName)"
        machineCreationLog = "Preparing to create \(trimmedName) (\(arch.shortLabel))…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        defer { busyMachines.remove(trimmedName) }
        var effectiveSettings = identity.map { Self.withIdentity(settings, $0) } ?? settings
        let resolvedSecrets = await MachineEnvImport.resolve(names: machineEnvAllowList)
        effectiveSettings = Self.mergingEnv(effectiveSettings, resolved: resolvedSecrets)
        if !resolvedSecrets.isEmpty {
            appendMachineCreationLog("Copying \(resolvedSecrets.keys.sorted().joined(separator: ", ")) into \(trimmedName)…")
        }
        if effectiveSettings.identity != nil, !effectiveSettings.ports.contains(where: { $0.guest == 22 }) {
            let sshHostPort = Self.allocateFreePort()
            if sshHostPort > 0 {
                effectiveSettings.ports.append(PortPair(host: sshHostPort, guest: 22))
            }
        }
        do {
            try await machineService.create(name: trimmedName, distro: distro, arch: arch, recipe: recipe, settings: effectiveSettings) { line in
                Task { @MainActor in self.appendMachineCreationLog(line) }
            }
            appendMachineCreationLog("Machine created and started.")
            registerMachineBridge(trimmedName)
            let refreshed = await refreshMachines()
            machineCreated = refreshed.first { $0.name == trimmedName }
            if machineCreated == nil {
                let message = "Machine '\(trimmedName)' was created but isn't showing in the list yet — check the Machines tab."
                appendMachineCreationLog(message)
                machineCreationError = message
                return message
            }
            return nil
        } catch {
            let message = "\(error)"
            appendMachineCreationLog("Error: \(message)")
            machineCreationError = message
            actionError = "Could not create machine"
            return message
        }
    }

    func editMachine(_ machine: Machine, settings: MachineSettings) async -> String? {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Linux machines")
            return "Engine not available"
        }
        busyMachines.insert(machine.name)
        machineCreationTitle = "Updating \(machine.name)"
        machineCreationLog = "Snapshotting \(machine.name) before applying new settings…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        defer { busyMachines.remove(machine.name) }
        do {
            let existing = await machineService.currentSettings(name: machine.name)
            let effectiveSettings = Self.preservingHiddenMachineSettings(settings, existing: existing)
            try await machineService.recreate(name: machine.name, settings: effectiveSettings)
            appendMachineCreationLog("Settings applied. Machine recreated from snapshot.")
            registerMachineBridge(machine.name)
            activeSheet = nil
            loadMachines()
            return nil
        } catch {
            let message = "\(error)"
            appendMachineCreationLog("Edit failed: \(message). The pre-edit snapshot was retained — restore it from Snapshots if needed.")
            machineCreationError = message
            actionError = "Could not update machine settings"
            loadMachines()
            return message
        }
    }

    private func appendMachineCreationLog(_ line: String) {
        machineCreationLog.append(line + "\n")
    }

    var snapshotMachine: Machine?
    var machineSnapshots: [MachineSnapshot] = []
    var editMachineTarget: Machine?

    func openMachineEdit(_ machine: Machine) {
        editMachineTarget = machine
    }

    func openSnapshots(_ machine: Machine) {
        snapshotMachine = machine
        machineSnapshots = []
        activeSheet = .machineSnapshots
        Task { await reloadSnapshots() }
    }

    private func reloadSnapshots() async {
        guard let machine = snapshotMachine else { return }
        let all = await machineService.listSnapshots()
        machineSnapshots = all.filter { $0.machineName == machine.name }
    }

    func takeSnapshot(_ machine: Machine, note: String) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Snapshots")
            return
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdISO = ISO8601DateFormatter().string(from: Date())
        let tag = "s" + UUID().uuidString.prefix(8).lowercased()
        let name = machine.name
        busyMachines.insert(name)
        let service = machineService
        Task {
            defer { busyMachines.remove(name) }
            do {
                _ = try await service.snapshot(machine: machine, note: trimmedNote, createdISO: createdISO, tag: tag)
            } catch {
                actionError = "Could not snapshot \(machine.name): \(error)"
            }
            if snapshotMachine?.name == machine.name { await reloadSnapshots() }
        }
    }

    func cloneMachine(_ machine: Machine) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Cloning")
            return
        }
        let name = machine.name
        let newName = name + "-copy-" + String(UUID().uuidString.prefix(4).lowercased())
        busyMachines.insert(name)
        machineCreationTitle = "Cloning \(name)"
        machineCreationLog = "Snapshotting \(name), then creating \(newName)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        let service = machineService
        Task {
            defer { busyMachines.remove(name) }
            do {
                let createdISO = ISO8601DateFormatter().string(from: Date())
                let tag = "s" + UUID().uuidString.prefix(8).lowercased()
                let snapshot = try await service.snapshot(machine: machine, note: "clone base", createdISO: createdISO, tag: tag)
                try await service.cloneFromSnapshot(snapshot, newName: newName)
                appendMachineCreationLog("Clone \(newName) created and started.")
                registerMachineBridge(newName)
                activeSheet = nil
                loadMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not clone machine"
            }
        }
    }

    func exportMachine(_ machine: Machine) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Exporting")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export machine"
        panel.nameFieldStringValue = "\(machine.name).dorymachine"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorymachine") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = machine.name
        busyMachines.insert(name)
        let service = machineService
        Task {
            defer { busyMachines.remove(name) }
            do {
                let createdISO = ISO8601DateFormatter().string(from: Date())
                let tag = "s" + UUID().uuidString.prefix(8).lowercased()
                let snapshot = try await service.snapshot(machine: machine, note: "export", createdISO: createdISO, tag: tag)
                try await service.export(snapshot, to: url)
            } catch {
                actionError = "Could not export \(machine.name): \(error)"
            }
        }
    }

    func cloneSnapshot(_ snapshot: MachineSnapshot) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Cloning")
            return
        }
        let newName = snapshot.machineName + "-copy-" + String(UUID().uuidString.prefix(4).lowercased())
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        machineCreationTitle = "Cloning \(snapshot.machineName)"
        machineCreationLog = "Creating \(newName) from snapshot…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        let service = machineService
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                try await service.cloneFromSnapshot(snapshot, newName: newName)
                appendMachineCreationLog("Clone \(newName) created and started.")
                registerMachineBridge(newName)
                activeSheet = nil
                loadMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not clone machine"
            }
        }
    }

    func restoreSnapshot(_ snapshot: MachineSnapshot) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Restoring")
            return
        }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        machineCreationTitle = "Restoring \(snapshot.machineName)"
        machineCreationLog = "Restoring \(snapshot.machineName) from snapshot…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        let service = machineService
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                try await service.restore(snapshot)
                appendMachineCreationLog("\(snapshot.machineName) restored from snapshot.")
                registerMachineBridge(snapshot.machineName)
                activeSheet = nil
                loadMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not restore machine"
            }
        }
    }

    func exportSnapshot(_ snapshot: MachineSnapshot) {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Exporting")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export machine snapshot"
        panel.nameFieldStringValue = "\(snapshot.machineName).dorymachine"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorymachine") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        let service = machineService
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                try await service.export(snapshot, to: url)
            } catch {
                actionError = "Could not export \(snapshot.machineName): \(error)"
            }
        }
    }

    func importMachineFile() {
        guard runtimeKind.isDockerCompatible else {
            actionError = Self.dockerCompatibleEngineRequired("Importing")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import a Dory machine file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "dorymachine") ?? .data,
            UTType(filenameExtension: "tar") ?? .data,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyMachines.insert(Self.importBusyKey)
        machineCreationTitle = "Importing machine"
        machineCreationLog = "Importing \(url.lastPathComponent)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        let service = machineService
        Task {
            defer { busyMachines.remove(Self.importBusyKey) }
            do {
                let imageRef = try await service.importMachine(from: url)
                appendMachineCreationLog("Imported snapshot \(imageRef). Use Clone or Restore from the Snapshots sheet.")
                activeSheet = nil
                loadMachines()
                if snapshotMachine != nil { await reloadSnapshots() }
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not import machine file"
            }
        }
    }

    func deleteSnapshot(_ snapshot: MachineSnapshot) {
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        let id = snapshot.id
        let activeRuntime = runtime
        machineSnapshots.removeAll { $0.id == snapshot.id }
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                try await activeRuntime.removeImage(id: id)
            } catch {
                actionError = "Could not delete snapshot: \(error)"
            }
            if snapshotMachine != nil { await reloadSnapshots() }
        }
    }

    func deleteMachine(_ machine: Machine) {
        let name = machine.name
        let service = machineService
        machines.removeAll { $0.name == name }
        unregisterMachineBridge(name)
        try? FileManager.default.removeItem(atPath: MachineService.bridgeHostDir(for: name))
        Task {
            do {
                try await service.delete(name: name)
            } catch {
                actionError = "Could not delete machine '\(name)': \(error.localizedDescription)"
            }
            loadMachines()
        }
    }

    func openContainerTerminal(_ container: Container) {
        TerminalLauncher.openContainerShell(socketPath: shimSocketPath, containerID: container.id)
    }

    func terminalSession(for container: Container) -> TerminalSession {
        TerminalSession(id: "container:\(container.id)", title: container.name, subtitle: container.image,
                        logo: nil, socketPath: shimSocketPath, containerID: container.id,
                        user: "root", shell: "/bin/sh", home: "/root")
    }

    func terminalSession(for machine: Machine) -> TerminalSession {
        let home = machine.username == "root" ? "/root" : "/Users/\(machine.username)"
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family
        return TerminalSession(id: "machine:\(machine.containerID)", title: machine.name,
                               subtitle: "\(machine.distro) \(machine.version)",
                               logo: family.flatMap { MachineDistro.logoAsset(family: $0) },
                               socketPath: shimSocketPath, containerID: machine.containerID,
                               user: machine.username, shell: machine.loginShell, home: home)
    }

    func terminalSession(for pod: Pod) -> TerminalSession {
        TerminalSession(id: "pod:\(pod.namespace)/\(pod.name)", title: pod.name, subtitle: pod.namespace,
                        logo: nil, socketPath: "", containerID: "", user: "root", shell: "/bin/sh", home: "/root",
                        kubeExec: KubeExecTarget(
                            pod: pod.name,
                            namespace: pod.namespace,
                            container: pod.primaryContainer,
                            kubeconfig: KubeClient.kubeconfig() ?? ""
                        ))
    }
}
