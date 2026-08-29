import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security
@preconcurrency import Virtualization

public enum DoryDaemonVirtualMachineProductionTrustReadinessCode:
    String, Sendable, Equatable
{
    case catalogUnavailable = "catalog-unavailable"
    case catalogSchemaV1Migration = "catalog-schema-v1-migration"
    case catalogSchemaUnsupported = "catalog-schema-unsupported"
    case trustFloorViolated = "trust-floor-violated"
    case planningTransactionUnavailable = "planning-transaction-unavailable"
    case qualificationAuthorityUnavailable = "qualification-authority-unavailable"
    case daemonSignatureUnavailable = "daemon-signature-unavailable"
    case hostFactsUnavailable = "host-facts-unavailable"
    case backendRuntimeUnavailable = "backend-runtime-unavailable"
    case resourceAuthorityUnavailable = "resource-authority-unavailable"
    case compositionFailed = "composition-failed"
}

public struct DoryDaemonVirtualMachineProductionTrustUnavailable:
    Error, Sendable, Equatable
{
    public var code: DoryDaemonVirtualMachineProductionTrustReadinessCode
    public var message: String
    private var legacyCompatibilityMigrationPermitted: Bool

    public init(
        code: DoryDaemonVirtualMachineProductionTrustReadinessCode,
        message: String
    ) {
        self.code = code
        self.message = message
        legacyCompatibilityMigrationPermitted = false
    }

    init(
        code: DoryDaemonVirtualMachineProductionTrustReadinessCode,
        message: String,
        permitsLegacyCompatibilityMigration: Bool
    ) {
        self.code = code
        self.message = message
        legacyCompatibilityMigrationPermitted = permitsLegacyCompatibilityMigration
    }

    /// Only absence and the explicitly supported schema-v1 migration state may retain the
    /// labeled compatibility path. Integrity, signer, runtime, host, ledger, and composition
    /// failures must never turn into authorization to launch the rejected helper through legacy.
    public var permitsLegacyCompatibilityMigration: Bool {
        legacyCompatibilityMigrationPermitted
    }
}

/// A ready result owns the exact inventory and launch composition installed into MachineManager.
/// It is intentionally non-Codable: verified authorities, helper paths, and live ledger handles
/// are daemon state and must never become API intent or a persisted trust assertion.
public struct DoryDaemonVirtualMachineProductionTrustContext: Sendable {
    public let machineManager: MachineManager
    public let inventory: any DoryDaemonVirtualMachineTrustInventory
    public let backendRuntimeBuildIdentifiers: [
        DoryVirtualizationBackendIdentity: String
    ]

    init(
        machineManager: MachineManager,
        inventory: any DoryDaemonVirtualMachineTrustInventory,
        backendRuntimeBuildIdentifiers: [
            DoryVirtualizationBackendIdentity: String
        ]
    ) {
        self.machineManager = machineManager
        self.inventory = inventory
        self.backendRuntimeBuildIdentifiers = backendRuntimeBuildIdentifiers
    }
}

public enum DoryDaemonVirtualMachineProductionTrustReadiness: Sendable {
    case ready(DoryDaemonVirtualMachineProductionTrustContext)
    case unavailable(DoryDaemonVirtualMachineProductionTrustUnavailable)
}

private enum DoryDaemonVirtualMachineProductionTrustFloor {
    private static let fileName = ".vm-production-trust-floor-v1"
    private static let lockFileName = ".vm-production-trust-floor.lock"

    struct Record: Codable, Sendable, Equatable {
        static let kind = "dev.dory.vm-production-trust-floor"
        static let schemaVersion = 1

        let kind: String
        let schemaVersion: Int
        let catalogReleaseVersion: String
        let catalogGeneratedAt: String
        let catalogDigest: String

        init(
            catalogReleaseVersion: String,
            catalogGeneratedAt: String,
            catalogDigest: String
        ) {
            kind = Self.kind
            schemaVersion = Self.schemaVersion
            self.catalogReleaseVersion = catalogReleaseVersion
            self.catalogGeneratedAt = catalogGeneratedAt
            self.catalogDigest = catalogDigest.lowercased()
        }
    }

    static func read(stateDirectory: String) throws -> Record? {
        let path = stateDirectory + "/" + fileName
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "VM production trust-floor record cannot be opened."
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 1_024,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "VM production trust-floor record is insecure or corrupt."
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count == info.st_size,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              isValid(record) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "VM production trust-floor record is invalid."
            )
        }
        return record
    }

    static func validate(
        authority: DoryVerifiedVirtualMachineQualificationAuthority,
        against record: Record?
    ) throws {
        let candidate = Record(
            catalogReleaseVersion: authority.catalogReleaseVersion,
            catalogGeneratedAt: authority.catalogGeneratedAt,
            catalogDigest: authority.catalogDigest
        )
        guard isValid(candidate) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "Verified catalog identity cannot establish the trust floor."
            )
        }
        guard let record else { return }
        guard let candidateTimestamp = timestamp(candidate.catalogGeneratedAt),
              let recordTimestamp = timestamp(record.catalogGeneratedAt) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "The accepted VM trust-floor timestamp is invalid."
            )
        }
        let versionOrder = candidate.catalogReleaseVersion.compare(
            record.catalogReleaseVersion,
            options: .numeric
        )
        guard versionOrder != .orderedAscending,
              candidateTimestamp >= recordTimestamp else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "The signed component catalog is older than the accepted VM trust floor."
            )
        }
        if versionOrder == .orderedSame {
            guard candidate == record else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "The signed component catalog conflicts with the accepted VM trust floor."
                )
            }
        }
    }

    static func activate(
        stateDirectory: String,
        authority: DoryVerifiedVirtualMachineQualificationAuthority,
        synchronizeDirectory: @Sendable (Int32) -> Bool
    ) throws {
        let candidate = Record(
            catalogReleaseVersion: authority.catalogReleaseVersion,
            catalogGeneratedAt: authority.catalogGeneratedAt,
            catalogDigest: authority.catalogDigest
        )
        guard isValid(candidate) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "Verified catalog identity cannot establish the trust floor."
            )
        }
        let lock = try EngineStateDirectoryLock(
            stateDirectory: stateDirectory,
            lockFileName: lockFileName
        )
        defer { withExtendedLifetime(lock) {} }
        let current = try read(stateDirectory: stateDirectory)
        try validate(authority: authority, against: current)
        if current == candidate {
            return
        }
        let path = stateDirectory + "/" + fileName
        let temporary = stateDirectory
            + "/.\(fileName).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "VM production trust floor cannot be persisted."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(candidate) + Data("\n".utf8)
        var descriptorOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard count > 0 else {
                        throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                            code: .trustFloorViolated,
                            message: "VM production trust floor cannot be written."
                        )
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "VM production trust floor cannot be synchronized."
                )
            }
            close(descriptor)
            descriptorOpen = false
            guard rename(temporary, path) == 0 else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "VM production trust floor cannot be published."
                )
            }
            let directory = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "VM production trust-floor directory cannot be opened."
                )
            }
            guard synchronizeDirectory(directory) else {
                close(directory)
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "VM production trust-floor directory cannot be synchronized."
                )
            }
            close(directory)
        } catch {
            if descriptorOpen { close(descriptor) }
            unlink(temporary)
            throw error
        }
    }

    static func hasResolvedPlanState(stateDirectory: String) throws -> Bool {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: stateDirectory) }
        catch {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "VM state cannot be inspected for existing resolved plans."
            )
        }
        for name in names {
            guard name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
                  !name.hasPrefix(".") else {
                continue
            }
            var directoryInfo = stat()
            let directory = stateDirectory + "/" + name
            guard lstat(directory, &directoryInfo) == 0 else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "VM state entry cannot be inspected."
                )
            }
            guard directoryInfo.st_mode & S_IFMT == S_IFDIR else { continue }
            var planInfo = stat()
            let plan = directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            if lstat(plan, &planInfo) == 0 { return true }
            guard errno == ENOENT else {
                throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: .trustFloorViolated,
                    message: "Existing resolved-plan state cannot be inspected."
                )
            }
        }
        return false
    }

    private static func isValid(_ record: Record) -> Bool {
        record.kind == Record.kind
            && record.schemaVersion == Record.schemaVersion
            && validVersion(record.catalogReleaseVersion)
            && timestamp(record.catalogGeneratedAt) != nil
            && isSHA256(record.catalogDigest)
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 43 || byte == 45
                || byte == 46 || byte == 95
        }
    }

    private static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }
}

