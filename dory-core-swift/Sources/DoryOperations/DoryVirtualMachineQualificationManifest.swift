import CryptoKit
import Foundation

public struct DoryVirtualMachineQualifiedComponent: Codable, Sendable, Equatable, Hashable {
    public var componentIdentifier: String
    public var buildIdentifier: String
    public var artifactSHA256: String

    public init(componentIdentifier: String, buildIdentifier: String, artifactSHA256: String) {
        self.componentIdentifier = componentIdentifier
        self.buildIdentifier = buildIdentifier
        self.artifactSHA256 = artifactSHA256.lowercased()
    }
}

/// One signed, exact result from Dory's backend conformance matrix. This is data inside a
/// catalog-authenticated asset; decoding this type alone never creates trusted capability facts.
public struct DoryVirtualMachineQualificationRecord: Codable, Sendable, Equatable, Hashable {
    public var qualificationIdentity: String
    public var guest: DoryGuestPlatform
    public var bootMediaKind: DoryBootMediaKind
    public var bootMediaSource: DoryBootMediaSource
    public var immutableArtifactSHA256: String?
    public var mutableProvenance: DoryMutableBootMediaProvenanceReference?
    public var backend: DoryVirtualizationBackendIdentity
    public var backendImplementationIdentifier: String
    public var backendRuntimeBuildIdentifier: String
    public var virtualHardwareABIVersion: UInt16
    public var graphics: DoryGraphicsAccelerationLevel
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var hostHardwareModelIdentifier: String
    public var hostOperatingSystemBuild: String
    public var components: [DoryVirtualMachineQualifiedComponent]
    public var virtioGPUKernelAndDeviceSupportQualified: Bool
    public var venusVulkanGuestRuntimeQualified: Bool

    public init(
        qualificationIdentity: String,
        guest: DoryGuestPlatform,
        bootMediaKind: DoryBootMediaKind,
        bootMediaSource: DoryBootMediaSource,
        immutableArtifactSHA256: String? = nil,
        mutableProvenance: DoryMutableBootMediaProvenanceReference? = nil,
        backend: DoryVirtualizationBackendIdentity,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        hostHardwareModelIdentifier: String,
        hostOperatingSystemBuild: String,
        components: [DoryVirtualMachineQualifiedComponent],
        virtioGPUKernelAndDeviceSupportQualified: Bool = false,
        venusVulkanGuestRuntimeQualified: Bool = false
    ) {
        self.qualificationIdentity = qualificationIdentity
        self.guest = guest
        self.bootMediaKind = bootMediaKind
        self.bootMediaSource = bootMediaSource
        self.immutableArtifactSHA256 = immutableArtifactSHA256?.lowercased()
        self.mutableProvenance = mutableProvenance
        self.backend = backend
        self.backendImplementationIdentifier = backendImplementationIdentifier
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.graphics = graphics
        self.devices = devices
        self.hostHardwareModelIdentifier = hostHardwareModelIdentifier
        self.hostOperatingSystemBuild = hostOperatingSystemBuild
        self.components = components.sorted { $0.componentIdentifier < $1.componentIdentifier }
        self.virtioGPUKernelAndDeviceSupportQualified =
            virtioGPUKernelAndDeviceSupportQualified
        self.venusVulkanGuestRuntimeQualified = venusVulkanGuestRuntimeQualified
    }
}

public struct DoryVirtualMachineQualificationManifest: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.virtual-machine-qualification-manifest"
    public static let schemaVersion: UInt16 = 1

    public var kind: String
    public var schemaVersion: UInt16
    public var manifestIdentity: String
    public var catalogReleaseVersion: String
    public var architecture: String
    public var signingKeyID: String
    public var records: [DoryVirtualMachineQualificationRecord]

    public init(
        manifestIdentity: String,
        catalogReleaseVersion: String,
        architecture: String,
        signingKeyID: String,
        records: [DoryVirtualMachineQualificationRecord]
    ) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        self.manifestIdentity = manifestIdentity
        self.catalogReleaseVersion = catalogReleaseVersion
        self.architecture = architecture
        self.signingKeyID = signingKeyID
        self.records = records
    }
}

