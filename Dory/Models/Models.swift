import DoryOperations
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case containers, images, volumes, networks, compose, builds, kubernetes, desktops, machines, components, health, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .compose: "Compose"
        case .builds: "Build Activity"
        case .kubernetes: "Kubernetes"
        case .desktops: "Linux Desktops"
        case .machines: "Linux Servers"
        case .components: "Components"
        case .health: "Health"
        case .settings: "Settings"
        }
    }

    var primaryActionLabel: String? {
        switch self {
        case .containers: "New Container"
        case .images: "Pull Image"
        case .volumes: "New Volume"
        case .networks: "New Network"
        case .compose: "Open Compose File"
        case .builds: nil
        case .kubernetes: nil
        case .desktops: "New Desktop"
        case .machines: "New Server"
        case .components: nil
        case .health: nil
        case .settings: nil
        }
    }
}

enum RunState: String, Sendable {
    case running, paused, suspended, stopped

    var label: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .suspended: "Suspended"
        case .stopped: "Stopped"
        }
    }

    func dotColor(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.green
        case .paused: p.amber
        case .suspended: p.accent
        case .stopped: p.text3
        }
    }

    func badgeBackground(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.greenWeak
        case .paused: p.amberWeak
        case .suspended: p.accentSoft
        case .stopped: p.pill
        }
    }
}

struct Container: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var image: String
    var status: RunState
    var cpuPercent: Double
    var memoryDisplay: String
    var memoryLimitDisplay: String
    var memoryFraction: Double
    var ports: String
    var uptime: String
    var created: String
    var ipAddress: String
    var domain: String
    var command: String
    var restartPolicy: String
    var createdEpoch: Int? = nil
    var labels: [String: String] = [:]
    var memoryBytes: Int64 = 0
    var volumes: [String] = []
    var nanoCPUs: Int64? = nil
    var memoryLimitBytes: Int64? = nil
    var mounts: [ContainerMount] = []
    var volumeTargets: [String] = []
    var networks: [String] = []
    var networkEndpointSettings: [String: DockerEndpointSettings] = [:]
    /// Full source-daemon image content ID used as a lossless migration fallback when the
    /// container's original tag is no longer present in RepoTags.
    var sourceImageID: String? = nil
    var exitCode: Int? = nil
    var commandArgs: [String] = []
    var entrypoint: [String] = []
    var hostname: String? = nil
    var domainname: String? = nil
    var macAddress: String? = nil
    var user: String? = nil
    var workingDir: String? = nil
    var shell: [String] = []
    var tty: Bool = false
    var openStdin: Bool = false
    var stdinOnce: Bool = false
    var stopSignal: String? = nil
    var stopTimeout: Int? = nil
    var networkMode: String? = nil
    var autoRemove: Bool? = nil
    var privileged: Bool? = nil
    var initProcessEnabled: Bool? = nil
    var capAdd: [String] = []
    var capDrop: [String] = []
    var dns: [String] = []
    var dnsOptions: [String] = []
    var dnsSearch: [String] = []
    var extraHosts: [String] = []
    var groupAdd: [String] = []
    var ipcMode: String? = nil
    var pidMode: String? = nil
    var usernsMode: String? = nil
    var readonlyRootfs: Bool? = nil
    var shmSize: Int64? = nil
    var tmpfs: [String: String] = [:]
    var attachStdin: Bool? = nil
    var attachStdout: Bool? = nil
    var attachStderr: Bool? = nil
    var healthcheck: DockerHealthConfig? = nil
    var networkDisabled: Bool? = nil
    var containerIDFile: String? = nil
    var logConfig: DockerLogConfig? = nil
    var volumeDriver: String? = nil
    var volumesFrom: [String] = []
    var consoleSize: [Int] = []
    var annotations: [String: String] = [:]
    var cgroupnsMode: String? = nil
    var cgroup: String? = nil
    var links: [String] = []
    var oomScoreAdj: Int? = nil
    var publishAllPorts: Bool? = nil
    var securityOpt: [String] = []
    var storageOpt: [String: String] = [:]
    var utsMode: String? = nil
    var sysctls: [String: String] = [:]
    var runtimeName: String? = nil
    var isolation: String? = nil
    var maskedPaths: [String] = []
    var readonlyPaths: [String] = []
    var resources: ContainerResourceUpdate = ContainerResourceUpdate()

    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var health: Health? {
        guard let raw = labels["dory.health"] ?? labels["com.docker.compose.health"] else { return nil }
        return Health(rawValue: raw)
    }
    var isRunning: Bool { status == .running }
    var cpuFraction: Double { min(1, cpuPercent * 0.14) }
}