struct DoryDaemonVerifiedBackendRuntime: Sendable, Equatable {
    var descriptor: MachineBackendDescriptor
    var executablePath: String
    var runtimeBuildIdentifier: String
    var components: [DoryVirtualMachineQualifiedComponent]
    var rendererAccelerationAdmission: DoryDaemonRendererAccelerationAdmission?

    init(
        descriptor: MachineBackendDescriptor,
        executablePath: String,
        runtimeBuildIdentifier: String,
        components: [DoryVirtualMachineQualifiedComponent],
        rendererAccelerationAdmission: DoryDaemonRendererAccelerationAdmission? = nil
    ) {
        self.descriptor = descriptor
        self.executablePath = executablePath
        self.runtimeBuildIdentifier = runtimeBuildIdentifier
        self.components = components.sorted { $0.componentIdentifier < $1.componentIdentifier }
        self.rendererAccelerationAdmission = rendererAccelerationAdmission
    }

    var productionAccelerationIsAdmissible: Bool {
        descriptor.identity == .doryHypervisor
            && rendererAccelerationAdmission?.authorizes(
                runtimeBuildIdentifier: runtimeBuildIdentifier
            ) == true
    }

    func productionAccelerationIsAdmissible(
        crashSuppressionStore: DoryRendererCrashSuppressionStore?
    ) -> Bool {
        guard productionAccelerationIsAdmissible,
              let rendererAccelerationAdmission else { return false }
        return crashSuppressionStore?.isSuppressed(
            rendererAccelerationAdmission
        ) != true
    }

    var componentEvidence: [DoryResolvedBackendComponentEvidence] {
        components.map {
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: $0.componentIdentifier,
                buildIdentifier: $0.buildIdentifier,
                artifactSHA256: $0.artifactSHA256
            )
        }
    }
}

/// Opaque daemon-only output from signature, catalog, host, and installed-runtime verification.
/// It deliberately carries no MachineManager or repository objects: production activation must
/// compose those once around the already-constructed manager and the planning composition seam.
struct DoryDaemonVirtualMachineVerifiedTrustMaterial: Sendable {
    var authority: DoryVerifiedVirtualMachineQualificationAuthority
    var runtimes: [DoryDaemonVerifiedBackendRuntime]
    var permitsLegacyCompatibilityMigration: Bool
    /// This provider is installed into production start authority only after the live daemon has
    /// passed its complete signing-identity proof. It remains lazy so non-renderer launches never
    /// depend on the embedded renderer release identity.
    var rendererReleaseIdentityProvider: any DoryRendererReleaseIdentityProviding
    var runtimeVerifier: @Sendable (
        String, MachineBackendDescriptor, String
    ) throws -> DoryDaemonVerifiedBackendRuntime
    var hostProbe: @Sendable (String) throws -> DoryDaemonProductionHostObservation
}

struct DoryDaemonBackendRuntimeSpecification: Sendable, Equatable {
    var descriptor: MachineBackendDescriptor
    var executablePath: String
    var componentIdentifier: String
}

struct DoryDaemonProductionHostObservation: Sendable, Equatable {
    var hardwareModelIdentifier: String
    var operatingSystemBuild: String
    var macOSMajorVersion: Int
    var virtualizationFrameworkAvailable: Bool
    var hypervisorFrameworkAvailable: Bool
    var metalAvailable: Bool
    var linuxIntelApplicationTranslationAvailable: Bool = false
    var resources: DoryVMHostResources
}

enum DoryDaemonProductionTrustInventoryError:
    Error, Sendable, Equatable
{
    case planningRequiresAdmissionTransaction
    case invalidRequest
    case mediaUnavailable
    case mediaInvalid
    case backendUnavailable
    case qualificationUnavailable
    case resourceAdmissionUnavailable
}

private struct DoryDaemonProductionPlanningHostIdentity: Sendable, Equatable {
    var hardwareModelIdentifier: String
    var operatingSystemBuild: String
    var macOSMajorVersion: Int
    var virtualizationFrameworkAvailable: Bool
    var hypervisorFrameworkAvailable: Bool
    var metalAvailable: Bool
    var logicalCPUCount: UInt64
    var physicalMemoryBytes: UInt64
}

private struct DoryDaemonProductionPlanningMaterial: Sendable {
    var host: DoryDaemonProductionHostObservation
    var artifact: DoryVerifiedVirtualMachineArtifact
    var launchArtifacts: [DoryResolvedMachineLaunchArtifact]
    var runtimes: [DoryDaemonVerifiedBackendRuntime]
    var qualifications: [DoryResolvedTrustedVirtualMachineQualification]
    var media: DoryDaemonVirtualMachineResolvedMedia
    var backendInventories: [DoryDaemonVirtualMachineBackendRuntimeInventory]
    var hostFacts: DoryAppleSiliconHostFacts

    var stableHostIdentity: DoryDaemonProductionPlanningHostIdentity {
        DoryDaemonProductionPlanningHostIdentity(
            hardwareModelIdentifier: host.hardwareModelIdentifier,
            operatingSystemBuild: host.operatingSystemBuild,
            macOSMajorVersion: host.macOSMajorVersion,
            virtualizationFrameworkAvailable: host.virtualizationFrameworkAvailable,
            hypervisorFrameworkAvailable: host.hypervisorFrameworkAvailable,
            metalAvailable: host.metalAvailable,
            logicalCPUCount: host.resources.logicalCPUCount,
            physicalMemoryBytes: host.resources.physicalMemoryBytes
        )
    }

    var qualificationRecords: [DoryVirtualMachineQualificationRecord] {
        qualifications.map(\.record).sorted {
            $0.qualificationIdentity < $1.qualificationIdentity
        }
    }
}