public enum DoryVirtualMachineQualificationAuthorityError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case catalogUnavailable
    case catalogSchemaUnsupported(Int)
    case authorityUndeclared
    case declarationInvalid
    case installedComponentUnavailable
    case installedComponentCatalogMismatch
    case manifestUnreadable
    case manifestInvalid(String)
    case qualificationUnavailable
    case mediaInspectionFailed

    public var description: String {
        switch self {
        case .catalogUnavailable: "no signature-verified component catalog is cached"
        case let .catalogSchemaUnsupported(version):
            "component catalog schema \(version) cannot authorize VM qualifications"
        case .authorityUndeclared: "component catalog does not declare a VM qualification asset"
        case .declarationInvalid: "VM qualification declaration is invalid"
        case .installedComponentUnavailable: "qualification component is not installed and verified"
        case .installedComponentCatalogMismatch:
            "installed qualification component does not belong to the verified catalog"
        case .manifestUnreadable: "qualification manifest asset cannot be read and verified"
        case let .manifestInvalid(detail): "qualification manifest is invalid: \(detail)"
        case .qualificationUnavailable: "no exact signed VM qualification matches the request"
        case .mediaInspectionFailed: "boot media does not match its signed qualification"
        }
    }
}

/// Non-Codable authority returned only after the entire catalog -> installed generation -> asset
/// digest chain has been checked. It is safe to pass inside the daemon, never through API intent.
public struct DoryVerifiedVirtualMachineQualificationAuthority: Sendable {
    public let catalogDigest: String
    public let catalogReleaseVersion: String
    public let catalogGeneratedAt: String
    public let componentIdentifier: String
    public let componentVersion: String
    public let manifestSHA256: String
    public let manifestIdentity: String
    public let signingKeyID: String

    fileprivate let manifest: DoryVirtualMachineQualificationManifest

    fileprivate init(
        catalogDigest: String,
        catalogReleaseVersion: String,
        catalogGeneratedAt: String,
        componentIdentifier: String,
        componentVersion: String,
        manifestSHA256: String,
        manifestIdentity: String,
        signingKeyID: String,
        manifest: DoryVirtualMachineQualificationManifest
    ) {
        self.catalogDigest = catalogDigest
        self.catalogReleaseVersion = catalogReleaseVersion
        self.catalogGeneratedAt = catalogGeneratedAt
        self.componentIdentifier = componentIdentifier
        self.componentVersion = componentVersion
        self.manifestSHA256 = manifestSHA256
        self.manifestIdentity = manifestIdentity
        self.signingKeyID = signingKeyID
        self.manifest = manifest
    }

    public func resolve(
        request: DoryVirtualMachineCapabilityRequest,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        hostHardwareModelIdentifier: String,
        hostOperatingSystemBuild: String,
        installedComponents: [DoryVirtualMachineQualifiedComponent]
    ) throws -> DoryResolvedTrustedVirtualMachineQualification {
        let components = installedComponents.sorted {
            $0.componentIdentifier < $1.componentIdentifier
        }
        let matches = manifest.records.filter {
            $0.guest == request.guest
                && $0.bootMediaKind == request.bootMedia.kind
                && $0.bootMediaSource == request.bootMedia.source
                && $0.immutableArtifactSHA256?.lowercased()
                    == request.bootMedia.artifactSHA256?.lowercased()
                && $0.mutableProvenance == request.bootMedia.mutableProvenance
                && $0.backend == request.backend
                && $0.backendImplementationIdentifier == backendImplementationIdentifier
                && $0.backendRuntimeBuildIdentifier == backendRuntimeBuildIdentifier
                && $0.virtualHardwareABIVersion == request.virtualHardwareABIVersion
                && $0.graphics == request.graphics
                && $0.devices == request.devices
                && $0.hostHardwareModelIdentifier == hostHardwareModelIdentifier
                && $0.hostOperatingSystemBuild == hostOperatingSystemBuild
                && $0.components == components
        }
        guard matches.count == 1, let record = matches.first else {
            throw DoryVirtualMachineQualificationAuthorityError.qualificationUnavailable
        }

        let evidence = DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: record.qualificationIdentity,
            qualificationReportSHA256: Self.digest(Self.canonicalData(record)),
            signingKeyID: signingKeyID,
            qualificationFormatVersion: manifest.schemaVersion,
            guest: record.guest,
            bootMediaKind: record.bootMediaKind,
            immutableArtifactSHA256: record.immutableArtifactSHA256,
            mutableProvenance: record.mutableProvenance,
            backend: record.backend,
            backendRuntimeBuildID: record.backendRuntimeBuildIdentifier,
            virtualHardwareABIVersion: record.virtualHardwareABIVersion,
            graphics: record.graphics,
            devices: record.devices
        )
        let runtime = DoryTrustedVirtualMachineRuntimeQualification(
            auditEvidence: evidence,
            runtimeQualified: true
        )
        let graphics: DoryTrustedGuestImageGraphicsQualification?
        if record.guest.family == .linux,
           record.backend == .doryHypervisor,
           record.graphics != .none {
            graphics = DoryTrustedGuestImageGraphicsQualification(
                auditEvidence: DorySignedArtifactQualificationEvidence(
                    manifestIdentity: manifestIdentity,
                    artifactSHA256: request.bootMedia.artifactSHA256 ?? "",
                    manifestSHA256: manifestSHA256,
                    signingKeyID: signingKeyID,
                    manifestFormatVersion: manifest.schemaVersion
                ),
                virtioGPUKernelAndDeviceSupportQualified:
                    record.virtioGPUKernelAndDeviceSupportQualified,
                venusVulkanGuestRuntimeQualified:
                    record.venusVulkanGuestRuntimeQualified
            )
        } else {
            graphics = nil
        }
        return DoryResolvedTrustedVirtualMachineQualification(
            record: record,
            runtime: runtime,
            graphics: graphics,
            manifestIdentity: manifestIdentity,
            manifestSHA256: manifestSHA256,
            signingKeyID: signingKeyID
        )
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DoryResolvedTrustedVirtualMachineQualification: Sendable {
    public let record: DoryVirtualMachineQualificationRecord
    public let runtime: DoryTrustedVirtualMachineRuntimeQualification
    public let graphics: DoryTrustedGuestImageGraphicsQualification?
    fileprivate let manifestIdentity: String
    fileprivate let manifestSHA256: String
    fileprivate let signingKeyID: String
}

public enum DoryVirtualMachineQualificationAuthorityResolver {
    public static let maximumManifestBytes = 4 * 1_024 * 1_024

