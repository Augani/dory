import SwiftUI
import AppKit
import Darwin
import DoryOperations
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum LoadState: Sendable { case connecting, ready, engineOff }

struct SettingsNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case success, failure }

    var id = UUID()
    var kind: Kind
    var message: String
}

private enum DoryMachineFileTransferUIError: LocalizedError {
    case authorityChanged
    case invalidCompletion
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .authorityChanged:
            "The file transfer identity changed unexpectedly."
        case .invalidCompletion:
            "The guest returned incomplete file transfer evidence."
        case .remoteFailure(let message):
            message
        }
    }
}

private enum DorydBackendReadinessError: LocalizedError, CustomStringConvertible {
    case engineUnavailable(state: String, detail: String)
    case dockerTimedOut(socketPath: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .engineUnavailable(state, detail):
            if detail.isEmpty {
                "Dory's engine became \(state) before Docker was ready."
            } else {
                "Dory's engine became \(state): \(detail)"
            }
        case let .dockerTimedOut(socketPath, detail):
            if detail.isEmpty {
                "Dory's engine is running, but Docker did not answer at \(socketPath)."
            } else {
                "Dory's engine is running, but Docker did not answer at \(socketPath): \(detail)"
            }
        }
    }

    var description: String { errorDescription ?? "Dory's engine did not become ready." }
}

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
    var requestedComponentIDs: [DoryComponentID] = []
    var selectedContainerID: String? = nil
    var isSidebarVisible = true
    var isContainerInspectorVisible = true
    var detailTab: DetailTab = .overview
    var settingsTab: SettingsTab = .general
    var menuOpen = false
    var onboarding = false
    var isConnecting = false
    var filter = "" {
        didSet {
            if section == .containers { reconcileContainerSelection() }
        }
    }
    var filterFocusToken = 0
    var imagesSort: TableSort?
    var volumesSort: TableSort?
    var networksSort: TableSort?
    var activeSheet: AppSheet?
    var actionError: String?
    var settingsNotice: SettingsNotice?
    var upgradeTransaction: DoryUpgradeTransactionRecord?
    var upgradeStatusError: String?
    var inspectedImage: DockerImage?
    var inspectedNetwork: DoryNetwork?
    var buildActivity: [BuildActivityRecord] = []
    var buildCacheUsage: BuildCacheUsage = .empty
    var buildActivityLoading = false
    var buildActivityError: String?
    var selectedBuildReference: String?
    var selectedBuildLogs = ""
    var selectedBuildLogsLoading = false
    var doryBuildActive = false
    @ObservationIgnored private var activeBuildTask: Task<Void, Never>?
    @ObservationIgnored private var activeBuildToken: UUID?

    var launchAtLogin = false
    var showMenuBarIcon = true
    var routeDockerCLI = true
    var keepDorydRunningAfterQuit = false
    /// Retained as an empty v1 managed-settings compatibility field. Host environment import is
    /// disabled: credentials belong in scoped secret grants, never persisted machine environment.
    var machineEnvAllowList: [String] = []
    var openLoginsOnMac = true
    var externalTerminalPreference = ExternalTerminalPreference(terminal: .terminal, customApplicationPath: nil)
    var dockerHostConflict: DockerHostConflict.Conflict?
    var dockerHostCleaned = false
    var dockerHostConflictDismissed = false
    var containerDetailWidth: Double = 372
    var containerScope: ContainerScope =
        ContainerScope(rawValue: UserDefaults.standard.string(forKey: "dory.containerScope") ?? "") ?? .all
    {
        didSet {
            UserDefaults.standard.set(containerScope.rawValue, forKey: Self.containerScopeKey)
            reconcileContainerSelection()
        }
    }

    var containers: [Container] = [] {
        didSet { reconcileContainerSelection() }
    }
    var images: [DockerImage] = []
    var volumes: [Volume] = []
    var networks: [DoryNetwork] = []
    var pods: [Pod] = []
    var machines: [Machine] = []
    var engineRunning = false
    var engineVersion = "1.4.0"
    /// True while the in-app Auto-Idle monitor has stopped the engine to reclaim memory. The docker
    /// socket stays listening; the next docker request (or returning to the app) wakes it on demand.
    var engineSleeping = false
    var finderStorageLocationActive = false

    var loadState: LoadState = .connecting
    var launchSplashComplete = false
    @ObservationIgnored private(set) var isSnapshotMode = false
    var containerFilter: ContainerFilter =
        ContainerFilter(rawValue: UserDefaults.standard.string(forKey: "containerFilter") ?? "") ?? .running
    {
        didSet {
            UserDefaults.standard.set(containerFilter.rawValue, forKey: "containerFilter")
            reconcileContainerSelection()
        }
    }

    var healthSnapshot: HealthSnapshot?
    var healthLoading = false
    var healthActiveLoading = false
    var healthActionInFlight = false
    var healthActionError: String?
    var healthSupportBundleInFlight = false
    var healthSupportBundlePath: String?
    var healthSupportBundleMessage: String?
    @ObservationIgnored private var healthLoadToken = 0
    var processMemorySnapshot: DoryProcessMemorySnapshot = .empty
    @ObservationIgnored private var processMemoryTask: Task<Void, Never>?
    var dataDriveOperationInFlight = false
    var dataDriveOperationStatus = ""
    var dataDriveRevision = 0

    var dorydRuntimeActive: Bool { runtimeOwnedByDoryd }
    var dorydRuntimeRequired: Bool { dorydEngineRequired }
    var localDorydCapabilities: [LocalDorydCapability] { Self.localDorydCapabilityCatalog }
    var runtimeAuthorityDisplay: String {
        if runtimeOwnedByDoryd { return "Managed by doryd" }
        if runtimeKind == .sharedVM { return "App-managed development engine" }
        if runtimeKind == .mock { return "Demo runtime" }
        if runtimeKind == .disconnected { return "Waiting for doryd" }
        return "External Docker-compatible engine"
    }

    var runtimeMode = "always-on"
    var idlePolicy = IdlePolicy.fallback
    var idlePolicyLoaded = false
    var idlePolicyBusy = false
    var lanVisible = false

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
    @ObservationIgnored private let dorydClient: DorydClient
    @ObservationIgnored private let dorydEngineEnabled: Bool
    @ObservationIgnored private let dorydEngineRequired: Bool
    @ObservationIgnored private let dorydEngineExplicitlyRequested: Bool
    @ObservationIgnored private let managesDorydLaunchAgent: Bool
    @ObservationIgnored private let dorydLaunchAgentEnsurer: @Sendable (DorydLaunchAgent.Configuration) async -> Bool
    @ObservationIgnored private let dorydLaunchAgentBootout: @Sendable () async -> Bool
    @ObservationIgnored private let authorizedNetworkingRemover: @Sendable () async throws -> Void
    @ObservationIgnored private let localCATrustManager: any LocalCATrustManaging
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let desktopMachineAssetPreparer: @Sendable (
        _ home: String,
        _ environment: [String: String],
        _ resourceDirectory: String?
    ) async throws -> DesktopMachineAssets
    @ObservationIgnored private let composeCommandRunner: any ToolCommandRunning
    @ObservationIgnored private let buildCommandRunner: any ToolCommandRunning
    @ObservationIgnored private let userFacingDoryCommandResolver: @MainActor @Sendable () -> String?
    @ObservationIgnored private let finderStorageLocation = DoryFinderStorageLocation()
    @ObservationIgnored private var lastFinderStorageRefresh = Date.distantPast
    @ObservationIgnored private var lastFinderStorageGroups: [DoryStorageInventoryGroup]?
    @ObservationIgnored private var runtimeOwnedByDoryd = false
    @ObservationIgnored private var daemonSocketPath: String?
    @ObservationIgnored private var engineSettingChangeInFlight = false
    var engineSettingChangeBusy: Bool { engineSettingChangeInFlight }
    var runtimeKind: RuntimeKind { runtime.kind }

    init(
        runtime: (any ContainerRuntime)? = nil,
        dorydClient: DorydClient = DorydClient(),
        useDorydEngine: Bool? = nil,
        dorydLaunchAgentEnsurer: (@Sendable (DorydLaunchAgent.Configuration) async -> Bool)? = nil,
        dorydLaunchAgentBootout: (@Sendable () async -> Bool)? = nil,
        authorizedNetworkingRemover: (@Sendable () async throws -> Void)? = nil,
        localCATrustManager: any LocalCATrustManaging = LocalCATrustManager(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        composeCommandRunner: any ToolCommandRunning = BoundedToolProcessRunner(),
        buildCommandRunner: any ToolCommandRunning = BoundedToolProcessRunner(),
        userFacingDoryCommandResolver: @escaping @MainActor @Sendable () -> String? = {
            HostTools.userFacingDoryCommand()
        },
        desktopMachineAssetPreparer: @escaping @Sendable (
            _ home: String,
            _ environment: [String: String],
            _ resourceDirectory: String?
        ) async throws -> DesktopMachineAssets = { home, environment, resourceDirectory in
            try await Task.detached(priority: .userInitiated) {
                try DesktopMachineAssetProvisioner.prepare(
                    home: home,
                    environment: environment,
                    resourceDirectory: resourceDirectory
                )
            }.value
        }
    ) {
        let env = environment
        let dorydFlags = Self.dorydEngineFlags(environment: env)
        self.environment = env
        self.composeCommandRunner = composeCommandRunner
        self.buildCommandRunner = buildCommandRunner
        self.userFacingDoryCommandResolver = userFacingDoryCommandResolver
        self.desktopMachineAssetPreparer = desktopMachineAssetPreparer
        self.dorydClient = dorydClient
        self.dorydEngineEnabled = dorydFlags.enabled
        self.dorydEngineRequired = dorydFlags.required
        self.dorydEngineExplicitlyRequested = useDorydEngine == true || dorydFlags.explicit
        self.managesDorydLaunchAgent = dorydClient.usesMachService || dorydLaunchAgentEnsurer != nil
        self.dorydLaunchAgentEnsurer = dorydLaunchAgentEnsurer ?? { configuration in
            await DorydLaunchAgent.ensureCurrent(configuration: configuration)
        }
        self.dorydLaunchAgentBootout = dorydLaunchAgentBootout ?? {
            await DorydLaunchAgent.bootoutCurrent()
        }
        self.authorizedNetworkingRemover = authorizedNetworkingRemover ?? {
            try await Self.removeAuthorizedNetworkingIfPresent()
        }
        self.localCATrustManager = localCATrustManager
        let networkHelperMaintenance = DoryAppDelegate.isNetworkHelperMaintenance()
        let realLaunch = !networkHelperMaintenance && !DoryAppDelegate.isTestHost
            && env["DORY_SECTION"] == nil && env["DORY_APPEARANCE"] == nil
            && env["XCTestConfigurationFilePath"] == nil
            && env["XCTestSessionIdentifier"] == nil && env["DORY_UI_TEST"] != "1"
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
            // Let Sparkle load its own consent and scheduling preferences.
            _ = DoryUpdater.shared
            if let v = UserDefaults.standard.object(forKey: Self.routeDockerKey) as? Bool { routeDockerCLI = v }
            keepDorydRunningAfterQuit = Self.resolvedKeepDorydRunningAfterQuit(defaults: .standard)
            // Earlier builds stored environment *names* here and copied their values into new VM
            // definitions. Clear that opt-in permanently; legacy VM records remain launchable but
            // no new machine inherits host credentials.
            UserDefaults.standard.removeObject(forKey: Self.machineEnvAllowListKey)
            if let v = UserDefaults.standard.object(forKey: Self.openLoginsOnMacKey) as? Bool { openLoginsOnMac = v }
            externalTerminalPreference = ExternalTerminalPreferenceStore.load()
            if let saved = UserDefaults.standard.string(forKey: Self.kubernetesVersionKey) {
                kubernetesVersionTag = KubeVersionCatalog.version(forTag: saved).tag
            }
            if let v = UserDefaults.standard.object(forKey: Self.dnsPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { dnsPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.httpProxyPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { httpProxyPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.httpsProxyPortKey) as? Int, let p = UInt16(exactly: v), p > 0 { httpsProxyPort = p }
            if let v = UserDefaults.standard.object(forKey: Self.domainsEnabledKey) as? Bool { domainsEnabled = v }
            if let saved = Self.normalizedDomainSuffix(UserDefaults.standard.string(forKey: Self.domainSuffixKey)) {
                domainSuffix = saved
            }
            if let saved = UserDefaults.standard.string(forKey: Self.defaultBridgeSubnetKey),
               let network = try? DoryIPv4BridgeNetwork(saved) {
                defaultBridgeSubnet = network.cidr
            }
            if let savedMode = Self.persistedRuntimeMode(environment: env) {
                runtimeMode = savedMode
            }
            if let override = Self.normalizedDomainSuffix(env["DORY_DOMAIN_SUFFIX"] ?? env["DORYD_DOMAIN_SUFFIX"]) {
                domainSuffix = override
            }
            dns = DoryDNS(suffix: domainSuffix)
            rosettaX86Enabled = SharedVMProvisioner.Config.amd64EmulationEnabled()
            if let raw = UserDefaults.standard.string(forKey: Self.enginePreferenceKey),
               let saved = EnginePreference(rawValue: raw) { enginePreference = saved }
            if let socket = UserDefaults.standard.string(forKey: Self.customEngineSocketKey) { customEngineSocket = socket }
            let resourceLimits = Self.engineResourceLimits()
            if let saved = UserDefaults.standard.object(forKey: Self.engineCPUCountKey) as? Int {
                engineCPUCount = min(max(saved, 1), resourceLimits.maximumCPUCount)
            }
            if let saved = UserDefaults.standard.object(forKey: Self.engineMemoryMBKey) as? Int {
                engineMemoryMB = min(max(saved, 2048), resourceLimits.maximumMemoryMB)
            }
            if let v = UserDefaults.standard.object(forKey: SharedVMProvisioner.Config.gpuVenusKey) as? Bool { gpuVenusEnabled = v }
            if gpuVenusEnabled, !gpuRuntimeAvailable {
                gpuVenusEnabled = false
                UserDefaults.standard.set(false, forKey: SharedVMProvisioner.Config.gpuVenusKey)
            }
            if gpuVenusEnabled, rosettaX86Enabled {
                gpuVenusEnabled = false
                UserDefaults.standard.set(false, forKey: SharedVMProvisioner.Config.gpuVenusKey)
            }
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
        let testMode = networkHelperMaintenance || env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil || env["DORY_UI_TEST"] == "1"
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
    static let routeDockerKey = "dory.routeDockerCLI"
    static let keepDorydRunningAfterQuitKey = "dory.keepDorydRunningAfterQuit"
    static let machineEnvAllowListKey = "dory.machineEnvAllowList"
    static let openLoginsOnMacKey = "dory.openLoginsOnMac"
    static let dockerHostDismissedKey = "dory.dockerHostDismissed"
    static let containerDetailWidthKey = "dory.containerDetailWidth"
    static let containerScopeKey = "dory.containerScope"
    static let kubernetesVersionKey = "dory.kubernetesVersion"

    static func resolvedKeepDorydRunningAfterQuit(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: keepDorydRunningAfterQuitKey) as? Bool) ?? false
    }

    var externalTerminalDisplayName: String {
        externalTerminalPreference.displayName
    }

    func setExternalTerminal(_ terminal: ExternalTerminal) {
        if terminal == .custom, externalTerminalPreference.customApplicationPath == nil {
            chooseExternalTerminalApplication()
            return
        }
        externalTerminalPreference.terminal = terminal
        ExternalTerminalPreferenceStore.save(externalTerminalPreference)
        showSettingsSuccess("External terminal set to \(externalTerminalDisplayName).")
    }

    func chooseExternalTerminalApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose External Terminal"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let recognized = ExternalTerminal.recognized(applicationURL: url) {
            externalTerminalPreference = ExternalTerminalPreference(
                terminal: recognized,
                customApplicationPath: nil
            )
        } else {
            externalTerminalPreference = ExternalTerminalPreference(
                terminal: .custom,
                customApplicationPath: url.standardizedFileURL.path
            )
        }
        ExternalTerminalPreferenceStore.save(externalTerminalPreference)
        showSettingsSuccess("External terminal set to \(externalTerminalDisplayName).")
    }
    nonisolated static let localDorydCapabilityCatalog: [LocalDorydCapability] = [
        LocalDorydCapability(
            id: "support-bundle",
            title: "Support bundle",
            summary: "Collect local diagnostics for the daemon, socket, engine, memory, helpers, and recovery checks.",
            command: "dory support bundle",
            status: "Stable"
        ),
        LocalDorydCapability(
            id: "agent-guide",
            title: "Agent guide",
            summary: "Expose Dory's stable machine-readable local command contract for coding agents and automation.",
            command: "dory agent guide --json",
            status: "Stable"
        ),
        LocalDorydCapability(
            id: "mcp",
            title: "Read-only MCP",
            summary: "Serve the local Dory tool surface over stdio while blocking machine execution and sandbox mutations.",
            command: "dory mcp serve --read-only",
            status: "Stable"
        ),
        LocalDorydCapability(
            id: "sandbox",
            title: "Agent-ready sandbox",
            summary: "Run non-root in a dedicated VM with resource caps, or keep a named environment with prepared tools, warm caches, and a clean reset.",
            command: "dory sandbox create my-project --workspace .",
            status: "Stable"
        ),
        LocalDorydCapability(
            id: "wait",
            title: "Wait primitive",
            summary: "Block scripts until the engine, a container, or a machine reaches the expected state.",
            command: "dory wait engine --until running --timeout 60 --json",
            status: "Stable"
        ),
        LocalDorydCapability(
            id: "events",
            title: "Event stream",
            summary: "Follow local doryd idle and incident events for CI, agents, or live debugging.",
            command: "dory events --follow --json",
            status: "Stable"
        ),
    ]
    nonisolated static let dockerCompatibleEngineHint = "Start Dory's shared VM in Settings > Docker Engine, or run a local Docker-compatible engine such as Docker Desktop, Colima, Rancher Desktop, Podman, or OrbStack."
    nonisolated static var dockerCompatibleFallbackHint: String {
        if MacHostPlatform.current().isAppleSilicon {
            "Dory can still run on this Mac by proxying a local Docker-compatible engine such as Docker Desktop, Colima, Rancher Desktop, Podman, or OrbStack."
        } else {
            "Dory does not ship a built-in Intel engine. This install can proxy a local Docker-compatible engine such as Colima, Docker Desktop, Rancher Desktop, Podman, or OrbStack."
        }
    }

    nonisolated static func dockerCompatibleEngineRequired(_ feature: String) -> String {
        "\(feature) needs Dory's shared VM or a Docker-compatible engine. \(dockerCompatibleEngineHint)"
    }

    nonisolated static func dorydMachineManagerRequired(_ feature: String = "Linux machines") -> String {
        "\(feature) needs Dory's daemon-managed VM machine runtime. Switch Docker Engine to Dory and make sure doryd is running; external Docker engines are supported for containers, not Linux Machines."
    }

    func managedSettingsProfile() -> ManagedSettingsProfile {
        ManagedSettingsProfile(
            engine: ManagedEngineSettings(
                preference: enginePreference.rawValue,
                routeDockerCLI: routeDockerCLI,
                keepDorydRunningAfterQuit: keepDorydRunningAfterQuit,
                rosettaX86: rosettaX86Enabled,
                gpuVenus: gpuVenusEnabled,
                cpuCount: engineCPUCount,
                memoryMB: engineMemoryMB
            ),
            network: ManagedNetworkSettings(
                domainsEnabled: domainsEnabled,
                domainSuffix: domainSuffix,
                dnsPort: dnsPort,
                httpProxyPort: httpProxyPort,
                httpsProxyPort: httpsProxyPort,
                customDomains: customDomainRoutes.map {
                    ManagedCustomDomainRoute(hostname: $0.hostname, publishedPort: $0.port)
                }
            ),
            autoIdle: ManagedAutoIdleSettings(
                mode: runtimeMode,
                sleepAfterMinutes: idlePolicy.sleepAfterMinutes,
                keepPublishedPortsAwake: idlePolicy.keepPublishedPortsAwake,
                keepKubernetesAwake: idlePolicy.keepKubernetesAwake,
                keepPinnedProjectsAwake: idlePolicy.keepPinnedProjectsAwake,
                showWakeNotifications: idlePolicy.showWakeNotifications
            ),
            fileSharing: ManagedFileSharingSettings(
                defaultPolicy: "safe-scoped",
                scopedMountsRequiredForSandboxes: true,
                credentialStoresHidden: true,
                machineEnvAllowList: machineEnvAllowList
            ),
            telemetry: ManagedTelemetrySettings()
        )
    }

    func managedSettingsJSON() -> String {
        ManagedSettingsEncoder.json(managedSettingsProfile())
    }

    nonisolated static func dorydEngineEnabled(environment: [String: String]) -> Bool {
        dorydEngineFlags(environment: environment).enabled
    }

    /// A clean installed app can spend tens of seconds registering and validating its signed
    /// LaunchAgent before doryd publishes the Mach service. Keep the app in its truthful starting
    /// state for that whole first-launch window instead of converting a still-progressing launch
    /// into a sticky engine error. Docker readiness has its own subsequent bounded wait.
    nonisolated static let dorydBackendAttachTimeout: TimeInterval = 60

    private nonisolated static func dorydEngineFlags(environment: [String: String]) -> (enabled: Bool, required: Bool, explicit: Bool) {
        // Dory 0.4 has one production local-engine owner. Keep the positive flags only as an
        // automation signal that a test explicitly wants to attach to doryd; historical disable
        // flags must not resurrect the retired app-owned engine.
        let explicitlyRequested = truthy(
            environment["DORY_APP_REQUIRE_DORYD"]
                ?? environment["DORY_REQUIRE_DORYD"]
                ?? environment["DORY_APP_USE_DORYD"]
                ?? environment["DORY_USE_DORYD"]
                ?? ""
        )
        return (true, true, explicitlyRequested)
    }

    private nonisolated static func truthy(_ raw: String) -> Bool {
        ["1", "true", "yes", "on"].contains(raw.lowercased())
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

    func setKubernetesVersion(_ version: KubeVersion) {
        kubernetesVersionTag = version.tag
        UserDefaults.standard.set(version.tag, forKey: Self.kubernetesVersionKey)
    }

    func setRouteDockerCLI(_ on: Bool) {
        let previous = routeDockerCLI
        routeDockerCLI = on
        UserDefaults.standard.set(on, forKey: Self.routeDockerKey)
        Task {
            let localChangeApplied: Bool
            if on {
                localChangeApplied = await configureTerminalDockerCLI()
            } else if !on {
                DockerContext.deactivateSync()
                HostDockerCLI.remove()
                dockerHostConflict = nil
                localChangeApplied = true
            } else {
                localChangeApplied = true
            }

            guard localChangeApplied else {
                routeDockerCLI = previous
                UserDefaults.standard.set(previous, forKey: Self.routeDockerKey)
                showSettingsFailure("Terminal docker command could not be enabled. Dory could not link its bundled CLI helpers into ~/.dory/bin or add that directory to a login shell profile.")
                return
            }

            var daemonRefreshApplied = true
            if dorydClient.usesMachService {
                daemonRefreshApplied = await DorydLaunchAgent.ensureCurrent(configuration: dorydLaunchAgentConfiguration())
            }

            guard daemonRefreshApplied else {
                showSettingsFailure(on
                    ? "Terminal docker command was installed, but doryd could not be refreshed. Restart Dory to finish applying it."
                    : "Terminal docker command was removed locally, but doryd could not be refreshed. Restart Dory to finish applying it.")
                return
            }
            showSettingsSuccess(on ? "Terminal docker command enabled." : "Terminal docker command removed.")
        }
    }

    func setKeepDorydRunningAfterQuit(_ on: Bool) {
        keepDorydRunningAfterQuit = on
        UserDefaults.standard.set(on, forKey: Self.keepDorydRunningAfterQuitKey)
        showSettingsSuccess(on
            ? "doryd will keep running after Dory quits."
            : "doryd will stop when Dory quits.")
    }

    @discardableResult
    private func configureTerminalDockerCLI() async -> Bool {
        guard routeDockerCLI, runtimeKind != .mock, !isAutomationContext else { return false }
        let installed = HostDockerCLI.install()
        if enginePreference == .dory || loadState != .engineOff {
            await DockerContext.activate(socketPath: shimSocketPath)
        }
        await detectDockerHostConflict()
        return installed
    }

    func setOpenLoginsOnMac(_ on: Bool) {
        openLoginsOnMac = on
        UserDefaults.standard.set(on, forKey: Self.openLoginsOnMacKey)
        hostBridge.setEnabled(on)
        showSettingsSuccess(on ? "Browser login handoff enabled." : "Browser login handoff disabled.")
    }

    private var isAutomationContext: Bool {
        let env = environment
        return DoryAppDelegate.isTestHost
            || env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
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
        showSettingsSuccess("\(value.rawValue.capitalized) appearance applied.")
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            showSettingsSuccess(on ? "Dory will launch at login." : "Dory will not launch at login.")
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showSettingsFailure("Could not update the login item: \(error.localizedDescription)")
        }
    }

    func setShowMenuBarIcon(_ on: Bool) {
        showMenuBarIcon = isAgentMode ? true : on
        UserDefaults.standard.set(showMenuBarIcon, forKey: Self.menuBarIconKey)
        DoryAppDelegate.refreshMenuBarVisibility()
        showSettingsSuccess(showMenuBarIcon ? "Menu bar icon enabled." : "Menu bar icon hidden.")
    }

    func setMachineEnvAllowList(_: [String]) {
        machineEnvAllowList = []
        UserDefaults.standard.removeObject(forKey: Self.machineEnvAllowListKey)
        showSettingsSuccess("Host environment import is disabled for new machines.")
    }

    func completeOnboarding() {
        onboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
    }

    var palette: DoryPalette { appearance.palette }

    func clearSettingsNotice() {
        settingsNotice = nil
    }

    func showSettingsSuccess(_ message: String) {
        settingsNotice = SettingsNotice(kind: .success, message: message)
    }

    func showSettingsFailure(_ message: String) {
        settingsNotice = SettingsNotice(kind: .failure, message: message)
    }

    var isAgentMode: Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool { return value }
        if let number = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber { return number.boolValue }
        if let string = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? String { return string == "1" || string.lowercased() == "true" || string.lowercased() == "yes" }
        return false
    }

    var shouldOpenWindowOnLaunch: Bool { !isAgentMode || onboarding || isSnapshotMode }

    private var shimServer: ShimHTTPServer?
    var shimSocketPath: String { daemonSocketPath ?? DockerShim.defaultSocketPath }
    private(set) var shimRunning = false
    /// Apple Silicon FEX translation for x86_64 Linux applications inside Dory's ARM64 container
    /// VM. Enabled on new installations and still user-disableable. This does not boot an Intel
    /// distro or ISO; Rosetta likewise translates applications inside an eligible ARM64 Linux VM.
    var rosettaX86Enabled = false
    /// Opt-in experimental GPU acceleration (virtio-gpu/Venus → virglrenderer → MoltenVK → Metal) for
    /// Vulkan and AI compute inside containers. Applied transactionally at engine restart; missing
    /// GPU runtime/kernel assets fail closed and restore this persisted choice.
    var gpuVenusEnabled = false
    /// Resource ceilings for Dory's daemon-owned Docker VM. They default to the same host-scaled
    /// values used by doryd, remain user-adjustable, and are written into the LaunchAgent so the UI
    /// is the authoritative configuration surface.
    var engineCPUCount = Int(DorydLaunchAgent.Configuration.hostScaledCPUCount())
    var engineMemoryMB = Int(DorydLaunchAgent.Configuration.hostScaledMemoryMB())
    let gpuArchitectureSupported = SharedVMProvisioner.venusArchitectureSupported()
    let gpuRuntimeAvailable = SharedVMProvisioner.venusRuntimeAvailable()

    /// Which backend the app connects to: Dory's bundled engine (default), an auto-detected existing
    /// engine (Colima, Docker Desktop, …), or a custom socket. Persisted; connectBackend honors it.
    var enginePreference: EnginePreference = .dory
    var customEngineSocket = ""
    static let enginePreferenceKey = "dory.enginePreference"
    static let customEngineSocketKey = "dory.customEngineSocket"
    static let engineCPUCountKey = "dory.engineCPUCount"
    static let engineMemoryMBKey = "dory.engineMemoryMB"

    var maximumEngineCPUCount: Int {
        Self.engineResourceLimits().maximumCPUCount
    }

    var maximumEngineMemoryGiB: Int {
        Self.engineResourceLimits().maximumMemoryMB / 1024
    }

    var recommendedEngineCPUCount: Int {
        Int(DorydLaunchAgent.Configuration.hostScaledCPUCount())
    }

    var recommendedEngineMemoryMB: Int {
        Int(DorydLaunchAgent.Configuration.hostScaledMemoryMB())
    }

    @ObservationIgnored private(set) var backendStartRequested = false
    @ObservationIgnored var windowOpenRequested = false

    @discardableResult
    func handleComponentSelectionURL(_ url: URL) -> Bool {
        guard let ids = DoryComponentSelectionURL.parse(url) else { return false }
        requestedComponentIDs = ids
        section = .components
        windowOpenRequested = true
        return true
    }

    func startBackendIfNeeded() {
        guard !backendStartRequested else { return }
        backendStartRequested = true
        observeAppActivation()
        startProcessMemoryRefresh()
        Task { await connectBackend() }
    }

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// Returning to Dory is a strong "I'm about to use it" signal, so wake an idle-slept engine the
    /// moment the app becomes active — the window is usable again before the user reaches for it.
    private func observeAppActivation() {
        guard activationObserver == nil, !isAutomationContext else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.ensureEngineAwake() }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Connects according to the persisted engine preference — Colima-style: Dory's bundled engine,
    /// an auto-detected existing engine, or a custom socket.
    private func connectPreferredBackend() async {
        switch enginePreference {
        case .external:
            runtimeOwnedByDoryd = false
            daemonSocketPath = nil
            if let docker = await DockerEngineRuntime.detect() {
                runtime = docker
                sharedVMStatus = "Using \(Self.externalEngineLabel(docker.socketPath))"
                await reload()
            } else {
                sharedVMStatus = "No running Docker-compatible engine found. Start it, or switch back to Dory's engine."
                loadState = .engineOff
            }
        case .custom:
            runtimeOwnedByDoryd = false
            daemonSocketPath = nil
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
            if await connectDorydBackend() {
                return
            }
            return
        }
    }

    @discardableResult
    private func connectDorydBackend() async -> Bool {
        runtimeOwnedByDoryd = false
        daemonSocketPath = nil
        sharedVMStatus = "Starting Dory's daemon…"
        if managesDorydLaunchAgent {
            let applied = await dorydLaunchAgentEnsurer(dorydLaunchAgentConfiguration())
            guard applied else {
                sharedVMStatus = "doryd's LaunchAgent could not apply the selected engine settings."
                loadState = .engineOff
                runtime = DisconnectedRuntime()
                return false
            }
        }
        do {
            let (status, socketPath) = try await waitForDorydBackend()
            daemonSocketPath = socketPath
            runtimeOwnedByDoryd = true
            let client = dorydClient
            let home = environment["HOME"] ?? NSHomeDirectory()
            let dockerRuntime = DockerEngineRuntime(
                socketPath: socketPath,
                kind: .sharedVM,
                migrationTargetStorageUsageProbe: {
                    let usage = try await client.dockerGuestDataDiskUsage()
                    return try Self.verifiedMigrationTargetStorageUsage(
                        usage,
                        expectedSocketPath: socketPath,
                        selectedDataDriveHome: home
                    )
                }
            )
            runtime = dockerRuntime

            if status.state != "running" {
                // Opening Dory is an explicit "I want the engine" signal. doryd may arm a sleeping
                // socket at login or after Auto-Idle, but the app should promote it to a live engine
                // on attach; idle policy decides only whether it may sleep again later.
                await refreshDorydRuntimeMode()
                loadState = .connecting
                sharedVMStatus = "Starting Dory's engine… The first launch can take a minute."
                let started = try await dorydClient.engineStart()
                guard started.ok else {
                    sharedVMStatus = started.message.isEmpty ? "doryd could not start the engine." : started.message
                    loadState = .engineOff
                    runtimeOwnedByDoryd = false
                    daemonSocketPath = nil
                    runtime = DisconnectedRuntime()
                    return false
                }
            }

            engineSleeping = false
            engineActivity.setSleeping(false)
            loadState = .connecting
            sharedVMStatus = "Dory's engine is running; connecting to Docker…"
            let snapshot = try await waitForDorydDockerReadiness(
                runtime: dockerRuntime,
                socketPath: socketPath
            )
            await applyRuntimeSnapshot(snapshot, synchronizeFinderStorage: true)
            sharedVMStatus = "Running through doryd"
            await loadCustomDomainRoutes()
            return true
        } catch {
            runtimeOwnedByDoryd = false
            daemonSocketPath = nil
            if let readinessError = error as? DorydBackendReadinessError {
                sharedVMStatus = readinessError.description
            } else {
                sharedVMStatus = "doryd is unavailable: \(error)"
            }
            loadState = .engineOff
            runtime = DisconnectedRuntime()
            return false
        }
    }

    /// Binds a daemon-owned guest measurement to both authorities used by migration: the exact
    /// Docker socket and the currently verified selected data drive. Capacity similarity is not an
    /// identity proof; two different drives commonly have the same default 128 GiB ceiling.
    nonisolated static func verifiedMigrationTargetStorageUsage(
        _ usage: DorydDockerGuestDataDiskUsage,
        expectedSocketPath: String,
        selectedDataDriveHome home: String
    ) throws -> MigrationTargetStorageUsage {
        guard usage.engineSocketPath == expectedSocketPath else {
            throw MigrationStrictInventoryError.incomplete(
                "doryd measured a different engine socket than the migration target"
            )
        }

        let selectedDriveID: UUID
        do {
            let store = try DoryDataDriveSelectionStore(home: home)
            guard let selection = try store.read(), selection.phase == .ready,
                  let drive = try store.inspectSelection() else {
                throw MigrationStrictInventoryError.incomplete(
                    "Dory has no verified selected data drive"
                )
            }
            let manifest = try drive.readManifest()
            guard manifest.id == selection.driveID else {
                throw MigrationStrictInventoryError.incomplete(
                    "Dory's selected data-drive record changed during verification"
                )
            }
            selectedDriveID = selection.driveID
        } catch let error as MigrationStrictInventoryError {
            throw error
        } catch {
            throw MigrationStrictInventoryError.incomplete(
                "Dory's selected data-drive identity could not be verified: \(error)"
            )
        }
        guard usage.dataDriveID == selectedDriveID else {
            throw MigrationStrictInventoryError.incomplete(
                "doryd measured a different data drive than the migration target"
            )
        }
        guard let totalBytes = Int64(exactly: usage.totalBytes),
              let usedBytes = Int64(exactly: usage.usedBytes),
              let availableBytes = Int64(exactly: usage.availableBytes) else {
            throw MigrationStrictInventoryError.incomplete(
                "Dory guest data-disk usage exceeds the supported signed byte range"
            )
        }
        return MigrationTargetStorageUsage(
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            availableBytes: availableBytes
        )
    }

    /// `engineStart` confirms doryd's lifecycle promotion, but attaching clients can still race the
    /// publication of the forwarded Unix socket or the first complete Docker inventory response.
    /// Keep the UI in a truthful connecting state and retry that narrow handoff. A failed probe must
    /// never stop daemon-owned work that is still becoming ready.
    private func waitForDorydDockerReadiness(
        runtime: DockerEngineRuntime,
        socketPath: String,
        timeout: TimeInterval = 30
    ) async throws -> RuntimeSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastRuntimeError = ""

        repeat {
            do {
                return try await runtime.snapshot()
            } catch {
                lastRuntimeError = error.localizedDescription
            }

            if let status = try? await dorydClient.engineStatus() {
                switch status.state {
                case "failed", "stopped", "unconfigured":
                    throw DorydBackendReadinessError.engineUnavailable(
                        state: status.state,
                        detail: status.detail
                    )
                case "starting":
                    sharedVMStatus = "Starting Dory's engine… The first launch can take a minute."
                case "running":
                    sharedVMStatus = "Dory's engine is running; connecting to Docker…"
                case "sleeping":
                    sharedVMStatus = "Waking Dory's engine…"
                default:
                    sharedVMStatus = "Waiting for Dory's engine…"
                }
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        throw DorydBackendReadinessError.dockerTimedOut(
            socketPath: socketPath,
            detail: lastRuntimeError
        )
    }

    private func waitForDorydBackend(
        timeout: TimeInterval = AppStore.dorydBackendAttachTimeout
    ) async throws -> (DorydEngineStatus, String) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        repeat {
            do {
                let status = try await dorydClient.engineStatus()
                let socketPath = try await dorydClient.dorySocketPath()
                return (status, socketPath)
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        } while Date() < deadline
        throw lastError ?? NSError(
            domain: "DorydReadiness",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "doryd did not answer before timeout"]
        )
    }

    /// Fetches doryd's runtime mode before attach finishes so the UI immediately reflects the real
    /// policy while the app promotes a sleeping/stopped daemon-owned engine to running.
    private func refreshDorydRuntimeMode() async {
        guard let status = try? await dorydClient.idleStatus() else { return }
        applyIdleStatus(status)
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
            if runtimeOwnedByDoryd {
                _ = try? await dorydClient.engineStop()
            }
            runtimeOwnedByDoryd = false
            daemonSocketPath = nil
            runtime = DisconnectedRuntime()
        }
        sharedVMStatus = "Switching engine…"
        await connectBackend()
    }

    func connectBackend() async {
        // Automation launches (UI tests, screenshot harnesses) never boot the real engine: they
        // exercise the app against the honest disconnected state unless they opt into a backend
        // with an explicit runtime, daemon flag, or injected non-Mach-service endpoint.
        let runtimeOverride = environment["DORY_RUNTIME"]
        let explicitlyAuthorizedBackend = runtimeOverride != nil
            || !dorydClient.usesMachService
            || (dorydEngineExplicitlyRequested && dorydEngineEnabled && enginePreference == .dory)
        if isAutomationContext, !explicitlyAuthorizedBackend {
            loadState = .engineOff
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        switch runtimeOverride {
        case "docker", "docker-proxy":
            if let docker = await DockerEngineRuntime.detect() { runtime = docker; await reload() }
            else { loadState = .engineOff }
        default:
            await connectPreferredBackend()
        }
        // Terminal integration only needs the bundled CLI and Dory's stable socket path; it should be
        // installed even while the engine is off/asleep so clean-Mac installs have `docker` on PATH.
        await configureTerminalDockerCLI()
        // With no live engine there is nothing to proxy. Injected fixture runtimes still wire the
        // shim so shim tests can drive it.
        guard runtimeKind == .mock || loadState != .engineOff else {
            try? await syncFinderStorageLocation(force: true)
            return
        }
        // Bring up the Docker-compatible socket before ancillary inventory work. Kubernetes and
        // machine discovery can involve external CLIs; they should never delay `docker` readiness.
        if runtimeOwnedByDoryd {
            stopShim()
        } else {
            startShim()
        }
        startPortForwarding()
        startAutoRefresh()
        Task { [weak self] in
            guard let self else { return }
            if !self.isAutomationContext {
                await self.loadIdlePolicy()
                await self.loadKubernetes()
                self.offerLegacyMachineCleanup()
            }
            self.loadMachines()
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

    /// Stops and re-provisions the shared engine so engine-level settings (GPU, x86_64 application
    /// compatibility, memory) or a newly installed Venus runtime take effect. The daemon-owned path
    /// captures the exact running-container set and explicitly starts only those containers after reconnecting.
    func restartEngine() async {
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = "Restarting the engine…"
        if runtimeOwnedByDoryd {
            let runningWorkloads: [EngineSettingWorkload]
            do {
                runningWorkloads = try await captureRunningWorkloads()
            } catch {
                sharedVMStatus = "Engine restart was cancelled because running containers could not be verified: \(error)"
                showSettingsFailure(sharedVMStatus)
                return
            }
            do {
                let stopped = try await dorydClient.engineStop()
                guard stopped.ok else {
                    let detail = stopped.message.isEmpty ? "doryd refused to stop the engine safely." : stopped.message
                    let recovery = await recoverPreviousDorydConfigurationAndWorkloads(runningWorkloads)
                    sharedVMStatus = "Engine restart failed: \(detail) \(recovery)"
                    showSettingsFailure(sharedVMStatus)
                    return
                }
            } catch {
                let recovery = await recoverPreviousDorydConfigurationAndWorkloads(runningWorkloads)
                sharedVMStatus = "Engine restart failed while stopping doryd: \(error) \(recovery)"
                showSettingsFailure(sharedVMStatus)
                return
            }
            await prepareForDorydReconnect()
            await connectBackend()
            guard runtimeOwnedByDoryd, loadState == .ready else {
                showSettingsFailure("The engine did not reconnect after restart. No additional containers were started.")
                return
            }
            let failures = await restartCapturedWorkloads(runningWorkloads)
            if failures.isEmpty {
                sharedVMStatus = "Engine restarted and prior workloads were restored."
                showSettingsSuccess(sharedVMStatus)
            } else {
                sharedVMStatus = "Engine restarted, but some prior workloads did not restart: "
                    + Self.workloadFailureSummary(failures)
                showSettingsFailure(sharedVMStatus)
            }
            return
        } else {
            await SharedVMProvisioner.stopEngine()
        }
        await connectBackend()
    }

    /// Grows Dory's sparse Docker data disk while the daemon is stopped, then restores exactly the
    /// containers that were running. Capacity inspection and rejected/no-op requests never stop the
    /// engine, and shrinking is refused because safely shrinking ext4 requires a separate workflow.
    func growDockerDataDisk(toGiB capacityGiB: Int) async {
        guard !engineSettingChangeInFlight else {
            showSettingsFailure("Another engine change is still being applied.")
            return
        }
        guard dorydEngineEnabled, enginePreference == .dory else {
            showSettingsFailure("Switch to Dory's daemon engine before changing its Docker storage capacity.")
            return
        }
        engineSettingChangeInFlight = true
        defer { engineSettingChangeInFlight = false }

        let home = environment["HOME"] ?? NSHomeDirectory()
        let current: DockerDataDiskUsage
        do {
            current = try await Task.detached {
                try Self.selectedDockerDataDiskUsage(home: home)
            }.value
        } catch {
            showSettingsFailure("Docker storage could not be inspected safely: \(error)")
            return
        }
        guard (current.minimumCapacityGiB...current.maximumCapacityGiB).contains(capacityGiB) else {
            showSettingsFailure(
                "Docker storage must be between \(current.minimumCapacityGiB) and \(current.maximumCapacityGiB) GiB."
            )
            return
        }
        guard capacityGiB >= current.capacityGiB else {
            showSettingsFailure(
                "Docker storage cannot be shrunk from \(current.capacityGiB) to \(capacityGiB) GiB. Back up and restore into a new drive instead."
            )
            return
        }
        guard capacityGiB != current.capacityGiB else {
            showSettingsSuccess("Docker storage is already \(capacityGiB) GiB.")
            return
        }
        guard runtimeOwnedByDoryd, loadState == .ready else {
            showSettingsFailure("Dory's daemon engine must be ready so running containers can be preserved before growth.")
            return
        }

        let runningWorkloads: [EngineSettingWorkload]
        do {
            runningWorkloads = try await captureRunningWorkloads()
        } catch {
            showSettingsFailure("Docker storage was not changed because running containers could not be verified: \(error)")
            return
        }
        do {
            let stopped = try await dorydClient.engineStop()
            guard stopped.ok else {
                let detail = stopped.message.isEmpty ? "doryd refused to stop the engine safely." : stopped.message
                let recovery = await recoverDorydRuntimeAndWorkloads(runningWorkloads)
                showSettingsFailure("Docker storage was not changed: \(detail) \(recovery)")
                return
            }
        } catch {
            let recovery = await recoverDorydRuntimeAndWorkloads(runningWorkloads)
            showSettingsFailure("Docker storage was not changed safely: \(error) \(recovery)")
            return
        }

        let grown: DockerDataDiskUsage
        do {
            grown = try await Task.detached {
                try Self.growSelectedDockerDataDisk(home: home, capacityGiB: capacityGiB)
            }.value
        } catch {
            let recovery = await recoverDorydRuntimeAndWorkloads(runningWorkloads)
            showSettingsFailure("Docker storage was not changed: \(error) \(recovery)")
            return
        }

        await prepareForDorydReconnect()
        await connectBackend()
        guard runtimeOwnedByDoryd, loadState == .ready else {
            showSettingsFailure(
                "Docker storage grew to \(grown.capacityGiB) GiB, but the engine did not reconnect. No additional containers were started."
            )
            return
        }
        let failures = await restartCapturedWorkloads(runningWorkloads)
        if failures.isEmpty {
            showSettingsSuccess("Docker storage grew to \(grown.capacityGiB) GiB and prior workloads were restored.")
        } else {
            showSettingsFailure(
                "Docker storage grew to \(grown.capacityGiB) GiB, but some prior workloads did not restart: "
                    + Self.workloadFailureSummary(failures)
            )
        }
    }

    func chooseExistingDataDrive() {
        guard !dataDriveOperationInFlight, !engineSettingChangeInFlight else {
            showSettingsFailure("Another data or engine operation is still running.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Use an Existing Dory Data Drive"
        panel.message = "Choose an initialized .dorydrive bundle. Dory verifies its identity before changing anything."
        panel.prompt = "Use Drive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dorydrive") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = environment["HOME"] ?? NSHomeDirectory()
        if let selected = try? DoryDataDriveSelectionStore(home: home).inspectSelection(),
           let candidate = try? DoryDataDrive(home: home, overrideRoot: url.path),
           selected.root == candidate.root {
            showSettingsSuccess("Dory is already using that data drive.")
            return
        }
        guard confirmDataDriveInterruption(
            title: "Change Dory's data drive?",
            message: "Dory will stop the engine and Linux machines, verify the selected drive, then restart the daemon and restore exactly the containers and machines that were running. The current drive is never deleted."
        ) else { return }
        Task { await selectExistingDataDrive(at: url) }
    }

    func chooseDataDriveBackupDestination() {
        guard !dataDriveOperationInFlight, !engineSettingChangeInFlight else {
            showSettingsFailure("Another data or engine operation is still running.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Back Up Dory Data"
        panel.message = "Creates a verified, resumable backup of images, containers, volumes, machines, snapshots, and settings."
        panel.prompt = "Back Up"
        panel.nameFieldStringValue = "Dory-\(Self.dataDriveBackupDate()).dorybackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorybackup") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showSettingsFailure("Existing backups are never overwritten. Choose a new backup name.")
            return
        }
        guard confirmDataDriveInterruption(
            title: "Back up the Dory data drive?",
            message: "Dory will briefly stop the engine and Linux machines to make a consistent backup, then restart the daemon and restore exactly the containers and machines that were running."
        ) else { return }
        Task { await backupSelectedDataDrive(to: url) }
    }

    func chooseDataDriveBackupToVerify() {
        guard !dataDriveOperationInFlight, !engineSettingChangeInFlight else {
            showSettingsFailure("Another data or engine operation is still running.")
            return
        }
        guard let url = chooseDataDriveBackup(title: "Verify Dory Backup", prompt: "Verify") else { return }
        Task { await verifyDataDriveBackup(at: url) }
    }

    func chooseDataDriveBackupToRestore() {
        guard !dataDriveOperationInFlight, !engineSettingChangeInFlight else {
            showSettingsFailure("Another data or engine operation is still running.")
            return
        }
        guard let archive = chooseDataDriveBackup(title: "Restore Dory Backup", prompt: "Choose Backup") else { return }
        let panel = NSSavePanel()
        panel.title = "Restore Dory Data Drive"
        panel.message = "Choose a new .dorydrive destination. Existing files are never overwritten."
        panel.prompt = "Restore"
        panel.nameFieldStringValue = "Restored Dory.dorydrive"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorydrive") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            showSettingsFailure("Restore destinations must be new. Choose a path that does not exist.")
            return
        }
        Task { await restoreDataDriveBackup(at: archive, to: destination) }
    }

    private func chooseDataDriveBackup(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dorybackup") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirmDataDriveInterruption(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private nonisolated static func dataDriveBackupDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private func backupSelectedDataDrive(to destination: URL) async {
        guard enginePreference == .dory else {
            showSettingsFailure("Switch to Dory's daemon engine before backing up its data drive.")
            return
        }
        dataDriveOperationInFlight = true
        engineSettingChangeInFlight = true
        dataDriveOperationStatus = "Stopping Dory safely for backup…"
        defer {
            dataDriveOperationInFlight = false
            engineSettingChangeInFlight = false
        }

        let workloads: DataDriveRuntimeState
        do {
            workloads = try await quiesceDorydForDataDriveOperation()
        } catch {
            await prepareForDorydReconnect()
            await connectBackend()
            dataDriveOperationStatus = "Backup was not started."
            showSettingsFailure("Dory could not prepare a consistent backup: \(error)")
            return
        }

        dataDriveOperationStatus = "Backing up and verifying every file…"
        let home = environment["HOME"] ?? NSHomeDirectory()
        let result: Result<DoryDataDriveArchiveVerification, Error>
        do {
            let verification = try await Task.detached(priority: .utility) {
                let selection = try DoryDataDriveSelectionStore(home: home)
                guard let drive = try selection.inspectSelection() else {
                    throw DoryDataDriveSelectionError.noSelection(selection.path)
                }
                return try DoryDataDriveTransaction.backup(from: drive, to: destination.path)
            }.value
            result = .success(verification)
        } catch {
            result = .failure(error)
        }

        let recovery = await reconnectAfterDataDriveOperation(workloads: workloads)
        switch result {
        case .success(let verification):
            dataDriveOperationStatus = "Backup verified at \(destination.path)."
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: verification.storedBytes), countStyle: .binary)
            if let recovery {
                showSettingsFailure("Backup verified (\(size)), but \(recovery)")
            } else {
                showSettingsSuccess("Dory data backup verified (\(size)).")
            }
        case .failure(let error):
            dataDriveOperationStatus = "Backup failed: \(error)"
            showSettingsFailure("Dory data was not backed up: \(error)\(recovery.map { " \($0)" } ?? "")")
        }
    }

    private func verifyDataDriveBackup(at archive: URL) async {
        dataDriveOperationInFlight = true
        dataDriveOperationStatus = "Verifying backup contents…"
        defer { dataDriveOperationInFlight = false }
        do {
            let verification = try await Task.detached(priority: .utility) {
                try DoryDataDriveArchive.verifyBackup(at: archive.path)
            }.value
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: verification.storedBytes), countStyle: .binary)
            dataDriveOperationStatus = "Backup verified: \(archive.path)"
            showSettingsSuccess("Backup is complete and valid: \(verification.entryCount) entries, \(size).")
        } catch {
            dataDriveOperationStatus = "Backup verification failed: \(error)"
            showSettingsFailure("Backup verification failed: \(error)")
        }
    }

    private func restoreDataDriveBackup(at archive: URL, to destination: URL) async {
        dataDriveOperationInFlight = true
        dataDriveOperationStatus = "Restoring and verifying the data drive…"
        defer { dataDriveOperationInFlight = false }
        let home = environment["HOME"] ?? NSHomeDirectory()
        do {
            let verification = try await Task.detached(priority: .utility) {
                let drive = try DoryDataDrive(home: home, overrideRoot: destination.path)
                return try DoryDataDriveTransaction.restore(at: archive.path, to: drive)
            }.value
            dataDriveOperationStatus = "Restored and verified: \(destination.path)"
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: verification.storedBytes), countStyle: .binary)
            showSettingsSuccess("Restored and verified \(size). Choose Use Existing… to switch to the restored drive.")
        } catch {
            dataDriveOperationStatus = "Restore failed: \(error)"
            showSettingsFailure("Dory data was not restored: \(error)")
        }
    }

    private func selectExistingDataDrive(at url: URL) async {
        guard enginePreference == .dory else {
            showSettingsFailure("Switch to Dory's daemon engine before changing its data drive.")
            return
        }
        dataDriveOperationInFlight = true
        engineSettingChangeInFlight = true
        dataDriveOperationStatus = "Stopping Dory safely before changing drives…"
        defer {
            dataDriveOperationInFlight = false
            engineSettingChangeInFlight = false
        }

        let workloads: DataDriveRuntimeState
        do {
            workloads = try await quiesceDorydForDataDriveOperation()
        } catch {
            await prepareForDorydReconnect()
            await connectBackend()
            dataDriveOperationStatus = "The selected drive was not changed."
            showSettingsFailure("Dory could not stop safely before changing drives: \(error)")
            return
        }

        dataDriveOperationStatus = "Verifying the selected drive and its identity…"
        let home = environment["HOME"] ?? NSHomeDirectory()
        let result: Result<DoryDataDrive, Error>
        do {
            let drive = try await Task.detached(priority: .utility) {
                try DoryDataDriveSelectionStore(home: home)
                    .bindExistingSelection(requestedRoot: url.path)
            }.value
            result = .success(drive)
        } catch {
            result = .failure(error)
        }

        let recovery = await reconnectAfterDataDriveOperation(workloads: workloads)
        switch result {
        case .success(let drive):
            dataDriveRevision += 1
            dataDriveOperationStatus = "Using \(drive.root)."
            if let recovery {
                showSettingsFailure("The data drive changed successfully, but \(recovery)")
            } else {
                showSettingsSuccess("Dory is now using the verified data drive at \(drive.root).")
            }
        case .failure(let error):
            dataDriveOperationStatus = "The selected drive was rejected: \(error)"
            showSettingsFailure("Dory kept the current data drive: \(error)\(recovery.map { " \($0)" } ?? "")")
        }
    }

    struct DataDriveRuntimeState: Sendable, Equatable {
        var containers: [EngineSettingWorkload]
        var machineIDs: [String]
    }

    func quiesceDorydForDataDriveOperation() async throws -> DataDriveRuntimeState {
        let engineStatus = try await dorydClient.engineStatus()
        let containers: [EngineSettingWorkload]
        if engineStatus.isRunning {
            guard runtimeOwnedByDoryd, loadState == .ready else {
                throw DoryDataDriveSelectionError.filesystem(
                    "Dory's running-container set is not ready to be verified"
                )
            }
            containers = try await captureRunningWorkloads()
        } else if engineStatus.state == "stopped" || engineStatus.state == "sleeping" {
            containers = []
        } else {
            throw DoryDataDriveSelectionError.filesystem(
                "Dory's engine is \(engineStatus.state); wait until it is fully running or stopped"
            )
        }
        let machineIDs = try await dorydClient.machineList()
            .filter { $0.state == "running" || $0.state == "starting" }
            .map(\.id)
            .sorted()
        guard managesDorydLaunchAgent else {
            throw DoryDataDriveSelectionError.filesystem("Dory cannot manage the installed daemon LaunchAgent")
        }
        guard await dorydLaunchAgentBootout() else {
            throw DoryDataDriveSelectionError.filesystem("Dory's daemon did not stop cleanly")
        }
        await prepareForDorydReconnect()
        return DataDriveRuntimeState(containers: containers, machineIDs: machineIDs)
    }

    /// Restarts doryd after a quiesced data operation and restores exactly the container and Linux
    /// machine sets that were running beforehand. A non-nil return describes remaining recovery.
    func reconnectAfterDataDriveOperation(workloads: DataDriveRuntimeState) async -> String? {
        await prepareForDorydReconnect()
        await connectBackend()
        guard runtimeOwnedByDoryd, loadState == .ready else {
            return "the daemon engine did not reconnect; no containers or Linux machines were restarted."
        }
        let containerFailures = await restartCapturedWorkloads(workloads.containers)
        let machineFailures = await restartCapturedMachines(workloads.machineIDs)
        guard containerFailures.isEmpty, machineFailures.isEmpty else {
            var details: [String] = []
            if !containerFailures.isEmpty {
                details.append("containers: \(Self.workloadFailureSummary(containerFailures))")
            }
            if !machineFailures.isEmpty {
                details.append("Linux machines: \(Self.workloadFailureSummary(machineFailures))")
            }
            return "some previously running workloads did not restart (\(details.joined(separator: "; ")))."
        }
        return nil
    }

    func refreshUpgradeStatus() async {
        let home = environment["HOME"] ?? NSHomeDirectory()
        do {
            let record = try await Task.detached(priority: .utility) {
                try DoryUpgradeTransactionStore(home: home).latest()
            }.value
            upgradeTransaction = record
            upgradeStatusError = nil
        } catch {
            upgradeTransaction = nil
            upgradeStatusError = "Upgrade evidence could not be read safely: \(error)"
        }
    }

    func upgradePreflightInput(candidate: DoryUpgradeCandidate) async throws -> DoryUpgradePreflightInput {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let selection = try DoryDataDriveSelectionStore(home: home)
        guard let drive = try selection.inspectSelection() else {
            throw DoryDataDriveSelectionError.noSelection(selection.path)
        }
        try drive.validateManifest()
        let estimatedBytes = try await Task.detached(priority: .utility) {
            try Self.allocatedBytes(at: drive.root)
        }.value
        let available = try Self.availableCapacity(at: home)
        let ports = await Self.allPublishedPorts(runtime)
            .compactMap(UInt16.init(exactly:))
            .sorted()
        let kube = await kubernetes.status()
        return DoryUpgradePreflightInput(
            candidate: candidate,
            priorVersion: AppInfo.version,
            priorBuild: AppInfo.build,
            drive: drive,
            hostAvailableBytes: available,
            dataDestinationAvailableBytes: available,
            estimatedDataSnapshotBytes: estimatedBytes,
            baselinePorts: ports,
            kubernetesExpected: kube.reachable
        )
    }

    func prepareUpgradeDataAndMarker(
        record: DoryUpgradeTransactionRecord,
        transactionStore: DoryUpgradeTransactionStore
    ) async throws {
        guard enginePreference == .dory else {
            throw DoryDataDriveSelectionError.filesystem(
                "switch to Dory's daemon engine before installing an app update so its durable runtime can be smoke-tested"
            )
        }
        if !runtimeOwnedByDoryd || loadState != .ready {
            await connectBackend()
        }
        guard runtimeOwnedByDoryd, loadState == .ready else {
            throw DoryDataDriveSelectionError.filesystem("Dory's managed engine is not ready for the update marker")
        }
        let marker = "dory-upgrade-\(record.id.uuidString.lowercased())"
        try await runtime.createVolume(
            name: marker,
            driver: nil,
            labels: [
                "dev.dory.upgrade.id": record.id.uuidString.lowercased(),
                "dev.dory.upgrade.prior-build": record.priorBuild,
                "dev.dory.upgrade.candidate-build": record.candidate.build,
            ],
            driverOptions: [:]
        )
        let ports = await Self.allPublishedPorts(runtime).compactMap(UInt16.init(exactly:)).sorted()
        let kube = await kubernetes.status()
        _ = try transactionStore.setRuntimeMarker(
            record.id,
            volume: marker,
            ports: ports,
            kubernetesExpected: kube.reachable
        )

        dataDriveOperationInFlight = true
        engineSettingChangeInFlight = true
        dataDriveOperationStatus = "Creating the verified last-good update snapshot…"
        defer {
            dataDriveOperationInFlight = false
            engineSettingChangeInFlight = false
        }
        let workloads: DataDriveRuntimeState
        do {
            workloads = try await quiesceDorydForDataDriveOperation()
        } catch {
            try? await runtime.removeVolumeForRollback(name: marker)
            throw error
        }
        let archive = transactionStore.dataBackupPath(record.id)
        let backupResult: Result<DoryDataDriveArchiveVerification, Error>
        do {
            let verification = try await Task.detached(priority: .utility) {
                let drive = try DoryDataDrive(home: transactionStore.home, overrideRoot: record.drivePath)
                return try DoryDataDriveTransaction.backup(from: drive, to: archive)
            }.value
            backupResult = .success(verification)
        } catch {
            backupResult = .failure(error)
        }
        let reconnectFailure = await reconnectAfterDataDriveOperation(workloads: workloads)
        if let reconnectFailure {
            throw DoryDataDriveSelectionError.filesystem(
                "the data snapshot completed, but runtime restoration failed: \(reconnectFailure)"
            )
        }
        switch backupResult {
        case .success:
            _ = try transactionStore.attachDataSnapshot(record.id, archivePath: archive)
            dataDriveOperationStatus = "Verified last-good snapshot ready."
        case .failure(let error):
            try? await runtime.removeVolumeForRollback(name: marker)
            throw error
        }
    }

    func runUpgradeSmokeTests(_ record: DoryUpgradeTransactionRecord) async -> [DoryUpgradeSmokeCheck] {
        if !runtimeOwnedByDoryd || loadState != .ready { await connectBackend() }
        var checks: [DoryUpgradeSmokeCheck] = []
        if Bundle.main.object(forInfoDictionaryKey: "DoryUpgradeGateForceSmokeFailure") as? Bool == true {
            do {
                let component = try await applyReleaseGateComponentUpdate(
                    operationID: record.id
                )
                checks.append(.init(
                    id: "release-gate.component-update",
                    passed: true,
                    detail: "activated signature-verified \(component.id.rawValue) \(component.version) before injected rollback"
                ))
            } catch {
                checks.append(.init(id: "release-gate.component-update", passed: false, detail: "\(error)"))
            }
        }
        do {
            let status = try await dorydClient.engineStatus()
            checks.append(.init(
                id: "engine.socket",
                passed: status.isRunning && Self.isUnixSocket(daemonSocketPath ?? ((environment["HOME"] ?? NSHomeDirectory()) + "/.dory/docker.sock")),
                detail: "doryd=\(status.state); \(status.detail)"
            ))
        } catch {
            checks.append(.init(id: "engine.socket", passed: false, detail: "\(error)"))
        }

        do {
            guard let response = await runtime.proxyRequest(
                method: "GET",
                path: "/version",
                headers: [],
                body: Data()
            ), response.isSuccess else {
                throw DoryDataDriveSelectionError.filesystem("Docker /version did not return success")
            }
            checks.append(.init(id: "docker.api", passed: true, detail: "Docker /version returned HTTP \(response.statusCode)"))
        } catch {
            checks.append(.init(id: "docker.api", passed: false, detail: "\(error)"))
        }

        do {
            let snapshot = try await runtime.migrationSnapshot()
            let marker = snapshot.volumes.first { volume in
                volume.name == record.markerVolume
                    && volume.labels["dev.dory.upgrade.id"] == record.id.uuidString.lowercased()
            }
            checks.append(.init(
                id: "volume.marker",
                passed: marker != nil,
                detail: marker == nil ? "pre-update marker volume or ownership label is missing" : "exact pre-update marker and ownership label survived"
            ))
        } catch {
            checks.append(.init(id: "volume.marker", passed: false, detail: "\(error)"))
        }

        if record.baselinePorts.isEmpty {
            checks.append(.init(id: "published.ports", required: false, passed: true, detail: "no published TCP port existed before the update"))
        } else {
            let results = await Task.detached(priority: .utility) {
                record.baselinePorts.map { ($0, Self.canConnectLoopback(port: $0, timeoutMilliseconds: 1_500)) }
            }.value
            let failed = results.filter { !$0.1 }.map { String($0.0) }
            checks.append(.init(
                id: "published.ports",
                passed: failed.isEmpty,
                detail: failed.isEmpty
                    ? "all pre-update loopback ports are connectable: \(record.baselinePorts.map(String.init).joined(separator: ","))"
                    : "pre-update loopback ports failed: \(failed.joined(separator: ","))"
            ))
        }

        let kube = await kubernetes.status()
        checks.append(.init(
            id: "kubernetes.api",
            required: record.kubernetesExpected,
            passed: !record.kubernetesExpected || kube.reachable,
            detail: record.kubernetesExpected ? kube.info : "Kubernetes was not reachable before the update"
        ))
        if Bundle.main.object(forInfoDictionaryKey: "DoryUpgradeGateForceSmokeFailure") as? Bool == true {
            checks.append(.init(
                id: "release-gate.injected",
                passed: false,
                detail: "signature-bound release fixture requested a post-install smoke failure"
            ))
        }
        return checks
    }

    private func applyReleaseGateComponentUpdate(
        operationID: UUID
    ) async throws -> DoryInstalledComponent {
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "DoryUpgradeGateComponentCatalogURL") as? String,
              let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
              ["127.0.0.1", "::1"].contains(url.host ?? ""),
              let rawID = Bundle.main.object(forInfoDictionaryKey: "DoryUpgradeGateComponentID") as? String,
              let id = DoryComponentID(rawValue: rawID), id.isRemovable else {
            throw DoryComponentError.invalidCatalog("signed release-gate component metadata is missing")
        }
        let store = try DoryComponentStore.selected(home: environment["HOME"] ?? NSHomeDirectory())
        try store.prepare()
        let client = DoryComponentCatalogClient(
            catalogURL: url,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: DoryComponentDefaults.architecture,
            appVersion: AppInfo.version
        )
        let fetched = try await client.fetch()
        _ = try store.cacheCatalog(
            data: fetched.data,
            signature: fetched.signature,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: DoryComponentDefaults.architecture,
            appVersion: AppInfo.version
        )
        guard let release = fetched.catalog.component(id) else {
            throw DoryComponentError.unknownComponent(rawID)
        }
        return try await DoryComponentInstaller(store: store).install(
            release,
            catalogData: fetched.data,
            operationID: operationID
        ) { _ in }
    }

    func removeUpgradeMarker(_ record: DoryUpgradeTransactionRecord) async {
        guard let marker = record.markerVolume else { return }
        try? await runtime.removeVolumeForRollback(name: marker)
    }

    nonisolated private static func allocatedBytes(at root: String) throws -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw DoryDataDriveSelectionError.filesystem("could not inventory Dory data allocation")
        }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let bytes = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
            let (next, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw DoryDataDriveSelectionError.filesystem("Dory data allocation exceeds supported accounting")
            }
            total = next
        }
        return total
    }

    nonisolated private static func availableCapacity(at path: String) throws -> UInt64 {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let value = values.volumeAvailableCapacityForImportantUsage, value > 0 else {
            throw DoryDataDriveSelectionError.filesystem("could not determine free space for the update transaction")
        }
        return UInt64(value)
    }

    nonisolated private static func isUnixSocket(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFSOCK
    }

    nonisolated private static func canConnectLoopback(port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, timeoutMilliseconds) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }

    /// Toggles FEX for x86_64 Linux applications inside the ARM64 container VM and restarts the
    /// shared engine. It never exposes an x86_64 guest OS or installer path.
    func setRosettaX86(_ on: Bool) async {
        guard on != rosettaX86Enabled else { return }
        guard !on || MacHostPlatform.current().isAppleSilicon else {
            showSettingsFailure("x86_64 Linux application compatibility is available only inside Dory's ARM64 engine on Apple Silicon; Dory does not ship an Intel engine.")
            return
        }
        guard !engineSettingChangeInFlight else {
            showSettingsFailure("Another engine setting is still being applied.")
            return
        }
        engineSettingChangeInFlight = true
        defer { engineSettingChangeInFlight = false }
        let previous = rosettaX86Enabled
        let previousGPU = gpuVenusEnabled
        rosettaX86Enabled = on
        if on, gpuVenusEnabled {
            gpuVenusEnabled = false
            UserDefaults.standard.set(false, forKey: SharedVMProvisioner.Config.gpuVenusKey)
        }
        UserDefaults.standard.set(on, forKey: SharedVMProvisioner.Config.rosettaX86Key)
        if await applyDorydOwnedEngineSetting(
            previousValue: previous,
            restore: { [weak self] value in
                self?.rosettaX86Enabled = value
                self?.gpuVenusEnabled = previousGPU
                UserDefaults.standard.set(value, forKey: SharedVMProvisioner.Config.rosettaX86Key)
                UserDefaults.standard.set(previousGPU, forKey: SharedVMProvisioner.Config.gpuVenusKey)
            },
            applyingMessage: on ? "Enabling x86_64 application compatibility…" : "Disabling x86_64 application compatibility…",
            successMessage: on && previousGPU
                ? "x86_64 application compatibility enabled. GPU acceleration was disabled to keep the required 4 KiB page size."
                : (on ? "x86_64 application compatibility enabled." : "x86_64 application compatibility disabled.")
        ) {
            return
        }
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = on ? "Enabling x86_64 application compatibility…" : "Disabling x86_64 application compatibility…"
        await SharedVMProvisioner.stopEngine()
        await connectBackend()
        showSettingsSuccess(on ? "x86_64 application compatibility enabled." : "x86_64 application compatibility disabled.")
    }

    /// Toggles experimental GPU acceleration (virtio-gpu/Venus) and restarts the shared engine so the
    /// virtio-gpu device is attached or removed at the next boot. No-op unless the shared engine is
    /// active; the Settings gate requires the dedicated arm64 GPU kernel and host Venus runtime.
    func setGPUVenus(_ on: Bool) async {
        guard on != gpuVenusEnabled else { return }
        guard !engineSettingChangeInFlight else {
            showSettingsFailure("Another engine setting is still being applied.")
            return
        }
        guard !on || gpuRuntimeAvailable else {
            showSettingsFailure("GPU acceleration is unavailable: the verified GPU kernel and Venus host runtime are required.")
            return
        }
        guard !on || !rosettaX86Enabled else {
            showSettingsFailure("GPU acceleration cannot be enabled while x86_64 application compatibility is on. FEX requires Dory's 4 KiB ARM64 guest kernel.")
            return
        }
        engineSettingChangeInFlight = true
        defer { engineSettingChangeInFlight = false }
        let previous = gpuVenusEnabled
        gpuVenusEnabled = on
        UserDefaults.standard.set(on, forKey: SharedVMProvisioner.Config.gpuVenusKey)
        if await applyDorydOwnedEngineSetting(
            previousValue: previous,
            restore: { [weak self] value in
                self?.gpuVenusEnabled = value
                UserDefaults.standard.set(value, forKey: SharedVMProvisioner.Config.gpuVenusKey)
            },
            applyingMessage: on ? "Enabling GPU acceleration…" : "Disabling GPU acceleration…",
            successMessage: on ? "GPU acceleration enabled." : "GPU acceleration disabled."
        ) {
            return
        }
        guard runtimeKind == .sharedVM || runtimeKind == .disconnected, !isConnecting else { return }
        sharedVMStatus = on ? "Enabling GPU acceleration…" : "Disabling GPU acceleration…"
        await SharedVMProvisioner.stopEngine()
        await connectBackend()
        showSettingsSuccess(on ? "GPU acceleration enabled." : "GPU acceleration disabled.")
    }

    struct EngineResourceLimits: Sendable, Equatable {
        var maximumCPUCount: Int
        var maximumMemoryMB: Int
    }

    nonisolated static func engineResourceLimits(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> EngineResourceLimits {
        let maximumCPUCount = max(1, min(activeProcessorCount, Int(UInt16.max)))
        let maximumMemoryMB = DoryEngineMemoryPolicy.maximumConfigurableMemoryMB(
            physicalMemory: physicalMemory
        )
        return EngineResourceLimits(
            maximumCPUCount: maximumCPUCount,
            maximumMemoryMB: maximumMemoryMB
        )
    }

    /// Applies Docker VM resource ceilings through the same workload-preserving transaction used
    /// for the other daemon-owned engine settings. Values outside the host-safe UI range are
    /// rejected instead of silently creating a LaunchAgent configuration the Mac cannot sustain.
    func setEngineResources(cpuCount: Int, memoryMB: Int) async {
        guard !engineSettingChangeInFlight else {
            showSettingsFailure("Another engine setting is still being applied.")
            return
        }
        let limits = Self.engineResourceLimits()
        guard (1...limits.maximumCPUCount).contains(cpuCount) else {
            showSettingsFailure("Engine CPU must be between 1 and \(limits.maximumCPUCount) cores on this Mac.")
            return
        }
        guard memoryMB.isMultiple(of: 1024),
              (2048...limits.maximumMemoryMB).contains(memoryMB) else {
            showSettingsFailure("Engine memory must be between 2 and \(limits.maximumMemoryMB / 1024) GB on this Mac.")
            return
        }
        guard cpuCount != engineCPUCount || memoryMB != engineMemoryMB else {
            showSettingsSuccess("Engine resources are already set to \(cpuCount) cores and \(memoryMB / 1024) GB.")
            return
        }

        engineSettingChangeInFlight = true
        defer { engineSettingChangeInFlight = false }
        let previous = EngineResources(cpuCount: engineCPUCount, memoryMB: engineMemoryMB)
        engineCPUCount = cpuCount
        engineMemoryMB = memoryMB
        UserDefaults.standard.set(cpuCount, forKey: Self.engineCPUCountKey)
        UserDefaults.standard.set(memoryMB, forKey: Self.engineMemoryMBKey)
        let applied = await applyDorydOwnedEngineSetting(
            previousValue: previous,
            restore: { [weak self] value in
                self?.engineCPUCount = value.cpuCount
                self?.engineMemoryMB = value.memoryMB
                UserDefaults.standard.set(value.cpuCount, forKey: Self.engineCPUCountKey)
                UserDefaults.standard.set(value.memoryMB, forKey: Self.engineMemoryMBKey)
            },
            applyingMessage: "Applying engine resources…",
            successMessage: "Engine resources set to \(cpuCount) cores and \(memoryMB / 1024) GB."
        )
        if !applied {
            engineCPUCount = previous.cpuCount
            engineMemoryMB = previous.memoryMB
            UserDefaults.standard.set(previous.cpuCount, forKey: Self.engineCPUCountKey)
            UserDefaults.standard.set(previous.memoryMB, forKey: Self.engineMemoryMBKey)
            showSettingsFailure("Switch to Dory's daemon engine before changing its CPU and memory.")
        }
    }

    private struct EngineResources: Sendable, Equatable {
        var cpuCount: Int
        var memoryMB: Int
    }

    /// Applies a daemon-owned engine setting as a small transaction: quiesce the engine using the
    /// long shutdown timeout, let launchd replace doryd with the new explicit environment, then
    /// reconnect and explicitly restart the exact containers that were running before the stop.
    /// Any failure restores the persisted value and makes one recovery attempt with the prior
    /// configuration so a rejected GPU/x86_64-application choice cannot strand the engine or user
    /// workloads.
    private func applyDorydOwnedEngineSetting<Value>(
        previousValue: Value,
        restore: @MainActor (Value) -> Void,
        applyingMessage: String,
        successMessage: String
    ) async -> Bool {
        guard dorydEngineEnabled, enginePreference == .dory else { return false }
        sharedVMStatus = applyingMessage
        var runningWorkloads: [EngineSettingWorkload] = []

        if runtimeOwnedByDoryd {
            do {
                runningWorkloads = try await captureRunningWorkloads()
            } catch {
                restore(previousValue)
                sharedVMStatus = "The running-container set could not be verified, so the engine setting was left unchanged."
                showSettingsFailure("Engine setting was not changed safely: \(error) \(sharedVMStatus)")
                return true
            }
            do {
                let stopped = try await dorydClient.engineStop()
                guard stopped.ok else {
                    restore(previousValue)
                    let detail = stopped.message.isEmpty ? "doryd refused to stop the engine safely." : stopped.message
                    let recovery = await recoverPreviousDorydConfigurationAndWorkloads(runningWorkloads)
                    sharedVMStatus = "Engine setting was not changed. \(recovery)"
                    showSettingsFailure("Engine setting was not changed: \(detail) \(recovery)")
                    return true
                }
            } catch {
                restore(previousValue)
                // A client timeout may arrive after shutdown completed, so always reconnect the old
                // configuration and restore the captured running set before reporting the failure.
                let recovery = await recoverPreviousDorydConfigurationAndWorkloads(runningWorkloads)
                sharedVMStatus = "Engine setting was not changed. \(recovery)"
                showSettingsFailure("Engine setting was not changed safely: \(error) \(recovery)")
                return true
            }
        }

        await prepareForDorydReconnect()
        await connectBackend()
        if runtimeOwnedByDoryd, loadState == .ready {
            let workloadFailures = await restartCapturedWorkloads(runningWorkloads)
            if workloadFailures.isEmpty {
                showSettingsSuccess(successMessage)
            } else {
                let summary = Self.workloadFailureSummary(workloadFailures)
                sharedVMStatus = "\(successMessage) Some previously running containers did not restart: \(summary)"
                showSettingsFailure(sharedVMStatus)
            }
            return true
        }

        let applyFailure = sharedVMStatus
        restore(previousValue)
        await prepareForDorydReconnect()
        await connectBackend()
        let recovered = runtimeOwnedByDoryd && loadState == .ready
        let workloadFailures = recovered ? await restartCapturedWorkloads(runningWorkloads) : []
        let recovery: String
        if !recovered {
            recovery = "The previous setting was restored, but the engine still needs recovery."
        } else if workloadFailures.isEmpty {
            recovery = "The previous setting was restored, the engine reconnected, and prior workloads were restarted."
        } else {
            recovery = "The previous setting was restored, but some prior workloads did not restart: "
                + Self.workloadFailureSummary(workloadFailures)
        }
        sharedVMStatus = "Engine setting was not applied. \(recovery)"
        let detail = applyFailure.isEmpty ? "doryd did not become ready." : applyFailure
        showSettingsFailure("Engine setting was not applied: \(detail) \(recovery)")
        return true
    }

    struct EngineSettingWorkload: Sendable, Equatable {
        var id: String
        var name: String
    }

    private func captureRunningWorkloads() async throws -> [EngineSettingWorkload] {
        let snapshot = try await runtime.snapshot()
        return snapshot.containers
            .filter(\.isRunning)
            .map { EngineSettingWorkload(id: $0.id, name: $0.name) }
    }

    private func prepareForDorydReconnect() async {
        runtimeOwnedByDoryd = false
        daemonSocketPath = nil
        runtime = DisconnectedRuntime()
        engineRunning = false
        try? await syncFinderStorageLocation(force: true)
    }

    private func recoverPreviousDorydConfigurationAndWorkloads(
        _ workloads: [EngineSettingWorkload]
    ) async -> String {
        await prepareForDorydReconnect()
        await connectBackend()
        guard runtimeOwnedByDoryd, loadState == .ready else {
            return "The previous setting was restored, but the engine still needs recovery."
        }
        let failures = await restartCapturedWorkloads(workloads)
        if failures.isEmpty {
            return "The previous setting was restored, the engine reconnected, and prior workloads were restarted."
        }
        return "The previous setting was restored, but some prior workloads did not restart: "
            + Self.workloadFailureSummary(failures)
    }

    private func recoverDorydRuntimeAndWorkloads(_ workloads: [EngineSettingWorkload]) async -> String {
        await prepareForDorydReconnect()
        await connectBackend()
        guard runtimeOwnedByDoryd, loadState == .ready else {
            return "The engine still needs recovery."
        }
        let failures = await restartCapturedWorkloads(workloads)
        if failures.isEmpty {
            return "The engine reconnected and prior workloads were restored."
        }
        return "The engine reconnected, but some prior workloads did not restart: "
            + Self.workloadFailureSummary(failures)
    }

    private nonisolated static func selectedDockerDataDiskUsage(home: String) throws -> DockerDataDiskUsage {
        let selectionStore = try DoryDataDriveSelectionStore(home: home)
        guard let drive = try selectionStore.inspectSelection() else {
            throw DoryDataDriveSelectionError.noSelection(selectionStore.path)
        }
        return try DockerDataDisk.usage(at: drive.engineDataDiskPath)
    }

    private nonisolated static func growSelectedDockerDataDisk(
        home: String,
        capacityGiB: Int
    ) throws -> DockerDataDiskUsage {
        let selectionStore = try DoryDataDriveSelectionStore(home: home)
        guard let drive = try selectionStore.inspectSelection() else {
            throw DoryDataDriveSelectionError.noSelection(selectionStore.path)
        }
        let lock = try EngineStateDirectoryLock(
            stateDirectory: drive.root,
            lockFileName: "drive.lock"
        )
        defer { withExtendedLifetime(lock) {} }
        return try DockerDataDisk.grow(
            destination: drive.engineDataDiskPath,
            capacityGiB: capacityGiB
        )
    }

    /// Docker accepts start for an already-running container (304), so issuing start for every
    /// captured ID handles both daemon auto-restart policies and containers left stopped after boot
    /// without touching anything that was stopped before the settings change.
    private func restartCapturedWorkloads(_ workloads: [EngineSettingWorkload]) async -> [String] {
        guard !workloads.isEmpty else { return [] }
        guard runtimeOwnedByDoryd, loadState == .ready else {
            return workloads.map { "\($0.name) (engine unavailable)" }
        }
        var failures: [String] = []
        for workload in workloads {
            do {
                try await runtime.start(containerID: workload.id)
            } catch {
                failures.append("\(workload.name) (\(error.localizedDescription))")
            }
        }
        await reload()
        return failures
    }

    /// doryd intentionally reloads persisted machine definitions in a stopped state. Restore only
    /// the IDs captured before shutdown so a user's deliberately stopped machines remain stopped.
    private func restartCapturedMachines(_ machineIDs: [String]) async -> [String] {
        guard !machineIDs.isEmpty else {
            loadMachines()
            return []
        }
        guard runtimeOwnedByDoryd, loadState == .ready else {
            return machineIDs.map { "\($0) (daemon unavailable)" }
        }
        var failures: [String] = []
        for machineID in machineIDs {
            do {
                try await refreshManagedDesktopKernelBeforeStart(machineID)
                _ = try await dorydClient.machineStart(machineID)
            } catch {
                failures.append("\(machineID) (\(error.localizedDescription))")
            }
        }
        loadMachines()
        return failures
    }

    /// Existing managed desktops retain their root disk across app/component upgrades. Refresh
    /// only Dory's copied direct-boot kernel before launch so renderer qualification is bound to
    /// the current verified runtime without touching the guest filesystem or user data.
    private func refreshManagedDesktopKernelBeforeStart(_ machineID: String) async throws {
        guard let status = try await dorydClient.machineList().first(where: {
            $0.id == machineID
        }) else {
            throw DesktopMachineAssetError.filesystem(
                "machine \(machineID) is unavailable"
            )
        }
        guard status.bootMode == .linuxKernel,
              status.displayMode == .desktop else {
            return
        }
        let typedSettings = status.typedSettings ?? DorydMachineTypedSettings(
            legacyEnvironment: status.environment,
            displayMode: status.displayMode
        )
        let distro = DesktopMachineDistro.resolve(
            typedSettings.guestIdentityIntent.desktop?.distributionIdentifier
        )
        let home = environment["HOME"] ?? NSHomeDirectory()
        let assets = try await desktopMachineAssetPreparer(
            home,
            Self.desktopAssetEnvironment(processEnvironment: environment, distro: distro),
            Bundle.main.resourcePath
        )
        let kernelPath = assets.kernelPath
        let kernelSHA256 = try await Task.detached(priority: .userInitiated) {
            try DesktopMachineAssetProvisioner.preparedKernelSHA256(at: kernelPath)
        }.value
        _ = try await dorydClient.machineRefreshManagedDesktopKernel(
            machineID,
            sourcePath: kernelPath,
            sourceSHA256: kernelSHA256
        )
    }

    private nonisolated static func workloadFailureSummary(_ failures: [String]) -> String {
        let visible = failures.prefix(3).joined(separator: ", ")
        let remaining = failures.count - min(failures.count, 3)
        return remaining > 0 ? "\(visible), and \(remaining) more" : visible
    }

    /// Selects Dory's daemon-owned local engine. doryd is the only production owner of this VM.
    func useSharedVM() async {
        guard runtimeKind != .sharedVM || !runtimeOwnedByDoryd else { return }
        let support = refreshSharedVMSupport()
        guard support.isSupported else {
            sharedVMStatus = Self.sharedVMUnavailableStatus(support)
            return
        }
        enginePreference = .dory
        UserDefaults.standard.set(EnginePreference.dory.rawValue, forKey: Self.enginePreferenceKey)
        await connectBackend()
    }

    private func stopShim() {
        shimServer?.stop()
        shimServer = nil
        shimRunning = false
    }

    var domainSuffix = AppStore.defaultDomainSuffix
    private let portForwarder = HostPortForwarder(targetHost: "127.0.0.1")
    @ObservationIgnored private lazy var hostBridge = HostBridgeWatcher(
        bridgeRoot: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge"),
        forwarder: portForwarder,
        enabled: openLoginsOnMac,
        open: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
    )
    private let domainTable = DomainTable()
    @ObservationIgnored private var dns = DoryDNS()
    @ObservationIgnored private let reverseProxy: DoryReverseProxy
    private var networkingStarted = false
    var localNetworkingActiveForTests: Bool { networkingStarted }
    private var portForwardingTask: Task<Void, Never>?


    /// On the shared VM, published container ports live on the VM's IP, not the host. Legacy
    /// app-managed engines keep a host-side forwarder + `*.dory.local` reverse proxy reconciled
    /// here. The doryd-managed engine owns route reconciliation inside the daemon.
    func startPortForwarding() {
        portForwardingTask?.cancel()
        guard runtimeKind == .sharedVM else { portForwarder.stopAll(); stopLocalNetworking(); return }
        if runtimeOwnedByDoryd {
            portForwarder.stopAll()
            stopLocalNetworking()
            return
        }
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
    static let defaultBridgeSubnetKey = "dory.defaultBridgeSubnet"
    nonisolated static let defaultDomainSuffix = "dory.local"
    nonisolated static let domainSuffixKey = "dory.domainSuffix"
    // User-configurable: 8080 collides with common dev servers, and MDM-managed DNS can't be pointed
    // at Dory, so the whole *.dory.local feature is turn-off-able (GitHub #2).
    var dnsPort: UInt16 = AppStore.defaultDNSPort
    var httpProxyPort: UInt16 = AppStore.defaultHTTPProxyPort
    var httpsProxyPort: UInt16 = AppStore.defaultHTTPSProxyPort
    var domainsEnabled = true
    var defaultBridgeSubnet = DoryIPv4BridgeNetwork.defaultCIDR
    var networkingAuthorizationInFlight = false
    var networkingAuthorizationMessage: String?
    var corporateConnectivityBusy = false
    var corporateConnectivityStatusJSON: String?
    var corporateConnectivityMessage: String?
    var customDomainRoutes: [DorydDomainRoute] = []
    var customDomainActiveHostnames: Set<String> = []
    var customDomainRoutesBusy = false
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
    }

    /// Applies changed networking settings (ports or the domains toggle): full teardown then restart
    /// so listeners rebind on the new ports and machine bridges are re-registered cleanly. Restarting
    /// through startPortForwarding cancels and re-drives the reconcile task, avoiding a double-register.
    func applyNetworkingSettings(
        dnsPort: UInt16? = nil,
        httpProxyPort: UInt16? = nil,
        httpsProxyPort: UInt16? = nil,
        domainsEnabled: Bool? = nil,
        domainSuffix: String? = nil
    ) {
        guard domainsEnabled == nil || !networkingAuthorizationInFlight else {
            showSettingsFailure("Wait for the current networking change to finish.")
            return
        }
        var launchAgentNeedsRefresh = false
        var suffixChanged = false
        var domainsChanged = false
        if let domainSuffix {
            guard let normalized = Self.normalizedDomainSuffix(domainSuffix) else {
                networkingAuthorizationMessage = "Use a DNS-style suffix such as dev.dory.local."
                showSettingsFailure("Use a DNS-style suffix such as dev.dory.local.")
                return
            }
            if normalized != self.domainSuffix {
                self.domainSuffix = normalized
                UserDefaults.standard.set(normalized, forKey: Self.domainSuffixKey)
                suffixChanged = true
                launchAgentNeedsRefresh = true
            }
        }
        if let dnsPort { self.dnsPort = dnsPort; UserDefaults.standard.set(Int(dnsPort), forKey: Self.dnsPortKey) }
        if let httpProxyPort { self.httpProxyPort = httpProxyPort; UserDefaults.standard.set(Int(httpProxyPort), forKey: Self.httpProxyPortKey) }
        if let httpsProxyPort { self.httpsProxyPort = httpsProxyPort; UserDefaults.standard.set(Int(httpsProxyPort), forKey: Self.httpsProxyPortKey) }
        if let domainsEnabled, domainsEnabled != self.domainsEnabled {
            self.domainsEnabled = domainsEnabled
            UserDefaults.standard.set(domainsEnabled, forKey: Self.domainsEnabledKey)
            domainsChanged = true
            launchAgentNeedsRefresh = true
        }
        stopLocalNetworking()
        if suffixChanged {
            domainTable.replaceContainers([:])
            domainTable.replaceKube([:])
            dns = DoryDNS(suffix: self.domainSuffix)
        }
        startPortForwarding()
        let refreshRequired = dnsPort != nil || httpProxyPort != nil || httpsProxyPort != nil
            || launchAgentNeedsRefresh
        if domainsChanged, !self.domainsEnabled, managesDorydLaunchAgent {
            disableDaemonOwnedDomains()
            return
        }
        if refreshRequired {
            Task { [weak self] in
                guard let self else { return }
                if await refreshDorydLaunchAgentForNetworkingSettings() {
                    showSettingsSuccess("Networking settings applied.")
                } else {
                    showSettingsFailure("doryd could not apply the selected networking settings.")
                }
            }
            return
        }
        showSettingsSuccess("Networking settings applied.")
    }

    private func disableDaemonOwnedDomains() {
        guard !networkingAuthorizationInFlight else { return }
        networkingAuthorizationInFlight = true
        networkingAuthorizationMessage = "Removing Dory's system domain routing…"
        Task { [weak self] in
            guard let self else { return }
            var authorizationRemoved = false
            do {
                try await authorizedNetworkingRemover()
                authorizationRemoved = true
                var trustRemovalNotice: String?
                do {
                    _ = try localCATrustManager.remove(
                        certificateAt: URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent(".dory/ca/ca.crt").path
                    )
                } catch {
                    trustRemovalNotice = error.localizedDescription
                }
                guard await refreshDorydLaunchAgentForNetworkingSettings() else {
                    throw NetworkingAuthorizationUIError.cleanupFailed(
                        "doryd could not restart with local domains disabled."
                    )
                }
                if let trustRemovalNotice {
                    networkingAuthorizationMessage = "Local domains and their system routing are disabled, but Dory could not remove its CA from your login keychain: \(trustRemovalNotice)"
                    showSettingsFailure("Local domains are disabled, but local CA cleanup needs attention.")
                } else {
                    networkingAuthorizationMessage = "Local domains and their system routing are disabled."
                    showSettingsSuccess("Local domains disabled.")
                }
            } catch {
                domainsEnabled = true
                UserDefaults.standard.set(true, forKey: Self.domainsEnabledKey)
                _ = await refreshDorydLaunchAgentForNetworkingSettings()
                let detail = error.localizedDescription
                if authorizationRemoved {
                    networkingAuthorizationMessage = "System routing was removed safely, but doryd could not keep local domains disabled. Reauthorize before using local domains again."
                } else {
                    networkingAuthorizationMessage = "Local domains stayed enabled because their system routing could not be removed: \(detail)"
                }
                showSettingsFailure("Local domains were not disabled: \(detail)")
            }
            networkingAuthorizationInFlight = false
        }
    }

    private func refreshDorydLaunchAgentForNetworkingSettings() async -> Bool {
        guard managesDorydLaunchAgent else { return true }
        return await dorydLaunchAgentEnsurer(dorydLaunchAgentConfiguration())
    }

    func setDefaultBridgeSubnet(_ rawValue: String) async {
        guard !engineSettingChangeInFlight else {
            showSettingsFailure("Another engine setting is still being applied.")
            return
        }
        let network: DoryIPv4BridgeNetwork
        do {
            network = try DoryIPv4BridgeNetwork(rawValue)
        } catch {
            showSettingsFailure(String(describing: error))
            return
        }
        guard network.cidr != defaultBridgeSubnet else {
            showSettingsSuccess("Docker bridge subnet is already \(network.cidr).")
            return
        }

        engineSettingChangeInFlight = true
        defer { engineSettingChangeInFlight = false }
        let previous = defaultBridgeSubnet
        defaultBridgeSubnet = network.cidr
        UserDefaults.standard.set(network.cidr, forKey: Self.defaultBridgeSubnetKey)
        let applied = await applyDorydOwnedEngineSetting(
            previousValue: previous,
            restore: { [weak self] value in
                self?.defaultBridgeSubnet = value
                UserDefaults.standard.set(value, forKey: Self.defaultBridgeSubnetKey)
            },
            applyingMessage: "Applying Docker bridge subnet…",
            successMessage: "Docker bridge subnet changed to \(network.cidr). Existing data was preserved."
        )
        if !applied {
            defaultBridgeSubnet = previous
            UserDefaults.standard.set(previous, forKey: Self.defaultBridgeSubnetKey)
            showSettingsFailure("Switch to Dory's engine before changing its Docker bridge subnet.")
        }
    }

    private func dorydLaunchAgentConfiguration() -> DorydLaunchAgent.Configuration {
        DorydLaunchAgent.Configuration(
            domainsEnabled: domainsEnabled,
            domainSuffix: domainSuffix,
            dnsPort: dnsPort,
            httpProxyPort: httpProxyPort,
            httpsProxyPort: httpsProxyPort,
            hostCLIEnabled: routeDockerCLI,
            vmQualificationBootstrapEnabled: AppInfo.vmQualificationBootstrapEnabled,
            amd64EmulationEnabled: rosettaX86Enabled && MacHostPlatform.current().isAppleSilicon,
            gpuVenusEnabled: gpuVenusEnabled,
            cpuCount: UInt16(clamping: engineCPUCount),
            memoryMB: UInt32(clamping: engineMemoryMB),
            bridgeSubnetCIDR: defaultBridgeSubnet,
            sshAuthSock: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        )
    }

    nonisolated static func normalizedDomainSuffix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var suffix = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while suffix.hasSuffix(".") {
            suffix.removeLast()
        }
        guard suffix.count <= 253 else { return nil }
        let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
            for scalar in label.unicodeScalars {
                let value = scalar.value
                let valid = (48...57).contains(value) || (97...122).contains(value) || value == 45
                guard valid else { return nil }
            }
        }
        return suffix
    }

    nonisolated static func normalizedCustomDomainPattern(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        let hostname: String
        if value.hasPrefix("*.") {
            hostname = String(value.dropFirst(2))
        } else {
            guard !value.contains("*") else { return nil }
            hostname = value
        }
        guard hostname.count <= 253 else { return nil }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else {
                return nil
            }
            for scalar in label.unicodeScalars {
                let value = scalar.value
                guard (48...57).contains(value) || (97...122).contains(value) || value == 45 else {
                    return nil
                }
            }
        }
        return value
    }

    func loadCustomDomainRoutes() async {
        guard dorydRuntimeActive else {
            customDomainRoutes = []
            customDomainActiveHostnames = []
            return
        }
        do {
            let status = try await dorydClient.networkStatus()
            customDomainRoutes = status.customRoutes.sorted { $0.hostname < $1.hostname }
            let configured = Set(customDomainRoutes.map(\.hostname))
            customDomainActiveHostnames = Set(status.routes.map(\.hostname)).intersection(configured)
        } catch {
            showSettingsFailure("Custom domains could not be loaded: \(error.localizedDescription)")
        }
    }

    func addCustomDomainRoute(hostname rawHostname: String, publishedPort: UInt16) async {
        guard let hostname = Self.normalizedCustomDomainPattern(rawHostname) else {
            showSettingsFailure("Use a DNS hostname such as admin.myproject.local or *.myproject.local.")
            return
        }
        let comparable = hostname.hasPrefix("*.") ? String(hostname.dropFirst(2)) : hostname
        guard comparable != domainSuffix, !comparable.hasSuffix(".\(domainSuffix)") else {
            showSettingsFailure("That hostname is already covered by *.\(domainSuffix).")
            return
        }
        var routes = customDomainRoutes.filter { $0.hostname != hostname }
        routes.append(DorydDomainRoute(hostname: hostname, address: "127.0.0.1", port: publishedPort))
        await replaceCustomDomainRoutes(routes, success: "Custom domain \(hostname) is configured for published port \(publishedPort).")
    }

    func removeCustomDomainRoute(_ route: DorydDomainRoute) async {
        await replaceCustomDomainRoutes(
            customDomainRoutes.filter { $0.hostname != route.hostname },
            success: "Custom domain \(route.hostname) removed."
        )
    }

    private func replaceCustomDomainRoutes(_ routes: [DorydDomainRoute], success: String) async {
        guard dorydRuntimeActive else {
            showSettingsFailure("Switch to Dory's engine before changing custom domains.")
            return
        }
        guard !customDomainRoutesBusy else { return }
        customDomainRoutesBusy = true
        defer { customDomainRoutesBusy = false }
        do {
            _ = try await dorydClient.networkReplaceRoutes(routes)
            let status = try await dorydClient.networkStatus()
            customDomainRoutes = status.customRoutes.sorted { $0.hostname < $1.hostname }
            let configured = Set(customDomainRoutes.map(\.hostname))
            customDomainActiveHostnames = Set(status.routes.map(\.hostname)).intersection(configured)
            showSettingsSuccess(success)
        } catch {
            showSettingsFailure("Custom domains were not changed: \(error.localizedDescription)")
        }
    }

    private static func persistedRuntimeMode(environment: [String: String]) -> String? {
        let rawPath = environment["DORY_CONFIG"] ?? "\(NSHomeDirectory())/.dory/config.json"
        let path = (rawPath as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = object["runtimeMode"] as? String else {
            return nil
        }
        switch mode {
        case "always-on", "auto-idle", "battery-saver", "manual":
            return mode
        default:
            return nil
        }
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
        networkingStarted = false
    }

    func registerMachineBridge(_ name: String) {
        try? FileManager.default.createDirectory(atPath: MachineService.bridgeHostDir(for: name), withIntermediateDirectories: true)
        hostBridge.startWatching(machine: name)
    }

    func unregisterMachineBridge(_ name: String) {
        hostBridge.stopWatching(machine: name)
        portForwarder.teardownLoopback(forMachine: name)
    }

    /// `<name>.dory.local` → the published host port that reaches the container. Containers without a
    /// published port are skipped (their domain has no web endpoint to route to yet).
    private static func containerEndpoints(_ runtime: any ContainerRuntime, suffix: String) async -> [String: Int] {
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/json", headers: [], body: Data()),
              response.isSuccess else { return [:] }
        struct Entry: Decodable { let Names: [String]?; let Ports: [PortItem]? }
        struct PortItem: Decodable { let PublicPort: Int?; let `Type`: String? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: response.body) else { return [:] }
        var result: [String: Int] = [:]
        for entry in entries {
            let publishedPorts = (entry.Ports ?? []).compactMap { item -> Int? in
                let proto = (item.Type ?? "tcp").lowercased()
                guard proto == "tcp" || proto == "tcp6" else { return nil }
                return item.PublicPort
            }
            guard let port = publishedPorts.min() else { continue }
            let backendPort = effectivePublishedPort(port)
            for raw in entry.Names ?? [] {
                let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
                guard !name.isEmpty else { continue }
                result["\(name).\(suffix)".lowercased()] = backendPort
            }
            if port == 80 {
                result["localhost"] = backendPort
                result["127.0.0.1"] = backendPort
            }
        }
        return result
    }

    nonisolated static func effectivePublishedPort(_ port: Int) -> Int {
        guard port > 0, port < 1024 else { return port }
        return 60_000 + port
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

    func authorizeLocalNetworking() async {
        await setLocalNetworkingAuthorization(removing: false)
    }

    func deauthorizeLocalNetworking() async {
        await setLocalNetworkingAuthorization(removing: true)
    }

    func loadCorporateConnectivity(runProbes: Bool = false) async {
        guard runtimeOwnedByDoryd else {
            corporateConnectivityMessage = "Start Dory's daemon-managed engine to inspect corporate connectivity."
            return
        }
        guard !corporateConnectivityBusy else { return }
        corporateConnectivityBusy = true
        defer { corporateConnectivityBusy = false }
        do {
            let json = try await dorydClient.corporateConnectivityStatus(runProbes: runProbes)
            corporateConnectivityStatusJSON = json
            corporateConnectivityMessage = Self.corporateConnectivitySummary(json)
        } catch {
            corporateConnectivityMessage = error.localizedDescription
        }
    }

    func applyCorporateConnectivity(profileJSON: String, dryRun: Bool) async {
        guard runtimeOwnedByDoryd else {
            corporateConnectivityMessage = "Start Dory's daemon-managed engine before changing corporate connectivity."
            return
        }
        guard !corporateConnectivityBusy else { return }
        corporateConnectivityBusy = true
        defer { corporateConnectivityBusy = false }
        do {
            let json = try await dorydClient.corporateConnectivityApply(
                profileJSON: profileJSON,
                dryRun: dryRun
            )
            corporateConnectivityStatusJSON = json
            corporateConnectivityMessage = Self.corporateConnectivitySummary(json)
            let valid = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["valid"] as? Bool ?? false
            if valid, !dryRun {
                showSettingsSuccess("Corporate connectivity profile applied and reconciled.")
            } else if !valid {
                showSettingsFailure("Corporate connectivity validation failed. Review the detailed message before applying.")
            }
        } catch {
            corporateConnectivityMessage = error.localizedDescription
            showSettingsFailure(error.localizedDescription)
        }
    }

    func disableCorporateConnectivity() async {
        guard runtimeOwnedByDoryd else { return }
        guard !corporateConnectivityBusy else { return }
        corporateConnectivityBusy = true
        defer { corporateConnectivityBusy = false }
        do {
            let json = try await dorydClient.corporateConnectivityDisable()
            corporateConnectivityStatusJSON = json
            corporateConnectivityMessage = Self.corporateConnectivitySummary(json)
            showSettingsSuccess("Dory-owned corporate proxy, registry, and guest CA settings were disabled.")
        } catch {
            corporateConnectivityMessage = error.localizedDescription
            showSettingsFailure(error.localizedDescription)
        }
    }

    nonisolated private static func corporateConnectivitySummary(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return "doryd returned an unreadable corporate connectivity status."
        }
        if object["valid"] as? Bool == false {
            return (object["validationErrors"] as? [String] ?? ["profile is invalid"]).joined(separator: " • ")
        }
        let enabled = object["enabled"] as? Bool ?? false
        let probes = object["probes"] as? [[String: Any]] ?? []
        let passed = probes.filter { $0["succeeded"] as? Bool == true }.count
        let system = object["system"] as? [String: Any]
        let interface = system?["defaultInterface"] as? String ?? "unknown route"
        let tunnels = system?["tunnelInterfaces"] as? [String] ?? []
        return enabled
            ? "Valid profile • \(passed)/\(probes.count) probes passed • route \(interface)" + (tunnels.isEmpty ? "" : " • tunnels \(tunnels.joined(separator: ", "))")
            : "Corporate connectivity profile is disabled."
    }

    private func setLocalNetworkingAuthorization(removing: Bool) async {
        guard runtimeOwnedByDoryd else {
            networkingAuthorizationMessage = "Start Dory's daemon-managed engine before changing local-domain authorization."
            return
        }
        guard !networkingAuthorizationInFlight else { return }
        networkingAuthorizationInFlight = true
        networkingAuthorizationMessage = nil
        defer { networkingAuthorizationInFlight = false }

        do {
            // Register and obtain macOS approval before installing persistent resolver/PF state.
            // Otherwise doryd immediately tries to reconcile through a service launchd still
            // considers unavailable, leaving a partial authorization and noisy XPC incidents.
            if !removing {
                try Self.ensurePrivilegedNetworkDaemon()
            }
            guard let helper = Self.bundledHelper("dory-network-helper") else {
                throw NetworkingAuthorizationUIError.helperMissing
            }
            let plan = try await dorydClient.networkAuthorizationPlan()
            guard let certificatePath = Self.localCACertificatePath(in: plan) else {
                throw NetworkingAuthorizationUIError.invalidLocalCARequest
            }
            var installedTrustForAttempt = false
            if !removing {
                installedTrustForAttempt = try localCATrustManager.install(
                    certificateAt: certificatePath
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedPlan = try encoder.encode(plan).base64EncodedString()
            let operation = removing ? " --remove" : ""
            // Feed the immutable plan through the privileged command's standard input. A
            // user-writable temporary file would leave a race between the admin prompt and the
            // root helper opening the plan.
            let command = "/usr/bin/printf %s \(Self.shellQuote(encodedPlan)) | /usr/bin/base64 -D | \(Self.shellQuote(helper)) --plan-json - --owner-uid \(getuid())\(operation)"
            let script = "do shell script \(Self.appleScriptString(command)) with administrator privileges"
            let result = await Shell.runAsyncResult("/usr/bin/osascript", ["-e", script])
            if result.exit == 0 {
                if removing {
                    do {
                        _ = try localCATrustManager.remove(certificateAt: certificatePath)
                    } catch {
                        networkingAuthorizationMessage = "Dory removed its resolver and PF rules, but could not remove the local CA from your login keychain: \(error.localizedDescription) Try Remove authorization again."
                        return
                    }
                }
                networkingAuthorizationMessage = Self.networkingAuthorizationSuccessMessage(
                    plan,
                    removing: removing
                )
            } else {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                var message = output.isEmpty ? "Local domain authorization was cancelled or failed." : output
                if installedTrustForAttempt {
                    do {
                        _ = try localCATrustManager.remove(certificateAt: certificatePath)
                    } catch {
                        message += " Dory could not remove the local CA it added to your login keychain: \(error.localizedDescription)"
                    }
                }
                networkingAuthorizationMessage = message
            }
        } catch {
            networkingAuthorizationMessage = "Local domain authorization failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func networkingAuthorizationSuccessMessage(
        _ plan: DorydNetworkingAuthorizationPlan,
        removing: Bool
    ) -> String {
        if removing {
            return "Dory-owned resolver, PF reference, and local CA trust were removed for \(plan.suffix)."
        }
        return "Dory networking is authorized for \(plan.suffix). \(networkingAuthorizationSummary(plan))"
    }

    nonisolated static func localCACertificatePath(
        in plan: DorydNetworkingAuthorizationPlan,
        home: String = NSHomeDirectory()
    ) -> String? {
        let requests = plan.requests.filter { $0.id == "trust.local-ca" && $0.kind == "localCATrust" }
        guard requests.count == 1, let path = requests[0].filePath else { return nil }
        let expected = URL(fileURLWithPath: home)
            .appendingPathComponent(".dory/ca/ca.crt")
            .standardizedFileURL.path
        guard URL(fileURLWithPath: path).standardizedFileURL.path == expected else { return nil }
        return expected
    }

    nonisolated static func networkingAuthorizationSummary(_ plan: DorydNetworkingAuthorizationPlan) -> String {
        let forwards = plan.privilegedTCPForwards.sorted {
            if $0.listenPort == $1.listenPort { return $0.targetPort < $1.targetPort }
            return $0.listenPort < $1.listenPort
        }
        guard !forwards.isEmpty else {
            return "Standard 80/443 redirects point to doryd's local proxies; no extra low TCP publishes were detected."
        }
        let shown = forwards.prefix(4)
            .map { "\($0.listenPort) -> \($0.targetPort)" }
            .joined(separator: ", ")
        let remaining = forwards.count - 4
        let suffix = remaining > 0 ? ", +\(remaining) more" : ""
        return "Standard 80/443 plus low TCP redirects: \(shown)\(suffix)."
    }

    nonisolated private static func bundledHelper(_ name: String) -> String? {
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundleURL.appendingPathComponent("Helpers/\(name)").path,
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: auxiliary) {
            return auxiliary
        }
        return nil
    }

    nonisolated static func ensurePrivilegedNetworkDaemon() throws {
        guard privilegedNetworkDaemonAssetsAvailable() else {
            throw NetworkingAuthorizationUIError.daemonMissing
        }
        let service = SMAppService.daemon(plistName: "dev.dory.network-helper.plist")
        let status = service.status
        if privilegedNetworkDaemonNeedsRegistration(status) {
            try registerPrivilegedNetworkDaemon(service)
            return
        }
        switch status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw NetworkingAuthorizationUIError.daemonApprovalRequired
        case .notRegistered, .notFound:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        @unknown default:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        }
    }

    nonisolated static func refreshPrivilegedNetworkDaemonFromCurrentBundle() async throws {
        guard privilegedNetworkDaemonAssetsAvailable() else {
            throw NetworkingAuthorizationUIError.daemonMissing
        }
        let service = SMAppService.daemon(plistName: "dev.dory.network-helper.plist")
        let status = service.status
        if privilegedNetworkDaemonNeedsRegistration(status) {
            try registerPrivilegedNetworkDaemon(service)
            return
        }
        switch status {
        case .enabled, .requiresApproval:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        case .notRegistered, .notFound:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        @unknown default:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        }

        try registerPrivilegedNetworkDaemon(service)
    }

    nonisolated static func privilegedNetworkDaemonNeedsRegistration(
        _ status: SMAppService.Status
    ) -> Bool {
        switch status {
        case .notRegistered, .notFound:
            return true
        case .enabled, .requiresApproval:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated private static func privilegedNetworkDaemonAssetsAvailable() -> Bool {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/dev.dory.network-helper.plist")
        return FileManager.default.isReadableFile(atPath: plist.path)
            && bundledHelper("dory-network-helper") != nil
    }

    nonisolated private static func registerPrivilegedNetworkDaemon(_ service: SMAppService) throws {
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw NetworkingAuthorizationUIError.daemonApprovalRequired
            }
            throw NetworkingAuthorizationUIError.daemonRegistrationFailed(error.localizedDescription)
        }

        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw NetworkingAuthorizationUIError.daemonApprovalRequired
        case .notRegistered, .notFound:
            throw NetworkingAuthorizationUIError.daemonRegistrationFailed(
                "macOS did not retain the networking service registration."
            )
        @unknown default:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        }
    }

    nonisolated static func unregisterPrivilegedNetworkDaemon() async throws {
        let service = SMAppService.daemon(plistName: "dev.dory.network-helper.plist")
        switch service.status {
        case .enabled:
            try await removeOwnedNetworkingWithBundledHelper()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        case .requiresApproval:
            guard !privilegedNetworkingStateExists() else {
                SMAppService.openSystemSettingsLoginItems()
                throw NetworkingAuthorizationUIError.daemonApprovalRequired
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        case .notRegistered, .notFound:
            guard !privilegedNetworkingStateExists() else {
                throw NetworkingAuthorizationUIError.cleanupFailed(
                    "Dory networking state still exists but its privileged service is not available."
                )
            }
            return
        @unknown default:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        }
    }

    nonisolated private static func removeOwnedNetworkingWithBundledHelper() async throws {
        try await runBundledNetworkingRemoval(
            argument: "--remove-owned-networking",
            stateStillExists: privilegedNetworkingStateExists
        )
    }

    nonisolated private static func removeAuthorizedNetworkingIfPresent() async throws {
        let service = SMAppService.daemon(plistName: "dev.dory.network-helper.plist")
        switch service.status {
        case .enabled:
            try await runBundledNetworkingRemoval(
                argument: "--remove-authorized-networking",
                stateStillExists: authorizedNetworkingStateExists
            )
        case .requiresApproval:
            guard !authorizedNetworkingStateExists() else {
                SMAppService.openSystemSettingsLoginItems()
                throw NetworkingAuthorizationUIError.daemonApprovalRequired
            }
        case .notRegistered, .notFound:
            guard !authorizedNetworkingStateExists() else {
                throw NetworkingAuthorizationUIError.cleanupFailed(
                    "Dory's domain networking is authorized but its privileged service is unavailable."
                )
            }
        @unknown default:
            throw NetworkingAuthorizationUIError.daemonUnavailable
        }
    }

    nonisolated private static func runBundledNetworkingRemoval(
        argument: String,
        stateStillExists: @Sendable () -> Bool
    ) async throws {
        guard let helper = bundledHelper("dory-network-helper") else {
            throw NetworkingAuthorizationUIError.helperMissing
        }
        let result = await Shell.runAsyncResult(helper, [argument])
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exit == 0,
              output == "network-authorization=removed"
                || output == "network-authorization=absent" else {
            throw NetworkingAuthorizationUIError.cleanupFailed(
                output.isEmpty ? "The privileged helper returned exit \(result.exit)." : output
            )
        }
        guard !stateStillExists() else {
            throw NetworkingAuthorizationUIError.cleanupFailed(
                "The privileged helper returned success but Dory networking files still exist."
            )
        }
    }

    nonisolated private static func privilegedNetworkingStateExists() -> Bool {
        authorizedNetworkingStateExists() || [
            "/etc/pf.anchors/dev.dory.lan",
            "/var/run/dev.dory/pf-enable-token",
            "/var/run/dev.dory/ipv4-forwarding-owner",
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func authorizedNetworkingStateExists() -> Bool {
        let configuredSuffix = normalizedDomainSuffix(
            UserDefaults.standard.string(forKey: domainSuffixKey)
        ) ?? defaultDomainSuffix
        return [
            "/private/var/db/dev.dory/network-authorization.json",
            "/private/var/db/dev.dory/local-ca.crt",
            "/etc/pf.anchors/dev.dory",
            "/etc/resolver/\(configuredSuffix)",
            "/var/run/dev.dory/system-pf-enable-token",
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }

    nonisolated private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private enum NetworkingAuthorizationUIError: LocalizedError {
        case helperMissing
        case invalidLocalCARequest
        case daemonMissing
        case daemonApprovalRequired
        case daemonUnavailable
        case daemonRegistrationFailed(String)
        case cleanupFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "dory-network-helper is missing from Dory.app."
            case .invalidLocalCARequest:
                return "Dory's networking service returned an invalid local CA request."
            case .daemonMissing:
                return "Dory's privileged networking service is missing from the app bundle. Reinstall Dory."
            case .daemonApprovalRequired:
                return "Dory opened Login Items. Enable Dory's networking service there, return to Dory, then click Authorize again."
            case .daemonUnavailable:
                return "Dory's privileged networking service is unavailable."
            case .daemonRegistrationFailed(let detail):
                return "Dory could not register its privileged networking service: \(detail)"
            case .cleanupFailed(let detail):
                return "Dory could not remove its owned networking state: \(detail)"
            }
        }
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
        let domainAvailable = runtimeOwnedByDoryd ? domainsEnabled : domainTable.backend(for: host) != nil
        if !runtimeOwnedByDoryd && !domainAvailable { ensureKubeProxy() }
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
            do {
                try process.run()
            } catch {
                continuation.yield(LogLine(
                    timestamp: "",
                    level: .error,
                    message: "Could not stream pod logs: \(error.localizedDescription)"
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
        }
    }

    static func kubeErrorText(_ error: KubeError) -> String {
        switch error {
        case .kubectlMissing: "kubectl is unavailable. Install or repair the Kubernetes component, then try again."
        case .nonZero(_, let stderr): stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .decode: "Could not read the cluster response."
        }
    }

    var kubernetesBusy = false

    /// One-click Kubernetes: bootstraps k3s inside Dory's shared VM and wires the host kubeconfig.
    func enableKubernetes() async {
        guard AppInfo.componentAvailable(.kubernetes) else {
            kubernetesInfo = "Install Kubernetes in Components before enabling the cluster."
            actionError = kubernetesInfo
            section = .components
            return
        }
        guard runtimeKind == .sharedVM else { kubernetesInfo = "Kubernetes needs Dory's shared VM engine"; return }
        guard !kubernetesBusy else { return }
        kubernetesBusy = true
        defer { kubernetesBusy = false }
        do {
            try await KubernetesProvisioner.enable(
                runtime: runtime,
                image: KubeVersionCatalog.version(forTag: kubernetesVersionTag).image,
                amd64Emulation: rosettaX86Enabled
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
        guard !runtimeOwnedByDoryd else {
            stopShim()
            return
        }
        guard shimServer == nil else { return }
        var shim = DockerShim(runtime: runtime)
        // Only Dory's own engine sleeps; external/custom sockets are always-on, so leave the tracker
        // and wake unwired there (the shim then never records activity or tries to wake).
        let activity: ShimActivity? = runtimeKind == .sharedVM ? engineActivity : nil
        if runtimeKind == .sharedVM {
            shim.activity = engineActivity
            shim.onWake = { [weak self] in await self?.ensureEngineAwake() }
        }
        let server = ShimHTTPServer(socketPath: DockerShim.defaultSocketPath, activity: activity) { request in await shim.handle(request) }
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
            try? await syncFinderStorageLocation(force: true)
            return
        }
        await applyRuntimeSnapshot(snap, synchronizeFinderStorage: true)
    }

    private func reloadWithoutExtendingEngineIdle() async {
        guard runtimeOwnedByDoryd, let docker = runtime as? DockerEngineRuntime,
              let payload = try? await dorydClient.engineDashboardSnapshot(),
              let snapshot = try? docker.dashboardSnapshot(from: payload) else {
            return
        }
        await applyRuntimeSnapshot(snapshot, synchronizeFinderStorage: false)
    }

    private func applyRuntimeSnapshot(
        _ snap: RuntimeSnapshot,
        synchronizeFinderStorage: Bool
    ) async {
        if containers != snap.containers { containers = snap.containers; syncMachineStats(); noteEngineActivity() }
        if images != snap.images { images = snap.images; noteEngineActivity() }
        if volumes != snap.volumes { volumes = snap.volumes }
        if networks != snap.networks { networks = snap.networks }
        if runtimeKind == .mock, pods != snap.pods { pods = snap.pods }
        if engineRunning != snap.engineRunning { engineRunning = snap.engineRunning }
        if engineVersion != snap.engineVersion { engineVersion = snap.engineVersion }
        reconcileContainerSelection()
        let liveIDs = Set(containers.map(\.id))
        for container in containers where container.isRunning {
            recordCPU(container.id, container.cpuPercent)
        }
        cpuHistory = cpuHistory.filter { liveIDs.contains($0.key) }
        let newState: LoadState = snap.engineRunning ? .ready : .engineOff
        if loadState != newState { loadState = newState }
        if synchronizeFinderStorage {
            try? await syncFinderStorageLocation()
        }
    }

    var canBrowseDoryStorage: Bool {
        runtimeOwnedByDoryd && engineRunning && !engineSleeping && loadState == .ready
    }

    func openDoryStorageInFinder() async {
        guard canBrowseDoryStorage else {
            actionError = "Start Dory's engine before opening its storage in Finder."
            return
        }
        do {
            try await syncFinderStorageLocation(force: true)
            try await finderStorageLocation.openInFinder()
            finderStorageLocationActive = true
        } catch {
            finderStorageLocationActive = false
            actionError = "Dory storage could not be opened in Finder: \(error.localizedDescription)"
        }
    }

    private func syncFinderStorageLocation(force: Bool = false) async throws {
        // An injected test environment can intentionally omit XCTest's variables while exercising
        // a real-shaped runtime. The host-process classification is authoritative: tests must
        // never register, hide, materialize, or publish into the user's live File Provider domain.
        guard !isAutomationContext else { return }
        guard canBrowseDoryStorage, let docker = runtime as? DockerEngineRuntime else {
            await finderStorageLocation.hide()
            finderStorageLocationActive = false
            lastFinderStorageGroups = nil
            lastFinderStorageRefresh = .distantPast
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastFinderStorageRefresh) >= 15 else { return }
        lastFinderStorageRefresh = now
        let snapshot = try await docker.storageInventory()
        if force || snapshot.groups != lastFinderStorageGroups {
            try finderStorageLocation.publish(snapshot)
            lastFinderStorageGroups = snapshot.groups
        }
        try await finderStorageLocation.show()
        finderStorageLocationActive = true
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
        if await syncDorydEngineStateBeforeDockerPoll() { return }
        // A sleeping engine should not be polled through Docker; leave it alone until a user action
        // or an external docker request wakes it through doryd's data plane.
        if engineSleeping { return }
        capEngineLogIfDue()
        if runtimeOwnedByDoryd {
            await reloadWithoutExtendingEngineIdle()
        } else {
            await reload()
        }
        loadMachines()
        if runtimeKind == .sharedVM { await loadKubernetes() }
        await evaluateIdleSleep()
    }

    /// Refresh for the menu-bar popover. Reads only non-waking data (process memory, the doryd machine
    /// list, and doryd's engine state) before touching Docker, then skips the Docker/Kubernetes poll
    /// while the engine sleeps — so opening the popover never wakes a slept engine.
    func refreshMenuBar() async {
        await refreshProcessMemory()
        loadMachines()
        if await syncDorydEngineStateBeforeDockerPoll() { return }
        if engineSleeping { return }
        if runtimeOwnedByDoryd {
            await reloadWithoutExtendingEngineIdle()
        } else {
            await reload()
        }
        if runtimeKind == .sharedVM { await loadKubernetes() }
    }

    private func syncDorydEngineStateBeforeDockerPoll() async -> Bool {
        guard runtimeOwnedByDoryd else { return engineSleeping }
        guard let status = try? await dorydClient.engineStatus() else { return engineSleeping }

        switch status.state {
        case "sleeping":
            engineSleeping = true
            engineActivity.setSleeping(true)
            engineRunning = false
            sharedVMStatus = "Sleeping — Docker use wakes it."
            try? await syncFinderStorageLocation(force: true)
            return true
        case "running":
            engineSleeping = false
            engineRunning = true
            loadState = .ready
            engineActivity.setSleeping(false)
            engineActivity.touch()
            sharedVMStatus = status.detail.isEmpty ? "Running through doryd" : status.detail
            return false
        case "starting":
            engineSleeping = false
            engineActivity.setSleeping(false)
            engineRunning = false
            loadState = .connecting
            sharedVMStatus = status.detail.isEmpty ? "Starting the engine…" : status.detail
            return true
        case "stopped", "failed", "unconfigured":
            engineSleeping = false
            engineActivity.setSleeping(false)
            engineRunning = false
            loadState = .engineOff
            sharedVMStatus = status.detail.isEmpty ? "doryd engine is \(status.state)." : status.detail
            try? await syncFinderStorageLocation(force: true)
            return true
        default:
            return engineSleeping
        }
    }

    // MARK: - In-app Auto-Idle (sleep the engine while the app is open)

    let engineActivity = ShimActivity()
    @ObservationIgnored private var wakeTask: Task<Void, Never>?

    /// Records engine use so the idle countdown restarts. Called from GUI actions; external docker
    /// use is recorded by the shim directly on `engineActivity`.
    func noteEngineActivity() { engineActivity.touch() }

    /// Restarts the engine if the idle monitor slept it. Concurrent callers coalesce onto one wake so
    /// a burst of docker requests boots the VM exactly once. A failed wake leaves `engineSleeping`
    /// true so the next request retries rather than proxying to a dead socket.
    func ensureEngineAwake() async {
        guard engineSleeping else { return }
        if wakeTask == nil {
            wakeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if self.engineSleeping {
                    self.sharedVMStatus = "Waking Dory's engine…"
                    if self.runtimeOwnedByDoryd {
                        let result = try? await self.dorydClient.engineWake()
                        if result?.ok == true {
                            await self.connectBackend()
                        } else {
                            self.sharedVMStatus = result?.message ?? "doryd could not wake the engine."
                        }
                    } else {
                        await self.connectBackend()
                    }
                    if self.loadState == .ready {
                        self.engineSleeping = false
                        self.engineActivity.setSleeping(false)
                        self.engineActivity.touch()
                        if !self.runtimeOwnedByDoryd {
                            SharedVMProvisioner.recordIncident("wake", "woke on demand after idle sleep")
                        }
                    }
                }
                self.wakeTask = nil
            }
        }
        await wakeTask?.value
    }

    /// Decides whether the idle engine may sleep. Conservative on purpose: only when the app is not
    /// frontmost, in an idle runtime mode, engine ready, nothing running, and no in-flight docker
    /// request — so a live workload, an active user, or a running build/pull never loses the engine.
    /// In-app operations that drive the engine directly (bypassing the shim's connection counter):
    /// `compose up`, a container action, a migration, a k8s or volume-browse op. While any is in
    /// flight the engine must stay awake, or the idle monitor could stop it mid-operation.
    private var isEngineBusyInApp: Bool {
        composeBusy || doryBuildActive || !pendingContainerIDs.isEmpty || kubernetesBusy || migrationBusy || volumeBrowseBusy || machineBusy
    }

    private func evaluateIdleSleep() async {
        guard !runtimeOwnedByDoryd else { return }
        guard runtimeKind == .sharedVM, !engineSleeping, !isConnecting, loadState == .ready else { return }
        guard runtimeMode == "auto-idle" || runtimeMode == "battery-saver" else { return }
        if NSApp.isActive || runningCount > 0 || isEngineBusyInApp { engineActivity.touch(); return }
        let (active, last) = engineActivity.snapshot
        guard active == 0 else { return }
        let minutes = max(1, idlePolicy.sleepAfterMinutes)
        guard Date().timeIntervalSince(last) >= TimeInterval(minutes * 60) else { return }
        await sleepEngineForIdle(minutes: minutes)
    }

#if DEBUG
    func evaluateIdleSleepForTests() async {
        await evaluateIdleSleep()
    }
#endif

    private func sleepEngineForIdle(minutes: Int) async {
        guard !engineSleeping else { return }
        // Claim the sleep on the MainActor (both flags flip together, no await between), then re-check
        // that nothing is in flight. A docker request that slipped in either already bumped `active`
        // (we abort and stay awake) or, having arrived after, sees the sleeping flag and wakes us.
        engineSleeping = true
        engineActivity.setSleeping(true)
        guard engineActivity.snapshot.active == 0 else {
            engineSleeping = false
            engineActivity.setSleeping(false)
            return
        }
        stopAutoRefresh()
        sharedVMStatus = "Sleeping — idle \(minutes) min. Docker use wakes it."
        if runtimeOwnedByDoryd {
            let result = try? await dorydClient.engineSleep()
            guard result?.ok == true else {
                engineSleeping = false
                engineActivity.setSleeping(false)
                sharedVMStatus = result?.message ?? "doryd could not sleep the engine."
                startAutoRefresh()
                return
            }
        } else {
            await SharedVMProvisioner.stopEngine()
            SharedVMProvisioner.recordIncident("idle-sleep", "engine slept after \(minutes) min idle (app open, nothing running)")
        }
        engineRunning = false
        try? await syncFinderStorageLocation(force: true)
    }

    @ObservationIgnored private var lastLogCap = Date.distantPast
    private func capEngineLogIfDue() {
        guard runtimeKind == .sharedVM else { return }
        guard Date().timeIntervalSince(lastLogCap) > 60 else { return }
        lastLogCap = Date()
        Task.detached { SharedVMProvisioner.capEngineLog() }
    }

    var selectedContainer: Container? {
        filteredContainers.first { $0.id == selectedContainerID }
    }

    func reconcileContainerSelection() {
        let visible = filteredContainers
        guard !visible.isEmpty else {
            selectedContainerID = nil
            return
        }
        if let selectedContainerID, visible.contains(where: { $0.id == selectedContainerID }) { return }
        selectedContainerID = visible[0].id
    }

    func revealContainer(_ container: Container, scope: ContainerScope) {
        section = .containers
        setContainerScope(scope)
        if !filteredContainers.contains(where: { $0.id == container.id }) {
            containerFilter = .all
        }
        selectedContainerID = container.id
        isContainerInspectorVisible = true
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
        case .builds:
            "\(buildActivity.filter(\.isActive).count) active · \(buildActivity.count) retained · \(DockerFormat.bytes(buildCacheUsage.totalBytes)) cache"
        case .kubernetes:
            pods.isEmpty ? "Cluster not enabled" : "\(pods.count) pods across \(Set(pods.map(\.namespace)).count) namespaces"
        case .desktops:
            machineSubtitle(for: .desktop, noun: "desktop")
        case .machines:
            machineSubtitle(for: .headless, noun: "server")
        case .components: "Docker Core with optional, removable feature packs"
        case .health: healthSubtitle
        case .settings: "Dory v\(AppInfo.version)"
        }
    }

    private func machineSubtitle(for displayMode: MachineDisplayMode, noun: String) -> String {
        let matching = machines.filter { $0.displayMode == displayMode }
        return "\(matching.count) \(noun)\(matching.count == 1 ? "" : "s") · \(matching.filter { $0.status == .running }.count) running"
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
        let snapshot = await HealthDiagnostics.load(active: active, dorydClient: dorydClient)
        // Only the most recently started load may publish; a slower passive run must not clobber a
        // fresher active snapshot (or vice versa).
        if token == healthLoadToken {
            healthSnapshot = snapshot
        }
        if active { healthActiveLoading = false } else { healthLoading = false }
    }

    func refreshProcessMemory() async {
        processMemorySnapshot = await Task.detached(priority: .utility) {
            DoryProcessMemorySampler.snapshot()
        }.value
    }

    private func startProcessMemoryRefresh() {
        processMemoryTask?.cancel()
        guard !isAutomationContext else {
            processMemoryTask = nil
            return
        }
        processMemoryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshProcessMemory()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func runHealthRepair() async {
        await runRepairTarget("all")
    }

    func collectHealthSupportBundle(active: Bool = false) async {
        guard !healthSupportBundleInFlight, !healthActionInFlight else { return }
        healthSupportBundleInFlight = true
        healthSupportBundlePath = nil
        healthSupportBundleMessage = nil
        healthActionError = nil
        let result = await HealthDiagnostics.collectSupportBundle(active: active)
        if result.ok, let bundle = result.bundle {
            healthSupportBundlePath = bundle.path
            healthSupportBundleMessage = bundle.share
        } else {
            healthActionError = result.output.isEmpty ? "Support bundle collection failed" : result.output
        }
        healthSupportBundleInFlight = false
    }

    func runRepairTarget(_ target: String) async {
        guard !healthActionInFlight else { return }
        healthActionInFlight = true
        healthActionError = nil
        var daemonFailure: String?
        var repairedByDaemon = false
        if ["socket", "dns", "routes", "domains", "ports", "dockerd", "guest-agent", "data-drive"].contains(target) {
            do {
                let result = try await dorydClient.repairSubsystem(target)
                repairedByDaemon = true
                if !result.ok {
                    healthActionError = result.message.isEmpty ? "Repair \(target) failed" : result.message
                }
            } catch {
                // The daemon may simply not be running, so the CLI path still runs. Its reason is
                // retained: if the fallback fails too, the daemon error is the useful diagnosis.
                daemonFailure = "\(error)"
            }
        }
        if !repairedByDaemon {
            let result = await HealthDiagnostics.runControl(["repair", target, "--apply"])
            if !result.ok {
                let output = result.output.isEmpty ? "Repair \(target) failed" : result.output
                healthActionError = daemonFailure.map { "\(output) (doryd repair also failed: \($0))" } ?? output
            }
        }
        healthActionInFlight = false
        await loadHealth()
    }

    var canRestartEngineForHealth: Bool {
        (runtimeKind == .sharedVM || runtimeKind == .disconnected) && !isConnecting
    }

    func restartEngineForHealth() async {
        guard canRestartEngineForHealth, !healthActionInFlight else { return }
        healthActionInFlight = true
        healthActionError = nil
        await restartEngine()
        healthActionInFlight = false
        await loadHealth()
    }

    func loadIdlePolicy() async {
        if let status = try? await dorydClient.idleStatus() {
            applyIdleStatus(status)
            return
        }
        guard !dorydEngineRequired else {
            idlePolicyLoaded = false
            return
        }
        let result = await HealthDiagnostics.runControl(["idle", "status", "--json"], timeout: 8)
        guard let data = result.output.data(using: .utf8),
              let status = try? JSONDecoder().decode(IdleStatus.self, from: data) else { return }
        applyIdleStatus(status)
    }

    func setRuntimeMode(_ mode: String) async {
        guard mode != runtimeMode, !idlePolicyBusy else { return }
        idlePolicyBusy = true
        defer { idlePolicyBusy = false }
        do {
            let status = try await dorydClient.idleSetMode(mode)
            applyIdleStatus(status)
            await confirmRuntimeModeApplied(status)
            return
        } catch {
            if dorydEngineRequired {
                showSettingsFailure("doryd did not apply the idle mode: \(error)")
                await loadIdlePolicy()
                return
            }
        }
        let result = await HealthDiagnostics.runControl(["idle", "mode", mode])
        if !result.ok {
            showSettingsFailure(result.output.isEmpty ? "Idle mode was not changed." : result.output)
            await loadIdlePolicy()
            return
        }
        await loadIdlePolicy()
        if let status = try? await dorydClient.idleStatus() {
            await confirmRuntimeModeApplied(status)
        } else {
            showSettingsSuccess("\(Self.runtimeModeLabel(runtimeMode)) applied.")
        }
    }

    func setIdleSleepAfter(_ minutes: Int) async {
        guard minutes != idlePolicy.sleepAfterMinutes, !idlePolicyBusy else { return }
        idlePolicyBusy = true
        defer { idlePolicyBusy = false }
        do {
            let status = try await dorydClient.idleSetPolicy(key: "sleepAfterMinutes", value: String(minutes))
            applyIdleStatus(status)
            showSettingsSuccess("Idle sleep now waits \(minutes) minute\(minutes == 1 ? "" : "s").")
            return
        } catch {
            if dorydEngineRequired {
                showSettingsFailure("doryd did not apply the idle policy: \(error)")
                await loadIdlePolicy()
                return
            }
        }
        let result = await HealthDiagnostics.runControl(["idle", "set", "sleepAfterMinutes", String(minutes)])
        if !result.ok {
            showSettingsFailure(result.output.isEmpty ? "Idle policy was not changed." : result.output)
            await loadIdlePolicy()
            return
        }
        await loadIdlePolicy()
        showSettingsSuccess("Idle sleep now waits \(minutes) minute\(minutes == 1 ? "" : "s").")
    }

    func setIdleFlag(_ key: String, _ on: Bool) async {
        guard !idlePolicyBusy else { return }
        idlePolicyBusy = true
        defer { idlePolicyBusy = false }
        do {
            let status = try await dorydClient.idleSetPolicy(key: key, value: on ? "on" : "off")
            applyIdleStatus(status)
            showSettingsSuccess("\(Self.idlePolicyLabel(key)) \(on ? "enabled" : "disabled").")
            return
        } catch {
            if dorydEngineRequired {
                showSettingsFailure("doryd did not apply the idle policy: \(error)")
                await loadIdlePolicy()
                return
            }
        }
        let result = await HealthDiagnostics.runControl(["idle", "set", key, on ? "on" : "off"])
        if !result.ok {
            showSettingsFailure(result.output.isEmpty ? "Idle policy was not changed." : result.output)
            await loadIdlePolicy()
            return
        }
        await loadIdlePolicy()
        showSettingsSuccess("\(Self.idlePolicyLabel(key)) \(on ? "enabled" : "disabled").")
    }

    private func applyIdleStatus(_ status: IdleStatus) {
        runtimeMode = status.mode
        idlePolicy = status.policy ?? .fallback
        idlePolicyLoaded = true
    }

    private func confirmRuntimeModeApplied(_ status: IdleStatus) async {
        let label = Self.runtimeModeLabel(status.mode)
        if runtimeOwnedByDoryd, Self.runtimeModeKeepsEngineAwake(status.mode) {
            guard status.engineState?.state == "running" else {
                let detail = status.engineState?.detail ?? "doryd did not return a confirmed engine state"
                showSettingsFailure("\(label) was not confirmed: \(detail)")
                return
            }
            engineSleeping = false
            engineRunning = true
            engineActivity.setSleeping(false)
            await connectBackend()
            guard loadState == .ready else {
                let detail = sharedVMStatus.isEmpty ? "Docker did not answer after the engine started." : sharedVMStatus
                showSettingsFailure("\(label) was saved, but Docker did not reconnect: \(detail)")
                return
            }
        }
        showSettingsSuccess("\(label) applied.")
    }

    private static func runtimeModeKeepsEngineAwake(_ mode: String) -> Bool {
        mode == "always-on" || mode == "manual"
    }

    private static func runtimeModeLabel(_ mode: String) -> String {
        switch mode {
        case "always-on": return "Always On"
        case "auto-idle": return "Auto-Idle"
        case "battery-saver": return "Battery Saver"
        case "manual": return "Manual Stop"
        default: return mode
        }
    }

    private static func idlePolicyLabel(_ key: String) -> String {
        switch key {
        case "keepPublishedPortsAwake": return "Published-port keep-awake"
        case "keepKubernetesAwake": return "Kubernetes keep-awake"
        case "keepPinnedProjectsAwake": return "Pinned-project keep-awake"
        case "showWakeNotifications": return "Wake notifications"
        default: return key
        }
    }

    func loadLanVisible() {
        lanVisible = SharedVMProvisioner.lanVisibleFromConfig()
    }

    func setLanVisible(_ on: Bool) async {
        guard on != lanVisible else { return }
        if on {
            do {
                try Self.ensurePrivilegedNetworkDaemon()
            } catch {
                showSettingsFailure(error.localizedDescription)
                return
            }
        }
        lanVisible = on
        let result = await HealthDiagnostics.runControl(["network", "--lan-visible", on ? "on" : "off"])
        if !result.ok {
            loadLanVisible()
            showSettingsFailure(result.output.isEmpty ? "LAN access was not changed." : result.output)
            return
        }
        showSettingsSuccess(on
            ? "Source-preserving LAN access is enabled for published ports."
            : "Published ports are localhost-only.")
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
        Task { await composeProjectOperation(.start, name: name) }
    }

    func stopComposeProject(_ name: String) {
        Task { await composeProjectOperation(.stop, name: name) }
    }

    func restartComposeProject(_ name: String) {
        Task { await composeProjectOperation(.restart, name: name) }
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

    func fetchLogs(_ id: String) async -> [LogLine] {
        do {
            return try await runtime.logs(containerID: id)
        } catch {
            actionError = "Could not read logs for this container: \(error.localizedDescription)"
            return []
        }
    }

    func fetchEnv(_ id: String) async -> [EnvVar] {
        do {
            return try await runtime.env(containerID: id)
        } catch {
            actionError = "Could not read the environment for this container: \(error.localizedDescription)"
            return []
        }
    }

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
        noteEngineActivity()
        await ensureEngineAwake()
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
            let isMock = runtimeKind == .mock
            c.status = .running
            c.cpuPercent = isMock ? 1.2 : 0
            c.memoryDisplay = isMock ? (c.memoryLimitDisplay == "2 GB" ? "128 MB" : "96 MB") : "—"
            c.memoryFraction = isMock ? 0.08 : 0
            c.memoryBytes = isMock ? (c.memoryLimitDisplay == "2 GB" ? 134_217_728 : 100_663_296) : 0
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
        guard !composeBusy else { actionError = "Another Compose operation is already running"; return }
        composeBusy = true
        actionError = nil
        composeStatus = "Validating \(fileURL.lastPathComponent) with Docker Compose v2…"
        defer { composeBusy = false }
        do {
            let cli = try composeCLI()
            let context = try await cli.resolve(files: Self.composeFileURLs(for: fileURL))
            composeStatus = "Starting \(context.name) with Docker Compose v2…"
            try await cli.up(context)
            await reload()
            let services = containers(inComposeProject: context.name)
            composeStatus = "\(context.name): \(services.count) container\(services.count == 1 ? "" : "s") started"
            containerScope = .compose
            section = .containers
            selectedContainerID = services.first?.id ?? selectedContainerID
        } catch is CancellationError {
            composeStatus = ""
        } catch {
            actionError = "Compose up failed: \(error.localizedDescription)"
            composeStatus = ""
        }
    }

    func composeDown(_ name: String) async {
        guard runtimeKind.isDockerCompatible else { actionError = "Compose needs Dory's shared VM or a Docker engine"; return }
        guard !composeBusy else { actionError = "Another Compose operation is already running"; return }
        composeBusy = true
        actionError = nil
        composeStatus = "Stopping \(name)…"
        defer { composeBusy = false }
        do {
            let cli = try composeCLI()
            let snapshot = try await runtime.snapshot()
            let context = try ComposeCLI.context(projectName: name, containers: snapshot.containers)
            try await cli.down(context)
            await reload()
            composeStatus = ""
        } catch is CancellationError {
            composeStatus = ""
        } catch {
            actionError = "Compose down failed: \(error.localizedDescription)"
            composeStatus = ""
        }
    }

    private func composeProjectOperation(_ operation: ComposeProjectOperation, name: String) async {
        guard runtimeKind.isDockerCompatible else {
            actionError = "Compose needs Dory's shared VM or a Docker engine"
            return
        }
        guard !composeBusy else {
            actionError = "Another Compose operation is already running"
            return
        }
        composeBusy = true
        actionError = nil
        let progressVerb = switch operation {
        case .start: "Starting"
        case .stop: "Stopping"
        case .restart: "Restarting"
        }
        composeStatus = "\(progressVerb) \(name)…"
        defer { composeBusy = false }
        do {
            let cli = try composeCLI()
            let snapshot = try await runtime.snapshot()
            let context = try ComposeCLI.context(projectName: name, containers: snapshot.containers)
            var services: [String] = []
            if operation == .restart {
                let running = snapshot.containers.filter {
                    $0.composeProject == name && $0.isRunning
                }
                guard running.allSatisfy({ $0.composeService != nil }) else {
                    throw ComposeCLIError.invalidMetadata(
                        "Compose project \(name) has a running container without a service label; no resources were changed"
                    )
                }
                services = Array(Set(running.compactMap(\.composeService))).sorted()
                guard !services.isEmpty else { composeStatus = ""; return }
            }
            try await cli.perform(operation, context: context, services: services)
            await reload()
            composeStatus = ""
        } catch is CancellationError {
            composeStatus = ""
        } catch {
            actionError = "Compose \(operation.rawValue) failed: \(error.localizedDescription)"
            composeStatus = ""
        }
    }

    private func composeCLI() throws -> ComposeCLI {
        guard let executable = HostDockerCLI.bundledTool("docker-compose") else {
            throw ComposeCLIError.helperUnavailable
        }
        guard let docker = runtime as? DockerEngineRuntime else {
            throw ComposeCLIError.socketUnavailable
        }
        return ComposeCLI(
            executableURL: URL(fileURLWithPath: executable),
            socketPath: docker.socketPath,
            baseEnvironment: environment,
            runner: composeCommandRunner
        )
    }

    nonisolated static func composeFileURLs(for fileURL: URL) -> [URL] {
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

    func buildImage(contextDir: URL, tag: String) -> AsyncStream<String> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                defer {
                    if self.activeBuildToken == token {
                        self.activeBuildTask = nil
                        self.activeBuildToken = nil
                        self.doryBuildActive = false
                    }
                    Task { await self.refreshBuildActivity() }
                }
                guard self.runtimeKind.isDockerCompatible else {
                    continuation.yield("ERROR: Image build needs Dory's shared VM or a Docker engine")
                    continuation.finish()
                    return
                }
                do {
                    let cli = try self.buildxCLI()
                    continuation.yield("Building with Docker Buildx…")
                    try await cli.build(contextDirectory: contextDir, tag: tag) { line in
                        continuation.yield(line)
                    }
                    try Task.checkCancellation()
                    await self.reload()
                    continuation.yield("Build complete.")
                } catch is CancellationError {
                    continuation.yield("Build cancelled.")
                } catch {
                    continuation.yield("ERROR: \(error.localizedDescription)")
                }
                continuation.finish()
            }
            activeBuildToken = token
            activeBuildTask = task
            doryBuildActive = true
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancelDoryBuild() {
        guard doryBuildActive else { return }
        activeBuildTask?.cancel()
    }

    func refreshBuildActivity() async {
        guard runtimeKind.isDockerCompatible else {
            buildActivity = []
            buildCacheUsage = .empty
            buildActivityError = "Build activity needs Dory's engine or another Docker-compatible backend."
            return
        }
        guard !buildActivityLoading else { return }
        buildActivityLoading = true
        defer { buildActivityLoading = false }
        do {
            let cli = try buildxCLI()
            async let records = cli.history()
            async let cache = cli.cacheUsage()
            let (loadedRecords, loadedCache) = try await (records, cache)
            buildActivity = loadedRecords.sorted { $0.createdAt > $1.createdAt }
            buildCacheUsage = loadedCache
            buildActivityError = nil
            if let selectedBuildReference,
               !buildActivity.contains(where: { $0.ref == selectedBuildReference }) {
                self.selectedBuildReference = nil
                selectedBuildLogs = ""
            }
        } catch {
            buildActivityError = error.localizedDescription
        }
    }

    func loadBuildLogs(_ record: BuildActivityRecord) async {
        selectedBuildReference = record.ref
        selectedBuildLogs = ""
        selectedBuildLogsLoading = true
        defer { selectedBuildLogsLoading = false }
        do {
            selectedBuildLogs = try await buildxCLI().logs(ref: record.ref)
        } catch {
            selectedBuildLogs = "Build logs are unavailable: \(error.localizedDescription)"
        }
    }

    private func buildxCLI() throws -> BuildxCLI {
        guard let executable = HostDockerCLI.bundledTool("docker-buildx") else {
            throw BuildxCLIError.helperUnavailable
        }
        guard let docker = runtime as? DockerEngineRuntime else {
            throw BuildxCLIError.socketUnavailable
        }
        return BuildxCLI(
            executableURL: URL(fileURLWithPath: executable),
            socketPath: docker.socketPath,
            baseEnvironment: environment,
            runner: buildCommandRunner
        )
    }

    func applyKubernetesYAML(_ yaml: String) async -> String? {
        guard runtimeKind == .sharedVM else { return "Enable Kubernetes on Dory's shared VM first" }
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Paste or open a YAML manifest" }
        guard let kubectl = KubeServiceProxy.kubectl() else { return "kubectl is unavailable. Install or repair the Kubernetes component, then try again." }
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
    var migrationSelectedObjectKeys: Set<DoryOperationObjectKey> = []
    /// The last import result, so the UI can surface per-item failures instead of a bare count.
    var migrationSummary: MigrationSummary?
    @ObservationIgnored private var migrationTask: Task<Void, Never>?
    @ObservationIgnored private var migrationSelectionSourcePath: String?

    private static let migrationPreflightIdleTimeout: TimeInterval = 30
    private static let migrationTransferIdleTimeout: TimeInterval = 300

    private func selectedMigrationSource() -> DockerSourceEngine? {
        guard let path = selectedMigrationSourcePath else { return nil }
        if let source = migrationSources.first(where: { $0.socketPath == path }) {
            return source
        }
        return DockerSourceEngine(
            label: DockerEngineSocketDiscovery.engineLabel(for: path, home: NSHomeDirectory()),
            socketPath: path,
            socketExists: FileManager.default.fileExists(atPath: path)
        )
    }

    private func selectedMigrationRuntime(operationIdleTimeout: TimeInterval) async -> DockerEngineRuntime? {
        guard let source = selectedMigrationSource() else { return nil }
        return await DockerEngineSourceActivator.readyRuntime(for: source)?
            .withOperationIdleTimeout(operationIdleTimeout)
    }

    func selectMigrationSource(_ path: String) async {
        selectedMigrationSourcePath = path
        migrationSelectionSourcePath = nil
        migrationSelectedObjectKeys = []
        await loadMigrationPreflight()
    }

    func setMigrationObject(_ key: DoryOperationObjectKey, selected: Bool) {
        var next = migrationSelectedObjectKeys
        if selected {
            next.insert(key)
        } else {
            next.remove(key)
        }
        migrationSelectedObjectKeys = next
        invalidateMigrationSelectionValidation()
    }

    func selectAllMigrationObjects() {
        migrationSelectedObjectKeys = Set(migrationInventory?.selectableObjects.map(\.key) ?? [])
        invalidateMigrationSelectionValidation()
    }

    func clearMigrationObjectSelection() {
        migrationSelectedObjectKeys = []
        invalidateMigrationSelectionValidation()
    }

    func recheckMigrationSelection() async {
        await loadMigrationPreflight()
    }

    private func invalidateMigrationSelectionValidation() {
        migrationInventory?.strictValidationPerformed = false
        migrationInventory?.strictValidationBlocker = nil
        migrationInventory?.strictRequestedObjectKeys = []
        migrationInventory?.strictDependencyObjectKeys = []
        migrationInventory?.strictOmittedObjectKeys = []
        migrationStatus = migrationSelectedObjectKeys.isEmpty
            ? "Select at least one image, volume, network, or container."
            : "Selection changed. Recheck to calculate dependencies, safety, and capacity."
    }

    /// Reads the selected host engine (if any) without modifying it, to power the pre-flight
    /// "here's what will move, nothing will be deleted" screen.
    func loadMigrationPreflight() async {
        migrationSources = await Task.detached { DockerEngineSocketDiscovery.availableSources() }.value
        migrationSummary = nil
        if selectedMigrationSourcePath == nil
            || !migrationSources.contains(where: { $0.socketPath == selectedMigrationSourcePath }) {
            selectedMigrationSourcePath = migrationSources.first?.socketPath
        }
        guard let selectedSource = selectedMigrationSource() else {
            migrationInventory = nil
            migrationStatus = "No Docker-compatible local engine detected."
            return
        }
        let socketWasMissing = !FileManager.default.fileExists(atPath: selectedSource.socketPath)
        migrationStatus = socketWasMissing
            ? "Starting \(selectedSource.label)…"
            : "Reading \(selectedSource.label)…"
        guard let source = await selectedMigrationRuntime(
            operationIdleTimeout: Self.migrationPreflightIdleTimeout
        ) else {
            migrationInventory = nil
            migrationStatus = "Couldn't reach \(selectedSource.label). Open \(selectedSource.label) and try again."
            return
        }
        let preflightTarget: (any ContainerRuntime)? = runtimeKind == .sharedVM ? runtime : nil
        guard var inventory = await MigrationAssistant.preflight(from: source, to: preflightTarget) else {
            migrationInventory = nil
            if preflightTarget != nil, (try? await source.migrationSnapshot()) != nil {
                migrationStatus = "Couldn't read Dory's target engine. Restart Dory's engine, then recheck the import."
            } else {
                migrationStatus = "Couldn't read \(selectedSource.label)."
            }
            return
        }
        let availableSelection = Set(inventory.selectableObjects.map(\.key))
        if migrationSelectionSourcePath != selectedSource.socketPath {
            migrationSelectedObjectKeys = availableSelection
            migrationSelectionSourcePath = selectedSource.socketPath
        } else {
            migrationSelectedObjectKeys.formIntersection(availableSelection)
        }
        if let availableHostBytes = Self.availableHostDiskBytes() {
            inventory.availableHostBytes = availableHostBytes
            inventory.hostDiskPreflightAvailable = true
        } else {
            inventory.hostDiskPreflightAvailable = false
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        if let engineCapacity = try? MigrationEngineCapacity.selected(home: home) {
            inventory.engineDiskLogicalBytes = engineCapacity.logicalBytes
            inventory.engineDiskUsableBytes = engineCapacity.usableBytes
        }
        if let preflightTarget, !migrationSelectedObjectKeys.isEmpty {
            do {
                let prepared = try await MigrationImportCoordinator.preflight(
                    from: source,
                    to: preflightTarget,
                    userSelection: migrationSelectedObjectKeys.sorted()
                )
                inventory.acceptStrictValidation(prepared)
            } catch {
                inventory.rejectStrictValidation(error)
            }
        }
        migrationInventory = inventory
        if migrationSelectedObjectKeys.isEmpty {
            migrationStatus = "Select at least one object to import."
        } else if let blocker = inventory.strictValidationBlocker {
            migrationStatus = "Import blocked before writing: \(blocker)"
        } else if inventory.isHostDiskUnknown {
            migrationStatus = "Import blocked before writing because macOS did not report available disk space."
        } else if inventory.isHostDiskInsufficient {
            migrationStatus = "Free at least \(inventory.additionalHostDiskDisplay) more before importing from \(inventory.sourceName): about \(inventory.requiredHostDiskDisplay) required, \(inventory.availableHostDiskDisplay) available. Restart Dory's engine first if data was recently pruned."
        } else if inventory.isEngineDiskInsufficient {
            let growth = inventory.recommendedEngineCapacityGiB.map {
                " Grow Docker storage safely to at least \($0) GiB in Resources, then recheck."
            } ?? " The required capacity exceeds Dory's supported 2 TiB maximum."
            migrationStatus = "Import blocked before writing: Dory's \(inventory.engineDiskCapacityDisplay) sparse engine disk exposes \(inventory.engineDiskUsableDisplay) usable but would need about \(inventory.requiredEngineDiskDisplay).\(growth)"
        } else if inventory.isVolumeSizeUnknown {
            migrationStatus = "Import blocked before writing because \(inventory.sourceName) did not report every named-volume size."
        } else if inventory.isContainerWritableSizeUnknown {
            migrationStatus = "Import blocked before writing because \(inventory.sourceName) did not report every container writable-layer size."
        } else if inventory.isVolumeHelperUnavailable {
            migrationStatus = "Import blocked before writing because \(inventory.sourceName) has named volumes but no usable image for safe volume transfer."
        } else if inventory.isTargetUsageUnknown {
            migrationStatus = "Import blocked before writing because Dory could not measure its existing Docker data usage."
        } else if inventory.isLiveVolumeCopyUnsafe {
            migrationStatus = "Stop or pause the listed running volume-backed containers in \(inventory.sourceName), then refresh before importing."
        } else if inventory.isLiveWritableLayerSnapshotUnsafe {
            migrationStatus = "Stop or pause the listed running containers with writable-layer changes in \(inventory.sourceName), then refresh before importing."
        } else if inventory.isTargetCollisionBlocked {
            let count = inventory.targetCollisionBlockers.count
            migrationStatus = "Import blocked before writing by \(count) same-name target conflict\(count == 1 ? "" : "s"). Back up and resolve the listed objects, or use a clean Dory engine."
        } else if inventory.isPortabilityBlocked {
            migrationStatus = "Import blocked before writing because one or more source container contracts are not portable to Dory."
        } else {
            migrationStatus = "Ready to import from \(inventory.sourceName)."
        }
        if socketWasMissing && !inventory.isImportBlocked {
            showSettingsSuccess("\(inventory.sourceName) is ready to import.")
        } else if inventory.isImportBlocked {
            showSettingsFailure(migrationStatus)
        }
    }

    /// Imports the selected engine's images + containers into Dory's own shared VM — the "switch to
    /// Dory" flow. The target is Dory's standalone engine, so afterwards the source can be uninstalled.
    func beginImportFromDocker() {
        guard !migrationBusy else { return }
        migrationTask?.cancel()
        migrationTask = Task { [weak self] in
            guard let self else { return }
            await self.importFromDocker()
            self.migrationTask = nil
        }
    }

    func cancelMigrationImport() {
        guard migrationBusy else { return }
        migrationStatus = "Cancelling import safely…"
        migrationTask?.cancel()
    }

    func importFromDocker() async {
        guard runtimeKind == .sharedVM else {
            migrationStatus = "Switch to Dory's shared VM first, then import"
            return
        }
        guard !migrationBusy else { return }
        guard let selectedSource = selectedMigrationSource() else {
            migrationStatus = "No import source selected."
            showSettingsFailure("No import source selected.")
            return
        }
        guard !migrationSelectedObjectKeys.isEmpty else {
            migrationStatus = "Select at least one object to import."
            showSettingsFailure(migrationStatus)
            return
        }
        // Never reject from the cached panel. The user may just have freed disk space or stopped a
        // live volume-backed source container; the strict source/target preflight below is the only
        // decision that may block this attempt.
        if !FileManager.default.fileExists(atPath: selectedSource.socketPath) {
            migrationStatus = "Starting \(selectedSource.label)…"
        }
        guard let source = await selectedMigrationRuntime(
            operationIdleTimeout: Self.migrationTransferIdleTimeout
        ) else {
            if Task.isCancelled {
                migrationStatus = "Import cancelled before any target objects were changed."
                return
            }
            migrationStatus = "Couldn't reach \(selectedSource.label). Open \(selectedSource.label) and try again."
            showSettingsFailure(migrationStatus)
            return
        }
        migrationBusy = true
        // A retry must not display failures from the previous attempt while its fresh, strict
        // preflight is running. The new summary is installed only after this attempt has results.
        migrationSummary = nil
        defer { migrationBusy = false }
        let target: any ContainerRuntime
        if let docker = runtime as? DockerEngineRuntime {
            target = docker.withOperationIdleTimeout(Self.migrationTransferIdleTimeout)
        } else {
            target = runtime
        }
        migrationStatus = "Starting exact import validation…"
        let summary: MigrationSummary
        do {
            summary = try await MigrationImportCoordinator.migrate(
                from: source,
                to: target,
                userSelection: migrationSelectedObjectKeys.sorted()
            ) { message in
                Task { @MainActor in self.migrationStatus = message }
            }
        } catch is CancellationError {
            migrationStatus = "Import cancelled safely. No partial import was accepted."
            migrationSummary = MigrationSummary(failures: [migrationStatus])
            showSettingsFailure(migrationStatus)
            await reload()
            return
        } catch {
            let detail = String(describing: error)
            migrationStatus = "Import did not complete. No partial result was accepted."
            migrationSummary = MigrationSummary(failures: [detail])
            showSettingsFailure("\(migrationStatus) \(detail)")
            await reload()
            return
        }
        migrationSummary = summary
        var base = "Imported \(summary.imagesImported.count) images, "
            + "\(summary.volumesCopied.count) volumes, "
            + "\(summary.networksCreated.count) networks, "
            + "\(summary.containersMigrated.count) containers"
        if !summary.containersAwaitingSourcePorts.isEmpty {
            let count = summary.containersAwaitingSourcePorts.count
            base += "; \(count) container\(count == 1 ? " is" : "s are") "
                + "waiting for the source engine to release host ports"
        }
        migrationStatus = base
        showSettingsSuccess("\(base) from \(source.displayName).")
        await reload()
    }

    private nonisolated static func availableHostDiskBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    func presentPrimary(for section: AppSection) {
        switch section {
        case .containers: activeSheet = .newContainer
        case .images: activeSheet = .pullImage
        case .volumes: activeSheet = .newVolume
        case .networks: activeSheet = .newNetwork
        case .compose: openComposeFile()
        case .builds: break
        case .desktops:
            guard AppInfo.includesDesktopLinux else {
                actionError = "Install the Linux Desktop runtime and at least one distribution in Components."
                self.section = .components
                return
            }
            activeSheet = .newDesktop
        case .machines:
            guard AppInfo.componentAvailable(.linuxMachines) else {
                actionError = "Install Linux Machines in Components before creating a server."
                self.section = .components
                return
            }
            activeSheet = .newMachine
        default: break
        }
    }

    func createContainer(name: String, image: String, ports: [String], env: [String: String], volumes: [String] = []) async -> String? {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return "Image is required" }
        var createdID: String?
        do {
            try await runtime.pull(image: trimmedImage)
            let finalName = name.isEmpty ? Self.defaultName(for: trimmedImage) : name
            let spec = ContainerSpec(name: finalName, image: trimmedImage, environment: env, ports: ports, volumes: volumes)
            let id = try await runtime.create(spec)
            createdID = id
            try await runtime.start(containerID: id)
            await reload()
            selectedContainerID = id
            return nil
        } catch {
            let failure = Self.userFacingError(error)
            guard let createdID else { return failure }
            do {
                try await runtime.remove(containerID: createdID)
                await reload()
                return failure
            } catch {
                await reload()
                return "\(failure) Dory could not remove the incomplete container: \(Self.userFacingError(error))"
            }
        }
    }

    nonisolated static func userFacingError(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return String(describing: error)
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

    @discardableResult
    private func requireDorydMachines(_ feature: String = "Linux machines") -> Bool {
        guard runtimeOwnedByDoryd else {
            actionError = Self.dorydMachineManagerRequired(feature)
            return false
        }
        return true
    }

    func machineSettings(_ name: String) async -> MachineSettings {
        guard requireDorydMachines() else { return .default }
        do {
            guard let status = try await dorydClient.machineList().first(where: { $0.id == name }) else {
                return .default
            }
            return MachineSettings(
                cpus: status.cpuCount,
                memoryMB: status.memoryMB.flatMap { Int(exactly: $0) },
                mounts: status.shares.map(Self.mountPair(fromDoryd:)),
                env: [:],
                virtualMachineSettings: status.typedSettings
                    ?? DorydMachineTypedSettings(
                        legacyEnvironment: status.environment,
                        displayMode: status.displayMode
                    ),
                displayPresentation: status.displayPresentation,
                address: status.configuredAddress,
                displayMode: status.displayMode,
                bootMode: status.bootMode
            )
        } catch {
            actionError = "Could not load doryd machine settings: \(error)"
            return .default
        }
    }

    private(set) var busyMachines: Set<String> = []
    @ObservationIgnored private var machineEventSequence: UInt64 = 0
    private(set) var machineFileTransfers: [String: DorydMachineFileTransferOperation] = [:]
    private(set) var machineGuestFileExports: [String: DorydMachineGuestFileExportOperation] = [:]
    private var recoveringMachineFileTransfers: Set<String> = []
    private var recoveringMachineGuestFileExports: Set<String> = []
    private var machineGuestFileExportSuggestedNames: [String: String] = [:]
    var machineBusy: Bool { !busyMachines.isEmpty }
    func isMachineBusy(_ name: String) -> Bool { busyMachines.contains(name) }
    func machineFileTransfer(for name: String) -> DorydMachineFileTransferOperation? {
        machineFileTransfers[name]
    }
    func machineGuestFileExport(for name: String) -> DorydMachineGuestFileExportOperation? {
        machineGuestFileExports[name]
    }
    func suggestedGuestFileExportName(for name: String) -> String {
        machineGuestFileExportSuggestedNames[name] ?? "\(name)-export"
    }
    static let importBusyKey = "__dory_import__"
    var machineCreationTitle = ""
    var machineCreationLog = ""
    var machineCreationError: String?
    var machineCreated: Machine?

    func loadMachines() {
        guard runtimeOwnedByDoryd else {
            machineEventSequence = 0
            machines = []
            return
        }
        Task { await refreshMachines(useEventCursor: true) }
    }

    @discardableResult
    private func refreshMachines(useEventCursor: Bool = false) async -> [Machine] {
        guard runtimeOwnedByDoryd else {
            machineEventSequence = 0
            machines = []
            dns.replaceHostIPs([:])
            return []
        }
        var eventBatch: DorydMachineEventBatch?
        var requiresMachineSnapshot = true
        let requestedEventSequence = machineEventSequence
        if useEventCursor {
            eventBatch = try? await dorydClient.machineEvents(
                afterSequence: requestedEventSequence
            )
            if let eventBatch {
                requiresMachineSnapshot = eventBatch.snapshotRequired
                    || !eventBatch.events.isEmpty
                if !requiresMachineSnapshot {
                    advanceMachineEventSequence(
                        eventBatch.headSequence,
                        requestedSequence: requestedEventSequence
                    )
                }
            }
        }
        do {
            if requiresMachineSnapshot {
                machines = try await dorydClient.machineList().map {
                    Self.machine(fromDoryd: $0, domainSuffix: domainSuffix)
                }
                if actionError?.hasPrefix("doryd machine list failed:") == true {
                    actionError = nil
                }
                if let eventBatch {
                    advanceMachineEventSequence(
                        eventBatch.headSequence,
                        requestedSequence: requestedEventSequence
                    )
                }
            }
            for machine in machines where machine.status == .running {
                Task { [weak self] in
                    guard let self, let stats = try? await self.dorydClient.machineStats(machine.name),
                          let index = self.machines.firstIndex(where: { $0.name == machine.name && $0.status == .running }) else {
                        return
                    }
                    self.machines[index].cpuPercent = stats.cpuPercent
                    self.machines[index].memoryDisplay = Self.machineMemoryDisplay(stats)
                }
                recoverActiveFileTransfer(for: machine)
                recoverGuestFileExport(for: machine)
            }
            return machines
        } catch {
            actionError = "doryd machine list failed: \(error)"
            machines = []
            return []
        }
    }

    private func advanceMachineEventSequence(
        _ headSequence: UInt64,
        requestedSequence: UInt64
    ) {
        // Async refreshes can overlap at suspension points. Never let an older response move a
        // newer cursor backwards; allow a daemon-reset snapshot to lower only the cursor that made
        // that exact request.
        if machineEventSequence == requestedSequence
            || headSequence > machineEventSequence {
            machineEventSequence = headSequence
        }
    }

    nonisolated static func machineDNSName(name: String, suffix: String) -> String {
        "\(name).\(suffix)".lowercased()
    }

    nonisolated static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func machine(fromDoryd status: DorydMachineStatus, domainSuffix: String = "dory.local") -> Machine {
        let runState: RunState
        switch status.state {
        case "running":
            runState = .running
        case "paused", "starting":
            runState = .paused
        case "suspended":
            runState = .suspended
        default:
            runState = .stopped
        }
        let detail = [status.agentBuild, status.lastError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? status.state
        let isDesktop = status.displayMode == .desktop
        let isCustomLinux = status.bootMode == .efi
        let typedSettings = status.typedSettings ?? DorydMachineTypedSettings(
            legacyEnvironment: status.environment,
            displayMode: status.displayMode
        )
        let desktopDistro = DesktopMachineDistro.resolve(
            typedSettings.guestIdentityIntent.desktop?.distributionIdentifier
        )
        let guestUsername = typedSettings.guestIdentityIntent.account?.username
            ?? (isCustomLinux ? "installer" : (isDesktop ? "dory" : "root"))
        let fileTransferPolicy = status.runtimeIdentity.mode == "legacy-compatibility"
            ? DoryVMClipboardDirection.bidirectional
            : typedSettings.clipboardPolicy?.files ?? .off
        return Machine(
            name: status.id,
            distro: isCustomLinux ? "Custom Linux" : (isDesktop ? desktopDistro.displayName : "Dory Linux"),
            version: isCustomLinux ? "EFI · arm64" : (isDesktop ? "\(desktopDistro.version) · \(desktopDistro.desktopName)" : detail),
            status: runState,
            cpuPercent: 0,
            memoryDisplay: "—",
            ip: status.address ?? Self.machineDNSName(name: status.id, suffix: domainSuffix),
            letter: isCustomLinux ? "L" : (isDesktop ? String(desktopDistro.displayName.prefix(1)) : "D"),
            badgeHex: isCustomLinux ? 0x7C3AED : (isDesktop ? desktopDistro.badgeHex : 0x3B82F6),
            containerID: "",
            arch: "",
            recipe: "doryd",
            username: guestUsername,
            loginShell: isCustomLinux ? "" : (isDesktop ? "/bin/bash" : "/bin/sh"),
            shellSocketPath: status.shellSocketPath ?? "",
            processID: status.pid,
            failure: status.failure,
            activeOperation: status.activeOperation,
            flightRecorderHeadSequence: status.flightRecorderHeadSequence,
            flightRecorderAvailable: status.flightRecorderAvailable,
            displayMode: status.displayMode,
            bootMode: status.bootMode,
            installerMediaAttached: status.installerMediaAttached,
            runtimeIdentity: status.runtimeIdentity,
            runtimeGraphicsSelection: status.runtimeGraphicsSelection,
            cloneReceipt: status.cloneReceipt,
            agentBuild: status.agentBuild,
            agentProtocolVersion: status.agentProtocolVersion,
            agentCapabilities: status.agentCapabilities,
            integrationHealth: status.integrationHealth,
            fileTransferPolicy: fileTransferPolicy,
            mounts: status.shares.map(Self.mountPair(fromDoryd:))
        )
    }

    nonisolated static func machineMemoryDisplay(_ stats: DorydMachineStats) -> String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: stats.memoryUsedBytes), countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: stats.memoryTotalBytes), countStyle: .memory)
        return "\(used) / \(total)"
    }

    nonisolated private static func mountPair(fromDoryd share: DorydMachineShareConfiguration) -> MountPair {
        MountPair(
            host: share.hostPath,
            guest: share.guestPath,
            readOnly: share.readOnly,
            shareTag: share.tag
        )
    }

    nonisolated static func dorydShares(from mounts: [MountPair]) -> [DorydMachineShareConfiguration] {
        var usedTags = Set(mounts.compactMap { mount -> String? in
            let tag = mount.shareTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            return tag?.isEmpty == false ? tag : nil
        })
        var nextGeneratedTag = 0
        var shares: [DorydMachineShareConfiguration] = []

        for mount in mounts {
            let host = mount.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let guest = mount.guest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !guest.isEmpty else { continue }
            let explicitTag = mount.shareTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag: String
            if let explicitTag, !explicitTag.isEmpty {
                tag = explicitTag
            } else {
                while usedTags.contains("doryapp\(nextGeneratedTag)") {
                    nextGeneratedTag += 1
                }
                tag = "doryapp\(nextGeneratedTag)"
                nextGeneratedTag += 1
                usedTags.insert(tag)
            }
            let bookmark = try? URL(fileURLWithPath: host).bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey],
                relativeTo: nil
            )
            shares.append(DorydMachineShareConfiguration(
                tag: tag,
                hostPath: host,
                guestPath: guest,
                readOnly: mount.readOnly,
                authorizationBookmark: bookmark
            ))
        }
        return shares
    }

    func machineTerminalCommand(_ machine: Machine) -> String? {
        guard canOpenMachineTerminal(machine) else { return nil }
        return TerminalLauncher.userFacingMachineShellCommand(target: UserFacingMachineShellTarget(
            machineID: machine.name
        ))
    }

    func canOpenMachineTerminal(_ machine: Machine) -> Bool {
        runtimeOwnedByDoryd && !machine.shellSocketPath.isEmpty && userFacingDoryCommandResolver() != nil
    }

    func readMachineSerialConsole(
        _ machine: Machine,
        cursor: DorydMachineSerialConsoleCursor,
        limit: UInt32 = 64 * 1_024
    ) async throws -> DorydMachineSerialConsoleBatch {
        guard runtimeOwnedByDoryd else {
            throw DorydClientError.daemon(Self.dorydMachineManagerRequired("machine serial console"))
        }
        return try await dorydClient.machineSerialConsole(
            machineID: machine.name,
            cursor: cursor,
            limit: limit
        )
    }

    func writeMachineSerialConsole(_ machine: Machine, data: Data) async throws {
        guard runtimeOwnedByDoryd else {
            throw DorydClientError.daemon(Self.dorydMachineManagerRequired("machine serial console"))
        }
        _ = try await dorydClient.writeMachineSerialConsole(machineID: machine.name, data: data)
    }

    func canOpenMachineDesktop(_ machine: Machine) -> Bool {
        runtimeOwnedByDoryd
            && machine.displayMode == .desktop
            && machine.status == .running
            && machine.processID != nil
    }

    func openMachineDesktop(_ machine: Machine) {
        guard canOpenMachineDesktop(machine), let processID = machine.processID,
              let application = NSRunningApplication(processIdentifier: processID) else {
            actionError = "The Desktop Linux display is not available yet. Start the machine and try again."
            return
        }
        if application.activate(options: [.activateAllWindows]) { return }
        // Raw-HV desktops run in an unbundled helper, which LaunchServices can discover by PID but
        // does not always activate. The helper handles SIGUSR1 by raising its own display window.
        guard Darwin.kill(processID, SIGUSR1) == 0 else {
            actionError = "Dory could not bring \(machine.name)'s desktop window forward."
            return
        }
    }

    func canUseMachineArtifacts(_ machine: Machine) -> Bool {
        runtimeOwnedByDoryd
    }

    func canTransferFiles(to machine: Machine) -> Bool {
        guard runtimeOwnedByDoryd,
              machine.status == .running,
              machine.fileTransferPolicy.allowsHostToGuest,
              machine.agentProtocolVersion == 1 else {
            return false
        }
        func supports(_ id: String) -> Bool {
            machine.agentCapabilities.contains { $0.id == id && $0.version >= 1 }
        }
        return supports("exec") && supports("sync-push")
    }

    func canTransferFolders(to machine: Machine) -> Bool {
        canTransferFiles(to: machine)
            && machine.agentCapabilities.contains {
                $0.id == "sync-push" && $0.version >= 2
            }
    }

    func canExportGuestFiles(from machine: Machine) -> Bool {
        runtimeOwnedByDoryd
            && machine.status == .running
            && machine.fileTransferPolicy.allowsGuestToHost
            && machine.agentProtocolVersion == 1
            && machine.username != "root"
            && machine.agentCapabilities.contains {
                $0.id == "sync-pull" && $0.version >= 1
            }
    }

    func canRepairMachineTools(_ machine: Machine) -> Bool {
        runtimeOwnedByDoryd
            && machine.displayMode == .desktop
            && machine.bootMode == .linuxKernel
    }

    func repairMachineTools(_ machine: Machine) {
        guard canRepairMachineTools(machine), !busyMachines.contains(machine.name) else { return }
        Task {
            do {
                let updates = try await updateManagedDesktops(
                    affectedBy: [
                        .linuxDesktop,
                        .desktopDebian,
                        .desktopUbuntu,
                        .desktopKali,
                    ],
                    force: true,
                    machineID: machine.name
                )
                guard let update = updates.first, updates.count == 1 else {
                    throw DesktopMachineAssetError.missingAsset(
                        "a verified Dory Tools update for \(machine.name)"
                    )
                }
                showSettingsSuccess(
                    "Repaired Dory Tools in \(machine.name) and verified \(update.version)."
                )
            } catch {
                actionError = "Could not repair Dory Tools in \(machine.name): \(Self.userFacingError(error))"
            }
        }
    }

    func cancelFileTransfer(to machine: Machine) async {
        guard let operation = machineFileTransfers[machine.name],
              !operation.phase.isTerminal else {
            return
        }
        do {
            let updated = try await dorydClient.machineTransferCancel(
                machine.name,
                operationID: operation.operationID
            )
            guard machineFileTransfers[machine.name]?.operationID == operation.operationID else {
                return
            }
            machineFileTransfers[machine.name] = updated
        } catch {
            actionError = "Could not cancel the file transfer to \(machine.name): \(Self.userFacingError(error))"
        }
    }

    func cancelGuestFileExport(from machine: Machine) async {
        guard let operation = machineGuestFileExports[machine.name],
              !operation.phase.isTerminal else {
            return
        }
        do {
            let updated = try await dorydClient.machineGuestExportCancel(
                machine.name,
                operationID: operation.operationID
            )
            guard machineGuestFileExports[machine.name]?.operationID
                    == operation.operationID else {
                return
            }
            machineGuestFileExports[machine.name] = updated
        } catch {
            actionError = "Could not cancel the file export from \(machine.name): \(Self.userFacingError(error))"
        }
    }

    func discardGuestFileExport(from machine: Machine) async {
        guard let operation = machineGuestFileExports[machine.name],
              operation.phase == .completed else {
            return
        }
        do {
            let discarded = try await dorydClient.machineGuestExportDiscard(
                machine.name,
                operationID: operation.operationID
            )
            guard discarded.ok,
                  machineGuestFileExports[machine.name]?.operationID
                    == operation.operationID else {
                throw DoryMachineFileTransferUIError.authorityChanged
            }
            machineGuestFileExports.removeValue(forKey: machine.name)
            machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
            showSettingsSuccess("Discarded the pending file export from \(machine.name).")
        } catch {
            actionError = "Could not discard the file export from \(machine.name): \(Self.userFacingError(error))"
        }
    }

    private func recoverActiveFileTransfer(for machine: Machine) {
        guard machineFileTransfers[machine.name] == nil,
              !busyMachines.contains(machine.name),
              recoveringMachineFileTransfers.insert(machine.name).inserted else {
            return
        }
        Task { [weak self] in
            await self?.recoverActiveFileTransfer(machineID: machine.name)
        }
    }

    private func recoverActiveFileTransfer(machineID: String) async {
        defer { recoveringMachineFileTransfers.remove(machineID) }
        let discovered: DorydMachineFileTransferOperation?
        do {
            discovered = try await dorydClient.machineTransferCurrent(machineID)
        } catch {
            return
        }
        guard let operation = discovered,
              !operation.phase.isTerminal,
              machineFileTransfers[machineID] == nil,
              !busyMachines.contains(machineID) else {
            return
        }

        let operationID = operation.operationID
        busyMachines.insert(machineID)
        machineFileTransfers[machineID] = operation
        defer {
            if machineFileTransfers[machineID]?.operationID == operationID {
                machineFileTransfers.removeValue(forKey: machineID)
                busyMachines.remove(machineID)
            }
        }

        do {
            var current = operation
            while !current.phase.isTerminal {
                try await Task.sleep(for: .milliseconds(150))
                current = try await dorydClient.machineTransferStatus(
                    machineID,
                    operationID: operationID
                )
                guard current.operationID == operationID,
                      machineFileTransfers[machineID]?.operationID == operationID else {
                    throw DoryMachineFileTransferUIError.authorityChanged
                }
                machineFileTransfers[machineID] = current
            }

            switch current.phase {
            case .completed:
                guard let result = current.result else {
                    throw DoryMachineFileTransferUIError.invalidCompletion
                }
                let fileLabel = result.filesSent == 1 ? "file" : "files"
                let bytes = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: result.bytesSent),
                    countStyle: .file
                )
                showSettingsSuccess(
                    "Sent \(result.filesSent) \(fileLabel) (\(bytes)) to \(result.guestDestination)."
                )
            case .cancelled:
                showSettingsSuccess("Cancelled the file transfer to \(machineID).")
            case .failed:
                let message = current.failure?.message ?? "The daemon reported a failed transfer."
                throw DoryMachineFileTransferUIError.remoteFailure(message)
            case .preparing, .transferring, .finalizing, .cancelling:
                throw DoryMachineFileTransferUIError.invalidCompletion
            }
        } catch is CancellationError {
            return
        } catch {
            actionError = "Could not restore the file transfer to \(machineID): \(Self.userFacingError(error))"
        }
    }

    private func recoverGuestFileExport(for machine: Machine) {
        guard machineGuestFileExports[machine.name] == nil,
              recoveringMachineGuestFileExports.insert(machine.name).inserted else {
            return
        }
        Task { [weak self] in
            await self?.recoverGuestFileExport(machineID: machine.name)
        }
    }

    private func recoverGuestFileExport(machineID: String) async {
        defer { recoveringMachineGuestFileExports.remove(machineID) }
        let discovered: DorydMachineGuestFileExportOperation?
        do {
            discovered = try await dorydClient.machineGuestExportCurrent(machineID)
        } catch {
            return
        }
        guard var operation = discovered,
              machineGuestFileExports[machineID] == nil,
              machineFileTransfers[machineID] == nil else {
            return
        }

        let operationID = operation.operationID
        machineGuestFileExportSuggestedNames[machineID] = "\(machineID)-export"
        machineGuestFileExports[machineID] = operation
        if operation.phase == .completed {
            showSettingsSuccess("Files from \(machineID) are ready to save.")
            return
        }
        guard !operation.phase.isTerminal, !busyMachines.contains(machineID) else {
            machineGuestFileExports.removeValue(forKey: machineID)
            machineGuestFileExportSuggestedNames.removeValue(forKey: machineID)
            return
        }

        busyMachines.insert(machineID)
        defer { busyMachines.remove(machineID) }
        do {
            operation = try await awaitGuestFileExport(
                machineID: machineID,
                operationID: operationID,
                initial: operation
            )
            switch operation.phase {
            case .completed:
                showSettingsSuccess("Files from \(machineID) are ready to save.")
            case .cancelled:
                machineGuestFileExports.removeValue(forKey: machineID)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machineID)
                showSettingsSuccess("Cancelled the file export from \(machineID).")
            case .failed:
                machineGuestFileExports.removeValue(forKey: machineID)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machineID)
                let message = operation.failure?.message
                    ?? "The daemon reported a failed file export."
                throw DoryMachineFileTransferUIError.remoteFailure(message)
            case .preparing, .transferring, .finalizing, .cancelling:
                throw DoryMachineFileTransferUIError.invalidCompletion
            }
        } catch is CancellationError {
            return
        } catch {
            actionError = "Could not restore the file export from \(machineID): \(Self.userFacingError(error))"
        }
    }

    @discardableResult
    func exportGuestFiles(
        _ guestSource: String,
        from machine: Machine,
        to destinationURL: URL
    ) async -> URL? {
        guard canExportGuestFiles(from: machine) else {
            actionError = "Start \(machine.name) and update Dory Tools before receiving files."
            return nil
        }
        guard !busyMachines.contains(machine.name),
              !recoveringMachineGuestFileExports.contains(machine.name),
              machineGuestFileExports[machine.name] == nil else {
            return nil
        }
        let suggestedName = destinationURL.lastPathComponent
        guard !suggestedName.isEmpty else {
            actionError = "Choose a name for the received files."
            return nil
        }

        busyMachines.insert(machine.name)
        defer { busyMachines.remove(machine.name) }
        actionError = nil
        var operationID: String?
        do {
            var operation = try await dorydClient.machineGuestExportStart(
                machine.name,
                guestSource: guestSource
            )
            operationID = operation.operationID
            machineGuestFileExportSuggestedNames[machine.name] = suggestedName
            machineGuestFileExports[machine.name] = operation
            operation = try await awaitGuestFileExport(
                machineID: machine.name,
                operationID: operation.operationID,
                initial: operation
            )

            switch operation.phase {
            case .completed:
                return await saveCompletedGuestFileExport(
                    from: machine,
                    operation: operation,
                    to: destinationURL
                )
            case .cancelled:
                machineGuestFileExports.removeValue(forKey: machine.name)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
                showSettingsSuccess("Cancelled the file export from \(machine.name).")
                return nil
            case .failed:
                machineGuestFileExports.removeValue(forKey: machine.name)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
                let message = operation.failure?.message
                    ?? "The daemon reported a failed file export."
                throw DoryMachineFileTransferUIError.remoteFailure(message)
            case .preparing, .transferring, .finalizing, .cancelling:
                throw DoryMachineFileTransferUIError.invalidCompletion
            }
        } catch is CancellationError {
            if let operationID {
                _ = try? await dorydClient.machineGuestExportCancel(
                    machine.name,
                    operationID: operationID
                )
            }
            machineGuestFileExports.removeValue(forKey: machine.name)
            machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
            return nil
        } catch {
            if let operationID,
               machineGuestFileExports[machine.name]?.phase.isTerminal == false {
                _ = try? await dorydClient.machineGuestExportCancel(
                    machine.name,
                    operationID: operationID
                )
                machineGuestFileExports.removeValue(forKey: machine.name)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
            }
            actionError = "Could not receive files from \(machine.name): \(Self.userFacingError(error))"
            return nil
        }
    }

    @discardableResult
    func saveGuestFileExport(
        from machine: Machine,
        to destinationURL: URL
    ) async -> URL? {
        guard let operation = machineGuestFileExports[machine.name],
              operation.phase == .completed else {
            return nil
        }
        actionError = nil
        return await saveCompletedGuestFileExport(
            from: machine,
            operation: operation,
            to: destinationURL
        )
    }

    private func awaitGuestFileExport(
        machineID: String,
        operationID: String,
        initial: DorydMachineGuestFileExportOperation
    ) async throws -> DorydMachineGuestFileExportOperation {
        var operation = initial
        while !operation.phase.isTerminal {
            try await Task.sleep(for: .milliseconds(150))
            operation = try await dorydClient.machineGuestExportStatus(
                machineID,
                operationID: operationID
            )
            guard operation.operationID == operationID,
                  machineGuestFileExports[machineID]?.operationID == operationID else {
                throw DoryMachineFileTransferUIError.authorityChanged
            }
            machineGuestFileExports[machineID] = operation
        }
        return operation
    }

    private func saveCompletedGuestFileExport(
        from machine: Machine,
        operation: DorydMachineGuestFileExportOperation,
        to destinationURL: URL
    ) async -> URL? {
        guard machineGuestFileExports[machine.name]?.operationID == operation.operationID,
              operation.phase == .completed,
              let result = operation.result,
              result.exportID == operation.operationID else {
            actionError = "Could not save files from \(machine.name): The completed export evidence is invalid."
            return nil
        }
        do {
            let materialized = try await Task.detached(priority: .userInitiated) {
                try DoryMachineFileTransferStager.materializeGuestExport(
                    privateStagingRoot: result.privateStagingRoot,
                    exportID: result.exportID,
                    expectedFileCount: result.filesReceived,
                    expectedDirectoryCount: result.directoriesReceived,
                    expectedByteCount: result.bytesReceived,
                    destinationDirectory: destinationURL.deletingLastPathComponent(),
                    destinationName: destinationURL.lastPathComponent
                )
            }.value
            do {
                let discarded = try await dorydClient.machineGuestExportDiscard(
                    machine.name,
                    operationID: operation.operationID
                )
                guard discarded.ok,
                      machineGuestFileExports[machine.name]?.operationID
                        == operation.operationID else {
                    throw DoryMachineFileTransferUIError.authorityChanged
                }
                machineGuestFileExports.removeValue(forKey: machine.name)
                machineGuestFileExportSuggestedNames.removeValue(forKey: machine.name)
            } catch {
                actionError = "Saved files from \(machine.name) to \(materialized.rootURL.path), but Dory could not remove its private staging copy."
                return materialized.rootURL
            }
            let fileLabel = result.filesReceived == 1 ? "file" : "files"
            let folderLabel = result.directoriesReceived == 1 ? "folder" : "folders"
            let itemSummary = result.directoriesReceived == 0
                ? "\(result.filesReceived) \(fileLabel)"
                : "\(result.filesReceived) \(fileLabel) and \(result.directoriesReceived) \(folderLabel)"
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: result.bytesReceived),
                countStyle: .file
            )
            showSettingsSuccess(
                "Saved \(itemSummary) (\(bytes)) from \(machine.name) to \(materialized.rootURL.path)."
            )
            return materialized.rootURL
        } catch {
            actionError = "Could not save files from \(machine.name): \(Self.userFacingError(error))"
            return nil
        }
    }

    @discardableResult
    func transferFiles(
        _ fileURLs: [URL],
        to machine: Machine
    ) async -> DorydMachineFileTransferResult? {
        guard canTransferFiles(to: machine) else {
            actionError = "Start \(machine.name) and update Dory Tools before sending files."
            return nil
        }
        guard !busyMachines.contains(machine.name),
              !recoveringMachineFileTransfers.contains(machine.name) else {
            return nil
        }
        busyMachines.insert(machine.name)
        defer {
            busyMachines.remove(machine.name)
            machineFileTransfers.removeValue(forKey: machine.name)
        }
        actionError = nil

        var staged: DoryStagedMachineFileTransfer?
        var operationID: String?
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try DoryMachineFileTransferStager.stage(fileURLs: fileURLs)
            }.value
            guard let preparedStage = staged else { return nil }
            guard preparedStage.directoryCount == 0 || canTransferFolders(to: machine) else {
                do {
                    try await Task.detached(priority: .utility) {
                        try preparedStage.remove()
                    }.value
                    staged = nil
                } catch {
                    actionError = "Dory could not remove its private staging copy."
                    return nil
                }
                actionError = "Update Dory Tools in \(machine.name) before sending folders."
                return nil
            }
            var operation = try await dorydClient.machineTransferStart(
                machine.name,
                staged: preparedStage
            )
            operationID = operation.operationID
            machineFileTransfers[machine.name] = operation
            while !operation.phase.isTerminal {
                try await Task.sleep(for: .milliseconds(150))
                operation = try await dorydClient.machineTransferStatus(
                    machine.name,
                    operationID: operation.operationID
                )
                guard operationID == operation.operationID else {
                    throw DoryMachineFileTransferUIError.authorityChanged
                }
                machineFileTransfers[machine.name] = operation
            }

            guard operation.phase == .completed,
                  let result = operation.result else {
                if operation.phase == .failed, let failure = operation.failure {
                    throw DoryMachineFileTransferUIError.remoteFailure(failure.message)
                }
                if operation.phase == .cancelled {
                    showSettingsSuccess("Cancelled the file transfer to \(machine.name).")
                    if let staged {
                        try? await Task.detached(priority: .utility) { try staged.remove() }.value
                    }
                    return nil
                }
                throw DoryMachineFileTransferUIError.invalidCompletion
            }
            guard result.filesSent == preparedStage.fileCount,
                  result.bytesSent == preparedStage.byteCount else {
                throw DoryMachineFileTransferUIError.invalidCompletion
            }
            let fileLabel = result.filesSent == 1 ? "file" : "files"
            let folderLabel = preparedStage.directoryCount == 1 ? "folder" : "folders"
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: result.bytesSent),
                countStyle: .file
            )
            do {
                try await Task.detached(priority: .utility) {
                    try preparedStage.remove()
                }.value
            } catch {
                actionError = "Files reached \(machine.name), but Dory could not remove its private staging copy."
                return result
            }
            let transferredItems = preparedStage.directoryCount == 0
                ? "\(result.filesSent) \(fileLabel)"
                : "\(result.filesSent) \(fileLabel) and \(preparedStage.directoryCount) \(folderLabel)"
            showSettingsSuccess("Sent \(transferredItems) (\(bytes)) to \(result.guestDestination).")
            return result
        } catch is CancellationError {
            if let operationID {
                _ = try? await dorydClient.machineTransferCancel(
                    machine.name,
                    operationID: operationID
                )
            }
            if let staged {
                try? await Task.detached(priority: .utility) {
                    try staged.remove()
                }.value
            }
            return nil
        } catch {
            if let operationID,
               machineFileTransfers[machine.name]?.phase.isTerminal == false {
                _ = try? await dorydClient.machineTransferCancel(
                    machine.name,
                    operationID: operationID
                )
            }
            if let staged {
                try? await Task.detached(priority: .utility) {
                    try staged.remove()
                }.value
            }
            actionError = "Could not send files to \(machine.name): \(Self.userFacingError(error))"
            return nil
        }
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
        actionError = "Reclaimed disk space from the old machine cache (~/.dory/machines). New machines are doryd-managed Linux VMs with their own lifecycle and address."
    }

    var browsingVolume: String?
    var volumeBrowsePath = ""
    var volumeEntries: [VolumeEntry] = []
    var volumeFilePreview: String?
    var volumeBrowseBusy = false

    func openVolumeBrowser(_ volume: String) {
        guard runtimeKind.isDockerCompatible || runtimeKind == .mock else {
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
        guard requireDorydMachines() else { return }
        guard let idx = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        let previousState = machines[idx].status
        let name = machine.name
        busyMachines.insert(name)
        Task {
            defer { busyMachines.remove(name) }
            do {
                switch previousState {
                case .running:
                    _ = try await dorydClient.machineStop(name)
                case .paused:
                    _ = try await dorydClient.machineResume(name)
                case .suspended:
                    _ = try await dorydClient.machineResume(name)
                case .stopped:
                    try await refreshManagedDesktopKernelBeforeStart(name)
                    _ = try await dorydClient.machineStart(name)
                }
            } catch {
                let action = switch previousState {
                case .running: "stop"
                case .paused: "resume"
                case .suspended: "restore"
                case .stopped: "start"
                }
                actionError = "Could not \(action) \(name): \(error)"
            }
            await refreshMachines()
        }
    }

    func pauseMachine(_ machine: Machine) {
        guard requireDorydMachines(), machine.status == .running else { return }
        guard !busyMachines.contains(machine.name) else { return }
        busyMachines.insert(machine.name)
        Task {
            defer { busyMachines.remove(machine.name) }
            do {
                _ = try await dorydClient.machinePause(machine.name)
            } catch {
                actionError = "Could not pause \(machine.name): \(error)"
            }
            await refreshMachines()
        }
    }

    func suspendMachine(_ machine: Machine) {
        guard requireDorydMachines(), machine.status == .running || machine.status == .paused else {
            return
        }
        guard !busyMachines.contains(machine.name) else { return }
        busyMachines.insert(machine.name)
        Task {
            defer { busyMachines.remove(machine.name) }
            do {
                _ = try await dorydClient.machineSuspend(machine.name)
            } catch {
                actionError = "Could not suspend \(machine.name): \(error)"
            }
            await refreshMachines()
        }
    }

    func restartMachine(_ machine: Machine) {
        guard requireDorydMachines(), machine.status == .running || machine.status == .paused else {
            return
        }
        guard !busyMachines.contains(machine.name) else { return }
        busyMachines.insert(machine.name)
        Task {
            defer { busyMachines.remove(machine.name) }
            do {
                if machine.bootMode == .linuxKernel,
                   machine.displayMode == .desktop {
                    _ = try await dorydClient.machineStop(machine.name)
                    try await refreshManagedDesktopKernelBeforeStart(machine.name)
                    _ = try await dorydClient.machineStart(machine.name)
                } else {
                    _ = try await dorydClient.machineRestart(machine.name)
                }
            } catch {
                actionError = "Could not restart \(machine.name): \(error)"
            }
            await refreshMachines()
        }
    }

    func setMachineInstallerMedia(_ machine: Machine, attached: Bool) {
        guard requireDorydMachines(), machine.bootMode == .efi else { return }
        guard !busyMachines.contains(machine.name) else { return }
        busyMachines.insert(machine.name)
        Task {
            defer { busyMachines.remove(machine.name) }
            do {
                _ = try await dorydClient.machineUpdate(
                    machine.name,
                    installerMediaAttached: attached
                )
            } catch {
                actionError = "Could not \(attached ? "attach" : "eject") the installer ISO for \(machine.name): \(error)"
            }
            await refreshMachines()
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

    nonisolated static func desktopAssetEnvironment(
        processEnvironment: [String: String],
        distro: DesktopMachineDistro
    ) -> [String: String] {
        var result = processEnvironment
        result["DORY_DESKTOP_DISTRO"] = distro.rawValue
        return result
    }

    /// Temporary compatibility projection until these fields move into native WorkspaceSpec
    /// properties. New app-created machines never persist arbitrary environment values.
    nonisolated static func sanitizedNewMachineEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        let allowed: Set<String> = [
            "DORY_CLIPBOARD_POLICY",
            "DORY_CUSTOM_LINUX",
            "DORY_DESKTOP_DISTRO",
            "DORY_DESKTOP_ENVIRONMENT",
            "DORY_DESKTOP_GRAPHICS",
            "DORY_DESKTOP_NAME",
            "DORY_DESKTOP_VERSION",
            "DORY_DESKTOP_VMM",
            "DORY_GUEST_UID",
            "DORY_GUEST_USER",
        ]
        return environment.filter { allowed.contains($0.key) }
    }

    /// Brings persistent desktop machines forward after a signed desktop component activation.
    /// The daemon preserves each guest's disk, applications, accounts, and settings; it owns the
    /// last-good snapshot, reboot qualification, and automatic rollback transaction.
    func updateManagedDesktops(
        affectedBy components: Set<DoryComponentID>,
        operationID: UUID = UUID(),
        force: Bool = false,
        machineID: String? = nil
    ) async throws -> [DorydDesktopUpdateResult] {
        let statuses = try await dorydClient.machineList()
        let desktopStatuses = statuses.filter {
            $0.displayMode == .desktop && (machineID == nil || $0.id == machineID)
        }
        guard !desktopStatuses.isEmpty else { return [] }

        let runtimeChanged = components.contains(.linuxDesktop)
        let store = try DoryComponentStore.selected()
        guard let runtimeRelease = try store.installedComponent(.linuxDesktop) else {
            throw DesktopMachineAssetError.missingAsset("runtime update")
        }
        _ = try store.verify(.linuxDesktop)
        var results: [DorydDesktopUpdateResult] = []

        for status in desktopStatuses {
            // EFI machines are user-provided installer workspaces. Boot mode is authoritative;
            // do not depend on the legacy DORY_CUSTOM_LINUX compatibility marker.
            guard status.bootMode != .efi else { continue }
            let typedSettings = status.typedSettings ?? DorydMachineTypedSettings(
                legacyEnvironment: status.environment,
                displayMode: status.displayMode
            )
            let distro = DesktopMachineDistro.resolve(
                Self.managedDesktopDistributionIdentifier(
                    configuredIdentifier:
                        typedSettings.guestIdentityIntent.desktop?.distributionIdentifier,
                    receipt: status.installedDesktopPayloadReceipt
                )
            )
            guard runtimeChanged || components.contains(distro.componentID) else { continue }
            guard let distroRelease = try store.installedComponent(distro.componentID) else {
                if components.contains(distro.componentID) {
                    throw DesktopMachineAssetError.missingAsset(distro.displayName + " update")
                }
                // Removing a component intentionally preserves its machine disks. A runtime-only
                // update cannot update that distro until the user reinstalls its signed payload.
                continue
            }
            _ = try store.verify(distro.componentID)
            let targetVersion = distroRelease.version + "+runtime." + runtimeRelease.version
            let bundleAssetIdentifier = "dory-desktop-" + distro.rawValue
                + "-update-arm64.tar"
            let kernelAssetIdentifier = "dory-desktop-kernel-arm64.lzfse"
            guard let bundleAsset = distroRelease.assets.first(where: {
                $0.path == bundleAssetIdentifier
            }),
            let kernelAsset = runtimeRelease.assets.first(where: {
                $0.path == kernelAssetIdentifier
            }) else {
                throw DesktopMachineAssetError.missingAsset(distro.displayName + " in-place update")
            }
            if !force && Self.desktopReceiptMatchesActiveComponents(
                status.installedDesktopPayloadReceipt,
                distributionIdentifier: distro.rawValue,
                releaseVersion: targetVersion,
                distributionComponentIdentifier: distro.componentID.rawValue,
                distributionInstallationName: distroRelease.installationName,
                distributionCatalogSHA256: distroRelease.catalogDigest,
                bundleAssetIdentifier: bundleAsset.path,
                bundleSHA256: bundleAsset.installedSHA256,
                runtimeInstallationName: runtimeRelease.installationName,
                runtimeCatalogSHA256: runtimeRelease.catalogDigest,
                kernelAssetIdentifier: kernelAsset.path,
                kernelSHA256: kernelAsset.installedSHA256
            ) {
                continue
            }

            guard !busyMachines.contains(status.id) else {
                throw DesktopMachineAssetError.filesystem(
                    "\(status.id) is busy with another machine operation"
                )
            }
            busyMachines.insert(status.id)
            defer { busyMachines.remove(status.id) }
            do {
                let result = try await dorydClient.machineDesktopUpdate(
                    status.id,
                    operationID: operationID,
                    distro: distro.rawValue,
                    version: targetVersion,
                    distributionInstallationName: distroRelease.installationName,
                    runtimeInstallationName: runtimeRelease.installationName
                )
                results.append(result)
            } catch {
                throw DesktopMachineAssetError.filesystem(
                    "Could not update " + status.id + ". Dory restored its last-good snapshot. "
                        + String(describing: error)
                )
            }
        }
        if !results.isEmpty {
            _ = await refreshMachines()
        }
        return results
    }

    /// Portable snapshots intentionally omit raw environment. Preserve an explicit typed guest
    /// identity when one exists; otherwise use the validated installed-payload observation.
    nonisolated static func managedDesktopDistributionIdentifier(
        configuredIdentifier: String?,
        receipt: DorydInstalledDesktopPayloadReceipt?
    ) -> String? {
        configuredIdentifier ?? (receipt?.isValid == true ? receipt?.distributionIdentifier : nil)
    }

    nonisolated static func desktopReceiptMatchesActiveComponents(
        _ receipt: DorydInstalledDesktopPayloadReceipt?,
        distributionIdentifier: String,
        releaseVersion: String,
        distributionComponentIdentifier: String,
        distributionInstallationName: String,
        distributionCatalogSHA256: String,
        bundleAssetIdentifier: String,
        bundleSHA256: String,
        runtimeInstallationName: String,
        runtimeCatalogSHA256: String,
        kernelAssetIdentifier: String,
        kernelSHA256: String
    ) -> Bool {
        guard let receipt, receipt.isValid else { return false }
        return receipt.provenance == "verified-update-bundle"
            && receipt.distributionIdentifier == distributionIdentifier
            && receipt.releaseVersion == releaseVersion
            && receipt.distributionComponentIdentifier == distributionComponentIdentifier
            && receipt.distributionInstallationName == distributionInstallationName
            && receipt.distributionCatalogSHA256 == distributionCatalogSHA256.lowercased()
            && receipt.bundleAssetIdentifier == bundleAssetIdentifier
            && receipt.bundleSHA256 == bundleSHA256.lowercased()
            && receipt.runtimeComponentIdentifier == DoryComponentID.linuxDesktop.rawValue
            && receipt.runtimeInstallationName == runtimeInstallationName
            && receipt.runtimeCatalogSHA256 == runtimeCatalogSHA256.lowercased()
            && receipt.kernelAssetIdentifier == kernelAssetIdentifier
            && receipt.kernelSHA256 == kernelSHA256.lowercased()
    }

    nonisolated static func preservingHiddenMachineSettings(_ settings: MachineSettings, existing: MachineSettings) -> MachineSettings {
        var copy = settings
        if copy.env.isEmpty { copy.env = existing.env }
        if copy.virtualMachineSettings == nil {
            copy.virtualMachineSettings = existing.virtualMachineSettings
        }
        if copy.displayPresentation == nil {
            copy.displayPresentation = existing.displayPresentation
        }
        if copy.identity == nil { copy.identity = existing.identity }
        if copy.address == nil { copy.address = existing.address }
        return copy
    }

    nonisolated private static func firstMachinePath(_ keys: [String], environment: [String: String]) -> String? {
        keys.compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    nonisolated private static func bundledMachinePath(_ names: [String]) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return names
            .map { resourceURL.appendingPathComponent($0).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func installedMachinePath(_ names: [String]) -> String? {
        names.lazy.compactMap {
            DoryComponentStore.activeAssetPath(component: .linuxMachines, path: $0)
        }.first
    }

    nonisolated private static var hostMachineAssetArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    nonisolated static func dorydMachineConfiguration(
        name: String,
        settings: MachineSettings,
        environment: [String: String],
        address: String? = nil,
        assets: DesktopMachineAssets? = nil
    ) -> DorydMachineConfiguration? {
        let useBundledAssets = environment["DORYD_DISABLE_BUNDLED_MACHINE_ASSETS"] != "1"
        let arch = hostMachineAssetArch
        let kernel: String
        let rootfs: String
        if settings.bootMode == .efi {
            kernel = ""
            rootfs = ""
        } else {
            guard let resolvedKernel = assets?.kernelPath
                ?? firstMachinePath(["DORYD_MACHINE_KERNEL", "DORYD_GUEST_KERNEL"], environment: environment)
                ?? installedMachinePath(["dory-hv-kernel-\(arch)", "dory-hv-kernel"])
                ?? (useBundledAssets ? bundledMachinePath(["dory-hv-kernel-\(arch)", "dory-hv-kernel"]) : nil),
                  let resolvedRootfs = assets?.rootfsPath
                ?? firstMachinePath(["DORYD_MACHINE_ROOTFS", "DORYD_GUEST_ROOTFS"], environment: environment)
                ?? installedMachinePath([
                    "dory-machine-rootfs-\(arch).ext4",
                    "dory-machine-rootfs.ext4",
                ])
                ?? (useBundledAssets ? bundledMachinePath([
                    "dory-machine-rootfs-\(arch).ext4",
                    "dory-machine-rootfs.ext4",
                    "initfs-\(arch).ext4",
                ]) : nil) else {
                return nil
            }
            kernel = resolvedKernel
            rootfs = resolvedRootfs
        }
        let memoryMB: UInt64
        if let rawMemory = environment["DORYD_MACHINE_MEMORY_MB"] {
            memoryMB = UInt64(rawMemory) ?? 0
        } else if let configuredMemory = settings.memoryMB {
            memoryMB = UInt64(exactly: configuredMemory) ?? 0
        } else {
            memoryMB = 2048
        }
        let cpuCount: Int
        if let rawCPUCount = environment["DORYD_MACHINE_CPUS"] {
            cpuCount = Int(rawCPUCount) ?? 0
        } else {
            cpuCount = settings.cpus ?? 2
        }
        return DorydMachineConfiguration(
            id: name,
            kernelPath: kernel,
            rootfsPath: rootfs,
            bootMode: settings.bootMode,
            installerISOPath: settings.installerISOPath,
            diskSizeBytes: settings.diskSizeGB.flatMap { UInt64(exactly: $0) }.map {
                $0 * 1024 * 1024 * 1024
            },
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            address: address,
            displayMode: settings.displayMode,
            shares: dorydShares(from: settings.mounts),
            typedSettings: settings.virtualMachineSettings
                ?? (settings.bootMode == .efi
                    ? DorydMachineTypedSettings()
                    : DorydMachineTypedSettings(
                        legacyEnvironment: sanitizedNewMachineEnvironment(settings.env),
                        displayMode: settings.displayMode
                    ))
        )
    }

    func createMachine(name: String, recipe: DevRecipe? = nil, settings: MachineSettings = .default) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { actionError = "Name is required"; return "Name is required" }
        guard trimmedName.utf8.count <= 63 else {
            actionError = "Invalid machine name: use 63 characters or fewer"
            return "Invalid machine name"
        }
        guard trimmedName.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]*/) != nil else {
            actionError = "Invalid machine name: use letters, digits, and _ . - (must start alphanumeric)"
            return "Invalid machine name"
        }
        if settings.bootMode == .efi {
            guard settings.displayMode == .desktop,
                  let installerISOPath = settings.installerISOPath,
                  FileManager.default.fileExists(atPath: installerISOPath) else {
                let message = "Choose a readable Linux installer ISO before creating the VM."
                actionError = message
                return message
            }
        } else if settings.displayMode == .desktop {
            let distro = DesktopMachineDistro.resolve(
                settings.virtualMachineSettings?.guestIdentityIntent.desktop?
                    .distributionIdentifier ?? settings.env["DORY_DESKTOP_DISTRO"]
            )
            guard AppInfo.componentAvailable(.linuxDesktop),
                  AppInfo.componentAvailable(distro.componentID) else {
                let message = "Install the Linux Desktop runtime and \(distro.displayName) in Components first."
                actionError = message
                section = .components
                return message
            }
        } else if !AppInfo.componentAvailable(.linuxMachines) {
            let message = "Install Linux Machines in Components before creating a server."
            actionError = message
            section = .components
            return message
        }
        guard requireDorydMachines() else { return actionError }
        return await createDorydMachine(name: trimmedName, settings: settings, recipe: recipe)
    }

    nonisolated static func dorydRecipeID(for recipe: DevRecipe) -> String? {
        switch recipe.id {
        case "node", "go", "rust", "java", "ruby", "devops":
            return recipe.id
        case "python":
            return "python-ml"
        default:
            return nil
        }
    }

    private func createDorydMachine(name: String, settings: MachineSettings, recipe: DevRecipe?) async -> String? {
        var settings = settings
        let address = Self.trimmedNonEmpty(settings.address)
        let provisioningRecipe: String?
        if let recipe {
            guard let recipeID = Self.dorydRecipeID(for: recipe) else {
                let message = "Recipe '\(recipe.display)' is not supported by doryd VM provisioning."
                actionError = message
                return message
            }
            provisioningRecipe = recipeID
        } else {
            provisioningRecipe = nil
        }
        guard !busyMachines.contains(name) else { return nil }
        busyMachines.insert(name)
        machineCreationTitle = "Creating \(name)"
        machineCreationLog = "Creating doryd VM \(name)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        defer { busyMachines.remove(name) }

        var stagedInstallerISOPath: String?
        defer {
            if let stagedInstallerISOPath {
                try? FileManager.default.removeItem(atPath: stagedInstallerISOPath)
            }
        }

        var createdDefinition = false
        do {
            if settings.bootMode == .efi, let installerISOPath = settings.installerISOPath {
                let sourceURL = URL(fileURLWithPath: installerISOPath)
                let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
                }
                appendMachineCreationLog("Checking the selected installer's EFI architecture…")
                let staged = try DoryInstallerISOStager.stage(atPath: installerISOPath)
                if staged.architecture == .unknown {
                    appendMachineCreationLog("The EFI architecture is non-standard; continuing as a custom image.")
                } else {
                    appendMachineCreationLog("\(staged.architecture.rawValue) EFI architecture confirmed.")
                }
                appendMachineCreationLog("Media SHA-256: \(staged.sha256)")
                if case .unqualified = staged.runtimeQualification {
                    appendMachineCreationLog("This exact installer/host combination is not yet runtime-qualified by Dory.")
                }
                appendMachineCreationLog("Installer media is staged for the VM service.")
                stagedInstallerISOPath = staged.path
                settings.installerISOPath = staged.path
            }
            let desktopAssets: DesktopMachineAssets?
            if settings.bootMode == .efi {
                appendMachineCreationLog("Importing the installer ISO and creating a thin-provisioned virtual disk…")
                desktopAssets = nil
            } else if settings.displayMode == .desktop {
                let distro = DesktopMachineDistro.resolve(
                    settings.virtualMachineSettings?.guestIdentityIntent.desktop?
                        .distributionIdentifier ?? settings.env["DORY_DESKTOP_DISTRO"]
                )
                appendMachineCreationLog("Preparing \(distro.displayName) \(distro.version) Desktop in the selected Dory data drive…")
                let home = environment["HOME"] ?? NSHomeDirectory()
                let resourceDirectory = Bundle.main.resourcePath
                desktopAssets = try await desktopMachineAssetPreparer(
                    home,
                    Self.desktopAssetEnvironment(processEnvironment: environment, distro: distro),
                    resourceDirectory
                )
                appendMachineCreationLog("Desktop assets verified. Creating a 64 GB thin-provisioned disk…")
            } else {
                desktopAssets = nil
            }
            guard let config = Self.dorydMachineConfiguration(
                name: name,
                settings: settings,
                environment: environment,
                address: address,
                assets: desktopAssets
            ) else {
                throw DesktopMachineAssetError.missingAsset("kernel or root filesystem")
            }
            _ = try await dorydClient.machineCreate(config)
            createdDefinition = true
            if let displayPresentation = settings.displayPresentation {
                _ = try await dorydClient.machineDisplayPresentationSet(
                    name,
                    presentation: displayPresentation
                )
            }
            appendMachineCreationLog("Definition written. Booting VM…")
            _ = try await dorydClient.machineStart(name)
            if let recipe, let provisioningRecipe {
                appendMachineCreationLog("Provisioning \(recipe.display)…")
                let result = try await dorydClient.machineProvision(name, recipe: provisioningRecipe)
                let verify = result.verify.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if verify.isEmpty {
                    appendMachineCreationLog("Provisioned \(result.recipeID).")
                } else {
                    appendMachineCreationLog("Provisioned \(result.recipeID): \(verify)")
                }
            }
            if settings.bootMode == .efi {
                appendMachineCreationLog(
                    "VM and display started. Complete Linux setup in the desktop window."
                )
            } else {
                appendMachineCreationLog("Machine created and started.")
            }
            let refreshed = await refreshMachines()
            machineCreated = refreshed.first { $0.name == name }
            if machineCreated == nil {
                let message = "Machine '\(name)' was created but isn't showing in the list yet - check the Machines tab."
                appendMachineCreationLog(message)
                machineCreationError = message
                return message
            }
            return nil
        } catch {
            let setupFailure = "\(error)"
            var rollbackFailure: String?
            if createdDefinition {
                appendMachineCreationLog("Setup failed. Removing the incomplete machine…")
                do {
                    let deletion = try await dorydClient.machineDelete(name)
                    if !deletion.ok {
                        rollbackFailure = deletion.message.isEmpty
                            ? "daemon rejected removal"
                            : deletion.message
                    } else {
                        appendMachineCreationLog("Incomplete machine removed.")
                    }
                } catch {
                    rollbackFailure = "\(error)"
                }
                _ = await refreshMachines()
            }
            let message = rollbackFailure.map {
                "\(setupFailure). Cleanup also failed: \($0)"
            } ?? setupFailure
            appendMachineCreationLog("Error: \(message)")
            machineCreationError = message
            actionError = "Could not create doryd VM machine: \(message)"
            return message
        }
    }

    func editMachine(_ machine: Machine, settings: MachineSettings) async -> String? {
        guard requireDorydMachines() else { return actionError }
        busyMachines.insert(machine.name)
        machineCreationTitle = "Updating \(machine.name)"
        machineCreationLog = "Updating doryd VM definition for \(machine.name)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        defer { busyMachines.remove(machine.name) }
        do {
            let current = try await dorydClient.machineList().first { $0.id == machine.name }
            let currentSettings = MachineSettings(
                cpus: current?.cpuCount,
                memoryMB: current?.memoryMB.flatMap { Int(exactly: $0) },
                mounts: current?.shares.map(Self.mountPair(fromDoryd:)) ?? [],
                env: current?.environment ?? [:],
                virtualMachineSettings: current.map {
                    $0.typedSettings ?? DorydMachineTypedSettings(
                        legacyEnvironment: $0.environment,
                        displayMode: $0.displayMode
                    )
                },
                displayPresentation: current?.displayPresentation,
                address: current?.configuredAddress,
                displayMode: current?.displayMode ?? machine.displayMode,
                bootMode: current?.bootMode ?? machine.bootMode
            )
            let effectiveSettings = Self.preservingHiddenMachineSettings(settings, existing: currentSettings)
            let baselineTypedSettings = currentSettings.virtualMachineSettings
                ?? DorydMachineTypedSettings()
            let desiredTypedSettings = effectiveSettings.virtualMachineSettings
                ?? baselineTypedSettings
            let memory = effectiveSettings.memoryMB.flatMap { UInt64(exactly: $0) } ?? current?.memoryMB
            let cpus = effectiveSettings.cpus ?? current?.cpuCount
            let address = Self.trimmedNonEmpty(effectiveSettings.address)
            let desiredPresentation = effectiveSettings.displayPresentation
                ?? currentSettings.displayPresentation
                ?? .windowed
            let previousPresentation = currentSettings.displayPresentation ?? .windowed
            let presentationChanged = desiredPresentation != previousPresentation
            if presentationChanged {
                _ = try await dorydClient.machineDisplayPresentationSet(
                    machine.name,
                    presentation: desiredPresentation
                )
            }
            do {
                _ = try await dorydClient.machineUpdate(
                    machine.name,
                    memoryMB: memory,
                    cpuCount: cpus,
                    address: address,
                    updatesAddress: true,
                    shares: Self.dorydShares(from: effectiveSettings.mounts),
                    typedSettingsPatch: DorydMachineTypedSettingsPatch(
                        baseline: baselineTypedSettings,
                        desired: desiredTypedSettings
                    )
                )
            } catch {
                if presentationChanged {
                    _ = try? await dorydClient.machineDisplayPresentationSet(
                        machine.name,
                        presentation: previousPresentation
                    )
                }
                throw error
            }
            appendMachineCreationLog("Settings applied to doryd VM definition.")
            activeSheet = nil
            await refreshMachines()
            return nil
        } catch {
            let message = "\(error)"
            appendMachineCreationLog("Edit failed: \(message).")
            machineCreationError = message
            actionError = "Could not update doryd VM machine"
            return message
        }
    }

    private func appendMachineCreationLog(_ line: String) {
        machineCreationLog.append(line + "\n")
    }

    nonisolated static func derivedMachineID(base: String, operation: String, token: String) -> String {
        let suffix = "-\(operation)-\(token.lowercased())"
        let maximumBaseLength = max(1, 63 - suffix.count)
        return String(base.prefix(maximumBaseLength)) + suffix
    }

    nonisolated static func generatedMachineToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    nonisolated private static func isDuplicateMachineError(_ error: Error, id: String) -> Bool {
        guard let clientError = error as? DorydClientError,
              case let .daemon(message) = clientError else {
            return false
        }
        return message == "machine already exists: \(id)"
    }

    private func cloneSnapshotWithAvailableName(
        machineID: String,
        snapshotID: String,
        base: String,
        operation: String
    ) async throws -> String {
        for attempt in 1...8 {
            let candidate = Self.derivedMachineID(
                base: base,
                operation: operation,
                token: Self.generatedMachineToken()
            )
            appendMachineCreationLog("Creating \(candidate)…")
            do {
                _ = try await dorydClient.machineCloneSnapshot(
                    machineID: machineID,
                    snapshotID: snapshotID,
                    newID: candidate
                )
                return candidate
            } catch {
                guard Self.isDuplicateMachineError(error, id: candidate), attempt < 8 else {
                    throw error
                }
                appendMachineCreationLog("\(candidate) already exists. Choosing another name…")
            }
        }
        throw DorydClientError.daemon("could not allocate an available machine name")
    }

    var snapshotMachine: Machine?
    var machineSnapshots: [MachineSnapshot] = []
    var machineBackupStatus: DorydMachineBackupStatus?
    var machineBackupLoading = false
    var machineBackupActionBusy = false
    var editMachineTarget: Machine?

    func openMachineEdit(_ machine: Machine) {
        editMachineTarget = machine
    }

    func openSnapshots(_ machine: Machine) {
        snapshotMachine = machine
        machineSnapshots = []
        machineBackupStatus = nil
        activeSheet = .machineSnapshots
        Task { await reloadSnapshots() }
    }

    private func reloadSnapshots() async {
        guard let machine = snapshotMachine else { return }
        guard requireDorydMachines("Snapshots") else {
            machineSnapshots = []
            machineBackupStatus = nil
            return
        }
        machineBackupLoading = true
        defer { machineBackupLoading = false }
        do {
            async let snapshots = dorydClient.machineSnapshots(machineID: machine.name)
            async let backupStatuses = dorydClient.machineBackupSchedules()
            machineSnapshots = try await snapshots.map(Self.machineSnapshot(fromDoryd:))
            machineBackupStatus = try await backupStatuses.first {
                $0.schedule.machineID == machine.name
            }
        } catch {
            actionError = "Could not load machine recovery status: \(error)"
            machineSnapshots = []
            machineBackupStatus = nil
        }
    }

    func saveMachineBackupSchedule(
        frequency: DorydMachineBackupFrequency,
        keepLocal: Int,
        verifyEveryRuns: Int
    ) {
        guard let machine = snapshotMachine,
              requireDorydMachines("Scheduled backups") else { return }
        machineBackupActionBusy = true
        Task {
            defer { machineBackupActionBusy = false }
            do {
                machineBackupStatus = try await dorydClient.machineBackupSet(
                    DorydMachineBackupSchedule(
                        machineID: machine.name,
                        enabled: true,
                        frequency: frequency,
                        keepLocal: keepLocal,
                        verifyEveryRuns: verifyEveryRuns
                    )
                )
            } catch {
                actionError = "Could not save the backup schedule: \(error)"
            }
        }
    }

    func removeMachineBackupSchedule() {
        guard let machine = snapshotMachine,
              requireDorydMachines("Scheduled backups") else { return }
        machineBackupActionBusy = true
        Task {
            defer { machineBackupActionBusy = false }
            do {
                let result = try await dorydClient.machineBackupRemove(machineID: machine.name)
                guard result.ok else { throw DorydClientError.daemon(result.message) }
                machineBackupStatus = nil
            } catch {
                actionError = "Could not disable the backup schedule: \(error)"
            }
        }
    }

    func runMachineBackupNow() {
        guard let machine = snapshotMachine,
              requireDorydMachines("Scheduled backups") else { return }
        let name = machine.name
        machineBackupActionBusy = true
        busyMachines.insert(name)
        Task {
            defer {
                machineBackupActionBusy = false
                busyMachines.remove(name)
            }
            do {
                machineBackupStatus = try await dorydClient.machineBackupRun(machineID: name)
                await reloadSnapshots()
            } catch {
                actionError = "Could not create and verify the backup: \(error)"
                await reloadSnapshots()
            }
        }
    }

    nonisolated static func machineSnapshot(fromDoryd snapshot: DorydMachineSnapshot) -> MachineSnapshot {
        MachineSnapshot(
            id: snapshot.id,
            imageRef: "doryd://\(snapshot.machineID)/\(snapshot.id)",
            machineName: snapshot.machineID,
            note: snapshot.note,
            createdISO: snapshot.createdISO,
            sizeBytes: snapshot.sizeBytes,
            distro: "Dory VM",
            version: "disk",
            arch: snapshot.architecture,
            boot: "vz",
            recipe: "doryd",
            runtimeIdentity: snapshot.runtimeIdentity,
            artifactEvidence: snapshot.artifactEvidence,
            consistency: snapshot.consistency,
            guestQuiesceReceipt: snapshot.guestQuiesceReceipt
        )
    }

    func takeSnapshot(_ machine: Machine, note: String) {
        guard requireDorydMachines("Snapshots") else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdISO = ISO8601DateFormatter().string(from: Date())
        let tag = "s" + UUID().uuidString.prefix(8).lowercased()
        let name = machine.name
        busyMachines.insert(name)
        Task {
            defer { busyMachines.remove(name) }
            do {
                _ = try await dorydClient.machineSnapshot(
                    name,
                    note: trimmedNote,
                    createdISO: createdISO,
                    snapshotID: String(tag)
                )
            } catch {
                actionError = "Could not snapshot \(machine.name): \(error)"
            }
            if snapshotMachine?.name == machine.name { await reloadSnapshots() }
            await refreshMachines()
        }
    }

    func cloneMachine(_ machine: Machine) {
        guard requireDorydMachines("Cloning") else { return }
        let name = machine.name
        busyMachines.insert(name)
        machineCreationTitle = "Cloning \(name)"
        machineCreationLog = "Snapshotting \(name)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        Task {
            defer { busyMachines.remove(name) }
            do {
                var newName: String?
                let cleanupFailure = try await withTemporaryMachineSnapshot(
                    machineID: name,
                    note: "clone base"
                ) { snapshot in
                    newName = try await cloneSnapshotWithAvailableName(
                        machineID: name,
                        snapshotID: snapshot.id,
                        base: name,
                        operation: "copy"
                    )
                }
                guard let newName else {
                    throw DorydClientError.daemon("clone completed without a machine name")
                }
                if let cleanupFailure {
                    appendMachineCreationLog("Clone created, but temporary snapshot cleanup failed: \(cleanupFailure)")
                    actionError = "Clone \(newName) was created, but Dory could not remove its temporary snapshot: \(cleanupFailure)"
                }
                appendMachineCreationLog("Clone \(newName) created and started.")
                activeSheet = nil
                await refreshMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not clone machine"
            }
        }
    }

    func exportMachine(_ machine: Machine) {
        guard requireDorydMachines("Exporting") else { return }
        let panel = NSSavePanel()
        panel.title = "Export machine"
        panel.nameFieldStringValue = "\(machine.name).dorymachine"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorymachine") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = machine.name
        busyMachines.insert(name)
        Task {
            defer { busyMachines.remove(name) }
            do {
                let cleanupFailure = try await withTemporaryMachineSnapshot(
                    machineID: name,
                    note: "export"
                ) { snapshot in
                    let result = try await dorydClient.machineExportSnapshot(
                        machineID: name,
                        snapshotID: snapshot.id,
                        to: url.path
                    )
                    if !result.ok {
                        throw DorydClientError.daemon(result.message)
                    }
                }
                if let cleanupFailure {
                    actionError = "Export completed, but Dory could not remove its temporary snapshot: \(cleanupFailure)"
                }
            } catch {
                actionError = "Could not export \(machine.name): \(error)"
            }
        }
    }

    func cloneSnapshot(_ snapshot: MachineSnapshot) {
        guard requireDorydMachines("Cloning") else { return }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        machineCreationTitle = "Cloning \(snapshot.machineName)"
        machineCreationLog = "Creating a machine from snapshot \(snapshot.id)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                let newName = try await cloneSnapshotWithAvailableName(
                    machineID: snapshot.machineName,
                    snapshotID: snapshot.id,
                    base: snapshot.machineName,
                    operation: "copy"
                )
                appendMachineCreationLog("Clone \(newName) created and started.")
                activeSheet = nil
                await refreshMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not clone machine"
            }
        }
    }

    func restoreSnapshot(_ snapshot: MachineSnapshot) {
        guard requireDorydMachines("Restoring") else { return }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        machineCreationTitle = "Restoring \(snapshot.machineName)"
        machineCreationLog = "Restoring \(snapshot.machineName) from snapshot…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                let safetyID = "s" + UUID().uuidString.prefix(8).lowercased()
                let safety = try await dorydClient.machineSnapshot(
                    snapshot.machineName,
                    note: "Automatic pre-restore safety snapshot",
                    createdISO: ISO8601DateFormatter().string(from: Date()),
                    snapshotID: String(safetyID)
                )
                appendMachineCreationLog("Safety snapshot \(safety.id) created.\n")
                _ = try await dorydClient.machineRestoreSnapshot(
                    machineID: snapshot.machineName,
                    snapshotID: snapshot.id
                )
                appendMachineCreationLog("\(snapshot.machineName) restored from snapshot. Use \(safety.id) to undo.")
                activeSheet = nil
                await refreshMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not restore machine"
            }
        }
    }

    func exportSnapshot(_ snapshot: MachineSnapshot) {
        guard requireDorydMachines("Exporting") else { return }
        let panel = NSSavePanel()
        panel.title = "Export machine snapshot"
        panel.nameFieldStringValue = "\(snapshot.machineName).dorymachine"
        panel.allowedContentTypes = [UTType(filenameExtension: "dorymachine") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                let result = try await dorydClient.machineExportSnapshot(
                    machineID: snapshot.machineName,
                    snapshotID: snapshot.id,
                    to: url.path
                )
                if !result.ok {
                    throw DorydClientError.daemon(result.message)
                }
            } catch {
                actionError = "Could not export \(snapshot.machineName): \(error)"
            }
        }
    }

    func importMachineFile() {
        guard requireDorydMachines("Importing") else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a Dory machine file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dorymachine") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importMachine(from: url)
    }

    func importMachine(from url: URL) {
        guard requireDorydMachines("Importing") else { return }
        busyMachines.insert(Self.importBusyKey)
        machineCreationTitle = "Importing machine"
        machineCreationLog = "Importing \(url.lastPathComponent)…\n"
        machineCreationError = nil
        machineCreated = nil
        activeSheet = .creatingMachine
        Task {
            defer { busyMachines.remove(Self.importBusyKey) }
            do {
                let assessment = try await dorydClient.machineAssessSnapshotImport(
                    from: url.path
                )
                appendMachineCreationLog(
                    "Verified complete archive \(assessment.contentID.prefix(12))… "
                        + "(\(assessment.architecture), ABI "
                        + "\(assessment.virtualHardwareABIVersion))."
                )
                appendMachineCreationLog(
                    "Portability: \(assessment.disposition.rawValue)."
                )
                let unavailableComponents = assessment.components.filter {
                    $0.availability != .available
                }
                if !unavailableComponents.isEmpty {
                    appendMachineCreationLog(
                        "Required components: " + unavailableComponents.map {
                            "\($0.componentIdentifier)@\($0.buildIdentifier) "
                                + "(\($0.availability.rawValue))"
                        }.joined(separator: ", ")
                    )
                }
                switch assessment.disposition {
                case .ready, .requiresReplanning:
                    break
                case .requiresComponents:
                    throw DorydClientError.daemon(
                        "Import requires unavailable or different Dory components: "
                            + unavailableComponents.map(\.componentIdentifier)
                                .joined(separator: ", ")
                    )
                case .unavailable:
                    throw DorydClientError.daemon(
                        "This archive is not portable to the current host ("
                            + assessment.issues.joined(separator: ", ") + ")."
                    )
                }
                let snapshot = try await dorydClient.machineImportSnapshot(
                    from: url.path,
                    expectedContentID: assessment.contentID
                )
                appendMachineCreationLog("Verified snapshot \(snapshot.id).")
                let newName: String
                do {
                    newName = try await cloneSnapshotWithAvailableName(
                        machineID: snapshot.machineID,
                        snapshotID: snapshot.id,
                        base: snapshot.machineID,
                        operation: "import"
                    )
                } catch {
                    let cleanupFailure = await removeTemporaryMachineSnapshot(
                        machineID: snapshot.machineID,
                        snapshotID: snapshot.id
                    )
                    if let cleanupFailure {
                        throw DorydClientError.daemon(
                            "\(error). Imported snapshot cleanup also failed: \(cleanupFailure)"
                        )
                    }
                    throw error
                }
                if let cleanupFailure = await removeTemporaryMachineSnapshot(
                    machineID: snapshot.machineID,
                    snapshotID: snapshot.id
                ) {
                    appendMachineCreationLog(
                        "Machine created, but imported snapshot cleanup failed: \(cleanupFailure)"
                    )
                    actionError = "Imported \(newName), but Dory could not remove its temporary snapshot: \(cleanupFailure)"
                }
                appendMachineCreationLog("Imported machine \(newName) and started it.")
                activeSheet = nil
                await refreshMachines()
            } catch {
                let message = "\(error)"
                appendMachineCreationLog("Error: \(message)")
                machineCreationError = message
                actionError = "Could not import machine file"
            }
        }
    }

    func deleteSnapshot(_ snapshot: MachineSnapshot) {
        guard requireDorydMachines("Snapshots") else { return }
        let busyKey = snapshot.machineName
        busyMachines.insert(busyKey)
        machineSnapshots.removeAll { $0.id == snapshot.id }
        Task {
            defer { busyMachines.remove(busyKey) }
            do {
                let result = try await dorydClient.machineDeleteSnapshot(
                    machineID: snapshot.machineName,
                    snapshotID: snapshot.id
                )
                if !result.ok {
                    throw DorydClientError.daemon(result.message)
                }
            } catch {
                actionError = "Could not delete snapshot: \(error)"
            }
            if snapshotMachine != nil { await reloadSnapshots() }
        }
    }

    private func withTemporaryMachineSnapshot(
        machineID: String,
        note: String,
        operation: (DorydMachineSnapshot) async throws -> Void
    ) async throws -> String? {
        let snapshot = try await dorydClient.machineSnapshot(
            machineID,
            note: note,
            createdISO: ISO8601DateFormatter().string(from: Date()),
            snapshotID: "s" + UUID().uuidString.prefix(8).lowercased()
        )
        do {
            try await operation(snapshot)
        } catch {
            let cleanupFailure = await removeTemporaryMachineSnapshot(
                machineID: machineID,
                snapshotID: snapshot.id
            )
            if let cleanupFailure {
                throw DorydClientError.daemon("\(error). Temporary snapshot cleanup also failed: \(cleanupFailure)")
            }
            throw error
        }
        return await removeTemporaryMachineSnapshot(machineID: machineID, snapshotID: snapshot.id)
    }

    private func removeTemporaryMachineSnapshot(machineID: String, snapshotID: String) async -> String? {
        do {
            let result = try await dorydClient.machineDeleteSnapshot(
                machineID: machineID,
                snapshotID: snapshotID
            )
            guard result.ok else {
                return result.message.isEmpty ? "daemon rejected cleanup" : result.message
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    func deleteMachine(_ machine: Machine) {
        guard requireDorydMachines() else { return }
        let name = machine.name
        guard !busyMachines.contains(name) else { return }
        busyMachines.insert(name)
        Task {
            defer { busyMachines.remove(name) }
            do {
                let result = try await dorydClient.machineDelete(name)
                if !result.ok {
                    throw DorydClientError.daemon(
                        result.message.isEmpty ? "daemon rejected deletion" : result.message
                    )
                }
                machines.removeAll { $0.name == name }
                unregisterMachineBridge(name)
                try? FileManager.default.removeItem(atPath: MachineService.bridgeHostDir(for: name))
            } catch {
                actionError = "Could not delete machine '\(name)': \(error)"
            }
            await refreshMachines()
        }
    }

    func openContainerTerminal(_ container: Container) {
        handleTerminalLaunch(TerminalLauncher.openContainerShell(
            socketPath: shimSocketPath,
            containerID: container.id,
            preference: externalTerminalPreference
        ))
    }

    func openExternalTerminal(command: String) {
        handleTerminalLaunch(TerminalLauncher.open(
            command: command,
            preference: externalTerminalPreference
        ))
    }

    private func handleTerminalLaunch(_ result: TerminalLauncher.LaunchResult) {
        switch result {
        case .launched:
            break
        case .unavailable(let message), .failed(let message):
            showSettingsFailure(message)
        }
    }

    func terminalSession(for container: Container) -> TerminalSession {
        TerminalSession(id: "container:\(container.id)", title: container.name, subtitle: container.image,
                        logo: nil, socketPath: shimSocketPath, containerID: container.id,
                        user: "root", shell: "/bin/sh", home: "/root")
    }

    func terminalSession(for machine: Machine) -> TerminalSession {
        let home = machine.username == "root" ? "/root" : "/Users/\(machine.username)"
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family
        let machineShell = runtimeOwnedByDoryd
            ? userFacingDoryCommandResolver().map { _ in MachineShellTarget(machineID: machine.name) }
            : nil
        let sessionID = runtimeOwnedByDoryd ? "machine:\(machine.name)" : "machine:\(machine.containerID)"
        return TerminalSession(id: sessionID, title: machine.name,
                               subtitle: "\(machine.distro) \(machine.version)",
                               logo: family.flatMap { MachineDistro.logoAsset(family: $0) },
                               socketPath: shimSocketPath, containerID: machine.containerID,
                               user: machine.username, shell: machine.loginShell, home: home,
                               machineShell: machineShell)
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
