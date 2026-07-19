import DoryOperations
import Foundation

enum MigrationStrictInventoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case incomplete(String)
    case unsafe(String)
    case unsupported(String)

    var description: String {
        switch self {
        case let .incomplete(detail): "strict migration inventory is incomplete: \(detail)"
        case let .unsafe(detail): "migration cannot start safely: \(detail)"
        case let .unsupported(detail): "migration input is unsupported: \(detail)"
        }
    }
}

struct PreparedMigrationExecution: Sendable {
    let operation: PreparedMigrationOperation
    let identity: MigrationOperationIdentity
    let sourceAuthority: MigrationDockerAuthority
    let targetAuthority: MigrationDockerAuthority
    let source: MigrationOperationSource
    let target: MigrationOperationTarget
    let capacity: MigrationCapacityContract
    let sourceVolumeBytes: [String: Int64]

    var ownership: MigrationOperationOwnership {
        MigrationOperationOwnership(
            operationID: operation.journalPlan.id,
            sourceAuthorityID: source.authorityID
        )
    }
}

private struct MigrationStrictBaseInventory {
    let sourceAuthority: MigrationDockerAuthority
    let targetAuthority: MigrationDockerAuthority
    let sourceSnapshot: RuntimeSnapshot
    let targetSnapshot: RuntimeSnapshot
    let writableSizes: [String: Int64]
}

private struct MigrationStrictObjectInventory {
    let sourceSpecifications: [String: ContainerSpec]
    let targetSpecifications: [String: ContainerSpec]
    let sourceNetworks: [String: Data]
    let targetNetworks: [String: Data]
}

private struct MigrationStrictStorageInventory {
    let volumeBytes: [String: Int64]
    let capacity: MigrationCapacityContract
}

enum MigrationStrictInventoryCollector {
    static let safetyFloorBytes: Int64 = 4_000_000_000

    static func collect(
        from sourceRuntime: any ContainerRuntime,
        to targetRuntime: any ContainerRuntime,
        availableHostBytes: Int64,
        sharedHome: String = NSHomeDirectory(),
        transferHelper: MigrationTransferHelperContract?,
        identity: MigrationOperationIdentity = .fresh(),
        hostArchitecture: String = currentHostArchitecture,
        engineCapacity: MigrationEngineCapacity = .defaultV1,
        userSelection: [DoryOperationObjectKey]? = nil
    ) async throws -> PreparedMigrationExecution {
        try validateHost(hostArchitecture, availableBytes: availableHostBytes)
        let base = try await readBase(from: sourceRuntime, to: targetRuntime)
        try validateBase(base)
        let objects = try await inspectObjects(
            base,
            sourceRuntime: sourceRuntime,
            targetRuntime: targetRuntime,
            sharedHome: sharedHome
        )
        let capabilities = MigrationOperationCapabilityContract(
            sourceSupportsArchiveTransfer: sourceRuntime.supportsImageArchiveTransfer,
            targetSupportsArchiveTransfer: targetRuntime.supportsImageArchiveTransfer,
            targetSupportsImageLoadReceipt: targetRuntime.supportsImageLoadReceipt,
            sourceSupportsRawAPI: sourceRuntime.supportsRawProxy,
            targetSupportsRawAPI: targetRuntime.supportsRawProxy,
            transferHelper: base.sourceSnapshot.volumes.isEmpty ? nil : transferHelper
        )
        // Build once with a neutral capacity contract to obtain the exact dependency closure.
        // Admission and quiescence are then calculated only for that closure, so omitted objects
        // cannot make an otherwise safe partial import fail.
        let provisional = try assemble(
            base: base,
            objects: objects,
            storage: MigrationStrictStorageInventory(
                volumeBytes: [:],
                capacity: MigrationCapacityContract(
                    sourceVolumeBytes: [:],
                    sourceWritableLayerBytes: [:],
                    targetDockerBytes: 0,
                    availableHostBytes: availableHostBytes,
                    requiredHostBytes: 0,
                    requiredEngineBytes: 0,
                    engineLogicalBytes: engineCapacity.logicalBytes,
                    engineUsableBytes: engineCapacity.usableBytes
                )
            ),
            capabilities: capabilities,
            identity: identity,
            userSelection: userSelection
        )
        let selectedKeys = Set(provisional.operation.completenessPlan.selectedObjectKeys)
        let selectedContainerIDs = Set(selectedKeys.compactMap {
            $0.kind == .container ? $0.sourceID : nil
        })
        try await validateSelectedPortability(
            base,
            selectedKeys: selectedKeys,
            sourceRuntime: sourceRuntime,
            sharedHome: sharedHome
        )
        try validateQuiescence(
            snapshot: RuntimeSnapshot(containers: base.sourceSnapshot.containers.filter {
                selectedContainerIDs.contains($0.id)
            }),
            specifications: objects.sourceSpecifications,
            writableSizes: base.writableSizes.filter {
                selectedContainerIDs.contains($0.key)
            }
        )
        try validateVolumes(base.sourceSnapshot.volumes.filter {
            selectedKeys.contains(DoryOperationObjectKey(kind: .volume, sourceID: $0.name))
        })
        let storage = try await inspectStorage(
            base,
            selectedKeys: selectedKeys,
            sourceRuntime: sourceRuntime,
            targetRuntime: targetRuntime,
            availableHostBytes: availableHostBytes,
            engineCapacity: engineCapacity
        )
        return try assemble(
            base: base,
            objects: objects,
            storage: storage,
            capabilities: capabilities,
            identity: identity,
            userSelection: userSelection
        )
    }

