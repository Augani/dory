import Foundation

struct ManagedSettingsProfile: Codable, Equatable, Sendable {
    var schema = "dev.dory.managed-settings"
    var version = 1
    var engine: ManagedEngineSettings
    var network: ManagedNetworkSettings
    var autoIdle: ManagedAutoIdleSettings
    var fileSharing: ManagedFileSharingSettings
    var telemetry: ManagedTelemetrySettings
}

struct ManagedEngineSettings: Codable, Equatable, Sendable {
    var preference: String
    var routeDockerCLI: Bool
    var keepDorydRunningAfterQuit: Bool
    var rosettaX86: Bool
    var gpuVenus: Bool
}

struct ManagedNetworkSettings: Codable, Equatable, Sendable {
    var domainsEnabled: Bool
    var domainSuffix: String
    var dnsPort: UInt16
    var httpProxyPort: UInt16
    var httpsProxyPort: UInt16
}

struct ManagedAutoIdleSettings: Codable, Equatable, Sendable {
    var mode: String
    var sleepAfterMinutes: Int
    var keepPublishedPortsAwake: Bool
    var keepKubernetesAwake: Bool
    var keepPinnedProjectsAwake: Bool
    var showWakeNotifications: Bool
}

struct ManagedFileSharingSettings: Codable, Equatable, Sendable {
    var defaultPolicy: String
    var scopedMountsRequiredForSandboxes: Bool
    var credentialStoresHidden: Bool
    var machineEnvAllowList: [String]
}

struct ManagedTelemetrySettings: Codable, Equatable, Sendable {
    var mode: String = "none"
}

enum ManagedSettingsEncoder {
    static func json(_ profile: ManagedSettingsProfile) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(profile),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
