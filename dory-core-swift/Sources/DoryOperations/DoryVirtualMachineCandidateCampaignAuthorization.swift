import CryptoKit
import Darwin
import Foundation
import DoryRendererWorkerWireContracts

/// One exact executable or worker inside the immutable application submitted to a physical
/// qualification campaign. Paths are relative to `applicationRoot`; absolute and indirect paths
/// are rejected by the resolver.
public struct DoryCandidateCampaignArtifact: Codable, Sendable, Equatable, Hashable {
    public var role: String
    public var path: String
    public var byteCount: UInt64
    public var sha256: String

    public init(role: String, path: String, byteCount: UInt64, sha256: String) {
        self.role = role
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
    }
}

public struct DoryCandidateCampaignHostConstraint: Codable, Sendable, Equatable, Hashable {
    public var hardwareModelIdentifier: String
    public var operatingSystemBuild: String

    public init(hardwareModelIdentifier: String, operatingSystemBuild: String) {
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.operatingSystemBuild = operatingSystemBuild
    }
}

public struct DoryCandidateCampaignResourceLimit: Codable, Sendable, Equatable, Hashable {
    public var maximumVirtualCPUCount: UInt64
    public var maximumMemoryBytes: UInt64
    public var maximumStorageBytes: UInt64

    public init(
        maximumVirtualCPUCount: UInt64,
        maximumMemoryBytes: UInt64,
        maximumStorageBytes: UInt64
    ) {
        self.maximumVirtualCPUCount = maximumVirtualCPUCount
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumStorageBytes = maximumStorageBytes
    }
}

/// An authorization cell is intentionally the same exact capability tuple consumed by the normal
/// planner plus its candidate runtime and bounded resources. It authorizes measurement only; it
/// does not assert that the tuple passed qualification.
public struct DoryCandidateCampaignCell: Codable, Sendable, Equatable, Hashable {
    public var cellIdentifier: String
    public var capability: DoryVirtualMachineCapabilityRequest
    public var backendImplementationIdentifier: String
    public var backendRuntimeBuildIdentifier: String
    public var components: [DoryVirtualMachineQualifiedComponent]
    public var resources: DoryCandidateCampaignResourceLimit

    public init(
        cellIdentifier: String,
        capability: DoryVirtualMachineCapabilityRequest,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        components: [DoryVirtualMachineQualifiedComponent],
        resources: DoryCandidateCampaignResourceLimit
    ) {
        self.cellIdentifier = cellIdentifier
        self.capability = capability
        self.backendImplementationIdentifier = backendImplementationIdentifier
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.components = components.sorted { $0.componentIdentifier < $1.componentIdentifier }
        self.resources = resources
    }
}

public struct DoryVirtualMachineCandidateCampaignAuthorization:
    Codable, Sendable, Equatable
{
    public static let kind = "dev.dory.virtual-machine-candidate-campaign-authorization"
    public static let purpose = "candidate-qualification-campaign"
    public static let schemaVersion: UInt16 = 1

    public var kind: String
    public var schemaVersion: UInt16
    public var purpose: String
    public var campaignIdentifier: String
    public var nonce: String
    public var issuedAt: String
    public var expiresAt: String
    public var revocationSequence: UInt64
    public var signingKeyID: String
    public var stateRoot: String
    public var candidateRoot: String
    public var applicationRoot: String
    public var candidateInventoryPath: String
    public var candidateInventorySHA256: String
    public var sbomRoot: String
    public var sbomPath: String
    public var sbomSHA256: String
    public var host: DoryCandidateCampaignHostConstraint
    public var machineIDPrefix: String
    public var artifacts: [DoryCandidateCampaignArtifact]
    public var cells: [DoryCandidateCampaignCell]

    public init(
        campaignIdentifier: String,
        nonce: String,
        issuedAt: String,
        expiresAt: String,
        revocationSequence: UInt64,
        signingKeyID: String,
        stateRoot: String,
        candidateRoot: String,
        applicationRoot: String,
        candidateInventoryPath: String = "component-candidate-inventory.json",
        candidateInventorySHA256: String,
        sbomRoot: String? = nil,
        sbomPath: String = "sbom.spdx.json",
        sbomSHA256: String,
        host: DoryCandidateCampaignHostConstraint,
        machineIDPrefix: String,
        artifacts: [DoryCandidateCampaignArtifact],
        cells: [DoryCandidateCampaignCell]
    ) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        purpose = Self.purpose
        self.campaignIdentifier = campaignIdentifier
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revocationSequence = revocationSequence
        self.signingKeyID = signingKeyID.lowercased()
        self.stateRoot = stateRoot
        self.candidateRoot = candidateRoot
        self.applicationRoot = applicationRoot
        self.candidateInventoryPath = candidateInventoryPath
        self.candidateInventorySHA256 = candidateInventorySHA256.lowercased()
        self.sbomRoot = sbomRoot ?? candidateRoot
        self.sbomPath = sbomPath
        self.sbomSHA256 = sbomSHA256.lowercased()
        self.host = host
        self.machineIDPrefix = machineIDPrefix
        self.artifacts = artifacts.sorted { ($0.role, $0.path) < ($1.role, $1.path) }
        self.cells = cells.sorted { $0.cellIdentifier < $1.cellIdentifier }
    }
}

