import DoryOperations
import Foundation

enum MigrationOperationPlanError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingContainerSpecification(String)
    case missingImage(container: String, image: String)
    case missingVolume(container: String, volume: String)
    case missingNetwork(container: String, network: String)
    case missingContainerDependency(container: String, dependency: String)
    case incompleteInventory(String)
    case missingNetworkSpecification(String)
    case invalidNetworkSpecification(String)
    case targetCollision(kind: DoryOperationObjectKind, name: String)
    case invalidWritableLayerSize(String)
    case unsupportedCapability(String)
    case encoding(String)

    var description: String {
        switch self {
        case let .missingContainerSpecification(name):
            return "source container \(name) has no complete inspected specification"
        case let .missingImage(container, image):
            return "source container \(container) depends on missing image \(image)"
        case let .missingVolume(container, volume):
            return "source container \(container) depends on missing volume \(volume)"
        case let .missingNetwork(container, network):
            return "source container \(container) depends on missing network \(network)"
        case let .missingContainerDependency(container, dependency):
            return "source container \(container) depends on missing container \(dependency)"
        case let .incompleteInventory(detail):
            return "strict migration inventory is incomplete: \(detail)"
        case let .missingNetworkSpecification(name):
            return "network \(name) has no complete inspected driver/IPAM/options contract"
        case let .invalidNetworkSpecification(name):
            return "network \(name) returned an invalid or mismatched driver/IPAM/options contract"
        case let .targetCollision(kind, name):
            return "target already contains unrelated \(kind.rawValue) \(name)"
        case let .invalidWritableLayerSize(name):
            return "source container \(name) has an invalid writable-layer size"
        case let .unsupportedCapability(detail):
            return "migration capability preflight failed: \(detail)"
        case let .encoding(detail):
            return "cannot encode immutable migration plan: \(detail)"
        }
    }
}

/// The exact semantic plan and journal authority published before an import may mutate Docker.
struct PreparedMigrationOperation: Sendable {
    let completenessPlan: DoryOperationCompletenessPlan
    let journalPlan: DoryOperationPlan
    let specifications: [DoryOperationSpecification]

    func begin(in store: DoryOperationJournalStore) throws -> DoryOperationLease {
        try store.begin(
            journalPlan,
            completenessPlan: completenessPlan,
            specifications: specifications
        )
    }
}

/// Converts a strict Docker inventory into the shared operation graph. The builder is deliberately
/// pure: inspection and capability probes happen before this call, and this call performs no I/O.
enum MigrationOperationPlanBuilder {
    static let defaultNetworks: Set<String> = ["bridge", "host", "none"]

    static func build(
        _ input: MigrationOperationPlanningInput
    ) throws -> PreparedMigrationOperation {
        try validateStrictInventory(input)
        var assembly = MigrationPlanAssembly()
        let imageIndex = try addImages(
            input.source.snapshot.images,
            target: input.target.snapshot.images,
            to: &assembly
        )
        let volumeNames = try addVolumes(
            input.source.snapshot.volumes,
            target: input.target.snapshot.volumes,
            ownership: input.ownership,
            to: &assembly
        )
        let networkNames = try addNetworks(
            input.source,
            target: input.target.snapshot.networks,
            ownership: input.ownership,
            to: &assembly
        )
        let containerContext = MigrationContainerPlanningContext(
            targetNames: Set(input.target.snapshot.containers.map(\.name)),
            dependencies: MigrationContainerDependencyContext(
                imageIndex: imageIndex,
                volumeNames: volumeNames,
                networkNames: networkNames,
                containerIdentityIndex: containerIdentityIndex(input.source.snapshot.containers)
            ),
            ownership: input.ownership
        )
        try addContainers(input.source, context: containerContext, to: &assembly)
        return try finalize(input, assembly: assembly)
    }