/// Production inventory backed exclusively by opaque verified authorities. It deliberately does
/// not implement admission reservation yet: the current coordinator has no atomic reserve -> plan
/// bind -> publish transaction. Start-time verification is complete for previously published and
/// bound plans; planning fails explicitly instead of returning invented admission evidence.
final class DoryProductionDaemonVirtualMachineTrustInventory:
    DoryDaemonVirtualMachineTrustInventory,
    DoryDaemonVirtualMachinePlanningTrustPreparing,
    DoryDaemonVirtualMachinePreSpawnAuthorizationProviding,
    @unchecked Sendable
{
    private let qualificationAuthority: DoryVerifiedVirtualMachineQualificationAuthority
    private let artifactAuthority: DoryVirtualMachineArtifactAuthority
    private let resourceLedger: DoryVirtualMachineResourceAdmissionLedger
    private let stateDirectory: String
    private let runtimeSpecifications: [
        DoryVirtualizationBackendIdentity: DoryDaemonBackendRuntimeSpecification
    ]
    private let runtimeVerifier: DoryDaemonVirtualMachineProductionTrustFactory.RuntimeVerifier
    private let hostProbe: DoryDaemonVirtualMachineProductionTrustFactory.HostProbe
    private let rendererReleaseIdentityProvider:
        any DoryRendererReleaseIdentityProviding
    private let rendererCrashSuppressionStore:
        DoryRendererCrashSuppressionStore?

    init(
        qualificationAuthority: DoryVerifiedVirtualMachineQualificationAuthority,
        artifactAuthority: DoryVirtualMachineArtifactAuthority,
        resourceLedger: DoryVirtualMachineResourceAdmissionLedger,
        stateDirectory: String,
        runtimeSpecifications: [DoryDaemonBackendRuntimeSpecification],
        runtimeVerifier: @escaping DoryDaemonVirtualMachineProductionTrustFactory.RuntimeVerifier,
        hostProbe: @escaping DoryDaemonVirtualMachineProductionTrustFactory.HostProbe,
        rendererReleaseIdentityProvider:
            any DoryRendererReleaseIdentityProviding,
        rendererCrashSuppressionStore:
            DoryRendererCrashSuppressionStore? = nil
    ) {
        self.qualificationAuthority = qualificationAuthority
        self.artifactAuthority = artifactAuthority
        self.resourceLedger = resourceLedger
        self.stateDirectory = stateDirectory
        self.runtimeSpecifications = Dictionary(uniqueKeysWithValues: runtimeSpecifications.map {
            ($0.descriptor.identity, $0)
        })
        self.runtimeVerifier = runtimeVerifier
        self.hostProbe = hostProbe
        self.rendererReleaseIdentityProvider = rendererReleaseIdentityProvider
        self.rendererCrashSuppressionStore = rendererCrashSuppressionStore
    }

    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        _ = request
        throw DoryDaemonProductionTrustInventoryError
            .planningRequiresAdmissionTransaction
    }

    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        let initial = try resolvePlanningMaterial(for: request)
        return DoryDaemonVirtualMachinePlanningTrustPreparation(
            hostResources: initial.host.resources,
            snapshot: { admission in
                DoryDaemonVirtualMachineTrustedInventorySnapshot(
                    hostFacts: initial.hostFacts,
                    media: initial.media,
                    launchArtifacts: initial.launchArtifacts,
                    backendRuntimes: initial.backendInventories,
                    resourceAdmission: admission,
                    runtimeQualifications: initial.qualifications.map(\.runtime),
                    capabilityQualifications: initial.qualifications.map(
                        \.capabilityQualification
                    )
                )
            },
            publicationAuthorization:
                DoryDaemonVirtualMachinePlanningPublicationAuthorization { [weak self] in
                    guard let self else {
                        throw DoryDaemonProductionTrustInventoryError.invalidRequest
                    }
                    let current = try self.resolvePlanningMaterial(for: request)
                    guard current.stableHostIdentity == initial.stableHostIdentity,
                          current.artifact.reference == initial.artifact.reference,
                          current.artifact.media == initial.artifact.media,
                          current.artifact.authorityRevision
                            == initial.artifact.authorityRevision,
                          current.launchArtifacts == initial.launchArtifacts,
                          current.runtimes == initial.runtimes,
                          current.qualificationRecords == initial.qualificationRecords else {
                        throw DoryDaemonProductionTrustInventoryError.invalidRequest
                    }
                }
        )
    }

    private func resolvePlanningMaterial(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonProductionPlanningMaterial {
        guard !request.acceptableGraphics.isEmpty,
              request.machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              request.definitionRevision > 0 else {
            throw DoryDaemonProductionTrustInventoryError.invalidRequest
        }
        let host: DoryDaemonProductionHostObservation
        do { host = try hostProbe(stateDirectory) }
        catch { throw DoryDaemonProductionTrustInventoryError.invalidRequest }
        let artifact: DoryVerifiedVirtualMachineArtifact
        let launchArtifacts: [DoryResolvedMachineLaunchArtifact]
        do {
            launchArtifacts = try resolveLaunchArtifacts(request.launchArtifacts)
            guard let primary = launchArtifacts.first(where: {
                $0.resolverReference == request.bootMedia.artifact
                    && $0.media.kind == request.bootMedia.kind
                    && $0.media.source == request.bootMedia.source
            }) else {
                throw DoryDaemonProductionTrustInventoryError.mediaUnavailable
            }
            artifact = try artifactAuthority.resolve(
                reference: primary.resolverReference,
                kind: primary.media.kind,
                source: primary.media.source
            )
        } catch {
            throw DoryDaemonProductionTrustInventoryError.mediaUnavailable
        }

        var runtimes: [DoryDaemonVerifiedBackendRuntime] = []
        for specification in runtimeSpecifications.values.sorted(by: {
            $0.descriptor.identity.rawValue < $1.descriptor.identity.rawValue
        }) {
            guard let runtime = try? runtimeVerifier(
                specification.executablePath,
                specification.descriptor,
                specification.componentIdentifier
            ), runtime.descriptor == specification.descriptor else { continue }
            runtimes.append(runtime)
        }
        guard !runtimes.isEmpty else {
            throw DoryDaemonProductionTrustInventoryError.backendUnavailable
        }

        var qualifications: [DoryResolvedTrustedVirtualMachineQualification] = []
        for runtime in runtimes {
            for graphics in request.acceptableGraphics {
                let capability = DoryVirtualMachineCapabilityRequest(
                    guest: request.guest,
                    bootMedia: artifact.media,
                    backend: runtime.descriptor.identity,
                    graphics: graphics,
                    devices: request.devices,
                    virtualHardwareABIVersion: request.virtualHardwareABIVersion
                )
                if let qualification = try? qualificationAuthority.resolve(
                    request: capability,
                    backendImplementationIdentifier:
                        runtime.descriptor.implementationIdentifier,
                    backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
                    hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                    hostOperatingSystemBuild: host.operatingSystemBuild,
                    installedComponents: runtime.components
                ) {
                    qualifications.append(qualification)
                }
            }
        }
        let portableRuntime = Self.portableLinuxEFIRuntime(
            for: request,
            media: artifact.media,
            runtimes: runtimes
        )
        let portableSoftwareQualification = qualifications.first {
            $0.record.backend == .appleVirtualizationFramework
                && $0.record.graphics == .software
        }
        guard !qualifications.isEmpty || portableRuntime != nil else {
            throw DoryDaemonProductionTrustInventoryError.qualificationUnavailable
        }

        let inspection: DoryTrustedBootMediaInspection?
        switch artifact.media.kind {
        case .installerISO:
            do {
                if let qualification = portableSoftwareQualification
                    ?? (portableRuntime == nil ? qualifications.first : nil) {
                    inspection = try DoryQualifiedBootMediaInspector.inspectInstallerISO(
                        atPath: artifact.path,
                        qualification: qualification
                    ).inspection
                } else {
                    let portable = try DoryQualifiedBootMediaInspector
                        .inspectPortableLinuxARM64InstallerISO(atPath: artifact.path)
                    guard portable.media == artifact.media else {
                        throw DoryDaemonProductionTrustInventoryError.mediaInvalid
                    }
                    inspection = portable.inspection
                }
            } catch {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
        case .linuxKernel:
            inspection = nil
        case .installedLinuxBootBundle:
            do { _ = try DoryInstalledLinuxBootBundle.verifyContents(atPath: artifact.path) }
            catch { throw DoryDaemonProductionTrustInventoryError.mediaInvalid }
            inspection = nil
        case .virtualDisk:
            guard artifact.mutableProvenance != nil else {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
            inspection = nil
        case .macOSRestoreImage:
            throw DoryDaemonProductionTrustInventoryError.mediaInvalid
        }

        let runtimeByIdentity = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.descriptor.identity, $0)
        })
        var inventories = qualifications.compactMap { qualification
            -> DoryDaemonVirtualMachineBackendRuntimeInventory? in
            let record = qualification.record
            guard let runtime = runtimeByIdentity[record.backend],
                  runtime.runtimeBuildIdentifier == record.backendRuntimeBuildIdentifier else {
                return nil
            }
            return DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: record.backend,
                runtimeBuildIdentifier: runtime.runtimeBuildIdentifier,
                components: runtime.componentEvidence,
                hostQualification: DoryResolvedHostQualificationEvidence(
                    qualificationIdentity: record.qualificationIdentity,
                    qualificationReportSHA256: Self.digest(Self.canonicalData(record)),
                    hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                    hostOperatingSystemBuild: host.operatingSystemBuild,
                    backend: record.backend,
                    backendRuntimeBuildIdentifier: record.backendRuntimeBuildIdentifier,
                    virtualHardwareABIVersion: record.virtualHardwareABIVersion,
                    qualifierIdentifier: "dory.catalog-v2.virtual-machine-qualification",
                    qualifierVersion: DoryVirtualMachineQualificationManifest.schemaVersion
                )
            )
        }
        let portableInventoryCount: Int
        if let portableRuntime, portableSoftwareQualification == nil {
            inventories.append(DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: portableRuntime.descriptor.identity,
                runtimeBuildIdentifier: portableRuntime.runtimeBuildIdentifier,
                components: portableRuntime.componentEvidence,
                hostQualification: nil
            ))
            portableInventoryCount = 1
        } else {
            portableInventoryCount = 0
        }
        guard inventories.count == qualifications.count + portableInventoryCount else {
            throw DoryDaemonProductionTrustInventoryError.backendUnavailable
        }
        return DoryDaemonProductionPlanningMaterial(
            host: host,
            artifact: artifact,
            launchArtifacts: launchArtifacts,
            runtimes: runtimes,
            qualifications: qualifications,
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: artifact.reference,
                media: artifact.media,
                // Graphics trust is capability-specific. Supplying one media-wide record here
                // would let array order authorize a different backend/graphics candidate.
                guestGraphicsQualification: nil,
                bootInspection: inspection,
                mutableProvenance: artifact.mutableProvenance
            ),
            backendInventories: inventories,
            hostFacts: hostFacts(host: host, runtimes: runtimes)
        )
    }

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        let plan = request.resolvedPlan
        guard request.machineID == plan.machineID,
              request.definitionRevision == plan.definitionRevision,
              request.planRevision == plan.planRevision,
              request.bootMediaReference == plan.bootMedia.resolverReference,
              request.exactCapabilityRequest == DoryVirtualMachineCapabilityRequest(
                  guest: plan.guest,
                  bootMedia: plan.bootMedia.media,
                  backend: plan.backend,
                  graphics: plan.graphics,
                  devices: plan.devices,
                  virtualHardwareABIVersion: plan.virtualHardwareABIVersion
              ) else {
            throw DoryDaemonProductionTrustInventoryError.invalidRequest
        }
        let host: DoryDaemonProductionHostObservation
        do { host = try hostProbe(stateDirectory) }
        catch { throw DoryDaemonProductionTrustInventoryError.invalidRequest }
        guard let runtimeSpecification = runtimeSpecifications[plan.backend] else {
            throw DoryDaemonProductionTrustInventoryError.backendUnavailable
        }
        let runtime: DoryDaemonVerifiedBackendRuntime
        do {
            runtime = try runtimeVerifier(
                runtimeSpecification.executablePath,
                runtimeSpecification.descriptor,
                runtimeSpecification.componentIdentifier
            )
        } catch {
            throw DoryDaemonProductionTrustInventoryError.backendUnavailable
        }
        guard runtime.descriptor.implementationIdentifier
                == runtimeSpecification.descriptor.implementationIdentifier,
              runtime.descriptor.implementationIdentifier
                == plan.backendImplementationIdentifier,
              runtime.runtimeBuildIdentifier
                == plan.backendRuntimeBuildIdentifier,
              runtime.componentEvidence == plan.components.sorted(by: {
                  $0.componentIdentifier < $1.componentIdentifier
              }) else {
            throw DoryDaemonProductionTrustInventoryError.backendUnavailable
        }

        let artifact: DoryVerifiedVirtualMachineArtifact
        let launchArtifacts: [DoryResolvedMachineLaunchArtifact]
        do {
            launchArtifacts = try resolveLaunchArtifacts(plan.launchArtifacts)
            guard launchArtifacts == plan.launchArtifacts else {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
            artifact = try artifactAuthority.resolve(
                reference: request.bootMediaReference,
                kind: plan.bootMedia.media.kind,
                source: plan.bootMedia.media.source
            )
        } catch {
            throw DoryDaemonProductionTrustInventoryError.mediaUnavailable
        }
        guard artifact.media == request.exactCapabilityRequest.bootMedia else {
            throw DoryDaemonProductionTrustInventoryError.mediaInvalid
        }

        let usesPortableBaseline = Self.planUsesPortableLinuxEFIBaseline(plan)
        let qualification: DoryResolvedTrustedVirtualMachineQualification?
        if usesPortableBaseline {
            qualification = nil
        } else {
            do {
                qualification = try qualificationAuthority.resolve(
                    request: request.exactCapabilityRequest,
                    backendImplementationIdentifier:
                        runtime.descriptor.implementationIdentifier,
                    backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
                    hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                    hostOperatingSystemBuild: host.operatingSystemBuild,
                    installedComponents: runtime.components
                )
            } catch {
                throw DoryDaemonProductionTrustInventoryError.qualificationUnavailable
            }
        }

        let inspection: DoryTrustedBootMediaInspection?
        switch artifact.media.kind {
        case .installerISO:
            do {
                if let qualification {
                    inspection = try DoryQualifiedBootMediaInspector.inspectInstallerISO(
                        atPath: artifact.path,
                        qualification: qualification
                    ).inspection
                } else {
                    let portable = try DoryQualifiedBootMediaInspector
                        .inspectPortableLinuxARM64InstallerISO(atPath: artifact.path)
                    guard portable.media == artifact.media,
                          portable.auditEvidence == plan.bootMedia.inspectionEvidence else {
                        throw DoryDaemonProductionTrustInventoryError.mediaInvalid
                    }
                    inspection = portable.inspection
                }
            } catch {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
        case .linuxKernel:
            inspection = nil
        case .installedLinuxBootBundle:
            do {
                _ = try DoryInstalledLinuxBootBundle.verifyContents(atPath: artifact.path)
                inspection = nil
            } catch {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
        case .virtualDisk:
            guard artifact.mutableProvenance != nil else {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
            inspection = nil
        case .macOSRestoreImage:
            // The current product has no daemon-owned VZMac restore-image inspector.
            throw DoryDaemonProductionTrustInventoryError.mediaInvalid
        }

        let admission: DoryResolvedMachineResourceAdmissionEvidence
        do {
            let snapshot = try resourceLedger.snapshot()
            let leases = snapshot.leases.filter {
                $0.binding.machineID == plan.machineID
                    && $0.binding.definitionRevision == plan.definitionRevision
                    && $0.binding.definitionSHA256 == plan.definitionSHA256
                    && $0.binding.plannedPlanRevision == plan.planRevision
                    && $0.state == .starting
            }
            guard leases.count == 1, let lease = leases.first else {
                throw DoryDaemonProductionTrustInventoryError
                    .resourceAdmissionUnavailable
            }
            admission = try resourceLedger.revalidateForStart(
                leaseID: lease.leaseID,
                plan: plan,
                hostFacts: host.resources
            )
        } catch {
            throw DoryDaemonProductionTrustInventoryError.resourceAdmissionUnavailable
        }

        let hostQualification = qualification.map { qualification in
            let record = qualification.record
            return DoryResolvedHostQualificationEvidence(
                qualificationIdentity: record.qualificationIdentity,
                qualificationReportSHA256: Self.digest(Self.canonicalData(record)),
                hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                hostOperatingSystemBuild: host.operatingSystemBuild,
                backend: record.backend,
                backendRuntimeBuildIdentifier: record.backendRuntimeBuildIdentifier,
                virtualHardwareABIVersion: record.virtualHardwareABIVersion,
                qualifierIdentifier: "dory.catalog-v2.virtual-machine-qualification",
                qualifierVersion: DoryVirtualMachineQualificationManifest.schemaVersion
            )
        }
        let runtimeInventory = DoryDaemonVirtualMachineBackendRuntimeInventory(
            backend: plan.backend,
            runtimeBuildIdentifier: runtime.runtimeBuildIdentifier,
            components: runtime.componentEvidence,
            hostQualification: hostQualification
        )
        return DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: hostFacts(host: host, runtime: runtime),
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: artifact.reference,
                media: artifact.media,
                guestGraphicsQualification: qualification?.graphics,
                bootInspection: inspection,
                mutableProvenance: artifact.mutableProvenance
            ),
            launchArtifacts: launchArtifacts,
            backendRuntimes: [runtimeInventory],
            resourceAdmission: admission,
            exactStartRuntimeQualification: qualification?.runtime
        )
    }

    func preSpawnAuthorization(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePreSpawnAuthorization {
        DoryDaemonVirtualMachinePreSpawnAuthorization.resolvingLaunchAuthority { [weak self] in
            guard let self else {
                throw DoryDaemonProductionTrustInventoryError.invalidRequest
            }
            // Repeats artifact hashing, structural media verification, helper signature/digest,
            // host/resource probing, signed exact qualification, and bound-ledger validation.
            _ = try self.startInventory(for: request)
            return try DoryProductionRendererReleaseIdentityAuthority.resolve(
                backend: request.resolvedPlan.backend,
                graphics: request.resolvedPlan.graphics,
                provider: self.rendererReleaseIdentityProvider
            )
        }
    }

    private static func portableLinuxEFIRuntime(
        for request: DoryDaemonVirtualMachineInventoryRequest,
        media: DoryBootMedia,
        runtimes: [DoryDaemonVerifiedBackendRuntime]
    ) -> DoryDaemonVerifiedBackendRuntime? {
        guard request.guest == DoryGuestPlatform(family: .linux, architecture: .arm64),
              request.bootMedia.kind == media.kind,
              request.bootMedia.source == media.source,
              media.source == .userProvided,
              media.kind == .installerISO || media.kind == .virtualDisk,
              request.acceptableGraphics.contains(.software) else {
            return nil
        }
        let candidates = runtimes.filter {
            $0.descriptor.identity == .appleVirtualizationFramework
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func planUsesPortableLinuxEFIBaseline(
        _ plan: DoryResolvedMachinePlan
    ) -> Bool {
        guard plan.guest == DoryGuestPlatform(family: .linux, architecture: .arm64),
              plan.backend == .appleVirtualizationFramework,
              plan.graphics == .software,
              plan.supportTier == .supported,
              plan.bootMedia.media.source == .userProvided,
              plan.bootMedia.media.kind == .installerISO
                || plan.bootMedia.media.kind == .virtualDisk,
              plan.qualificationEvidence.graphics == nil,
              plan.qualificationEvidence.runtime == nil,
              plan.hostQualification == nil else {
            return false
        }
        if plan.bootMedia.media.kind == .installerISO {
            return plan.bootMedia.inspectionEvidence?.catalogManifestEvidence == nil
        }
        return plan.bootMedia.inspectionEvidence == nil
    }

    private func resolveLaunchArtifacts(
        _ requirements: [DoryDaemonVirtualMachineLaunchArtifactRequirement]
    ) throws -> [DoryResolvedMachineLaunchArtifact] {
        try requirements.map { requirement in
            let artifact = try artifactAuthority.resolve(
                reference: requirement.reference,
                kind: requirement.kind,
                source: requirement.source
            )
            guard (artifact.media.mutableProvenance != nil) == requirement.mutable else {
                throw DoryDaemonProductionTrustInventoryError.mediaInvalid
            }
            return DoryResolvedMachineLaunchArtifact(
                resolverReference: artifact.reference,
                media: artifact.media,
                authorityRevision: artifact.authorityRevision,
                usages: requirement.usages,
                mutableProvenanceEvidence:
                    artifact.mutableProvenance?.persistedAuditEvidence
            )
        }
    }

    private func resolveLaunchArtifacts(
        _ planned: [DoryResolvedMachineLaunchArtifact]
    ) throws -> [DoryResolvedMachineLaunchArtifact] {
        try planned.map { expected in
            let artifact = try artifactAuthority.resolve(
                reference: expected.resolverReference,
                kind: expected.media.kind,
                source: expected.media.source
            )
            return DoryResolvedMachineLaunchArtifact(
                resolverReference: artifact.reference,
                media: artifact.media,
                authorityRevision: artifact.authorityRevision,
                usages: expected.usages,
                mutableProvenanceEvidence:
                    artifact.mutableProvenance?.persistedAuditEvidence
            )
        }
    }

    private func hostFacts(
        host: DoryDaemonProductionHostObservation,
        runtime: DoryDaemonVerifiedBackendRuntime
    ) -> DoryAppleSiliconHostFacts {
        let rawBuild = runtime.descriptor.identity == .doryHypervisor
            ? runtime.runtimeBuildIdentifier : ""
        let vzBuild = runtime.descriptor.identity == .appleVirtualizationFramework
            ? runtime.runtimeBuildIdentifier : ""
        return DoryAppleSiliconHostFacts(
            macOSMajorVersion: host.macOSMajorVersion,
            virtualizationFrameworkAvailable:
                host.virtualizationFrameworkAvailable && !vzBuild.isEmpty,
            hypervisorFrameworkAvailable: host.hypervisorFrameworkAvailable,
            doryHypervisorAvailable: !rawBuild.isEmpty,
            qemuHypervisorFrameworkAvailable: false,
            windowsUEFIFirmwareAvailable: false,
            windowsSecureBootAvailable: false,
            windowsSBSADeviceModelAvailable: false,
            virtualTPM20Available: false,
            windowsGuestDrivers: DoryWindowsGuestDriverFacts(
                storageAvailable: false,
                networkAvailable: false,
                displayAvailable: false,
                inputAvailable: false
            ),
            macOSGuestVirtualizationSupported: false,
            macOSRestoreImageInstallationSupported: false,
            doryMacOSBackendAvailable: false,
            doryMacOSBackendQualified: false,
            metalAvailable: host.metalAvailable,
            doryAcceleratedRendererAvailable:
                host.metalAvailable && runtime.productionAccelerationIsAdmissible(
                    crashSuppressionStore: rendererCrashSuppressionStore
                ),
            linuxIntelApplicationTranslationAvailable:
                host.linuxIntelApplicationTranslationAvailable,
            runtimeQualificationContext:
                DoryVirtualMachineRuntimeQualificationHostContext(
                    virtualHardwareABIVersion: 1,
                    doryHypervisorRuntimeBuildID: rawBuild,
                    virtualizationFrameworkAdapterBuildID: vzBuild,
                    qemuRuntimeBuildID: ""
                )
        )
    }

    private func hostFacts(
        host: DoryDaemonProductionHostObservation,
        runtimes: [DoryDaemonVerifiedBackendRuntime]
    ) -> DoryAppleSiliconHostFacts {
        let rawBuild = runtimes.first {
            $0.descriptor.identity == .doryHypervisor
        }?.runtimeBuildIdentifier ?? ""
        let rawRuntime = runtimes.first {
            $0.descriptor.identity == .doryHypervisor
        }
        let rawAccelerationAdmissible =
            rawRuntime?.productionAccelerationIsAdmissible(
                crashSuppressionStore: rendererCrashSuppressionStore
            ) == true
        let vzBuild = runtimes.first {
            $0.descriptor.identity == .appleVirtualizationFramework
        }?.runtimeBuildIdentifier ?? ""
        return DoryAppleSiliconHostFacts(
            macOSMajorVersion: host.macOSMajorVersion,
            virtualizationFrameworkAvailable:
                host.virtualizationFrameworkAvailable && !vzBuild.isEmpty,
            hypervisorFrameworkAvailable: host.hypervisorFrameworkAvailable,
            doryHypervisorAvailable: !rawBuild.isEmpty,
            qemuHypervisorFrameworkAvailable: false,
            windowsUEFIFirmwareAvailable: false,
            windowsSecureBootAvailable: false,
            windowsSBSADeviceModelAvailable: false,
            virtualTPM20Available: false,
            windowsGuestDrivers: DoryWindowsGuestDriverFacts(
                storageAvailable: false,
                networkAvailable: false,
                displayAvailable: false,
                inputAvailable: false
            ),
            macOSGuestVirtualizationSupported: false,
            macOSRestoreImageInstallationSupported: false,
            doryMacOSBackendAvailable: false,
            doryMacOSBackendQualified: false,
            metalAvailable: host.metalAvailable,
            doryAcceleratedRendererAvailable:
                host.metalAvailable && rawAccelerationAdmissible,
            linuxIntelApplicationTranslationAvailable:
                host.linuxIntelApplicationTranslationAvailable,
            runtimeQualificationContext:
                DoryVirtualMachineRuntimeQualificationHostContext(
                    virtualHardwareABIVersion: 1,
                    doryHypervisorRuntimeBuildID: rawBuild,
                    virtualizationFrameworkAdapterBuildID: vzBuild,
                    qemuRuntimeBuildID: ""
                )
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

/// Resolves the production trust root before constructing a resolved-plan MachineManager. Every
/// default dependency probes daemon-owned state. Internal injected dependencies exist solely for
/// deterministic tests; the public entry point never accepts caller trust booleans.
public struct DoryDaemonVirtualMachineProductionTrustFactory: Sendable {
    typealias AuthorityResolver = @Sendable (
        DoryComponentStore, String, String, String
    ) throws -> DoryVerifiedVirtualMachineQualificationAuthority
    typealias RuntimeVerifier = @Sendable (
        String, MachineBackendDescriptor, String
    ) throws -> DoryDaemonVerifiedBackendRuntime
    typealias HostProbe = @Sendable (String) throws -> DoryDaemonProductionHostObservation
    typealias DirectorySynchronizer = @Sendable (Int32) -> Bool
    typealias TrustFloorActivator = @Sendable (
        String,
        DoryVerifiedVirtualMachineQualificationAuthority,
        @escaping DirectorySynchronizer
    ) throws -> Void

    private let authorityResolver: AuthorityResolver
    private let runtimeVerifier: RuntimeVerifier
    private let hostProbe: HostProbe
    private let daemonIdentityVerifier: @Sendable () -> Bool
    private let rendererReleaseIdentityProvider:
        any DoryRendererReleaseIdentityProviding
    private let planningTransactionAvailable: @Sendable () -> Bool
    private let synchronizeTrustFloorDirectory: DirectorySynchronizer
    private let trustFloorActivator: TrustFloorActivator

    /// Compiled into and covered by the daemon's code signature. Production catalog compatibility
    /// must not trust an environment override or a mutable outer Info.plist.
    public static let compiledDaemonVersion = "0.4.6"

    public init() {
        authorityResolver = { store, publicKey, architecture, appVersion in
            try DoryVirtualMachineQualificationAuthorityResolver.resolve(
                store: store,
                publicKey: publicKey,
                expectedArchitecture: architecture,
                appVersion: appVersion
            )
        }
        runtimeVerifier = Self.verifyProductionRuntime
        hostProbe = Self.probeProductionHost
        daemonIdentityVerifier = DorydXPCSecurity
            .currentProcessSatisfiesProductionDaemonRequirement
        rendererReleaseIdentityProvider = DoryEmbeddedRendererReleaseIdentityProvider()
        planningTransactionAvailable = { false }
        synchronizeTrustFloorDirectory = { fsync($0) == 0 }
        trustFloorActivator = { stateDirectory, authority, synchronizeDirectory in
            try DoryDaemonVirtualMachineProductionTrustFloor.activate(
                stateDirectory: stateDirectory,
                authority: authority,
                synchronizeDirectory: synchronizeDirectory
            )
        }
    }

    init(
        authorityResolver: @escaping AuthorityResolver,
        runtimeVerifier: @escaping RuntimeVerifier,
        hostProbe: @escaping HostProbe,
        daemonIdentityVerifier: @escaping @Sendable () -> Bool,
        rendererReleaseIdentityProvider:
            any DoryRendererReleaseIdentityProviding =
                DoryEmbeddedRendererReleaseIdentityProvider(),
        planningTransactionAvailable: @escaping @Sendable () -> Bool = { false },
        synchronizeTrustFloorDirectory: @escaping DirectorySynchronizer = { fsync($0) == 0 },
        trustFloorActivator: TrustFloorActivator? = nil
    ) {
        self.authorityResolver = authorityResolver
        self.runtimeVerifier = runtimeVerifier
        self.hostProbe = hostProbe
        self.daemonIdentityVerifier = daemonIdentityVerifier
        self.rendererReleaseIdentityProvider = rendererReleaseIdentityProvider
        self.planningTransactionAvailable = planningTransactionAvailable
        self.synchronizeTrustFloorDirectory = synchronizeTrustFloorDirectory
        self.trustFloorActivator = trustFloorActivator ?? {
            stateDirectory, authority, synchronizeDirectory in
            try DoryDaemonVirtualMachineProductionTrustFloor.activate(
                stateDirectory: stateDirectory,
                authority: authority,
                synchronizeDirectory: synchronizeDirectory
            )
        }
    }

    public func resolve(
        store: DoryComponentStore,
        machineConfiguration: MachineManagerConfiguration
    ) -> DoryDaemonVirtualMachineProductionTrustReadiness {
        resolve(
            store: store,
            machineConfiguration: machineConfiguration,
            appVersion: Self.compiledDaemonVersion,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: DoryComponentDefaults.architecture
        )
    }

    /// Test-only/internal trust seam. Production callers cannot replace the pinned catalog key or
    /// current architecture through the public API.
    func resolve(
        store: DoryComponentStore,
        machineConfiguration: MachineManagerConfiguration,
        appVersion: String,
        publicKey: String,
        expectedArchitecture: String
    ) -> DoryDaemonVirtualMachineProductionTrustReadiness {
        let material: DoryDaemonVirtualMachineVerifiedTrustMaterial
        switch verifiedTrustMaterial(
            store: store,
            machineConfiguration: machineConfiguration,
            appVersion: appVersion,
            publicKey: publicKey,
            expectedArchitecture: expectedArchitecture
        ) {
        case let .success(verified):
            material = verified
        case let .failure(reason):
            return .unavailable(reason)
        }
        let authority = material.authority
        let runtimes = material.runtimes
        let mayUseLegacyMigration = material.permitsLegacyCompatibilityMigration

        let artifactAuthority = DoryVirtualMachineArtifactAuthority(
            root: machineConfiguration.stateDirectory + "/.artifact-authority"
        )
        let resourceLedger = DoryVirtualMachineResourceAdmissionLedger(
            root: machineConfiguration.stateDirectory + "/.resource-admissions"
        )
        do { _ = try resourceLedger.snapshot() }
        catch {
            return unavailable(
                .resourceAuthorityUnavailable,
                "The durable VM resource-admission ledger is unavailable."
            )
        }
        guard planningTransactionAvailable() else {
            return .unavailable(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .planningTransactionUnavailable,
                message: "Resolved-plan reserve, bind, and publication are not yet installed in the production workspace workflow.",
                permitsLegacyCompatibilityMigration: mayUseLegacyMigration
            ))
        }
        let inventory = DoryProductionDaemonVirtualMachineTrustInventory(
            qualificationAuthority: authority,
            artifactAuthority: artifactAuthority,
            resourceLedger: resourceLedger,
            stateDirectory: machineConfiguration.stateDirectory,
            runtimeSpecifications: runtimes.map {
                DoryDaemonBackendRuntimeSpecification(
                    descriptor: $0.descriptor,
                    executablePath: $0.executablePath,
                    componentIdentifier: $0.components[0].componentIdentifier
                )
            },
            runtimeVerifier: runtimeVerifier,
            hostProbe: hostProbe,
            rendererReleaseIdentityProvider:
                material.rendererReleaseIdentityProvider
        )

        do {
            try activateVerifiedTrustFloor(
                stateDirectory: machineConfiguration.stateDirectory,
                material: material
            )
            let manager = MachineManager(
                configuration: machineConfiguration,
                launchPolicy: .requireResolvedPlan
            )
            let backends: [any MachineBackend] = runtimes.map { runtime in
                switch runtime.descriptor.identity {
                case .appleVirtualizationFramework:
                    VirtualizationFrameworkLinuxMachineBackend(
                        executablePath: runtime.executablePath,
                        operations: manager.resolvedLaunchCompatibilityOperations(
                            for: runtime.descriptor.identity
                        )
                    )
                case .doryHypervisor:
                    RawHVLinuxMachineBackend(
                        executablePath: runtime.executablePath,
                        operations: manager.resolvedLaunchCompatibilityOperations(
                            for: runtime.descriptor.identity
                        )
                    )
                case .qemuHypervisorFramework:
                    // No production QEMU/Windows adapter exists in this milestone.
                    preconditionFailure("unreachable unverified backend runtime")
                }
            }
            let registry = try BackendRegistry(backends: backends)
            let plans = DoryResolvedMachinePlanRepository(
                root: machineConfiguration.stateDirectory
            )
            let collector = DoryDaemonVirtualMachineStartEvidenceCollector(
                registry: registry,
                inventory: inventory
            )
            let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
                registry: registry,
                plans: plans,
                evidenceCollector: collector
            )
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { machineID in
                    try? plans.read(id: machineID).planRevision
                }
            )
            return .ready(DoryDaemonVirtualMachineProductionTrustContext(
                machineManager: manager,
                inventory: inventory,
                backendRuntimeBuildIdentifiers: Dictionary(
                    uniqueKeysWithValues: runtimes.map {
                        ($0.descriptor.identity, $0.runtimeBuildIdentifier)
                    }
                )
            ))
        } catch {
            return unavailable(
                .compositionFailed,
                "Resolved-plan VM launch infrastructure could not be composed."
            )
        }
    }

    /// Shared preparation boundary for the legacy composition bridge and the per-workspace
    /// activation path. Verification is performed once and yields only opaque daemon authority;
    /// neither path may independently rebuild or reinterpret the catalog/runtime trust graph.
    func verifiedTrustMaterial(
        store: DoryComponentStore,
        machineConfiguration: MachineManagerConfiguration,
        appVersion: String,
        publicKey: String,
        expectedArchitecture: String
    ) -> Result<
        DoryDaemonVirtualMachineVerifiedTrustMaterial,
        DoryDaemonVirtualMachineProductionTrustUnavailable
    > {
        let trustFloor: DoryDaemonVirtualMachineProductionTrustFloor.Record?
        let hasResolvedPlanState: Bool
        do {
            trustFloor = try DoryDaemonVirtualMachineProductionTrustFloor
                .read(stateDirectory: machineConfiguration.stateDirectory)
            hasResolvedPlanState = try DoryDaemonVirtualMachineProductionTrustFloor
                .hasResolvedPlanState(stateDirectory: machineConfiguration.stateDirectory)
        } catch {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "The durable VM production trust floor is invalid or unavailable."
            ))
        }
        let mayUseLegacyMigration = trustFloor == nil && !hasResolvedPlanState
        let authority: DoryVerifiedVirtualMachineQualificationAuthority
        do {
            authority = try authorityResolver(
                store, publicKey, expectedArchitecture, appVersion
            )
        } catch let error as DoryVirtualMachineQualificationAuthorityError {
            let code: DoryDaemonVirtualMachineProductionTrustReadinessCode
            switch error {
            case .catalogUnavailable:
                code = .catalogUnavailable
            case let .catalogSchemaUnsupported(version):
                code = version == DoryComponentCatalog.oldestSupportedSchemaVersion
                    ? .catalogSchemaV1Migration : .catalogSchemaUnsupported
            default:
                code = .qualificationAuthorityUnavailable
            }
            if code == .catalogUnavailable || code == .catalogSchemaV1Migration {
                guard mayUseLegacyMigration else {
                    return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                        code: .trustFloorViolated,
                        message: "VM production trust was previously activated; catalog authority cannot be removed or downgraded."
                    ))
                }
                return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                    code: code,
                    message: error.description,
                    permitsLegacyCompatibilityMigration: true
                ))
            }
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: code,
                message: error.description
            ))
        } catch {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .qualificationAuthorityUnavailable,
                message: "VM qualification authority could not be verified."
            ))
        }

        do {
            try DoryDaemonVirtualMachineProductionTrustFloor.validate(
                authority: authority,
                against: trustFloor
            )
        } catch {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .trustFloorViolated,
                message: "The signed component catalog violates the accepted VM trust floor."
            ))
        }

        guard daemonIdentityVerifier() else {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .daemonSignatureUnavailable,
                message: "Resolved-plan launch requires a production-signed Dory daemon."
            ))
        }
        do { _ = try hostProbe(machineConfiguration.stateDirectory) }
        catch {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .hostFactsUnavailable,
                message: "Exact host model, OS build, framework, or resource facts are unavailable."
            ))
        }

        var runtimes: [DoryDaemonVerifiedBackendRuntime] = []
        do {
            runtimes.append(try runtimeVerifier(
                machineConfiguration.vmmExecutablePath,
                VirtualizationFrameworkLinuxMachineBackend.backendDescriptor,
                "dory-vmm"
            ))
        } catch {
            return .failure(DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "The signed Virtualization.framework helper failed exact verification."
            ))
        }
        if let rawPath = machineConfiguration.acceleratedDesktopExecutablePath,
           let runtime = try? runtimeVerifier(
               rawPath,
               RawHVLinuxMachineBackend.backendDescriptor,
               "dory-hv"
           ) {
            runtimes.append(runtime)
        }
        return .success(DoryDaemonVirtualMachineVerifiedTrustMaterial(
            authority: authority,
            runtimes: runtimes,
            permitsLegacyCompatibilityMigration: mayUseLegacyMigration,
            rendererReleaseIdentityProvider: rendererReleaseIdentityProvider,
            runtimeVerifier: runtimeVerifier,
            hostProbe: hostProbe
        ))
    }

    /// Advances the monotonic catalog floor only after the caller has recovered planning state
    /// and installed the exact resulting launch graph into its MachineManager.
    func activateVerifiedTrustFloor(
        stateDirectory: String,
        material: DoryDaemonVirtualMachineVerifiedTrustMaterial
    ) throws {
        try trustFloorActivator(
            stateDirectory,
            material.authority,
            synchronizeTrustFloorDirectory
        )
    }

    private func unavailable(
        _ code: DoryDaemonVirtualMachineProductionTrustReadinessCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineProductionTrustReadiness {
        .unavailable(DoryDaemonVirtualMachineProductionTrustUnavailable(
            code: code,
            message: message
        ))
    }

    private static func verifyProductionRuntime(
        path: String,
        descriptor: MachineBackendDescriptor,
        componentIdentifier: String
    ) throws -> DoryDaemonVerifiedBackendRuntime {
        guard DorydXPCSecurity.currentTeamIdentifier()
                == DorydXPCSecurity.productionTeamID else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .daemonSignatureUnavailable,
                message: "The daemon is not production signed."
            )
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        guard canonical == path else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper path is not canonical."
            )
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: canonical) as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode,
        SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
            == errSecSuccess else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper signature is invalid."
            )
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let values = signingInformation as? [CFString: Any],
        values[kSecCodeInfoTeamIdentifier] as? String
            == DorydXPCSecurity.productionTeamID,
        values[kSecCodeInfoIdentifier] as? String
            == (descriptor.identity == .doryHypervisor
                ? DoryRendererWorkerIdentity.runnerBundleIdentifier
                : componentIdentifier) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper signer does not match Dory."
            )
        }

        let digest = try stableExecutableDigest(canonical)
        let build = "sha256:\(digest)"
        let rendererAdmission: DoryDaemonRendererAccelerationAdmission?
        if descriptor.identity == .doryHypervisor {
            rendererAdmission = try DoryDaemonRendererProductionAuthority.verifyIfPresent(
                runnerExecutablePath: canonical,
                runtimeBuildIdentifier: build
            )
        } else {
            rendererAdmission = nil
        }
        let runtimeComponent = DoryVirtualMachineQualifiedComponent(
            componentIdentifier: componentIdentifier,
            buildIdentifier: build,
            artifactSHA256: digest
        )
        return DoryDaemonVerifiedBackendRuntime(
            descriptor: descriptor,
            executablePath: canonical,
            runtimeBuildIdentifier: build,
            components: [runtimeComponent] + (rendererAdmission?.qualifiedComponents ?? []),
            rendererAccelerationAdmission: rendererAdmission
        )
    }

    private static func stableExecutableDigest(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper cannot be opened."
            )
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_nlink == 1,
              before.st_uid == 0 || before.st_uid == geteuid(),
              before.st_mode & (S_IWGRP | S_IWOTH) == 0,
              before.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper file identity is insecure."
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameSnapshot(before, after) else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .backendRuntimeUnavailable,
                message: "Backend helper changed during verification."
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func probeProductionHost(
        stateDirectory: String
    ) throws -> DoryDaemonProductionHostObservation {
        guard let model = sysctlString("hw.model"),
              let build = sysctlString("kern.osversion"),
              !model.isEmpty, !build.isEmpty else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .hostFactsUnavailable,
                message: "Host model or OS build is unavailable."
            )
        }
        let process = ProcessInfo.processInfo
        guard process.operatingSystemVersion.majorVersion > 0,
              process.activeProcessorCount > 0,
              process.physicalMemory > 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .hostFactsUnavailable,
                message: "Host CPU, memory, or OS facts are invalid."
            )
        }
        let values = try URL(fileURLWithPath: stateDirectory).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let free = values.volumeAvailableCapacityForImportantUsage,
              free > 0 else {
            throw DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: .hostFactsUnavailable,
                message: "Host storage capacity is unavailable."
            )
        }
        return DoryDaemonProductionHostObservation(
            hardwareModelIdentifier: model,
            operatingSystemBuild: build,
            macOSMajorVersion: process.operatingSystemVersion.majorVersion,
            virtualizationFrameworkAvailable: frameworkAvailable(
                "/System/Library/Frameworks/Virtualization.framework/Virtualization"
            ),
            hypervisorFrameworkAvailable: frameworkAvailable(
                "/System/Library/Frameworks/Hypervisor.framework/Hypervisor"
            ),
            metalAvailable: frameworkAvailable(
                "/System/Library/Frameworks/Metal.framework/Metal"
            ),
            linuxIntelApplicationTranslationAvailable:
                linuxIntelApplicationTranslationAvailable(),
            resources: DoryVMHostResources(
                logicalCPUCount: UInt64(process.activeProcessorCount),
                physicalMemoryBytes: process.physicalMemory,
                freeStorageBytes: UInt64(free)
            )
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return nil }
        let payload = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: payload, as: UTF8.self)
    }

    private static func frameworkAvailable(_ path: String) -> Bool {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return false }
        dlclose(handle)
        return true
    }

    private static func linuxIntelApplicationTranslationAvailable() -> Bool {
        #if arch(arm64)
        VZLinuxRosettaDirectoryShare.availability == .installed
        #else
        false
        #endif
    }
}