    public static func resolve(
        store: DoryComponentStore,
        publicKey: String,
        expectedArchitecture: String,
        appVersion: String
    ) throws -> DoryVerifiedVirtualMachineQualificationAuthority {
        guard let cached = try store.cachedCatalog(
            publicKey: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        ) else {
            throw DoryVirtualMachineQualificationAuthorityError.catalogUnavailable
        }
        guard cached.catalog.schemaVersion == DoryComponentCatalog.schemaVersion else {
            throw DoryVirtualMachineQualificationAuthorityError.catalogSchemaUnsupported(
                cached.catalog.schemaVersion
            )
        }
        guard let declaration = cached.catalog.virtualMachineQualification else {
            throw DoryVirtualMachineQualificationAuthorityError.authorityUndeclared
        }
        guard let release = cached.catalog.component(declaration.component),
              let declaredAsset = release.assets.first(where: {
                  $0.path == declaration.path
              }) else {
            throw DoryVirtualMachineQualificationAuthorityError.declarationInvalid
        }
        let installed: DoryInstalledComponent
        do {
            installed = try store.verify(declaration.component)
        } catch {
            throw DoryVirtualMachineQualificationAuthorityError.installedComponentUnavailable
        }
        let catalogDigest = DoryComponentCatalogVerifier.digest(cached.data)
        guard installed.catalogDigest == catalogDigest,
              installed.version == release.version,
              installed.assets == release.assets,
              installed.assets.contains(declaredAsset) else {
            throw DoryVirtualMachineQualificationAuthorityError
                .installedComponentCatalogMismatch
        }
        let data: Data
        do {
            data = try store.verifiedAssetData(
                component: declaration.component,
                path: declaration.path,
                maximumBytes: maximumManifestBytes
            )
        } catch {
            throw DoryVirtualMachineQualificationAuthorityError.manifestUnreadable
        }
        let manifest: DoryVirtualMachineQualificationManifest
        do {
            manifest = try JSONDecoder().decode(
                DoryVirtualMachineQualificationManifest.self,
                from: data
            )
        } catch {
            throw DoryVirtualMachineQualificationAuthorityError.manifestInvalid(
                "JSON could not be decoded"
            )
        }
        try validate(
            manifest,
            declaration: declaration,
            catalog: cached.catalog,
            manifestSHA256: declaredAsset.installedSHA256,
            expectedSigningKeyID: signingKeyID(publicKey)
        )
        return DoryVerifiedVirtualMachineQualificationAuthority(
            catalogDigest: catalogDigest,
            catalogReleaseVersion: cached.catalog.releaseVersion,
            catalogGeneratedAt: cached.catalog.generatedAt,
            componentIdentifier: installed.id.rawValue,
            componentVersion: installed.version,
            manifestSHA256: declaredAsset.installedSHA256,
            manifestIdentity: manifest.manifestIdentity,
            signingKeyID: manifest.signingKeyID,
            manifest: manifest
        )
    }

