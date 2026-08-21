import Foundation

public enum DoryVMSandboxSSHAgentAccess: String, Codable, Sendable, CaseIterable, Hashable {
    case denied
    case granted
}

public enum DoryVMSandboxProfile: String, Codable, Sendable, CaseIterable, Hashable {
    case standard
    case agentReady = "agent-ready"
}

public enum DoryVMSandboxTool: String, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case agentCore = "agent-core"
    case node
    case pythonML = "python-ml"
    case go
    case rust
    case java
    case ruby
    case devops
    case dockerHost = "docker-host"
    case k8sLab = "k8s-lab"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Non-secret, durable lifecycle and credential-grant intent for a temporary workspace.
///
/// Network destinations, command environments, host paths, and secret values deliberately live
/// outside this definition. They are scoped operation inputs and must never become VM metadata.
public struct DoryVMSandboxPolicy: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public static let legacyMarkerEnvironmentKey = "DORY_SANDBOX"
    public static let legacyExpirationEnvironmentKey = "DORY_SANDBOX_EXPIRES_AT"
    public static let legacySSHAgentEnvironmentKey = "DORY_SANDBOX_SSH_AGENT"
    public static let legacyProfileEnvironmentKey = "DORY_SANDBOX_PROFILE"
    public static let legacyToolsEnvironmentKey = "DORY_SANDBOX_TOOLS"
    public static let legacyBaselineEnvironmentKey = "DORY_SANDBOX_BASELINE"

    public var schemaVersion: UInt16
    /// Nil means retained until an explicit delete. A non-nil value is an absolute Unix epoch.
    public var expiresAtUnixSeconds: UInt64?
    public var sshAgentAccess: DoryVMSandboxSSHAgentAccess
    public var profile: DoryVMSandboxProfile
    public var tools: [DoryVMSandboxTool]
    public var baselineSnapshotID: String?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        expiresAtUnixSeconds: UInt64? = nil,
        sshAgentAccess: DoryVMSandboxSSHAgentAccess = .denied,
        profile: DoryVMSandboxProfile = .standard,
        tools: [DoryVMSandboxTool] = [],
        baselineSnapshotID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
        self.sshAgentAccess = sshAgentAccess
        self.profile = profile
        self.tools = tools
        self.baselineSnapshotID = baselineSnapshotID
    }

    public var isValidForPersistence: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              expiresAtUnixSeconds.map({ $0 > 0 }) ?? true,
              tools.count <= DoryVMSandboxTool.allCases.count,
              tools == Array(Set(tools)).sorted() else {
            return false
        }
        switch profile {
        case .standard:
            return tools.isEmpty && baselineSnapshotID == nil
        case .agentReady:
            return tools.contains(.agentCore)
                && baselineSnapshotID.map(Self.isValidIdentifier) == true
        }
    }

    public static func legacyEnvironment(_ environment: [String: String]) -> Self? {
        guard environment[legacyMarkerEnvironmentKey] == "1" else { return nil }

        let expiration: UInt64?
        switch environment[legacyExpirationEnvironmentKey] {
        case nil, "0"?:
            expiration = nil
        case let raw?:
            guard let value = UInt64(raw), value > 0 else { return nil }
            expiration = value
        }

        let sshAgentAccess: DoryVMSandboxSSHAgentAccess
        switch environment[legacySSHAgentEnvironmentKey] {
        case nil, "0"?: sshAgentAccess = .denied
        case "1"?: sshAgentAccess = .granted
        default: return nil
        }

        let profile: DoryVMSandboxProfile
        let tools: [DoryVMSandboxTool]
        let baseline: String?
        switch environment[legacyProfileEnvironmentKey] {
        case nil:
            guard environment[legacyToolsEnvironmentKey] == nil,
                  environment[legacyBaselineEnvironmentKey] == nil else { return nil }
            profile = .standard
            tools = []
            baseline = nil
        case DoryVMSandboxProfile.agentReady.rawValue?:
            guard let rawTools = environment[legacyToolsEnvironmentKey],
                  let rawBaseline = environment[legacyBaselineEnvironmentKey] else { return nil }
            let parts = rawTools.split(separator: ",", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            let parsed = parts.compactMap { DoryVMSandboxTool(rawValue: String($0)) }
            guard parsed.count == parts.count, Set(parsed).count == parsed.count else {
                return nil
            }
            profile = .agentReady
            tools = parsed.sorted()
            baseline = rawBaseline
        default:
            return nil
        }

        let candidate = Self(
            expiresAtUnixSeconds: expiration,
            sshAgentAccess: sshAgentAccess,
            profile: profile,
            tools: tools,
            baselineSnapshotID: baseline
        )
        return candidate.isValidForPersistence ? candidate : nil
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), isASCIIAlphaNumeric(bytes[0]) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
