import Foundation

/// Stable capability names shared by guest-integration packages and qualification evidence.
/// A package may implement only a subset; callers must negotiate the exact version they need.
public enum DoryGuestIntegrationCapabilityID: String, Codable, Sendable, CaseIterable, Hashable {
    case readiness
    case gracefulShutdown = "graceful-shutdown"
    case reboot
    case clockSynchronization = "clock-sync"
    case health
    case displayTopology = "display-topology"
    case displayResize = "display-resize"
    case clipboardText = "clipboard-text"
    case clipboardImage = "clipboard-image"
    case sharedFolderDiscovery = "shared-folder-discovery"
    case sharedFolderMountStatus = "shared-folder-mount-status"
    case fileTransferPush = "sync-push"
    case fileTransferPull = "sync-pull"
    case networkIdentity = "network-identity"
    case processLaunch = "exec"
    case processInput = "exec-stdin"
    case listenPorts = "ports-watch"
    case lifecycleReceipt = "lifecycle-receipt"
    case telemetry
    case snapshotQuiesce = "snapshot-quiesce"
    case packageUpdate = "package-update"
}

public struct DoryGuestIntegrationCapabilityDeclaration: Codable, Sendable, Equatable, Hashable {
    public var id: DoryGuestIntegrationCapabilityID
    public var version: UInt16

    public init(id: DoryGuestIntegrationCapabilityID, version: UInt16) {
        self.id = id
        self.version = version
    }
}

/// The guest-native payload shape. These roles do not grant product support or driver trust.
public enum DoryGuestIntegrationArtifactRole: String, Codable, Sendable, CaseIterable, Hashable {
    case linuxToolsArchive = "linux-tools-archive"
    case windowsService = "windows-service"
    case windowsDriver = "windows-driver"
    case macOSPackage = "macos-package"
}

public enum DoryGuestIntegrationSignatureKind: String, Codable, Sendable, CaseIterable, Hashable {
    case doryEd25519 = "dory-ed25519"
    case microsoftAuthenticode = "microsoft-authenticode"
    case appleDeveloperID = "apple-developer-id"
}

/// Non-secret signature identity recorded by packaging. A resolver must still verify the actual
/// bytes and signature chain before constructing trusted runtime facts.
public struct DoryGuestIntegrationSignatureEvidence: Codable, Sendable, Equatable, Hashable {
    public var kind: DoryGuestIntegrationSignatureKind
    public var identity: String
    public var signatureSHA256: String

    public init(
        kind: DoryGuestIntegrationSignatureKind,
        identity: String,
        signatureSHA256: String
    ) {
        self.kind = kind
        self.identity = identity
        self.signatureSHA256 = signatureSHA256.lowercased()
    }
}

public struct DoryGuestIntegrationArtifact: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var role: DoryGuestIntegrationArtifactRole
    public var artifact: DoryVMResolverReference
    public var sha256: String
    public var byteCount: UInt64
    public var signature: DoryGuestIntegrationSignatureEvidence

    public init(
        id: String,
        role: DoryGuestIntegrationArtifactRole,
        artifact: DoryVMResolverReference,
        sha256: String,
        byteCount: UInt64,
        signature: DoryGuestIntegrationSignatureEvidence
    ) {
        self.id = id
        self.role = role
        self.artifact = artifact
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.signature = signature
    }
}

/// Package maturity remains distinct from guest/backend support. `contract-only` is the required
/// state for Windows and macOS declarations until their authorization and physical qualification
/// gates pass.
public enum DoryGuestIntegrationPackageState: String, Codable, Sendable, CaseIterable, Hashable {
    case contractOnly = "contract-only"
    case qualified
}

/// Audit evidence retained by a structurally qualified manifest. It is intentionally declarative;
/// only a signature-verifying daemon authority may turn it into trusted capability facts.
public struct DoryGuestIntegrationQualificationEvidence: Codable, Sendable, Equatable, Hashable {
    public var manifestIdentity: String
    public var manifestSHA256: String
    public var suiteSHA256: String
    public var sbomSHA256: String
    public var attestationSHA256: String
    public var qualifiedCapabilities: [DoryGuestIntegrationCapabilityDeclaration]

    public init(
        manifestIdentity: String,
        manifestSHA256: String,
        suiteSHA256: String,
        sbomSHA256: String,
        attestationSHA256: String,
        qualifiedCapabilities: [DoryGuestIntegrationCapabilityDeclaration]
    ) {
        self.manifestIdentity = manifestIdentity
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.suiteSHA256 = suiteSHA256.lowercased()
        self.sbomSHA256 = sbomSHA256.lowercased()
        self.attestationSHA256 = attestationSHA256.lowercased()
        self.qualifiedCapabilities = qualifiedCapabilities
    }
}

public enum DoryGuestIntegrationPackageValidationCode: String, Codable, Sendable, Hashable {
    case unsupportedSchema = "unsupported-schema"
    case invalidIdentity = "invalid-identity"
    case invalidVersion = "invalid-version"
    case unsupportedPlatform = "unsupported-platform"
    case invalidCapabilities = "invalid-capabilities"
    case invalidArtifacts = "invalid-artifacts"
    case invalidSignature = "invalid-signature"
    case incompleteWindowsPackage = "incomplete-windows-package"
    case invalidQualification = "invalid-qualification"
}