    private static func validateStrictInventory(
        _ input: MigrationOperationPlanningInput
    ) throws {
        try validateCapabilities(input)
        let selectedContainerIDs = Set(input.source.snapshot.containers.map(\.id))
        guard Set(input.source.containerSpecifications.keys) == selectedContainerIDs else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source container specifications do not exactly match the selected container inventory"
            )
        }
        guard Set(input.source.writableLayerSizes.keys) == selectedContainerIDs else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source writable-layer sizes do not exactly match the selected container inventory"
            )
        }
        let target = input.target
        guard Set(target.containerSpecifications.keys) == Set(target.snapshot.containers.map(\.id)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "target container specifications do not exactly match the target inventory"
            )
        }
        let customNetworks = input.source.snapshot.networks.filter {
            !defaultNetworks.contains($0.name)
        }
        guard Set(input.source.networkInspections.keys) == Set(customNetworks.map(\.name)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source network inspections do not exactly match the custom-network inventory"
            )
        }
        guard Set(target.networkInspections.keys) == Set(target.snapshot.networks.map(\.name)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "target network inspections do not exactly match the target network inventory"
            )
        }
    }

    private static func validateCapabilities(
        _ input: MigrationOperationPlanningInput
    ) throws {
        let capabilities = input.capabilities
        guard capabilities.sourceSupportsArchiveTransfer,
              capabilities.targetSupportsArchiveTransfer else {
            throw MigrationOperationPlanError.unsupportedCapability(
                "both engines must support streaming image archives"
            )
        }
        guard capabilities.targetSupportsImageLoadReceipt else {
            throw MigrationOperationPlanError.unsupportedCapability(
                "the target engine must return an immutable image-load receipt"
            )
        }
        guard capabilities.sourceSupportsRawAPI,
              capabilities.targetSupportsRawAPI else {
            throw MigrationOperationPlanError.unsupportedCapability(
                "both engines must expose the local raw Docker API"
            )
        }
        if !input.source.snapshot.volumes.isEmpty,
           capabilities.transferHelper == nil {
            throw MigrationOperationPlanError.unsupportedCapability(
                "named volumes require the signed arm64 transfer helper"
            )
        }
    }

    private static func finalize(
        _ input: MigrationOperationPlanningInput,
        assembly: MigrationPlanAssembly
    ) throws -> PreparedMigrationOperation {
        let targetInventoryDigest = try digest(MigrationTargetInventory(
            snapshot: input.target.snapshot,
            containerSpecifications: input.target.containerSpecifications,
            networkInspections: input.target.networkInspections
        ))
        let context = DoryOperationPlanningContext(
            targetInventoryDigest: targetInventoryDigest,
            unownedTargetInventoryDigest: targetInventoryDigest,
            capabilitiesDigest: try digest(MigrationCapabilitySnapshot(
                sourceEngineVersion: input.source.snapshot.engineVersion,
                targetEngineVersion: input.target.snapshot.engineVersion,
                contract: input.capabilities
            )),
            capacityDigest: try digest(input.capacity),
            quiescenceDigest: try digest(MigrationQuiescenceContract(
                containers: input.source.snapshot.containers
            ))
        )
        let completenessPlan = try DoryOperationPlanner.plan(
            inventory: assembly.inventory,
            intents: assembly.intents,
            userSelection: assembly.inventory.map(\.key),
            context: context
        )
        let journalPlan = try DoryOperationPlan(
            id: input.identity.id,
            kind: .competitorImport,
            createdAt: input.identity.createdAt,
            source: authority(
                id: input.source.authorityID,
                snapshot: input.source.snapshot,
                inventoryDigest: completenessPlan.sourceInventoryDigest
            ),
            target: authority(
                id: input.target.authorityID,
                snapshot: input.target.snapshot,
                inventoryDigest: targetInventoryDigest
            ),
            completenessPlan: completenessPlan
        )
        return PreparedMigrationOperation(
            completenessPlan: completenessPlan,
            journalPlan: journalPlan,
            specifications: assembly.specifications.values.sorted { $0.digest < $1.digest }
        )
    }

    private static func authority(
        id: String,
        snapshot: RuntimeSnapshot,
        inventoryDigest: String
    ) throws -> DoryOperationAuthority {
        DoryOperationAuthority(
            kind: .dockerEngine,
            id: id,
            fingerprint: try digest(MigrationAuthorityContract(
                id: id,
                engineVersion: snapshot.engineVersion,
                inventoryDigest: inventoryDigest
            ))
        )
    }
}
