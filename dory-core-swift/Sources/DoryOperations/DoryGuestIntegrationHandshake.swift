import Foundation

/// Explicit host-granted permissions for one guest-tools connection. Capabilities describe what
/// a tools build can do; permissions describe which potentially sensitive actions this particular
/// machine operation has authorized. Keeping those facts separate prevents a convenient tools
/// channel from becoming arbitrary host command or filesystem access.
public enum DoryGuestIntegrationPermission: String, Codable, Sendable, CaseIterable, Hashable {
    case gracefulShutdown = "graceful-shutdown"
    case clipboardRead = "clipboard-read"
    case clipboardWrite = "clipboard-write"
    case fileTransferPush = "file-transfer-push"
    case fileTransferPull = "file-transfer-pull"
    case openURL = "open-url"
    case displayTopology = "display-topology"
    case clockSynchronization = "clock-sync"

    /// Permissions are gated both by host policy and by a matching live capability declaration.
    /// In particular, a guest cannot turn a generic connection into a file-transfer or command
    /// channel merely by naming the permission in its hello.
    public var requiredCapability: DoryGuestIntegrationCapabilityID {
        switch self {
        case .gracefulShutdown: .gracefulShutdown
        case .clipboardRead, .clipboardWrite: .clipboardText
        case .fileTransferPush: .fileTransferPush
        case .fileTransferPull: .fileTransferPull
        case .openURL: .openURL
        case .displayTopology: .displayTopology
        case .clockSynchronization: .clockSynchronization
        }
    }
}

public enum DoryGuestIntegrationHandshakeValidationCode: String, Codable, Sendable, Hashable {
    case unsupportedSchema = "unsupported-schema"
    case invalidMachineIdentity = "invalid-machine-identity"
    case invalidGuestIdentity = "invalid-guest-identity"
    case invalidToolsBuild = "invalid-tools-build"
    case invalidProtocol = "invalid-protocol"
    case invalidCapabilities = "invalid-capabilities"
    case invalidPermissions = "invalid-permissions"
    case invalidNonce = "invalid-nonce"
    case operationMismatch = "operation-mismatch"
    case generationMismatch = "generation-mismatch"
    case guestMismatch = "guest-mismatch"
    case protocolMismatch = "protocol-mismatch"
    case nonceMismatch = "nonce-mismatch"
    case permissionDenied = "permission-denied"
    case requiredCapabilityMissing = "required-capability-missing"
}

public struct DoryGuestIntegrationHandshakeValidationIssue: Sendable, Equatable, Hashable {
    public var code: DoryGuestIntegrationHandshakeValidationCode
    public var field: String