struct DockerImage: Identifiable, Hashable, Sendable {
    var repository: String
    var tag: String
    var imageID: String
    var size: String
    var created: String
    var usedByCount: Int
    var sizeBytes: Int64 = 0
    var createdEpoch: Int = 0
    var labels: [String: String] = [:]
    /// Additional RepoTags for the same image ID. The table keeps one row per image while
    /// migrations still copy every user-visible tag.
    var additionalReferences: [String] = []
    nonisolated var id: String { imageID.isEmpty ? "\(repository):\(tag)" : imageID }

    var usedLabel: String { usedByCount > 0 ? "\(usedByCount) container\(usedByCount > 1 ? "s" : "")" : "Unused" }
    var isUsed: Bool { usedByCount > 0 }
}

struct TableSort: Equatable, Sendable {
    var key: String
    var ascending: Bool
}

struct Volume: Identifiable, Hashable, Sendable {
    var name: String
    var size: String
    var driver: String
    var usedBy: String
    var created: String
    var labels: [String: String] = [:]
    var options: [String: String] = [:]
    var id: String { name }
}

struct DoryNetwork: Identifiable, Hashable, Sendable {
    var name: String
    var driver: String
    var scope: String
    var subnet: String
    var containerCount: Int
    var labels: [String: String] = [:]
    var id: String { name }
}

enum PodPhase: String, Sendable {
    case running = "Running"
    case pending = "Pending"
    case completed = "Completed"
    case crashLoopBackOff = "CrashLoopBackOff"

    func color(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.green
        case .pending: p.amber
        case .completed: p.text3
        case .crashLoopBackOff: p.red
        }
    }

    func background(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.greenWeak
        case .pending: p.amberWeak
        case .completed: p.pill
        case .crashLoopBackOff: p.redWeak
        }
    }
}

enum KubeResourceKind: String, CaseIterable, Identifiable, Sendable {
    case pods, deployments, services, configMaps, secrets, ingresses
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .services: "Services"
        case .configMaps: "ConfigMaps"
        case .secrets: "Secrets"
        case .ingresses: "Ingress"
        }
    }
    var apiKind: String {
        switch self {
        case .configMaps: "configmaps"
        case .ingresses: "ingress"
        default: rawValue
        }
    }
    var deleteKind: String {
        switch self {
        case .pods: "pod"
        case .deployments: "deployment"
        case .services: "service"
        case .configMaps: "configmap"
        case .secrets: "secret"
        case .ingresses: "ingress"
        }
    }
}

struct Pod: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var phase: PodPhase
    var ready: String
    var restarts: Int
    var age: String
    var containers: [String] = []
    var id: String { "\(namespace)/\(name)" }
    var primaryContainer: String? { containers.first }
    var streamsAllContainerLogs: Bool { containers.count > 1 }
}

struct Machine: Identifiable, Hashable, Sendable {
    var name: String
    var distro: String
    var version: String
    var status: RunState
    var cpuPercent: Double
    var memoryDisplay: String
    var ip: String
    var letter: String
    var badgeHex: UInt32
    var containerID: String = ""
    var arch: String = ""
    var recipe: String = ""
    var username: String = "root"
    var loginShell: String = "/bin/sh"
    var uid: Int? = nil
    var homePath: String? = nil
    var sshPort: Int? = nil
    var shellSocketPath: String = ""
    var processID: Int32? = nil
    var failure: DorydMachineFailure? = nil
    var activeOperation: DorydMachineOperationSummary? = nil
    var flightRecorderHeadSequence: UInt64 = 0
    var flightRecorderAvailable: Bool = false
    var displayMode: MachineDisplayMode = .headless
    var bootMode: MachineBootMode = .linuxKernel
    var installerMediaAttached: Bool = false
    var runtimeIdentity: DorydMachineRuntimeIdentity = .legacyCompatibility
    var cloneReceipt: DorydMachineCloneReceipt? = nil
    var agentBuild: String? = nil
    var agentProtocolVersion: UInt32? = nil
    var agentCapabilities: [DorydAgentCapability] = []
    var integrationHealth: DoryGuestIntegrationHealth? = nil
    var mounts: [MountPair] = []
    var id: String { name }