public enum DoryCandidateCampaignAuthorizationError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case authorityUnreadable
    case signatureInvalid
    case manifestInvalid(String)
    case expired
    case notYetValid
    case revoked
    case artifactMismatch(String)
    case hostMismatch
    case campaignCellUnavailable
    case replayRejected

    public var description: String {
        switch self {
        case .authorityUnreadable: "candidate campaign authority is unreadable"
        case .signatureInvalid: "candidate campaign signature is invalid"
        case let .manifestInvalid(detail): "candidate campaign manifest is invalid: \(detail)"
        case .expired: "candidate campaign authority has expired"
        case .notYetValid: "candidate campaign authority is not yet valid"
        case .revoked: "candidate campaign authority is below the accepted revocation sequence"
        case let .artifactMismatch(role): "candidate campaign artifact does not match: \(role)"
        case .hostMismatch: "candidate campaign host does not match"
        case .campaignCellUnavailable: "candidate campaign does not authorize this exact cell"
        case .replayRejected: "candidate campaign replay state rejected the authority"
        }
    }
}

/// Opaque result of signature, lifetime, root, replay, and candidate-file verification. It is
/// never Codable and cannot be converted into public qualification authority.
public struct DoryVerifiedVirtualMachineCandidateCampaignAuthority: Sendable {
    public let campaignIdentifier: String
    public let manifestSHA256: String
    public let signingKeyID: String
    public let expiresAt: String
    public let revocationSequence: UInt64
    public let stateRoot: String
    fileprivate let manifest: DoryVirtualMachineCandidateCampaignAuthorization

    fileprivate init(
        manifestSHA256: String,
        manifest: DoryVirtualMachineCandidateCampaignAuthorization
    ) {
        campaignIdentifier = manifest.campaignIdentifier
        self.manifestSHA256 = manifestSHA256
        signingKeyID = manifest.signingKeyID
        expiresAt = manifest.expiresAt
        revocationSequence = manifest.revocationSequence
        stateRoot = manifest.stateRoot
        self.manifest = manifest
    }

