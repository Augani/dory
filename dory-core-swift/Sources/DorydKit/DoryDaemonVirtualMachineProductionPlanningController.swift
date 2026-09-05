import Darwin
import DoryOperations
import DoryVZMacCore
import Foundation

public enum DoryDaemonVirtualMachineProductionPlanningControllerFailureCode:
    String, Sendable, Equatable
{
    case invalidRequest = "invalid-request"
    case mediaAuthorityMissing = "media-authority-missing"
    case mediaAuthorityConflict = "media-authority-conflict"
    case transactionRejected = "transaction-rejected"
    case publicationMismatch = "publication-mismatch"
}

public struct DoryDaemonVirtualMachineProductionPlanningControllerFailure:
    Error, Sendable, Equatable
{
    public var code: DoryDaemonVirtualMachineProductionPlanningControllerFailureCode
    public var message: String

    public init(
        code: DoryDaemonVirtualMachineProductionPlanningControllerFailureCode,
        message: String
    ) {
        self.code = code
        self.message = message
    }
}

/// Checkpoint-bound authority minted by the desktop root after validating its private journal.
/// This proof is neither Codable nor available through the public planning input initializer.
struct DoryDaemonImmutableArtifactReplacementProof: Sendable, Equatable {
    let operationID: UUID
    let reference: DoryVMResolverReference
    let path: String
    let expectedAuthorityRevision: UInt64
    let sha256: String

    init(
        operationID: UUID,
        reference: DoryVMResolverReference,
        path: String,
        expectedAuthorityRevision: UInt64,
        sha256: String
    ) throws {
        guard operationID.uuidString != "00000000-0000-0000-0000-000000000000",
              reference.isValidForPersistence,
              path.hasPrefix("/"), path != "/", !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              expectedAuthorityRevision > 0,
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DoryDaemonVirtualMachineProductionPlanningControllerFailure(
                code: .invalidRequest, message: "Immutable replacement proof is invalid."
            )
        }
        self.operationID = operationID
        self.reference = reference
        self.path = path
        self.expectedAuthorityRevision = expectedAuthorityRevision
        self.sha256 = sha256
    }
}

/// Daemon-local path binding supplied only after MachineManager has staged the artifact into its
/// private workspace. This value is intentionally non-Codable: host paths never become API or
/// desired-state authority.
public struct DoryDaemonVirtualMachinePlanningArtifactPublication: Sendable, Equatable {
    public enum Mutability: Sendable, Equatable {
        case immutable
        case mutable
    }

    public var reference: DoryVMResolverReference
    public var path: String
    public var kind: DoryBootMediaKind
    public var source: DoryBootMediaSource
    public var mutability: Mutability
    public var expectedAuthorityRevision: UInt64?
    var immutableReplacementProof: DoryDaemonImmutableArtifactReplacementProof?

    public init(
        reference: DoryVMResolverReference,
        path: String,
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        mutability: Mutability,
        expectedAuthorityRevision: UInt64? = nil
    ) {
        self.reference = reference
        self.path = path
        self.kind = kind
        self.source = source
        self.mutability = mutability
        self.expectedAuthorityRevision = expectedAuthorityRevision
    }
}

public protocol DoryDaemonVirtualMachinePlanningTransactionCoordinating: Sendable {
    func recoveryDescriptor(for machineID: String) throws -> DoryDaemonVirtualMachinePlanningRecoveryDescriptor?
    func resolveReserveAndPublish(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult
}

extension DoryDaemonVirtualMachinePlanningTransactionCoordinating {
    public func recoveryDescriptor(for machineID: String) throws -> DoryDaemonVirtualMachinePlanningRecoveryDescriptor? { nil }
}

extension DoryDaemonVirtualMachinePlanningTransactionCoordinator:
    DoryDaemonVirtualMachinePlanningTransactionCoordinating {}

/// Narrow product boundary used by MachineManager and XPC. The concrete controller retains the
/// trusted artifact/repository graph; tests can inject only an observer/rejector and therefore
/// cannot manufacture a resolved runtime identity.
public protocol DoryDaemonVirtualMachineProductionPlanningControlling: Sendable {
    func recoveryDescriptor(for machineID: String) throws -> DoryDaemonVirtualMachinePlanningRecoveryDescriptor?
    func authorityRevision(for reference: DoryVMResolverReference) throws -> UInt64?
    func validateBackingOwnership(
        of artifact: DoryResolvedMachineLaunchArtifact, atPath path: String
    ) throws
    func publishResolvedPlan(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    ) throws
}

extension DoryDaemonVirtualMachineProductionPlanningControlling {
    public func recoveryDescriptor(for machineID: String) throws -> DoryDaemonVirtualMachinePlanningRecoveryDescriptor? { nil }