    var badgeColor: Color { Color(hex: badgeHex) }
    var actionLabel: String { status == .running ? "Stop" : "Start" }
    var isEmulated: Bool { !arch.isEmpty && arch != MachineArch.host.rawValue }

    var runtimeEvidence: [MachineRuntimeEvidence] {
        var evidence: [MachineRuntimeEvidence] = []
        if let failure {
            evidence.append(MachineRuntimeEvidence(
                id: "failure",
                label: Self.failureLabel(failure.code),
                systemImage: "exclamationmark.octagon.fill",
                tone: .warning,
                detail: Self.failureDetail(failure)
            ))
        } else if let activeOperation {
            evidence.append(MachineRuntimeEvidence(
                id: "operation",
                label: activeOperation.kind.rawValue.capitalized,
                systemImage: "arrow.triangle.2.circlepath",
                tone: .standard,
                detail: "Operation \(activeOperation.operationID.prefix(8))…"
            ))
        }
        if recipe == "doryd" {
            if !flightRecorderAvailable {
                evidence.append(MachineRuntimeEvidence(
                    id: "flight-recorder",
                    label: "Recorder unavailable",
                    systemImage: "waveform.path.ecg.rectangle",
                    tone: .warning,
                    detail: "Durable workspace diagnostics need repair"
                ))
            } else if flightRecorderHeadSequence > 0 {
                evidence.append(MachineRuntimeEvidence(
                    id: "flight-recorder",
                    label: "Flight recorder",
                    systemImage: "waveform.path.ecg.rectangle",
                    tone: .standard,
                    detail: "Durable through event \(flightRecorderHeadSequence)"
                ))
            }
        }
        if let cloneReceipt {
            evidence.append(MachineRuntimeEvidence(
                id: "clone-storage",
                label: "Copy-on-write clone",
                systemImage: "square.on.square",
                tone: .standard,
                detail: "APFS-managed from \(cloneReceipt.sourceMachineID)/\(cloneReceipt.sourceSnapshotID)"
            ))
        }
        switch runtimeIdentity.mode {
        case "resolved-plan":
            evidence.append(MachineRuntimeEvidence(
                id: "authority",
                label: runtimeIdentity.supportTier == "supported" ? "Supported" : "Preview",
                systemImage: runtimeIdentity.supportTier == "supported"
                    ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tone: runtimeIdentity.supportTier == "supported" ? .positive : .warning,
                detail: runtimeIdentity.runtimeQualification?.qualificationIdentity
                    ?? "Resolved plan \(runtimeIdentity.planRevision ?? 0)"
            ))
            if let backend = runtimeIdentity.backend {
                evidence.append(MachineRuntimeEvidence(
                    id: "backend",
                    label: Self.backendLabel(backend),
                    systemImage: "cpu",
                    tone: .standard,
                    detail: runtimeIdentity.backendRuntimeBuildIdentifier ?? backend
                ))
            }
            if displayMode == .desktop {
                evidence.append(MachineRuntimeEvidence(
                    id: "graphics",
                    label: Self.graphicsLabel(runtimeIdentity.graphics),
                    systemImage: "display",
                    tone: runtimeIdentity.graphics == "hardware-accelerated-3d"
                        ? .positive : .standard,
                    detail: runtimeIdentity.graphicsQualification?.manifestIdentity
                        ?? "No separate signed graphics qualification"
                ))
            }
            if runtimeIdentity.selectionDisposition == "approved-fallback" {
                evidence.append(MachineRuntimeEvidence(
                    id: "fallback",
                    label: "Approved fallback",
                    systemImage: "arrow.triangle.branch",
                    tone: .warning,
                    detail: runtimeIdentity.fallbackAuthorizationIdentity ?? "Approved alternative"
                ))
            }
        case "requires-replanning":
            evidence.append(MachineRuntimeEvidence(
                id: "authority",
                label: "Needs planning",
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                detail: runtimeIdentity.invalidationReason ?? "No current launch plan"
            ))
        default:
            evidence.append(MachineRuntimeEvidence(
                id: "authority",
                label: "Compatibility",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .standard,
                detail: "Legacy compatibility launch authority"
            ))
        }
        evidence.append(toolsRuntimeEvidence)
        return evidence
    }