    public func resolve(
        request: DoryVirtualMachineCapabilityRequest,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        hostHardwareModelIdentifier: String,
        hostOperatingSystemBuild: String,
        installedComponents: [DoryVirtualMachineQualifiedComponent],
        machineID: String,
        virtualCPUCount: UInt64,
        memoryBytes: UInt64,
        storageBytes: UInt64
    ) throws -> DoryResolvedCandidateCampaignCell {
        guard hostHardwareModelIdentifier == manifest.host.hardwareModelIdentifier,
              hostOperatingSystemBuild == manifest.host.operatingSystemBuild else {
            throw DoryCandidateCampaignAuthorizationError.hostMismatch
        }
        guard machineID.hasPrefix(manifest.machineIDPrefix),
              machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil else {
            throw DoryCandidateCampaignAuthorizationError.campaignCellUnavailable
        }
        let components = installedComponents.sorted {
            $0.componentIdentifier < $1.componentIdentifier
        }
        let matches = manifest.cells.filter { cell in
            cell.capability == request
                && cell.backendImplementationIdentifier == backendImplementationIdentifier
                && cell.backendRuntimeBuildIdentifier == backendRuntimeBuildIdentifier
                && cell.components == components
                && virtualCPUCount > 0
                && virtualCPUCount <= cell.resources.maximumVirtualCPUCount
                && memoryBytes > 0
                && memoryBytes <= cell.resources.maximumMemoryBytes
                && storageBytes > 0
                && storageBytes <= cell.resources.maximumStorageBytes
        }
        guard matches.count == 1, let cell = matches.first else {
            throw DoryCandidateCampaignAuthorizationError.campaignCellUnavailable
        }
        return DoryResolvedCandidateCampaignCell(
            campaignIdentifier: campaignIdentifier,
            manifestSHA256: manifestSHA256,
            signingKeyID: signingKeyID,
            cell: cell
        )
    }

    /// Commits this already verified authority as the monotonic campaign floor. Reusing the same
    /// manifest is idempotent; a conflicting nonce/digest or an older revocation sequence fails.
    public func activateReplayFloor() throws {
        try DoryCandidateCampaignReplayFloor.activate(authority: self)
    }
}

public struct DoryResolvedCandidateCampaignCell: Sendable, Equatable {
    public let campaignIdentifier: String
    public let manifestSHA256: String
    public let signingKeyID: String
    public let cell: DoryCandidateCampaignCell

    public init(
        campaignIdentifier: String,
        manifestSHA256: String,
        signingKeyID: String,
        cell: DoryCandidateCampaignCell
    ) {
        self.campaignIdentifier = campaignIdentifier
        self.manifestSHA256 = manifestSHA256
        self.signingKeyID = signingKeyID
        self.cell = cell
    }

    public var authorizationIdentity: String {
        "candidate-campaign-" + String(manifestSHA256.prefix(24))
    }

    /// Candidate media identity is sufficient for the campaign planner to persist a transparent
    /// inspection reference. This is not a catalog-manifest qualification reference.
    public var bootMediaInspectionEvidence: DoryBootMediaInspectionAuditEvidence? {
        guard cell.capability.bootMedia.kind == .installerISO
                || cell.capability.bootMedia.kind == .macOSRestoreImage,
              let digest = cell.capability.bootMedia.artifactSHA256 else { return nil }
        return DoryBootMediaInspectionAuditEvidence(
            inspectionIdentity: "candidate-" + cell.cellIdentifier,
            artifactSHA256: digest,
            inspectionReportSHA256: manifestSHA256,
            inspectorID: "dory.candidate-campaign.media-binding",
            inspectorVersion: DoryVirtualMachineCandidateCampaignAuthorization.schemaVersion,
            catalogManifestEvidence: nil,
            detectedArchitecture: cell.capability.guest.architecture,
            detectedKind: cell.capability.bootMedia.kind
        )
    }
}

public enum DoryVirtualMachineCandidateCampaignAuthorityResolver {
    public static let maximumAuthorityBytes = 4 * 1_024 * 1_024
    public static let maximumSignatureBytes = 256
    public static let maximumLifetime: TimeInterval = 7 * 24 * 60 * 60