    private nonisolated static var currentHostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported"
        #endif
    }
}

private extension MigrationStrictInventoryCollector {
    static func readBase(
        from sourceRuntime: any ContainerRuntime,
        to targetRuntime: any ContainerRuntime
    ) async throws -> MigrationStrictBaseInventory {
        async let sourceAuthority = MigrationDockerAuthority.read(from: sourceRuntime)
        async let targetAuthority = MigrationDockerAuthority.read(from: targetRuntime)
        async let sourceSnapshot = sourceRuntime.migrationSnapshot()
        async let targetSnapshot = targetRuntime.migrationSnapshot()
        async let writableSizes = sourceRuntime.migrationContainerWritableSizes()
        return try await MigrationStrictBaseInventory(
            sourceAuthority: sourceAuthority,
            targetAuthority: targetAuthority,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            writableSizes: writableSizes
        )
    }

    static func validateBase(_ base: MigrationStrictBaseInventory) throws {
        try validateAuthorities(
            base.sourceAuthority,
            target: base.targetAuthority,
            sourceSnapshot: base.sourceSnapshot,
            targetSnapshot: base.targetSnapshot
        )
        try validateNoUnpublishedArtifacts(base.sourceSnapshot, role: "source")
        try validateNoUnpublishedArtifacts(base.targetSnapshot, role: "target")
    }

    static func inspectObjects(
        _ base: MigrationStrictBaseInventory,
        sourceRuntime: any ContainerRuntime,
        targetRuntime: any ContainerRuntime,
        sharedHome: String
    ) async throws -> MigrationStrictObjectInventory {
        let sourceSpecifications = try await containerSpecifications(
            snapshot: base.sourceSnapshot,
            runtime: sourceRuntime,
            sharedHome: sharedHome,
            validatePortability: false
        )
        let targetSpecifications = try await containerSpecifications(
            snapshot: base.targetSnapshot,
            runtime: targetRuntime,
            sharedHome: sharedHome,
            validatePortability: false
        )
        let customNetworks = base.sourceSnapshot.networks.filter {
            !MigrationOperationPlanBuilder.defaultNetworks.contains($0.name)
        }
        return try await MigrationStrictObjectInventory(
            sourceSpecifications: sourceSpecifications,
            targetSpecifications: targetSpecifications,
            sourceNetworks: networkInspections(
                customNetworks,
                runtime: sourceRuntime,
                requirePortable: false
            ),
            targetNetworks: networkInspections(
                base.targetSnapshot.networks,
                runtime: targetRuntime,
                requirePortable: false
            )
        )
    }