    public func validateBackingOwnership(
        of artifact: DoryResolvedMachineLaunchArtifact, atPath path: String
    ) throws {
        throw DoryDaemonVirtualMachineProductionPlanningControllerFailure(
            code: .mediaAuthorityMissing,
            message: "Artifact backing ownership validation is unavailable."
        )
    }
}

/// The sole production entry for a manager-owned native create/update/replan transaction. It
/// first establishes exact artifact authority, then delegates reserve -> bind -> publication to
/// the crash-safe coordinator, and finally proves the published plan and workspace are the exact
/// result. It never derives intent from compatibility environment variables or calls MachineManager
/// create/update recursively.
public final class DoryDaemonVirtualMachineProductionPlanningController:
    @unchecked Sendable
{
    private let artifactAuthority: DoryVirtualMachineArtifactAuthority
    private let coordinator: any DoryDaemonVirtualMachinePlanningTransactionCoordinating
    private let resolveValidatedTransaction: @Sendable (
        DoryDaemonValidatedPlanningTransaction
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult
    private let workspaces: DoryWorkspaceRepository
    private let plans: DoryResolvedMachinePlanRepository

    init(
        planning: DoryDaemonVirtualMachineProductionPlanningContext
    ) {
        artifactAuthority = planning.artifactAuthority
        coordinator = planning.coordinator
        let concreteCoordinator = planning.coordinator
        resolveValidatedTransaction = { try concreteCoordinator.resolveReserveAndPublish($0) }
        workspaces = planning.workspaces
        plans = planning.plans
    }

    init(
        artifactAuthority: DoryVirtualMachineArtifactAuthority,
        coordinator: any DoryDaemonVirtualMachinePlanningTransactionCoordinating,
        workspaces: DoryWorkspaceRepository,
        plans: DoryResolvedMachinePlanRepository
    ) {
        self.artifactAuthority = artifactAuthority
        self.coordinator = coordinator
        // An independently supplied protocol implementation owns its public input boundary.
        // Only the concrete production composition receives the internal validated handoff.
        resolveValidatedTransaction = { try coordinator.resolveReserveAndPublish($0.request) }
        self.workspaces = workspaces
        self.plans = plans
    }

    public func recoveryDescriptor(for machineID: String) throws -> DoryDaemonVirtualMachinePlanningRecoveryDescriptor? {
        try coordinator.recoveryDescriptor(for: machineID)
    }

    /// The manager must first authenticate the persisted plan, runtime generation and private
    /// workspace path. This check permits guest writes only on that exact mutable backing;
    /// it cannot provide fresh start evidence or authorize a replacement helper.
    public func validateBackingOwnership(
        of artifact: DoryResolvedMachineLaunchArtifact, atPath path: String
    ) throws {
        try artifactAuthority.validateBackingOwnership(
            reference: artifact.resolverReference,
            path: path,
            media: artifact.media,
            authorityRevision: artifact.authorityRevision,
            mutableProvenanceEvidence: artifact.mutableProvenanceEvidence
        )
    }

    public func resolveReserveAndPublish(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts publications: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        let validated = try DoryDaemonValidatedPlanningTransaction(request)
        let requirements = validated.planning.inventoryRequest.launchArtifacts
        guard requirements.count == publications.count,
              Set(publications.map(\.reference)).count == publications.count else {
            throw failure(.invalidRequest, "Planning artifacts do not match desired-state authority.")
        }
        let publicationsByReference = Dictionary(
            uniqueKeysWithValues: publications.map { ($0.reference, $0) }
        )
        for requirement in requirements {
            guard let publication = publicationsByReference[requirement.reference],
                  publication.kind == requirement.kind,
                  publication.source == requirement.source,
                  (publication.mutability == .mutable) == requirement.mutable,
                  let launchPath = exactLaunchPath(
                    for: requirement,
                    definition: request.planning.definition,
                    machine: request.planning.machine
                  ),
                  publication.path == launchPath else {
                throw failure(
                    .invalidRequest,
                    "Planning artifact path, kind, provenance, or mutability is not exact."
                )
            }
            try establishArtifactAuthority(publication, operationID: request.operationID)
        }

        let result: DoryDaemonVirtualMachinePlanningTransactionResult
        do { result = try resolveValidatedTransaction(validated) }
        catch let transaction as DoryDaemonVirtualMachinePlanningTransactionFailure {
            throw failure(
                .transactionRejected,
                "Production planning transaction failed closed "
                    + "(\(transaction.code.rawValue): \(transaction.message))"
            )
        } catch {
            throw failure(.transactionRejected, "Production planning transaction failed closed.")
        }
        let workspace: DoryVirtualMachineDefinition
        let plan: DoryResolvedMachinePlan
        do {
            workspace = try workspaces.readPersistedRecord(
                id: request.planning.definition.identity.id
            ).definition
            plan = try plans.read(id: request.planning.definition.identity.id)
        } catch {
            throw failure(.publicationMismatch, "Published planning authority is unavailable.")
        }
        guard workspace == request.planning.definition,
              plan == result.planning.resolvedPlan,
              DoryMachineRuntimeIdentity.planSHA256(plan)
                == result.planning.resolvedPlanSHA256 else {
            throw failure(.publicationMismatch, "Published planning authority is not exact.")
        }
        return result
    }

    /// Returns the exact current artifact-authority revision so a manager-owned replan can make
    /// mutable-media replacement an explicit compare-and-swap. Corrupt authority is never
    /// collapsed into a missing record.
    public func authorityRevision(
        for reference: DoryVMResolverReference
    ) throws -> UInt64? {
        try artifactAuthority.authorityRecord(reference: reference)?.authorityRevision
    }

    public func publishResolvedPlan(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    ) throws {
        _ = try resolveReserveAndPublish(request, artifacts: artifacts)
    }

    /// Compatibility launch paths remain daemon-local, but they are still launch authority. A
    /// resolver publication must describe the exact path the selected adapter will consume; a
    /// definition reference cannot authorize different bytes at an unrelated machine path.
    private func exactLaunchPath(
        for requirement: DoryDaemonVirtualMachineLaunchArtifactRequirement,
        definition: DoryVirtualMachineDefinition,
        machine: DoryMachineConfiguration
    ) -> String? {
        var paths = Set<String>()
        for usage in requirement.usages {
            switch usage.kind {
            case .boot:
                guard let boot = definition.boot.devices.first(where: {
                    $0.id == usage.identifier && $0.artifact == requirement.reference
                }) else { return nil }
                switch boot.kind {
                case .linuxKernel:
                    guard machine.bootMode == .linuxKernel else { return nil }
                    paths.insert(machine.kernelPath)
                case .installedLinuxBootBundle:
                    paths.insert(machine.kernelPath)
                case .installerISO:
                    guard let installerISOPath = machine.installerISOPath else { return nil }
                    paths.insert(installerISOPath)
                case .virtualDisk:
                    if machine.guestFamily == .macOS {
                        guard machine.bootMode == .macOSRestore,
                              let bundlePath = machine.macOSMachineBundlePath else {
                            return nil
                        }
                        paths.insert(
                            bundlePath + "/" + DoryVZMacMachineBundle.diskName
                        )
                    } else {
                        paths.insert(machine.rootfsPath)
                    }
                case .macOSRestoreImage:
                    guard machine.guestFamily == .macOS,
                          machine.bootMode == .macOSRestore,
                          let restoreImagePath = machine.macOSRestoreImagePath else {
                        return nil
                    }
                    paths.insert(restoreImagePath)
                }
            case .storage:
                guard let storage = definition.storage.first(where: {
                    $0.id == usage.identifier && $0.artifact == requirement.reference
                }), storage.role == .system else {
                    // Compatibility MachineManager cannot launch auxiliary typed disks yet.
                    return nil
                }
                if machine.guestFamily == .macOS {
                    guard machine.bootMode == .macOSRestore,
                          let bundlePath = machine.macOSMachineBundlePath else {
                        return nil
                    }
                    paths.insert(
                        bundlePath + "/" + DoryVZMacMachineBundle.diskName
                    )
                } else {
                    paths.insert(machine.rootfsPath)
                }
            case .firmware:
                // Firmware resolver paths are not represented by DoryMachineConfiguration yet.
                return nil
            }
        }
        guard paths.count == 1, let path = paths.first, !path.isEmpty,
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            return nil
        }
        return path
    }

    private func establishArtifactAuthority(
        _ publication: DoryDaemonVirtualMachinePlanningArtifactPublication,
        operationID: UUID
    ) throws {
        let current: DoryVirtualMachineArtifactAuthorityRecord?
        do { current = try artifactAuthority.authorityRecord(reference: publication.reference) }
        catch { throw failure(.mediaAuthorityConflict, "Media authority cannot be inspected.") }

        if let proof = publication.immutableReplacementProof {
            guard proof.operationID == operationID,
                  proof.reference == publication.reference, proof.path == publication.path,
                  publication.mutability == .immutable,
                  publication.kind == .linuxKernel || publication.kind == .installedLinuxBootBundle,
                  publication.expectedAuthorityRevision == proof.expectedAuthorityRevision,
                  let current, current.authorityRevision == proof.expectedAuthorityRevision,
                  current.path == publication.path, current.kind == publication.kind,
                  current.source == publication.source,
                  case .immutable = current.identity else {
                throw failure(.mediaAuthorityConflict, "Immutable replacement authority is not exact.")
            }
        }

        if let current {
            if current.path == URL(fileURLWithPath: publication.path).standardizedFileURL.path,
               current.kind == publication.kind, current.source == publication.source,
               (try? artifactAuthority.resolve(
                   reference: publication.reference,
                   kind: publication.kind,
                   source: publication.source
               )) != nil,
               publication.immutableReplacementProof.map({ proof in
                   if case let .immutable(sha256, _) = current.identity {
                       return sha256 == proof.sha256
                   }
                   return false
               }) ?? true {
                return
            }
            guard publication.mutability == .mutable || publication.immutableReplacementProof != nil,
                  publication.expectedAuthorityRevision == current.authorityRevision else {
                throw failure(.mediaAuthorityConflict, "Existing media authority is not exact.")
            }
        } else if publication.expectedAuthorityRevision != nil {
            throw failure(.mediaAuthorityMissing, "Expected media authority does not exist.")
        }

        do {
            switch publication.mutability {
            case .immutable:
                _ = try artifactAuthority.publishImmutable(
                    reference: publication.reference,
                    path: publication.path,
                    kind: publication.kind,
                    source: publication.source,
                    expectedAuthorityRevision: publication.expectedAuthorityRevision,
                    expectedSHA256: publication.immutableReplacementProof?.sha256
                )
            case .mutable:
                _ = try artifactAuthority.publishMutable(
                    reference: publication.reference,
                    path: publication.path,
                    kind: publication.kind,
                    source: publication.source,
                    expectedAuthorityRevision: publication.expectedAuthorityRevision
                )
            }
        } catch {
            throw failure(.mediaAuthorityConflict, "Exact media authority could not be published.")
        }
    }

    private func failure(
        _ code: DoryDaemonVirtualMachineProductionPlanningControllerFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineProductionPlanningControllerFailure {
        DoryDaemonVirtualMachineProductionPlanningControllerFailure(
            code: code,
            message: message
        )
    }
}

extension DoryDaemonVirtualMachineProductionPlanningController:
    DoryDaemonVirtualMachineProductionPlanningControlling {}

enum DoryDaemonVirtualMachineProductionRecoveryError: Error, Sendable, Equatable {
    case invalidDescriptor
    case machineUnavailable
    case insecureMachineAuthority
    case machineAuthorityChanged
    case requestMismatch
}

/// Production-owned recovery bridge. It reconstructs raw compatibility state only from the
/// manager's canonical private root and only after the coordinator has validated the journal
/// descriptor. No public activation argument can substitute a recovery request.
final class DoryDaemonVirtualMachineProductionRecoveryProvider:
    DoryDaemonVirtualMachinePlanningRecoveryProviding, @unchecked Sendable
{
    private static let maximumMachineBytes = 16 * 1_024 * 1_024
    private let stateDirectory: String

    init(stateDirectory: String) {
        self.stateDirectory = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
    }

    func recoveryRequest(
        for descriptor: DoryDaemonVirtualMachinePlanningRecoveryDescriptor
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionRequest? {
        guard descriptor.machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !descriptor.machineID.hasPrefix("."),
              descriptor.definition.identity.id == descriptor.machineID else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.invalidDescriptor
        }
        let machine = try readMachine(id: descriptor.machineID)
        let request = DoryDaemonVirtualMachinePlanningTransactionRequest(
            operationID: descriptor.operationID,
            planning: DoryDaemonVirtualMachinePlanningRequest(
                definition: descriptor.definition,
                canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(descriptor.definition),
                machine: machine,
                publication: descriptor.planPublication,
                fallbackAuthorization: descriptor.fallbackAuthorization,
                experimentalAuthorization: descriptor.experimentalAuthorization
            ),
            workspacePublication: descriptor.workspacePublication,
            resourceRequirements: descriptor.resourceRequirements,
            startingLeaseDurationMilliseconds:
                descriptor.startingLeaseDurationMilliseconds
        )
        guard descriptor.matches(request) else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.requestMismatch
        }
        return request
    }

    private func readMachine(id: String) throws -> DoryMachineConfiguration {
        let path = stateDirectory + "/" + id + "/machine.json"
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.machineUnavailable
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= Self.maximumMachineBytes else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.insecureMachineAuthority
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        guard data.count == before.st_size, fstat(descriptor, &after) == 0,
              Self.sameSnapshot(before, after) else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.machineAuthorityChanged
        }
        guard let machine = try? JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: data
        ), machine.id == id else {
            throw DoryDaemonVirtualMachineProductionRecoveryError.machineUnavailable
        }
        return machine
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