    public static func resolve(
        authorityPath: String,
        signaturePath: String,
        publicKeyBase64: String,
        expectedStateRoot: String,
        expectedApplicationRoot: String,
        minimumRevocationSequence: UInt64 = 1,
        now: Date = Date()
    ) throws -> DoryVerifiedVirtualMachineCandidateCampaignAuthority {
        let authorityData = try stableData(
            authorityPath, maximumBytes: maximumAuthorityBytes
        )
        let signatureData = try stableData(
            signaturePath, maximumBytes: maximumSignatureBytes
        )
        guard let signatureText = String(data: signatureData, encoding: .ascii),
              signatureText == signatureText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
              let signature = Data(base64Encoded: String(signatureText.dropLast())),
              signature.count == 64,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
              ),
              publicKey.isValidSignature(signature, for: authorityData) else {
            throw DoryCandidateCampaignAuthorizationError.signatureInvalid
        }
        let manifest: DoryVirtualMachineCandidateCampaignAuthorization
        do {
            manifest = try JSONDecoder().decode(
                DoryVirtualMachineCandidateCampaignAuthorization.self,
                from: authorityData
            )
        } catch {
            throw DoryCandidateCampaignAuthorizationError.authorityUnreadable
        }
        guard canonicalData(manifest) == authorityData else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "JSON is not canonical or contains unknown fields"
            )
        }
        try validate(
            manifest,
            publicKeyData: publicKeyData,
            expectedStateRoot: expectedStateRoot,
            expectedApplicationRoot: expectedApplicationRoot,
            minimumRevocationSequence: minimumRevocationSequence,
            now: now
        )
        try verifyCandidateFiles(manifest)
        let authority = DoryVerifiedVirtualMachineCandidateCampaignAuthority(
            manifestSHA256: digest(authorityData), manifest: manifest
        )
        try DoryCandidateCampaignReplayFloor.validate(authority: authority)
        return authority
    }

    private static func validate(
        _ manifest: DoryVirtualMachineCandidateCampaignAuthorization,
        publicKeyData: Data,
        expectedStateRoot: String,
        expectedApplicationRoot: String,
        minimumRevocationSequence: UInt64,
        now: Date
    ) throws {
        guard manifest.kind == DoryVirtualMachineCandidateCampaignAuthorization.kind,
              manifest.schemaVersion
                == DoryVirtualMachineCandidateCampaignAuthorization.schemaVersion,
              manifest.purpose == DoryVirtualMachineCandidateCampaignAuthorization.purpose,
              safeIdentifier(manifest.campaignIdentifier),
              safeIdentifier(manifest.nonce),
              safeIdentifier(manifest.machineIDPrefix),
              manifest.signingKeyID == digest(publicKeyData),
              isSHA256(manifest.candidateInventorySHA256),
              isSHA256(manifest.sbomSHA256),
              manifest.stateRoot == canonical(expectedStateRoot),
              manifest.applicationRoot == canonical(expectedApplicationRoot),
              manifest.stateRoot == canonical(manifest.stateRoot),
              manifest.applicationRoot == canonical(manifest.applicationRoot),
              manifest.candidateRoot == canonical(manifest.candidateRoot),
              manifest.sbomRoot == canonical(manifest.sbomRoot),
              secureDirectory(manifest.stateRoot),
              secureDirectory(manifest.applicationRoot),
              secureDirectory(manifest.candidateRoot),
              secureDirectory(manifest.sbomRoot),
              let issued = timestamp(manifest.issuedAt),
              let expires = timestamp(manifest.expiresAt),
              issued < expires,
              expires.timeIntervalSince(issued) <= maximumLifetime else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "identity, root, signing key, or lifetime is invalid"
            )
        }
        guard manifest.revocationSequence >= minimumRevocationSequence else {
            throw DoryCandidateCampaignAuthorizationError.revoked
        }
        guard now >= issued else {
            throw DoryCandidateCampaignAuthorizationError.notYetValid
        }
        guard now < expires else {
            throw DoryCandidateCampaignAuthorizationError.expired
        }
        guard !manifest.cells.isEmpty,
              Set(manifest.cells.map(\.cellIdentifier)).count == manifest.cells.count,
              Set(manifest.cells.map(\.capability)).count == manifest.cells.count,
              manifest.cells.map(\.cellIdentifier) == manifest.cells.map(\.cellIdentifier).sorted(),
              manifest.cells.allSatisfy(validCell) else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "campaign cells are empty, duplicated, unordered, or invalid"
            )
        }
        let roles = manifest.artifacts.map(\.role)
        let requiredRoles: Set<String> = [
            "app", "control", "daemon", "dory-hv", "dory-vmm", "renderer-worker",
            "filesystem-worker",
        ]
        let artifactOrdering = manifest.artifacts.map { $0.role + "\u{0}" + $0.path }
        guard artifactOrdering == artifactOrdering.sorted(),
              Set(roles).count == roles.count,
              requiredRoles.isSubset(of: Set(roles)) else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "candidate artifacts are unordered, duplicated, or incomplete"
            )
        }
    }

    private static func validCell(_ cell: DoryCandidateCampaignCell) -> Bool {
        safeIdentifier(cell.cellIdentifier)
            && !cell.backendImplementationIdentifier.isEmpty
            && cell.backendImplementationIdentifier.utf8.count <= 128
            && cell.backendRuntimeBuildIdentifier.hasPrefix("sha256:")
            && isSHA256(String(cell.backendRuntimeBuildIdentifier.dropFirst(7)))
            && cell.capability.virtualHardwareABIVersion > 0
            && [.doryHypervisor, .appleVirtualizationFramework]
                .contains(cell.capability.backend)
            && cell.resources.maximumVirtualCPUCount > 0
            && cell.resources.maximumMemoryBytes > 0
            && cell.resources.maximumStorageBytes > 0
            && !cell.components.isEmpty
            && cell.components == cell.components.sorted {
                $0.componentIdentifier < $1.componentIdentifier
            }
            && Set(cell.components.map(\.componentIdentifier)).count
                == cell.components.count
            && cell.components.allSatisfy {
                safeIdentifier($0.componentIdentifier)
                    && !$0.buildIdentifier.isEmpty
                    && $0.buildIdentifier.utf8.count <= 128
                    && isSHA256($0.artifactSHA256)
            }
            && {
                let media = cell.capability.bootMedia
                if media.kind == .virtualDisk {
                    return media.artifactSHA256 == nil && media.mutableProvenance != nil
                }
                return media.mutableProvenance == nil
                    && media.artifactSHA256.map(isSHA256) == true
            }()
    }

    private static func verifyCandidateFiles(
        _ manifest: DoryVirtualMachineCandidateCampaignAuthorization
    ) throws {
        try verify(
            root: manifest.candidateRoot,
            relativePath: manifest.candidateInventoryPath,
            expectedBytes: nil,
            expectedSHA256: manifest.candidateInventorySHA256,
            role: "component-candidate-inventory"
        )
        try verify(
            root: manifest.sbomRoot,
            relativePath: manifest.sbomPath,
            expectedBytes: nil,
            expectedSHA256: manifest.sbomSHA256,
            role: "sbom"
        )
        for artifact in manifest.artifacts {
            try verify(
                root: manifest.applicationRoot,
                relativePath: artifact.path,
                expectedBytes: artifact.byteCount,
                expectedSHA256: artifact.sha256,
                role: artifact.role
            )
        }
    }

    private static func verify(
        root: String,
        relativePath: String,
        expectedBytes: UInt64?,
        expectedSHA256: String,
        role: String
    ) throws {
        guard safeRelativePath(relativePath), isSHA256(expectedSHA256) else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "unsafe path or digest for \(role)"
            )
        }
        guard secureParentDirectories(root: root, relativePath: relativePath) else {
            throw DoryCandidateCampaignAuthorizationError.manifestInvalid(
                "indirect or writable parent path for \(role)"
            )
        }
        let path = root + "/" + relativePath
        let data = try stableData(path, maximumBytes: Int.max)
        guard expectedBytes.map({ UInt64(data.count) == $0 }) ?? true,
              digest(data) == expectedSHA256 else {
            throw DoryCandidateCampaignAuthorizationError.artifactMismatch(role)
        }
    }

    private static func stableData(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryCandidateCampaignAuthorizationError.authorityUnreadable
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_nlink == 1,
              before.st_uid == geteuid() || before.st_uid == 0,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0,
              before.st_size <= maximumBytes else {
            throw DoryCandidateCampaignAuthorizationError.authorityUnreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), 4 * 1_024 * 1_024))
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            guard data.count <= maximumBytes - chunk.count else {
                throw DoryCandidateCampaignAuthorizationError.authorityUnreadable
            }
            data.append(chunk)
        }
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(path, &pathInfo) == 0,
              sameSnapshot(before, after),
              sameSnapshot(after, pathInfo) else {
            throw DoryCandidateCampaignAuthorizationError.authorityUnreadable
        }
        return data
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func secureDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && (info.st_uid == geteuid() || info.st_uid == 0)
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func secureParentDirectories(root: String, relativePath: String) -> Bool {
        var path = root
        for component in relativePath.split(separator: "/").dropLast() {
            path += "/" + component
            guard secureDirectory(path) else { return false }
        }
        return true
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && value.utf8.count <= 512
            && value.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { part in
                    !part.isEmpty && part != "." && part != ".."
                        && part.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
                }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,127}/) != nil
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

