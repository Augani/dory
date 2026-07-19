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
nonisolated struct PreparedMigrationOperation: Sendable {
    let completenessPlan: DoryOperationCompletenessPlan
    let journalPlan: DoryOperationPlan
    let specifications: [DoryOperationSpecification]
    let baselineManifests: MigrationOperationBaselineManifests

    nonisolated func begin(in store: DoryOperationJournalStore) throws -> DoryOperationLease {
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

    /// Rebuilds the canonical source side without consulting or mutating the target. Completion
    /// uses this to prove that both selected and deliberately omitted objects still match the
    /// immutable baselines captured before target staging began.
    static func sourceInventory(
        _ source: MigrationOperationSource,
        ownership: MigrationOperationOwnership
    ) throws -> [DoryOperationInventoryObject] {
        try validateSourceInventory(source)
        var assembly = MigrationPlanAssembly()
        let imageIndex = try addImages(source.snapshot.images, target: [], to: &assembly)
        let volumeNames = try addVolumes(
            source.snapshot.volumes,
            target: [],
            ownership: ownership,
            to: &assembly
        )
        let networkNames = try addNetworks(
            source,
            target: [],
            ownership: ownership,
            to: &assembly
        )
        try addContainers(
            source,
            context: MigrationContainerPlanningContext(
                targetNames: [],
                dependencies: MigrationContainerDependencyContext(
                    imageIndex: imageIndex,
                    volumeNames: volumeNames,
                    networkNames: networkNames,
                    containerIdentityIndex: containerIdentityIndex(source.snapshot.containers)
                ),
                ownership: ownership
            ),
            to: &assembly
        )
        return assembly.inventory
    }

    private static func validateStrictInventory(
        _ input: MigrationOperationPlanningInput
    ) throws {
        try validateCapabilities(input)
        try validateSourceInventory(input.source)
        let target = input.target
        guard Set(target.containerSpecifications.keys) == Set(target.snapshot.containers.map(\.id)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "target container specifications do not exactly match the target inventory"
            )
        }
        guard Set(target.networkInspections.keys) == Set(target.snapshot.networks.map(\.name)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "target network inspections do not exactly match the target network inventory"
            )
        }
    }

    private static func validateSourceInventory(
        _ source: MigrationOperationSource
    ) throws {
        try validateImageIdentities(source.snapshot.images)
        let selectedContainerIDs = Set(source.snapshot.containers.map(\.id))
        guard Set(source.containerSpecifications.keys) == selectedContainerIDs else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source container specifications do not exactly match the selected container inventory"
            )
        }
        guard Set(source.writableLayerSizes.keys) == selectedContainerIDs else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source writable-layer sizes do not exactly match the selected container inventory"
            )
        }
        let customNetworks = source.snapshot.networks.filter {
            !defaultNetworks.contains($0.name)
        }
        guard Set(source.networkInspections.keys) == Set(customNetworks.map(\.name)) else {
            throw MigrationOperationPlanError.incompleteInventory(
                "source network inspections do not exactly match the custom-network inventory"
            )
        }
    }

    private static func validateImageIdentities(_ images: [DockerImage]) throws {
        var identities = Set<String>()
        for image in images {
            guard let identity = MigrationImageTransferExecution.canonicalImageID(image.imageID),
                  identities.insert(identity).inserted else {
                throw MigrationOperationPlanError.incompleteInventory(
                    "source images do not have unique immutable sha256 identities"
                )
            }
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
    }

    private static func finalize(
        _ input: MigrationOperationPlanningInput,
        assembly: MigrationPlanAssembly
    ) throws -> PreparedMigrationOperation {
        let targetInventoryData = try canonicalData(MigrationTargetInventory(
            snapshot: input.target.snapshot,
            containerSpecifications: input.target.containerSpecifications,
            networkInspections: input.target.networkInspections
        ))
        let targetInventoryDigest = sha256(targetInventoryData)
        let context = try planningContext(input, targetInventoryDigest: targetInventoryDigest)
        let requested = input.userSelection ?? assembly.inventory.map(\.key)
        let closure = try dependencyClosure(
            selection: requested,
            inventory: assembly.inventory
        )
        if closure.contains(where: { $0.kind == .volume }),
           input.capabilities.transferHelper == nil {
            throw MigrationOperationPlanError.unsupportedCapability(
                "named volumes require the signed arm64 transfer helper"
            )
        }
        try validateSelectedTargetCollisions(
            input,
            selected: closure
        )
        let completenessPlan = try DoryOperationPlanner.plan(
            inventory: assembly.inventory,
            intents: assembly.intents.filter { closure.contains($0.source) },
            userSelection: requested,
            context: context
        )
        let baselines = try baselineManifests(
            assembly: assembly,
            completenessPlan: completenessPlan,
            targetInventoryData: targetInventoryData
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
            specifications: assembly.specifications.values.filter {
                Set(completenessPlan.objects.map(\.specificationDigest)).contains($0.digest)
            }.sorted { $0.digest < $1.digest },
            baselineManifests: baselines
        )
    }

    private static func dependencyClosure(
        selection: [DoryOperationObjectKey],
        inventory: [DoryOperationInventoryObject]
    ) throws -> Set<DoryOperationObjectKey> {
        let byKey = Dictionary(uniqueKeysWithValues: inventory.map { ($0.key, $0) })
        var result = Set<DoryOperationObjectKey>()
        var pending = selection
        while let key = pending.popLast() {
            guard let object = byKey[key] else {
                throw MigrationOperationPlanError.incompleteInventory(
                    "selection references missing source object \(key)"
                )
            }
            guard result.insert(key).inserted else { continue }
            pending.append(contentsOf: object.dependencies)
        }
        return result
    }

    private static func validateSelectedTargetCollisions(
        _ input: MigrationOperationPlanningInput,
        selected: Set<DoryOperationObjectKey>
    ) throws {
        let targetVolumes = Set(input.target.snapshot.volumes.map(\.name))
        let targetNetworks = Set(input.target.snapshot.networks.map(\.name))
        let targetContainers = Set(input.target.snapshot.containers.map(\.name))
        for key in selected {
            switch key.kind {
            case .image:
                guard let image = input.source.snapshot.images.first(where: {
                    stableImageSourceID($0) == key.sourceID
                }) else { continue }
                _ = try imageCollisionDecision(
                    image,
                    references: imageReferences(image),
                    targetIDs: Set(input.target.snapshot.images.map {
                        normalizedImageID($0.imageID)
                    }),
                    targetByReference: Dictionary(
                        input.target.snapshot.images.flatMap { candidate in
                            imageReferences(candidate).map {
                                (canonicalImageReference($0), candidate)
                            }
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            case .volume where targetVolumes.contains(key.sourceID):
                throw MigrationOperationPlanError.targetCollision(kind: .volume, name: key.sourceID)
            case .network where targetNetworks.contains(key.sourceID):
                throw MigrationOperationPlanError.targetCollision(kind: .network, name: key.sourceID)
            case .container:
                guard let container = input.source.snapshot.containers.first(where: {
                    $0.id == key.sourceID
                }) else { continue }
                if targetContainers.contains(container.name) {
                    throw MigrationOperationPlanError.targetCollision(
                        kind: .container,
                        name: container.name
                    )
                }
            case .writableLayer, .volume, .network:
                break
            }
        }
    }

    private static func planningContext(
        _ input: MigrationOperationPlanningInput,
        targetInventoryDigest: String
    ) throws -> DoryOperationPlanningContext {
        DoryOperationPlanningContext(
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
    }

    private static func baselineManifests(
        assembly: MigrationPlanAssembly,
        completenessPlan: DoryOperationCompletenessPlan,
        targetInventoryData: Data
    ) throws -> MigrationOperationBaselineManifests {
        let source = try DoryOperationPlanner.inventoryBaselines(
            inventory: assembly.inventory,
            plan: completenessPlan
        )
        return MigrationOperationBaselineManifests(
            sourceInventory: source.sourceInventory,
            unselectedSourceInventory: source.unselectedSourceInventory,
            targetInventory: targetInventoryData,
            unownedTargetInventory: targetInventoryData
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