    private static func failureLabel(_ code: DorydMachineFailureCode) -> String {
        switch code {
        case .lifecycleOperationFailed: "Operation failed"
        case .lifecycleRecoveryRequired: "Recovery required"
        case .workspaceAuthorityInvalid: "Planning required"
        case .backendLaunchFailed: "Backend launch failed"
        case .readinessHandoffFailed: "Readiness failed"
        case .readinessTimedOut: "Readiness timed out"
        case .helperExited: "VM helper exited"
        case .savedStateInvalid: "Saved state invalid"
        case .resourceAdmissionRejected: "Resources changed"
        case .desktopUpdateRecoveryRequired: "Update recovery required"
        case .desktopUpdateRolledBack: "Update rolled back"
        case .deletionFailed: "Deletion failed"
        case .diagnosticPersistenceFailed: "Diagnostics unavailable"
        case .unclassified: "Machine failure"
        }
    }

    private static func failureDetail(_ failure: DorydMachineFailure) -> String {
        let recovery: String
        switch failure.recoveryDisposition {
        case .retry: recovery = "Retry the operation"
        case .replan: recovery = "Replan this workspace"
        case .repair: recovery = "Run repair and review diagnostics"
        case .rollbackCompleted: recovery = "Rollback completed"
        case .deleteWorkspace: recovery = "Delete and recreate the workspace"
        case .inspectDiagnostics: recovery = "Review diagnostics"
        }
        if let operationID = failure.operationID {
            return "\(recovery) · operation \(operationID.prefix(8))…"
        }
        return recovery
    }

    var integrationHealthProjection: DoryGuestIntegrationHealth {
        if let integrationHealth, integrationHealth.isValid {
            return integrationHealth
        }
        let authority: DoryGuestIntegrationRuntimeAuthority
        switch runtimeIdentity.mode {
        case "resolved-plan": authority = .resolvedPlan
        case "requires-replanning": authority = .requiresReplanning
        default: authority = .legacyCompatibility
        }
        return DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: status == .running,
            runtimeAuthority: authority,
            desktopIntegrationsExpected: displayMode == .desktop,
            clipboardTextExpected: displayMode == .desktop,
            clipboardImageExpected: displayMode == .desktop,
            sharedFoldersExpected: !mounts.isEmpty,
            // Older daemons did not expose the plan's exact device contract. The compatibility
            // projection therefore stays fail-closed instead of inferring host integrations.
            qualifiedRuntimeFeatures: [],
            agentBuild: agentBuild,
            agentProtocolVersion: agentProtocolVersion,
            agentCapabilities: agentCapabilities.map {
                DoryGuestIntegrationNegotiatedCapability(id: $0.id, version: $0.version)
            }
        )
    }

    private var toolsRuntimeEvidence: MachineRuntimeEvidence {
        let health = integrationHealthProjection
        switch health.state {
        case .inactive:
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools inactive",
                systemImage: "wrench.and.screwdriver",
                tone: .standard,
                detail: "Integration checks resume when the workspace is running"
            )
        case .missingTools:
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools unavailable",
                systemImage: "wrench.and.screwdriver",
                tone: .warning,
                detail: "The guest has not reported a valid Dory Tools handshake"
            )
        case .incompatible:
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools incompatible",
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                detail: "\(health.agentBuild ?? "Dory Tools") uses unsupported protocol \(health.agentProtocolVersion ?? 0)"
            )
        case .degraded:
            let unavailable = health.features
                .filter { $0.required && $0.state != .active }
                .map(\.id.rawValue)
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools partially ready",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .warning,
                detail: unavailable.isEmpty
                    ? "The workspace needs a current resolved runtime plan"
                    : "Unavailable: \(unavailable.joined(separator: ", "))"
            )
        case .compatibility:
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools compatibility",
                systemImage: "wrench.and.screwdriver",
                tone: .standard,
                detail: "\(health.agentBuild ?? "Dory Tools") · guest capabilities negotiated; runtime integrations unqualified"
            )
        case .healthy:
            return MachineRuntimeEvidence(
                id: "tools",
                label: "Tools ready",
                systemImage: "wrench.and.screwdriver.fill",
                tone: .positive,
                detail: "\(health.agentBuild ?? "Dory Tools") · \(health.features.filter { $0.state == .active }.count) active integrations"
            )
        }
    }

    private static func backendLabel(_ backend: String) -> String {
        switch backend {
        case "dory-hypervisor": "Raw HV"
        case "apple-virtualization-framework": "Virtualization.framework"
        case "qemu-hvf": "QEMU/HVF"
        default: backend
        }
    }

    private static func graphicsLabel(_ graphics: String?) -> String {
        switch graphics {
        case "hardware-accelerated-3d": "Qualified 3D"
        case "host-accelerated-display": "Accelerated display"
        case "software": "Software graphics"
        case "none": "No graphics"
        default: "Graphics unknown"
        }
    }
}