    public init(code: DoryGuestIntegrationHandshakeValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

/// The untrusted first message from a guest tools peer. It contains no bearer credential: the
/// daemon compares it with the operation-specific expectation below before treating any declared
/// capability or requested permission as live runtime state.
public struct DoryGuestIntegrationHandshake: Codable, Sendable, Equatable, Hashable {
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: UUID
    public var lifecycleGeneration: UInt64
    public var guest: DoryGuestPlatform
    public var toolsBuild: String
    public var protocolVersion: UInt32
    public var capabilities: [DoryGuestIntegrationNegotiatedCapability]
    public var requestedPermissions: [DoryGuestIntegrationPermission]
    /// A host-generated 128-bit hexadecimal challenge. A reconnect gets a new nonce, so an old
    /// hello cannot be replayed after suspend, restart, or operation replacement.
    public var nonce: String

    public init(
        machineID: String,
        operationID: UUID,
        lifecycleGeneration: UInt64,
        guest: DoryGuestPlatform,
        toolsBuild: String,
        protocolVersion: UInt32,
        capabilities: [DoryGuestIntegrationNegotiatedCapability],
        requestedPermissions: [DoryGuestIntegrationPermission],
        nonce: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.machineID = machineID
        self.operationID = operationID
        self.lifecycleGeneration = lifecycleGeneration
        self.guest = guest
        self.toolsBuild = toolsBuild
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.requestedPermissions = requestedPermissions
        self.nonce = nonce.lowercased()
    }

    public var validationIssues: [DoryGuestIntegrationHandshakeValidationIssue] {
        var issues: [DoryGuestIntegrationHandshakeValidationIssue] = []
        func add(_ code: DoryGuestIntegrationHandshakeValidationCode, _ field: String) {
            issues.append(.init(code: code, field: field))
        }
        if schemaVersion != Self.schemaVersion { add(.unsupportedSchema, "schemaVersion") }
        if !Self.isMachineID(machineID) { add(.invalidMachineIdentity, "machineID") }
        if lifecycleGeneration == 0 { add(.invalidMachineIdentity, "lifecycleGeneration") }
        if !Self.isSupportedGuest(guest) { add(.invalidGuestIdentity, "guest") }
        if !Self.isToolsBuild(toolsBuild) { add(.invalidToolsBuild, "toolsBuild") }
        if protocolVersion == 0 { add(.invalidProtocol, "protocolVersion") }
        let capabilityIDs = capabilities.map(\.id)
        if capabilities.isEmpty
            || !capabilities.allSatisfy(\.isValid)
            || capabilityIDs != capabilityIDs.sorted()
            || Set(capabilityIDs).count != capabilityIDs.count {
            add(.invalidCapabilities, "capabilities")
        }
        let permissionNames = requestedPermissions.map(\.rawValue)
        if permissionNames != permissionNames.sorted()
            || Set(permissionNames).count != permissionNames.count {
            add(.invalidPermissions, "requestedPermissions")
        }
        if !Self.isNonce(nonce) { add(.invalidNonce, "nonce") }
        return issues
    }

    private static func isMachineID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...63).contains(bytes.count) && bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    private static func isSupportedGuest(_ guest: DoryGuestPlatform) -> Bool {
        switch guest.family {
        case .linux: return guest.architecture == .arm64 || guest.architecture == .x86_64
        case .macOS, .windows: return guest.architecture == .arm64
        }
    }

    private static func isToolsBuild(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
    }

    private static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

/// Host-only expectation for a single connection attempt. It is intentionally not Codable so
/// callers cannot accidentally persist or forward a live replay challenge as machine intent.
public struct DoryGuestIntegrationHandshakeExpectation: Sendable, Equatable, Hashable {
    public var machineID: String
    public var operationID: UUID
    public var lifecycleGeneration: UInt64
    public var guest: DoryGuestPlatform
    public var protocolVersion: UInt32
    public var nonce: String
    public var grantedPermissions: Set<DoryGuestIntegrationPermission>

    public init(
        machineID: String,
        operationID: UUID,
        lifecycleGeneration: UInt64,
        guest: DoryGuestPlatform,
        protocolVersion: UInt32,
        nonce: String,
        grantedPermissions: Set<DoryGuestIntegrationPermission>
    ) {
        self.machineID = machineID
        self.operationID = operationID
        self.lifecycleGeneration = lifecycleGeneration
        self.guest = guest
        self.protocolVersion = protocolVersion
        self.nonce = nonce.lowercased()
        self.grantedPermissions = grantedPermissions
    }

    /// Returns no capabilities or permissions on failure. A caller must replace the expectation
    /// whenever the operation generation or transport reconnect changes.
    public func admit(_ handshake: DoryGuestIntegrationHandshake) -> [DoryGuestIntegrationHandshakeValidationIssue] {
        var issues = handshake.validationIssues
        func add(_ code: DoryGuestIntegrationHandshakeValidationCode, _ field: String) {
            issues.append(.init(code: code, field: field))
        }
        guard issues.isEmpty else { return issues }
        if handshake.machineID != machineID { add(.operationMismatch, "machineID") }
        if handshake.operationID != operationID { add(.operationMismatch, "operationID") }
        if handshake.lifecycleGeneration != lifecycleGeneration { add(.generationMismatch, "lifecycleGeneration") }
        if handshake.guest != guest { add(.guestMismatch, "guest") }
        if handshake.protocolVersion != protocolVersion { add(.protocolMismatch, "protocolVersion") }
        if handshake.nonce != nonce { add(.nonceMismatch, "nonce") }
        if !Set(handshake.requestedPermissions).isSubset(of: grantedPermissions) {
            add(.permissionDenied, "requestedPermissions")
        }
        let advertised = Set(handshake.capabilities.map(\.id))
        if handshake.requestedPermissions.contains(where: {
            !advertised.contains($0.requiredCapability.rawValue)
        }) {
            add(.requiredCapabilityMissing, "requestedPermissions")
        }
        return issues
    }
}