    static func validateSelectedPortability(
        _ base: MigrationStrictBaseInventory,
        selectedKeys: Set<DoryOperationObjectKey>,
        sourceRuntime: any ContainerRuntime,
        sharedHome: String
    ) async throws {
        let selectedContainerIDs = Set(selectedKeys.compactMap {
            $0.kind == .container ? $0.sourceID : nil
        })
        for container in base.sourceSnapshot.containers
            .filter({ selectedContainerIDs.contains($0.id) })
            .sorted(by: { $0.id < $1.id }) {
            _ = try await MigrationContainerInspector.inspect(
                container,
                on: sourceRuntime,
                sharedHome: sharedHome,
                validatePortability: true
            )
        }
        let selectedNetworkNames = Set(selectedKeys.compactMap {
            $0.kind == .network ? $0.sourceID : nil
        })
        _ = try await networkInspections(
            base.sourceSnapshot.networks.filter {
                selectedNetworkNames.contains($0.name)
            },
            runtime: sourceRuntime,
            requirePortable: true
        )
    }

    static func inspectStorage(
        _ base: MigrationStrictBaseInventory,
        selectedKeys: Set<DoryOperationObjectKey>,
        sourceRuntime: any ContainerRuntime,
        targetRuntime: any ContainerRuntime,
        availableHostBytes: Int64,
        engineCapacity: MigrationEngineCapacity
    ) async throws -> MigrationStrictStorageInventory {
        let selectedVolumeNames = base.sourceSnapshot.volumes.map(\.name).filter {
            selectedKeys.contains(DoryOperationObjectKey(kind: .volume, sourceID: $0))
        }
        let volumeBytes = try await namedVolumeSizes(
            expected: selectedVolumeNames,
            runtime: sourceRuntime
        )
        let targetDockerBytes = try await dockerUsage(runtime: targetRuntime)
        let selectedImageIDs = Set(selectedKeys.compactMap {
            $0.kind == .image ? $0.sourceID : nil
        })
        let selectedWritableIDs = Set(selectedKeys.compactMap {
            $0.kind == .writableLayer ? $0.sourceID : nil
        })
        var selectedSource = base.sourceSnapshot
        selectedSource.images = selectedSource.images.filter {
            selectedImageIDs.contains(MigrationOperationPlanBuilder.stableImageSourceID($0))
        }
        selectedSource.volumes = selectedSource.volumes.filter {
            selectedVolumeNames.contains($0.name)
        }
        selectedSource.containers = selectedSource.containers.filter {
            selectedWritableIDs.contains($0.id)
        }
        let selectedWritableSizes = base.writableSizes.filter {
            selectedWritableIDs.contains($0.key)
        }
        let capacity = try capacityContract(MigrationCapacityInput(
            source: selectedSource,
            target: base.targetSnapshot,
            volumeBytes: volumeBytes,
            writableSizes: selectedWritableSizes,
            targetDockerBytes: targetDockerBytes,
            availableHostBytes: availableHostBytes,
            engineCapacity: engineCapacity
        ))
        return MigrationStrictStorageInventory(volumeBytes: volumeBytes, capacity: capacity)
    }

    static func assemble(
        base: MigrationStrictBaseInventory,
        objects: MigrationStrictObjectInventory,
        storage: MigrationStrictStorageInventory,
        capabilities: MigrationOperationCapabilityContract,
        identity: MigrationOperationIdentity,
        userSelection: [DoryOperationObjectKey]?
    ) throws -> PreparedMigrationExecution {
        let source = MigrationOperationSource(
            snapshot: base.sourceSnapshot,
            authorityID: base.sourceAuthority.authorityID,
            containerSpecifications: objects.sourceSpecifications,
            networkInspections: objects.sourceNetworks,
            writableLayerSizes: base.writableSizes
        )
        let target = MigrationOperationTarget(
            snapshot: base.targetSnapshot,
            authorityID: base.targetAuthority.authorityID,
            containerSpecifications: objects.targetSpecifications,
            networkInspections: objects.targetNetworks
        )
        let operation = try MigrationOperationPlanBuilder.build(MigrationOperationPlanningInput(
            source: source,
            target: target,
            capabilities: capabilities,
            capacity: storage.capacity,
            identity: identity,
            userSelection: userSelection
        ))
        return PreparedMigrationExecution(
            operation: operation,
            identity: identity,
            sourceAuthority: base.sourceAuthority,
            targetAuthority: base.targetAuthority,
            source: source,
            target: target,
            capacity: storage.capacity,
            sourceVolumeBytes: storage.volumeBytes
        )
    }

