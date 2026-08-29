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

/// Immutable release-candidate identity shared by the qualification manifest and every physical
/// performance-campaign receipt. Neither digest is inferred from a mutable installation.
public struct DoryVirtualMachineQualificationCandidateBinding:
    Codable, Sendable, Equatable, Hashable
{
    public var componentCandidateInventorySHA256: String
    public var sbomSHA256: String

    public init(componentCandidateInventorySHA256: String, sbomSHA256: String) {
        self.componentCandidateInventorySHA256 = componentCandidateInventorySHA256.lowercased()
        self.sbomSHA256 = sbomSHA256.lowercased()
    }
}

/// Digest-bound pointer from one qualification record to the independently signed result of its
/// physical performance campaign. A manifest record without this evidence cannot mint runtime or
/// graphics authority.
public struct DoryVirtualMachinePerformanceQualificationEvidence:
    Codable, Sendable, Equatable, Hashable
{
    public var bundleInventorySHA256: String
    public var graphicsImplementation: String
    public var matrixCellID: String
    public var signaturePublicKeyID: String
    public var verificationReceiptPath: String
    public var verificationReceiptSHA256: String

    public init(
        bundleInventorySHA256: String,
        graphicsImplementation: String,
        matrixCellID: String,
        signaturePublicKeyID: String,
        verificationReceiptPath: String,
        verificationReceiptSHA256: String
    ) {
        self.bundleInventorySHA256 = bundleInventorySHA256.lowercased()
        self.graphicsImplementation = graphicsImplementation
        self.matrixCellID = matrixCellID.lowercased()
        self.signaturePublicKeyID = signaturePublicKeyID.lowercased()
        self.verificationReceiptPath = verificationReceiptPath
        self.verificationReceiptSHA256 = verificationReceiptSHA256.lowercased()
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
    /// `true` only when the exact guest kernel waits for the framebuffer writer fence before its
    /// virtio-gpu KMS path publishes `RESOURCE_FLUSH`. Older manifests decode this as `nil` and
    /// therefore cannot authorize acceleration.
    public var producerFenceBeforeFlushQualified: Bool?
    public var venusVulkanGuestRuntimeQualified: Bool
    public var performanceQualification: DoryVirtualMachinePerformanceQualificationEvidence

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
        producerFenceBeforeFlushQualified: Bool = false,
        venusVulkanGuestRuntimeQualified: Bool = false,
        performanceQualification: DoryVirtualMachinePerformanceQualificationEvidence
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
        self.producerFenceBeforeFlushQualified = producerFenceBeforeFlushQualified
        self.venusVulkanGuestRuntimeQualified = venusVulkanGuestRuntimeQualified
        self.performanceQualification = performanceQualification
    }
}

public struct DoryVirtualMachineQualificationManifest: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.virtual-machine-qualification-manifest"
    public static let schemaVersion: UInt16 = 2

    public var kind: String
    public var schemaVersion: UInt16
    public var manifestIdentity: String
    public var catalogReleaseVersion: String
    public var architecture: String
    public var signingKeyID: String
    public var candidateBinding: DoryVirtualMachineQualificationCandidateBinding
    public var records: [DoryVirtualMachineQualificationRecord]

    public init(
        manifestIdentity: String,
        catalogReleaseVersion: String,
        architecture: String,
        signingKeyID: String,
        candidateBinding: DoryVirtualMachineQualificationCandidateBinding,
        records: [DoryVirtualMachineQualificationRecord]
    ) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        self.manifestIdentity = manifestIdentity
        self.catalogReleaseVersion = catalogReleaseVersion
        self.architecture = architecture
        self.signingKeyID = signingKeyID
        self.candidateBinding = candidateBinding
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
    case performanceEvidenceUnreadable
    case performanceEvidenceInvalid(String)
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
        case .performanceEvidenceUnreadable:
            "performance qualification evidence cannot be read and verified"
        case let .performanceEvidenceInvalid(detail):
            "performance qualification evidence is invalid: \(detail)"
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
                && $0.devices.matchesRuntimeQualificationContract(request.devices)
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
                producerFenceBeforeFlushQualified:
                    record.producerFenceBeforeFlushQualified == true,
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
            capabilityQualification: DoryTrustedVirtualMachineCapabilityQualification(
                request: request,
                runtime: runtime,
                graphics: graphics
            ),
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
    public let capabilityQualification: DoryTrustedVirtualMachineCapabilityQualification
    fileprivate let manifestIdentity: String
    fileprivate let manifestSHA256: String
    fileprivate let signingKeyID: String
}

