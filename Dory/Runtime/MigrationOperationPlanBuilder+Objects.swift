import DoryOperations
import Foundation

extension MigrationOperationPlanBuilder {
    static func addImages(
        _ source: [DockerImage],
        target: [DockerImage],
        to assembly: inout MigrationPlanAssembly
    ) throws -> MigrationImageIndex {
        var byID: [String: DoryOperationObjectKey] = [:]
        var byReference: [String: DoryOperationObjectKey] = [:]
        let targetIDs = Set(target.map { normalizedImageID($0.imageID) })
        let targetByReference = Dictionary(
            target.flatMap { image in
                imageReferences(image).map { (canonicalImageReference($0), image) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let sortedSource = source.map { image in
            (sortKey: stableImageSourceID(image), image: image)
        }.sorted { $0.sortKey < $1.sortKey }.map(\.image)
        for image in sortedSource {
            let sourceID = stableImageSourceID(image)
            let key = DoryOperationObjectKey(kind: .image, sourceID: sourceID)
            let specification = try makeSpecification(MigrationImageContract(image: image))
            assembly.retain(specification)
            assembly.inventory.append(DoryOperationInventoryObject(
                key: key,
                sourceFingerprint: try digest(MigrationImageIdentity(id: sourceID)),
                specificationDigest: specification.digest
            ))
            let references = imageReferences(image)
            let decision = try imageCollisionDecision(
                image,
                references: references,
                targetIDs: targetIDs,
                targetByReference: targetByReference
            )
            for reference in references {
                byReference[canonicalImageReference(reference)] = key
            }
            byID[normalizedImageID(image.imageID)] = key
            assembly.intents.append(DoryOperationObjectIntent(
                source: key,
                normalizedTargetName: references.first ?? sourceID,
                collisionDecision: decision,
                acceptedFinalState: .present
            ))
        }
        return MigrationImageIndex(byID: byID, byReference: byReference)
    }

    static func addVolumes(
        _ source: [Volume],
        target: [Volume],
        ownership: MigrationOperationOwnership,
        to assembly: inout MigrationPlanAssembly
    ) throws -> Set<String> {
        let targetNames = Set(target.map(\.name))
        for volume in source.sorted(by: { $0.name < $1.name }) {
            guard !targetNames.contains(volume.name) else {
                throw MigrationOperationPlanError.targetCollision(kind: .volume, name: volume.name)
            }
            let key = DoryOperationObjectKey(kind: .volume, sourceID: volume.name)
            let sourceContract = MigrationVolumeContract(volume: volume)
            let specification = try makeSpecification(MigrationVolumeContract(
                volume: volume,
                labels: ownership.labels(
                    existing: volume.labels,
                    kind: .volume,
                    sourceID: volume.name,
                    targetID: volume.name
                )
            ))
            assembly.retain(specification)
            assembly.inventory.append(DoryOperationInventoryObject(
                key: key,
                sourceFingerprint: try digest(sourceContract),
                specificationDigest: specification.digest
            ))
            assembly.intents.append(DoryOperationObjectIntent(
                source: key,
                normalizedTargetName: volume.name,
                acceptedFinalState: .present
            ))
        }
        return Set(source.map(\.name))
    }

    static func addNetworks(
        _ source: MigrationOperationSource,
        target: [DoryNetwork],
        ownership: MigrationOperationOwnership,
        to assembly: inout MigrationPlanAssembly
    ) throws -> Set<String> {
        let networks = source.snapshot.networks.filter { !defaultNetworks.contains($0.name) }
        let targetNames = Set(target.map(\.name))
        for network in networks.sorted(by: { $0.name < $1.name }) {
            guard !targetNames.contains(network.name) else {
                throw MigrationOperationPlanError.targetCollision(kind: .network, name: network.name)
            }
            guard let inspected = source.networkInspections[network.name] else {
                throw MigrationOperationPlanError.missingNetworkSpecification(network.name)
            }
            let key = DoryOperationObjectKey(kind: .network, sourceID: network.name)
            let sourceContract = try MigrationNetworkContract(
                network: network,
                inspectedData: inspected
            )
            let specification = try makeSpecification(MigrationNetworkContract(
                network: network,
                inspectedData: inspected,
                labels: ownership.labels(
                    existing: network.labels,
                    kind: .network,
                    sourceID: network.name,
                    targetID: network.name
                )
            ))
            assembly.retain(specification)
            assembly.inventory.append(DoryOperationInventoryObject(
                key: key,
                sourceFingerprint: try digest(sourceContract),
                specificationDigest: specification.digest
            ))
            assembly.intents.append(DoryOperationObjectIntent(
                source: key,
                normalizedTargetName: network.name,
                acceptedFinalState: .present
            ))
        }
        return Set(networks.map(\.name))
    }

    static func addContainers(
        _ source: MigrationOperationSource,
        context: MigrationContainerPlanningContext,
        to assembly: inout MigrationPlanAssembly
    ) throws {
        for container in source.snapshot.containers.sorted(by: { $0.id < $1.id }) {
            guard !context.targetNames.contains(container.name) else {
                throw MigrationOperationPlanError.targetCollision(kind: .container, name: container.name)
            }
            guard let specification = source.containerSpecifications[container.id] else {
                throw MigrationOperationPlanError.missingContainerSpecification(container.name)
            }
            guard let writableBytes = source.writableLayerSizes[container.id], writableBytes >= 0 else {
                throw MigrationOperationPlanError.invalidWritableLayerSize(container.name)
            }
            try addContainer(
                container,
                specification: specification,
                writableBytes: writableBytes,
                context: context,
                to: &assembly
            )
        }
    }

    private static func addContainer(
        _ container: Container,
        specification: ContainerSpec,
        writableBytes: Int64,
        context: MigrationContainerPlanningContext,
        to assembly: inout MigrationPlanAssembly
    ) throws {
        let imageKey = try imageDependency(
            container: container,
            specification: specification,
            index: context.dependencies.imageIndex
        )
        var dependencies = try containerObjectDependencies(
            container: container,
            specification: specification,
            imageKey: imageKey,
            context: context.dependencies
        )
        if writableBytes > 0 {
            let layerKey = try addWritableLayer(
                container,
                logicalBytes: writableBytes,
                imageKey: imageKey,
                to: &assembly
            )
            dependencies.append(layerKey)
        }
        let key = DoryOperationObjectKey(kind: .container, sourceID: container.id)
        var targetSpecification = specification
        targetSpecification.labels = context.ownership.labels(
            existing: specification.labels,
            kind: .container,
            sourceID: container.id,
            targetID: container.name
        )
        let persistedSpecification = try makeSpecification(targetSpecification)
        assembly.retain(persistedSpecification)
        assembly.inventory.append(DoryOperationInventoryObject(
            key: key,
            sourceFingerprint: try digest(MigrationContainerSourceContract(
                id: container.id,
                specification: specification
            )),
            specificationDigest: persistedSpecification.digest,
            dependencies: Array(Set(dependencies)).sorted()
        ))
        assembly.intents.append(DoryOperationObjectIntent(
            source: key,
            normalizedTargetName: container.name,
            acceptedFinalState: acceptedFinalState(container: container, specification: specification)
        ))
    }

    private static func addWritableLayer(
        _ container: Container,
        logicalBytes: Int64,
        imageKey: DoryOperationObjectKey,
        to assembly: inout MigrationPlanAssembly
    ) throws -> DoryOperationObjectKey {
        let key = DoryOperationObjectKey(kind: .writableLayer, sourceID: container.id)
        let specification = try makeSpecification(MigrationWritableLayerContract(
            containerID: container.id,
            logicalBytes: logicalBytes
        ))
        assembly.retain(specification)
        assembly.inventory.append(DoryOperationInventoryObject(
            key: key,
            sourceFingerprint: specification.digest,
            specificationDigest: specification.digest,
            dependencies: [imageKey]
        ))
        assembly.intents.append(DoryOperationObjectIntent(
            source: key,
            normalizedTargetName: "writable-layer-\(container.id)",
            acceptedFinalState: .applied
        ))
        return key
    }
}