    static func validateHost(_ architecture: String, availableBytes: Int64) throws {
        guard architecture == "arm64" else {
            throw MigrationStrictInventoryError.unsupported(
                "public v1 requires an Apple Silicon Mac"
            )
        }
        guard availableBytes >= 0 else {
            throw MigrationStrictInventoryError.incomplete(
                "macOS did not report available host storage"
            )
        }
    }

    static func validateAuthorities(
        _ source: MigrationDockerAuthority,
        target: MigrationDockerAuthority,
        sourceSnapshot: RuntimeSnapshot,
        targetSnapshot: RuntimeSnapshot
    ) throws {
        guard source.daemonIdentity != target.daemonIdentity else {
            throw MigrationStrictInventoryError.unsafe(
                "source and target resolve to the same Docker daemon"
            )
        }
        guard sourceSnapshot.engineRunning,
              targetSnapshot.engineRunning,
              sourceSnapshot.engineVersion == source.engineVersion,
              targetSnapshot.engineVersion == target.engineVersion else {
            throw MigrationStrictInventoryError.incomplete(
                "engine version and running-state authority changed during collection"
            )
        }
    }

    static func validateNoUnpublishedArtifacts(
        _ snapshot: RuntimeSnapshot,
        role: String
    ) throws {
        let labeled = snapshot.containers.map(\.labels)
            + snapshot.images.map(\.labels)
            + snapshot.volumes.map(\.labels)
            + snapshot.networks.map(\.labels)
        let unfinished = labeled.contains { labels in
            labels["dev.dory.operation.id"] != nil
                && labels["dev.dory.operation.state"] != "published"
        }
        guard !unfinished else {
            throw MigrationStrictInventoryError.unsafe(
                "the \(role) engine contains unfinished Dory operation objects; recover them first"
            )
        }
    }

    static func containerSpecifications(
        snapshot: RuntimeSnapshot,
        runtime: any ContainerRuntime,
        sharedHome: String,
        validatePortability: Bool
    ) async throws -> [String: ContainerSpec] {
        var result: [String: ContainerSpec] = [:]
        for container in snapshot.containers.sorted(by: { $0.id < $1.id }) {
            result[container.id] = try await MigrationContainerInspector.inspect(
                container,
                on: runtime,
                sharedHome: sharedHome,
                validatePortability: validatePortability
            )
        }
        guard result.count == snapshot.containers.count else {
            throw MigrationStrictInventoryError.incomplete("duplicate source container identities")
        }
        return result
    }

    static func validateQuiescence(
        snapshot: RuntimeSnapshot,
        specifications: [String: ContainerSpec],
        writableSizes: [String: Int64]
    ) throws {
        let ids = Set(snapshot.containers.map(\.id))
        guard Set(writableSizes.keys) == ids,
              writableSizes.values.allSatisfy({ $0 >= 0 }) else {
            throw MigrationStrictInventoryError.incomplete(
                "writable-layer sizes do not exactly match the source containers"
            )
        }
        var liveVolumes: [String] = []
        var liveLayers: [String] = []
        for container in snapshot.containers where container.status == .running {
            guard let specification = specifications[container.id] else {
                throw MigrationStrictInventoryError.incomplete(
                    "missing inspected source container \(container.name)"
                )
            }
            if specification.mounts.contains(where: {
                $0.type.lowercased() == "volume" && !$0.readOnly
            }) {
                liveVolumes.append(container.name)
            }
            if writableSizes[container.id, default: 0] > 0 {
                liveLayers.append(container.name)
            }
        }
        guard liveVolumes.isEmpty else {
            throw MigrationStrictInventoryError.unsafe(
                "running containers are writing named volumes: \(liveVolumes.sorted().joined(separator: ", "))"
            )
        }
        guard liveLayers.isEmpty else {
            throw MigrationStrictInventoryError.unsafe(
                "running containers have writable-layer changes: \(liveLayers.sorted().joined(separator: ", "))"
            )
        }
    }

    static func validateVolumes(_ volumes: [Volume]) throws {
        for volume in volumes {
            guard volume.driver.lowercased() == "local", volume.options.isEmpty else {
                throw MigrationStrictInventoryError.unsupported(
                    "volume \(volume.name) uses driver/options backed by external host state"
                )
            }
        }
    }
}