private struct DoryLinuxVMPerformanceVerificationReceipt: Decodable {
    static let kind = "dev.dory.linux-vm-performance-verification-receipt"
    static let schemaVersion: UInt16 = 1

    struct Candidate: Decodable {
        var applicationSHA256: String
        var budgetSetSHA256: String
        var componentCandidateInventorySHA256: String
        var runtimePlanSHA256: String
        var sbomSHA256: String
        var virtualHardwareABIVersion: String
    }

    struct SupportCell: Decodable {
        var backend: String
        var graphicsImplementation: String
        var hostIdentitySHA256: String
        var installedSystemIdentitySHA256: String
        var installerSHA256: String
        var matrixCellID: String
        var requestedGraphicsQuality: String
        var selectedGraphicsQuality: String
    }

    var bundleInventorySHA256: String
    var candidate: Candidate
    var kind: String
    var releaseQualified: Bool
    var schemaVersion: UInt16
    var signaturePublicKeyID: String
    var supportCell: SupportCell
}

public enum DoryVirtualMachineQualificationAuthorityResolver {
    public static let maximumManifestBytes = 4 * 1_024 * 1_024
    public static let maximumPerformanceReceiptBytes = 2 * 1_024 * 1_024
    public static let maximumPerformanceSignatureBytes = 256
    private static let performanceReceiptSuffix =
        ".linux-vm-performance-verification.json"

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
            release: release,
            manifestSHA256: declaredAsset.installedSHA256,
            expectedSigningKeyID: signingKeyID(publicKey)
        )
        try validatePerformanceEvidence(
            manifest,
            release: release,
            store: store,
            component: declaration.component,
            publicKey: publicKey
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
        release: DoryComponentRelease,
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
              isSHA256(manifest.candidateBinding.componentCandidateInventorySHA256),
              isSHA256(manifest.candidateBinding.sbomSHA256),
              manifest.candidateBinding.sbomSHA256 == release.provenance?.sbomDigest,
              Set(manifest.records.map(\.qualificationIdentity)).count
                == manifest.records.count,
              Set(manifest.records.map(\.performanceQualification.verificationReceiptPath)).count
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
            && (record.devices.networkInterface?.isValid ?? true)
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
            && performanceEvidenceIsStructurallyValid(record.performanceQualification)
            && (record.graphics != .hardwareAccelerated3D
                || (record.virtioGPUKernelAndDeviceSupportQualified
                    && record.producerFenceBeforeFlushQualified == true
                    && record.venusVulkanGuestRuntimeQualified))
    }

    private static func performanceEvidenceIsStructurallyValid(
        _ evidence: DoryVirtualMachinePerformanceQualificationEvidence
    ) -> Bool {
        isSHA256(evidence.bundleInventorySHA256)
            && !evidence.graphicsImplementation.isEmpty
            && isSHA256(evidence.matrixCellID)
            && isSHA256(evidence.signaturePublicKeyID)
            && evidence.verificationReceiptPath
                == evidence.matrixCellID + performanceReceiptSuffix
            && isSHA256(evidence.verificationReceiptSHA256)
    }

    private static func validatePerformanceEvidence(
        _ manifest: DoryVirtualMachineQualificationManifest,
        release: DoryComponentRelease,
        store: DoryComponentStore,
        component: DoryComponentID,
        publicKey: String
    ) throws {
        let recordReceiptPaths = Set(
            manifest.records.map(\.performanceQualification.verificationReceiptPath)
        )
        let catalogReceiptPaths = Set(release.assets.compactMap { asset in
            asset.role == .qualificationEvidence
                && asset.path.hasSuffix(performanceReceiptSuffix)
                ? asset.path : nil
        })
        let catalogSignaturePaths = Set(release.assets.compactMap { asset in
            asset.role == .qualificationEvidence
                && asset.path.hasSuffix(performanceReceiptSuffix + ".sig")
                ? asset.path : nil
        })
        guard recordReceiptPaths == catalogReceiptPaths,
              catalogSignaturePaths == Set(recordReceiptPaths.map { $0 + ".sig" }),
              let publicKeyData = Data(base64Encoded: publicKey),
              publicKeyData.count == 32,
              let verifier = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ) else {
            throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                "receipt set or signing key is incomplete"
            )
        }

        for record in manifest.records {
            let evidence = record.performanceQualification
            let signaturePath = evidence.verificationReceiptPath + ".sig"
            guard let receiptAsset = release.assets.first(where: {
                $0.path == evidence.verificationReceiptPath
                    && $0.role == .qualificationEvidence
            }), let signatureAsset = release.assets.first(where: {
                $0.path == signaturePath && $0.role == .qualificationEvidence
            }), receiptAsset.installedSHA256 == evidence.verificationReceiptSHA256 else {
                throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                    "catalog assets do not bind the record receipt"
                )
            }

            let receiptData: Data
            let signatureData: Data
            do {
                receiptData = try store.verifiedAssetData(
                    component: component,
                    path: receiptAsset.path,
                    maximumBytes: maximumPerformanceReceiptBytes
                )
                signatureData = try store.verifiedAssetData(
                    component: component,
                    path: signatureAsset.path,
                    maximumBytes: maximumPerformanceSignatureBytes
                )
            } catch {
                throw DoryVirtualMachineQualificationAuthorityError
                    .performanceEvidenceUnreadable
            }
            guard digest(receiptData) == evidence.verificationReceiptSHA256 else {
                throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                    "receipt digest differs from the record"
                )
            }
            guard let signatureText = String(data: signatureData, encoding: .ascii),
                  signatureText == signatureText.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ) + "\n",
                  let signature = Data(
                      base64Encoded: signatureText.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
                  ),
                  signature.count == 64,
                  verifier.isValidSignature(signature, for: receiptData) else {
                throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                    "receipt signature is invalid"
                )
            }

            let receipt: DoryLinuxVMPerformanceVerificationReceipt
            do {
                receipt = try JSONDecoder().decode(
                    DoryLinuxVMPerformanceVerificationReceipt.self,
                    from: receiptData
                )
            } catch {
                throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                    "receipt JSON could not be decoded"
                )
            }
            guard performanceReceipt(
                receipt,
                binds: record,
                manifest: manifest
            ) else {
                throw DoryVirtualMachineQualificationAuthorityError.performanceEvidenceInvalid(
                    "receipt does not bind its candidate, support cell, or record"
                )
            }
        }
    }

    private static func performanceReceipt(
        _ receipt: DoryLinuxVMPerformanceVerificationReceipt,
        binds record: DoryVirtualMachineQualificationRecord,
        manifest: DoryVirtualMachineQualificationManifest
    ) -> Bool {
        let evidence = record.performanceQualification
        let expectedBackend: String
        switch record.backend {
        case .doryHypervisor: expectedBackend = "rawhv"
        case .appleVirtualizationFramework: expectedBackend = "vz"
        case .qemuHypervisorFramework: return false
        }
        let expectedGraphicsQuality = record.graphics == .hardwareAccelerated3D
            ? "accelerated" : "software"
        let implementationMatchesQuality = expectedGraphicsQuality == "accelerated"
            ? receipt.supportCell.graphicsImplementation != "software"
            : receipt.supportCell.graphicsImplementation == "software"

        return receipt.kind == DoryLinuxVMPerformanceVerificationReceipt.kind
            && receipt.schemaVersion
                == DoryLinuxVMPerformanceVerificationReceipt.schemaVersion
            && receipt.releaseQualified
            && receipt.signaturePublicKeyID == manifest.signingKeyID
            && receipt.signaturePublicKeyID == evidence.signaturePublicKeyID
            && receipt.bundleInventorySHA256 == evidence.bundleInventorySHA256
            && receipt.candidate.componentCandidateInventorySHA256
                == manifest.candidateBinding.componentCandidateInventorySHA256
            && receipt.candidate.sbomSHA256 == manifest.candidateBinding.sbomSHA256
            && receipt.candidate.virtualHardwareABIVersion
                == String(record.virtualHardwareABIVersion)
            && isSHA256(receipt.candidate.applicationSHA256)
            && isSHA256(receipt.candidate.budgetSetSHA256)
            && isSHA256(receipt.candidate.runtimePlanSHA256)
            && receipt.supportCell.backend == expectedBackend
            && receipt.supportCell.installerSHA256 == record.immutableArtifactSHA256
            && receipt.supportCell.matrixCellID == evidence.matrixCellID
            && receipt.supportCell.graphicsImplementation
                == evidence.graphicsImplementation
            && receipt.supportCell.requestedGraphicsQuality == expectedGraphicsQuality
            && receipt.supportCell.selectedGraphicsQuality == expectedGraphicsQuality
            && implementationMatchesQuality
            && isSHA256(receipt.supportCell.hostIdentitySHA256)
            && isSHA256(receipt.supportCell.installedSystemIdentitySHA256)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKeyID(_ publicKeyBase64: String) -> String {
        guard let bytes = Data(base64Encoded: publicKeyBase64) else { return "" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DoryQualifiedBootMediaInspector {
    public static let inspectorID = "dory.portable-efi-media-inspector"
    /// v2 replaces marker/filename inference with validated FAT traversal and PE32+ EFI evidence.
    public static let inspectorVersion: UInt16 = 2

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
        do {
            identity = try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: path)
        }
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
            declaredGuest: record.guest,
            detectedGuestFamily: record.guest.family,
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

    /// Produces a digest-bound structural receipt for the one unqualified installer contract Dory
    /// can safely expose: user-provided ARM64 EFI Linux media on the portable VZ software path.
    /// This receipt deliberately carries no catalog evidence and therefore cannot authorize a
    /// managed image, accelerated graphics, or a different backend.
    public static func inspectPortableLinuxARM64InstallerISO(
        atPath path: String
    ) throws -> (
        media: DoryBootMedia,
        inspection: DoryTrustedBootMediaInspection,
        auditEvidence: DoryBootMediaInspectionAuditEvidence
    ) {
        let identity: DoryInstallerISOMediaIdentity
        do {
            identity = try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: path)
        }
        catch {
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        guard identity.architecture == .arm64
                || identity.architecture == .multiArchitecture else {
            throw DoryVirtualMachineQualificationAuthorityError.mediaInspectionFailed
        }
        let guest = DoryGuestPlatform(family: .linux, architecture: .arm64)
        let report = ISOInspectionReport(
            artifactSHA256: identity.sha256,
            byteCount: identity.byteCount,
            architecture: identity.architecture.rawValue,
            declaredGuest: guest,
            detectedGuestFamily: nil,
            efiBootable: true
        )
        let evidence = DoryBootMediaInspectionAuditEvidence(
            inspectionIdentity: "\(inspectorID):\(identity.sha256)",
            artifactSHA256: identity.sha256,
            inspectionReportSHA256: digest(canonicalData(report)),
            inspectorID: inspectorID,
            inspectorVersion: inspectorVersion
        )
        return (
            DoryBootMedia(
                kind: .installerISO,
                source: .userProvided,
                artifactSHA256: identity.sha256
            ),
            DoryTrustedBootMediaInspection(
                auditEvidence: evidence,
                detectedKind: .installerISO,
                detectedGuestFamily: nil,
                detectedArchitecture: .arm64,
                isEFIBootable: true
            ),
            evidence
        )
    }

    private struct ISOInspectionReport: Codable {
        var artifactSHA256: String
        var byteCount: UInt64
        var architecture: String
        /// The platform requested by the caller. This is not structural media evidence.
        var declaredGuest: DoryGuestPlatform
        /// Only catalog-qualified media can make an exact family assertion. Portable EFI
        /// inspection proves the loader architecture, but deliberately leaves this nil.
        var detectedGuestFamily: DoryGuestFamily?
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