public struct DoryGuestIntegrationPackageValidationIssue: Sendable, Equatable, Hashable {
    public var code: DoryGuestIntegrationPackageValidationCode
    public var field: String

    public init(code: DoryGuestIntegrationPackageValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

/// Versioned packaging contract for Dory Tools across guest families. This type deliberately does
/// not participate in capability resolution by itself: parsing a manifest is never a trust event.
public struct DoryGuestIntegrationPackageManifest: Codable, Sendable, Equatable {
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var manifestIdentity: String
    public var packageVersion: String
    public var guest: DoryGuestPlatform
    public var protocolVersion: UInt16
    public var state: DoryGuestIntegrationPackageState
    public var capabilities: [DoryGuestIntegrationCapabilityDeclaration]
    public var artifacts: [DoryGuestIntegrationArtifact]
    public var qualification: DoryGuestIntegrationQualificationEvidence?

    public init(
        manifestIdentity: String,
        packageVersion: String,
        guest: DoryGuestPlatform,
        protocolVersion: UInt16,
        state: DoryGuestIntegrationPackageState,
        capabilities: [DoryGuestIntegrationCapabilityDeclaration],
        artifacts: [DoryGuestIntegrationArtifact],
        qualification: DoryGuestIntegrationQualificationEvidence? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.manifestIdentity = manifestIdentity
        self.packageVersion = packageVersion
        self.guest = guest
        self.protocolVersion = protocolVersion
        self.state = state
        self.capabilities = capabilities
        self.artifacts = artifacts
        self.qualification = qualification
    }

    public var isValidForPersistence: Bool { validationIssues().isEmpty }

    public func validationIssues() -> [DoryGuestIntegrationPackageValidationIssue] {
        var issues: [DoryGuestIntegrationPackageValidationIssue] = []
        func add(_ code: DoryGuestIntegrationPackageValidationCode, _ field: String) {
            issues.append(.init(code: code, field: field))
        }

        if schemaVersion != Self.schemaVersion { add(.unsupportedSchema, "schemaVersion") }
        if !Self.isIdentifier(manifestIdentity) { add(.invalidIdentity, "manifestIdentity") }
        if !Self.isBoundedLabel(packageVersion, maximumBytes: 64) {
            add(.invalidVersion, "packageVersion")
        }
        if protocolVersion == 0 { add(.invalidVersion, "protocolVersion") }
        if guest.family != .linux, guest.architecture != .arm64 {
            add(.unsupportedPlatform, "guest.architecture")
        }

        let capabilityOrder = capabilities.map { $0.id.rawValue }
        if capabilities.isEmpty
            || capabilityOrder != capabilityOrder.sorted()
            || Set(capabilityOrder).count != capabilityOrder.count
            || capabilities.contains(where: { $0.version == 0 })
            || !capabilities.contains(where: { $0.id == .readiness }) {
            add(.invalidCapabilities, "capabilities")
        }

        let artifactOrder = artifacts.map(\.id)
        if artifacts.isEmpty
            || artifactOrder != artifactOrder.sorted()
            || Set(artifactOrder).count != artifactOrder.count
            || artifacts.contains(where: {
                !Self.isIdentifier($0.id)
                    || !$0.artifact.isValidForPersistence
                    || !Self.isSHA256($0.sha256)
                    || $0.byteCount == 0
            }) {
            add(.invalidArtifacts, "artifacts")
        }

        let allowedRoles: Set<DoryGuestIntegrationArtifactRole>
        let requiredSignature: DoryGuestIntegrationSignatureKind
        switch guest.family {
        case .linux:
            allowedRoles = [.linuxToolsArchive]
            requiredSignature = .doryEd25519
        case .windows:
            allowedRoles = [.windowsService, .windowsDriver]
            requiredSignature = .microsoftAuthenticode
            let roles = Set(artifacts.map(\.role))
            if !roles.contains(.windowsService) || !roles.contains(.windowsDriver) {
                add(.incompleteWindowsPackage, "artifacts")
            }
        case .macOS:
            allowedRoles = [.macOSPackage]
            requiredSignature = .appleDeveloperID
        }
        if artifacts.contains(where: { !allowedRoles.contains($0.role) }) {
            add(.invalidArtifacts, "artifacts.role")
        }
        if artifacts.contains(where: {
            $0.signature.kind != requiredSignature
                || !Self.isBoundedLabel($0.signature.identity, maximumBytes: 256)
                || !Self.isSHA256($0.signature.signatureSHA256)
        }) {
            add(.invalidSignature, "artifacts.signature")
        }

        switch state {
        case .contractOnly:
            if qualification != nil { add(.invalidQualification, "qualification") }
        case .qualified:
            guard let qualification else {
                add(.invalidQualification, "qualification")
                return issues
            }
            let qualified = qualification.qualifiedCapabilities
            if qualification.manifestIdentity != manifestIdentity
                || !Self.isSHA256(qualification.manifestSHA256)
                || !Self.isSHA256(qualification.suiteSHA256)
                || !Self.isSHA256(qualification.sbomSHA256)
                || !Self.isSHA256(qualification.attestationSHA256)
                || qualified != capabilities {
                add(.invalidQualification, "qualification")
            }
        }
        return issues
    }

    private static func isIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...96).contains(bytes.count), let first = bytes.first,
              isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isBoundedLabel(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