enum MachineRuntimeEvidenceTone: Hashable, Sendable {
    case standard
    case positive
    case warning
}

struct MachineRuntimeEvidence: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var systemImage: String
    var tone: MachineRuntimeEvidenceTone
    var detail: String
}

enum LogLevel: String, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"

    func color(_ p: DoryPalette) -> Color {
        switch self {
        case .info: p.accentText
        case .warn: p.amber
        case .error: p.red
        case .debug: p.text3
        }
    }
}

struct LogLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    var timestamp: String
    var level: LogLevel
    var message: String
}

struct EnvVar: Identifiable, Hashable, Sendable {
    var key: String
    var value: String
    var id: String { key }
}

struct StatMetric: Identifiable, Sendable {
    var label: String
    var value: String
    var fraction: Double
    var tint: Color
    var id: String { label }
}

struct LabelPair: Identifiable, Hashable, Sendable {
    var key: String
    var value: String
    var id: String { key }
}

struct NetworkMember: Identifiable, Hashable, Sendable {
    var name: String
    var ipv4: String
    var id: String { name }
}

struct ImageDetail: Sendable, Equatable {
    var reference: String
    var id: String
    var tags: [String]
    var digest: String?
    var created: String
    var architecture: String
    var os: String
    var size: String
    var entrypoint: String
    var command: String
    var workingDir: String
    var exposedPorts: [String]
    var env: [EnvVar]
    var labels: [LabelPair]
}

struct NetworkDetail: Sendable, Equatable {
    var name: String
    var id: String
    var driver: String
    var scope: String
    var subnet: String
    var gateway: String
    var isInternal: Bool
    var attachable: Bool
    var options: [LabelPair]
    var containers: [NetworkMember]
}

enum AppSheet: String, Identifiable, Sendable {
    case newContainer, pullImage, volumeBrowser, newVolume, newNetwork, buildImage, registryLogin, applyYAML, inspectImage, inspectNetwork, kubeResourceDetail, newDesktop, newMachine, creatingMachine, machineSnapshots
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview, stats, logs, terminal, env
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ContainerScope: String, CaseIterable, Identifiable, Sendable {
    case all, standalone, compose
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .standalone: "Standalone"
        case .compose: "Compose"
        }
    }
}

/// Which engine backend the app connects to — Colima-style choice between Dory's own bundled
/// engine and any Docker-compatible engine already on the Mac.
enum EnginePreference: String, CaseIterable, Identifiable, Sendable {
    /// Dory's bundled dory-hv engine (the default, full-feature backend).
    case dory
    /// Auto-detect an existing engine: Colima, Docker Desktop, OrbStack, Rancher Desktop, Podman.
    case external
    /// A user-supplied Docker-compatible unix socket path.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dory: "Dory daemon"
        case .external: "Existing engine"
        case .custom: "Custom socket"
        }
    }

    var summary: String {
        switch self {
        case .dory: "doryd-managed engine for Docker, Compose, Kubernetes, networking, and VM machines"
        case .external: "Use a Docker engine already on this Mac (Colima, Docker Desktop, OrbStack, Rancher, Podman)"
        case .custom: "Point Dory at any Docker-compatible unix socket"
        }
    }
}

struct LocalDorydCapability: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let command: String
    let status: String
}

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, updates, components, engine, resources, machines, autoIdle, network, usb, localTools, migrate, managed, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: "General"
        case .updates: "Updates"
        case .components: "Components"
        case .engine: "Engine & Daemon"
        case .resources: "Resources"
        case .machines: "Machines"
        case .autoIdle: "Auto-Idle"
        case .network: "Network"
        case .usb: "USB Devices"
        case .localTools: "Local Tools"
        case .migrate: "Migrate & Compare"
        case .managed: "Managed"
        case .about: "About"
        }
    }
}