    private static func validate(
        _ manifest: DoryVirtualMachineQualificationManifest,
        declaration: DoryComponentVirtualMachineQualificationAsset,
        catalog: DoryComponentCatalog,
        manifestSHA256: String,
        expectedSigningKeyID: String
    ) throws {
        guard manifest.kind == DoryVirtualMachineQualificationManifest.kind,
              manifest.schemaVersion == DoryVirtualMachineQualificationManifest.schemaVersion,
              declaration.manifestFormatVersion == manifest.schemaVersion,
              declaration.manifestIdentity == manifest.manifestIdentity,
              declaration.signingKeyID == manifest.signingKeyID,
              manifest.signingKeyID == expectedSigningKeyID,
              manifest.catalogReleaseVersion == catalog.releaseVersion,
              manifest.architecture == catalog.architecture,
              !manifest.records.isEmpty,
              isSHA256(manifestSHA256),
              Set(manifest.records.map(\.qualificationIdentity)).count
                == manifest.records.count,
              manifest.records.allSatisfy(recordIsValid) else {
            throw DoryVirtualMachineQualificationAuthorityError.manifestInvalid(
                "header, key, catalog, or record binding is incomplete"
            )
        }
    }

    private static func recordIsValid(_ record: DoryVirtualMachineQualificationRecord) -> Bool {
        let mediaBindingCount = (record.immutableArtifactSHA256 == nil ? 0 : 1)
            + (record.mutableProvenance == nil ? 0 : 1)
        return !record.qualificationIdentity.isEmpty
            && mediaBindingCount == 1
            && (record.immutableArtifactSHA256.map(isSHA256) ?? true)
            && record.mutableProvenance.map {
                !$0.repositoryIdentity.isEmpty && !$0.mediaIdentity.isEmpty && $0.revision > 0
            } ?? true
            && !record.backendImplementationIdentifier.isEmpty
            && !record.backendRuntimeBuildIdentifier.isEmpty
            && record.virtualHardwareABIVersion > 0
            && !record.hostHardwareModelIdentifier.isEmpty
            && !record.hostOperatingSystemBuild.isEmpty
            && !record.components.isEmpty
            && Set(record.components.map(\.componentIdentifier)).count
                == record.components.count
            && record.components.allSatisfy {
                !$0.componentIdentifier.isEmpty
                    && !$0.buildIdentifier.isEmpty
                    && isSHA256($0.artifactSHA256)
            }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    private static func signingKeyID(_ publicKeyBase64: String) -> String {
        guard let bytes = Data(base64Encoded: publicKeyBase64) else { return "" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DoryQualifiedBootMediaInspector {
    public static let inspectorID = "dory.iso9660-efi-inspector"
    public static let inspectorVersion: UInt16 = 1

    /// Structural inspection is bound to a catalog-authenticated exact qualification. This avoids
    /// treating a caller-declared guest family as a fact about arbitrary ISO bytes.
    public static func inspectInstallerISO(
        atPath path: String,
        qualification: DoryResolvedTrustedVirtualMachineQualification
    ) throws -> (media: DoryBootMedia, inspection: DoryTrustedBootMediaInspection) {
        let record = qualification.record
        guard record.bootMediaKind == .installerISO,
              let expectedDigest = record.immutableArtifactSHA256 else {
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        let identity: DoryInstallerISOMediaIdentity
        do { identity = try DoryInstallerISOInspector.mediaIdentity(atPath: path) }
        catch {
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        let architecture: DoryGuestArchitecture
        switch identity.architecture {
        case .arm64: architecture = .arm64
        case .x86_64: architecture = .x86_64
        case .multiArchitecture: architecture = record.guest.architecture
        case .unknown:
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        guard identity.sha256 == expectedDigest.lowercased(),
              architecture == record.guest.architecture else {
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        let report = ISOInspectionReport(
            artifactSHA256: identity.sha256,
            byteCount: identity.byteCount,
            architecture: identity.architecture.rawValue,
            guest: record.guest,
            efiBootable: true
        )
        let evidence = DoryBootMediaInspectionAuditEvidence(
            inspectionIdentity: "\(inspectorID):\(identity.sha256)",
            artifactSHA256: identity.sha256,
            inspectionReportSHA256: digest(canonicalData(report)),
            inspectorID: inspectorID,
            inspectorVersion: inspectorVersion,
            catalogManifestEvidence: DorySignedArtifactQualificationEvidence(
                manifestIdentity: qualification.manifestIdentity,
                artifactSHA256: identity.sha256,
                manifestSHA256: qualification.manifestSHA256,
                signingKeyID: qualification.signingKeyID,
                manifestFormatVersion:
                    DoryVirtualMachineQualificationManifest.schemaVersion
            )
        )
        return (
            DoryBootMedia(
                kind: .installerISO,
                source: record.bootMediaSource,
                artifactSHA256: identity.sha256
            ),
            DoryTrustedBootMediaInspection(
                auditEvidence: evidence,
                detectedKind: .installerISO,
                detectedGuestFamily: record.guest.family,
                detectedArchitecture: architecture,
                isEFIBootable: true
            )
        )
    }

    private struct ISOInspectionReport: Codable {
        var artifactSHA256: String
        var byteCount: UInt64
        var architecture: String
        var guest: DoryGuestPlatform
        var efiBootable: Bool
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
