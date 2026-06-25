import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case containers, images, volumes, networks, compose, kubernetes, machines, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .compose: "Compose"
        case .kubernetes: "Kubernetes"
        case .machines: "Linux Machines"
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
        case .kubernetes: nil
        case .machines: "New Machine"
        case .settings: nil
        }
    }
}

enum RunState: String, Sendable {
    case running, paused, stopped

    var label: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .stopped: "Stopped"
        }
    }

    func dotColor(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.green
        case .paused: p.amber
        case .stopped: p.text3
        }
    }

    func badgeBackground(_ p: DoryPalette) -> Color {
        switch self {
        case .running: p.greenWeak
        case .paused: p.amberWeak
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
    var exitCode: Int? = nil
    var commandArgs: [String] = []
    var entrypoint: [String] = []
    var hostname: String? = nil
    var domainname: String? = nil
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
    var id: String { imageID.isEmpty ? "\(repository):\(tag)" : imageID }

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
    var id: String { name }

    var badgeColor: Color { Color(hex: badgeHex) }
    var actionLabel: String { status == .running ? "Stop" : "Start" }
    var isEmulated: Bool { !arch.isEmpty && arch != MachineArch.host.rawValue }
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
    case newContainer, pullImage, volumeBrowser, newVolume, newNetwork, buildImage, registryLogin, applyYAML, inspectImage, inspectNetwork, kubeResourceDetail, newMachine, creatingMachine, machineSnapshots
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview, stats, logs, terminal, env
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, engine, resources, network, migrate, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: "General"
        case .engine: "Docker Engine"
        case .resources: "Resources"
        case .network: "Network"
        case .migrate: "Migrate & Compare"
        case .about: "About"
        }
    }
}