private enum DoryCandidateCampaignReplayFloor {
    private static let fileName = ".vm-candidate-campaign-floor-v1"
    private static let lockFileName = ".vm-candidate-campaign-floor.lock"
    private static let maximumBytes = 2_048

    private struct Record: Codable, Equatable {
        static let kind = "dev.dory.vm-candidate-campaign-floor"
        static let schemaVersion: UInt16 = 1

        let kind: String
        let schemaVersion: UInt16
        let campaignIdentifier: String
        let nonce: String
        let manifestSHA256: String
        let revocationSequence: UInt64
        let expiresAt: String

        init(authority: DoryVerifiedVirtualMachineCandidateCampaignAuthority) {
            kind = Self.kind
            schemaVersion = Self.schemaVersion
            campaignIdentifier = authority.manifest.campaignIdentifier
            nonce = authority.manifest.nonce
            manifestSHA256 = authority.manifestSHA256
            revocationSequence = authority.revocationSequence
            expiresAt = authority.expiresAt
        }
    }

    static func validate(
        authority: DoryVerifiedVirtualMachineCandidateCampaignAuthority
    ) throws {
        try validate(Record(authority: authority), against: read(stateRoot: authority.stateRoot))
    }

    static func activate(
        authority: DoryVerifiedVirtualMachineCandidateCampaignAuthority
    ) throws {
        let candidate = Record(authority: authority)
        let lock = try EngineStateDirectoryLock(
            stateDirectory: authority.stateRoot,
            lockFileName: lockFileName
        )
        defer { withExtendedLifetime(lock) {} }
        let current = try read(stateRoot: authority.stateRoot)
        try validate(candidate, against: current)
        if candidate == current { return }

        let path = authority.stateRoot + "/" + fileName
        let temporary = authority.stateRoot + "/." + fileName + "."
            + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = open(
            temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(candidate) + Data("\n".utf8)
        var isOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor, bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw DoryCandidateCampaignAuthorizationError.replayRejected
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DoryCandidateCampaignAuthorizationError.replayRejected
            }
            close(descriptor)
            isOpen = false
            guard rename(temporary, path) == 0 else {
                throw DoryCandidateCampaignAuthorizationError.replayRejected
            }
            let directory = open(authority.stateRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else {
                throw DoryCandidateCampaignAuthorizationError.replayRejected
            }
            defer { close(directory) }
            guard fsync(directory) == 0 else {
                throw DoryCandidateCampaignAuthorizationError.replayRejected
            }
        } catch {
            if isOpen { close(descriptor) }
            unlink(temporary)
            throw error
        }
    }

    private static func read(stateRoot: String) throws -> Record? {
        let path = stateRoot + "/" + fileName
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.readToEnd(), data.count == info.st_size,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.kind == Record.kind,
              record.schemaVersion == Record.schemaVersion,
              record.manifestSHA256.utf8.count == 64 else {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        return record
    }

    private static func validate(_ candidate: Record, against current: Record?) throws {
        guard let current else { return }
        guard candidate.revocationSequence >= current.revocationSequence else {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        if candidate.revocationSequence == current.revocationSequence,
           candidate != current {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
        if candidate.campaignIdentifier == current.campaignIdentifier,
           candidate != current {
            throw DoryCandidateCampaignAuthorizationError.replayRejected
        }
    }
}
