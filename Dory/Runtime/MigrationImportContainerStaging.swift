import DoryOperations
import Foundation

struct MigrationContainerDefinitionManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let sourceContainerID: String
    let targetName: String
    let plannedSpecificationDigest: String
    let effectiveSpecificationDigest: String
    let dependencyTargets: [String: String]
    let acceptedFinalState: DoryOperationAcceptedFinalState

    init(
        operationID: UUID,
        object: DoryOperationPlannedObject,
        effectiveSpecificationDigest: String,
        dependencyTargets: [String: String]
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        sourceContainerID = object.source.sourceID
        targetName = object.normalizedTargetName
        plannedSpecificationDigest = object.specificationDigest
        self.effectiveSpecificationDigest = effectiveSpecificationDigest
        self.dependencyTargets = dependencyTargets
        acceptedFinalState = object.acceptedFinalState
    }
}

extension MigrationImportAssetStagingExecution {
    mutating func stageContainerDefinition(
        _ object: DoryOperationPlannedObject
    ) async throws {
        var specification = try plannedContainerSpecification(object)
        try await requireExactSourceContainer(object)
        try await requireTargetContainerAbsent(object)
        let dependencies = try stagedDependencies(object)
        specification.image = try effectiveContainerImage(
            object,
            dependencies: dependencies
        )
        let effectiveData = try MigrationImportAssetCanonical.data(specification)
        let effectiveDigest = try session.lease.publishManifest(effectiveData)
        let manifest = try MigrationImportAssetCanonical.data(
            MigrationContainerDefinitionManifest(
                operationID: session.prepared.identity.id,
                object: object,
                effectiveSpecificationDigest: effectiveDigest,
                dependencyTargets: Dictionary(uniqueKeysWithValues: dependencies.map {
                    ($0.key.description, $0.value.verifiedTarget.id)
                })
            )
        )
        let manifestDigest = try session.lease.publishManifest(manifest)
        try session.lease.publishStagedObject(DoryOperationStagedObject(
            source: object.source,
            verifiedTarget: DoryOperationTargetIdentity(
                id: object.normalizedTargetName,
                fingerprint: effectiveDigest
            ),
            verificationManifestDigest: manifestDigest,
            disposition: .createdOperationOwned
        ))
        state = try session.lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: state.revision,
            stepID: "staging.container-definition-verified"
        )
    }

    func plannedContainerSpecification(
        _ object: DoryOperationPlannedObject
    ) throws -> ContainerSpec {
        let data = try session.lease.readSpecification(digest: object.specificationDigest)
        guard let specification = try? JSONDecoder().decode(ContainerSpec.self, from: data),
              specification.name == object.normalizedTargetName,
              object.collisionDecision == .create,
              object.acceptedFinalState.isContainerPublicationState,
              let source = session.prepared.source.containerSpecifications[
                object.source.sourceID
              ],
              owns(
                specification.labels,
                expected: session.prepared.ownership.labels(
                    existing: source.labels,
                    kind: .container,
                    sourceID: object.source.sourceID,
                    targetID: object.normalizedTargetName
                )
              ) else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        return specification
    }

    func stagedDependencies(
        _ object: DoryOperationPlannedObject
    ) throws -> [DoryOperationObjectKey: DoryOperationStagedObject] {
        let all = Dictionary(uniqueKeysWithValues: try session.lease.readStagedObjects().map {
            ($0.source, $0)
        })
        let dependencies = Dictionary(uniqueKeysWithValues: object.dependencies.compactMap { key in
            all[key].map { (key, $0) }
        })
        guard dependencies.count == object.dependencies.count else {
            throw MigrationImportAssetStagingError.invalidSession(
                "container dependencies are not durably staged"
            )
        }
        return dependencies
    }

    func effectiveContainerImage(
        _ object: DoryOperationPlannedObject,
        dependencies: [DoryOperationObjectKey: DoryOperationStagedObject]
    ) throws -> String {
        let layers = object.dependencies.filter { $0.kind == .writableLayer }
        let images = object.dependencies.filter { $0.kind == .image }
        guard layers.count <= 1,
              images.count == 1,
              let dependency = (layers.first ?? images.first),
              let target = dependencies[dependency]?.verifiedTarget.id else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        return target
    }

    func requireExactSourceContainer(
        _ object: DoryOperationPlannedObject
    ) async throws {
        let snapshot = try await environment.source.migrationSnapshot()
        let current = snapshot.containers.filter { $0.id == object.source.sourceID }
        let baseline = session.prepared.source.snapshot.containers.filter {
            $0.id == object.source.sourceID
        }
        guard current.count == 1,
              baseline.count == 1,
              current[0].status == baseline[0].status,
              let planned = session.prepared.source.containerSpecifications[
                object.source.sourceID
              ],
              let plannedBytes = session.prepared.source.writableLayerSizes[
                object.source.sourceID
              ] else {
            throw MigrationImportAssetStagingError.invalidSession(
                "source container lifecycle changed for \(object.source)"
            )
        }
        let inspected = try await MigrationContainerInspector.inspect(
            current[0],
            on: environment.source,
            sharedHome: environment.sharedHome
        )
        let sizes = try await environment.source.migrationContainerWritableSizes()
        let inspectedData = try MigrationImportAssetCanonical.data(inspected)
        let plannedData = try MigrationImportAssetCanonical.data(planned)
        guard inspectedData == plannedData else {
            throw MigrationImportAssetStagingError.invalidSession(
                "source container definition changed for \(object.source) in fields "
                    + changedContainerSpecificationFields(plannedData, inspectedData)
                        .joined(separator: ",")
            )
        }
        guard sizes[object.source.sourceID] == plannedBytes else {
            throw MigrationImportAssetStagingError.invalidSession(
                "source writable layer changed for \(object.source): expected \(plannedBytes), "
                    + "observed \(sizes[object.source.sourceID].map(String.init) ?? "missing")"
            )
        }
    }

    func changedContainerSpecificationFields(
        _ planned: Data,
        _ current: Data
    ) -> [String] {
        guard let lhs = try? JSONSerialization.jsonObject(with: planned) as? [String: Any],
              let rhs = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else {
            return ["unparseable"]
        }
        return changedJSONPaths(lhs, rhs, prefix: "")
    }

    func changedJSONPaths(
        _ lhs: [String: Any],
        _ rhs: [String: Any],
        prefix: String
    ) -> [String] {
        Set(lhs.keys).union(rhs.keys).sorted().flatMap { key -> [String] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            switch (lhs[key], rhs[key]) {
            case let (left as [String: Any], right as [String: Any]):
                return changedJSONPaths(left, right, prefix: path)
            case (nil, nil):
                return []
            case let (left?, right?) where (left as AnyObject).isEqual(right):
                return []
            default:
                return [path]
            }
        }
    }

    func requireTargetContainerAbsent(
        _ object: DoryOperationPlannedObject
    ) async throws {
        let snapshot = try await environment.target.migrationSnapshot()
        let collisions = snapshot.containers.filter {
            $0.name == object.normalizedTargetName
        }
        guard collisions.isEmpty else {
            throw MigrationImportAssetStagingError.invalidSession(
                "target container name \(object.normalizedTargetName) appeared as "
                    + collisions.map(\.id).joined(separator: ",")
            )
        }
    }
}

private extension DoryOperationAcceptedFinalState {
    var isContainerPublicationState: Bool {
        switch self {
        case .created, .exited, .running, .paused, .createdStoppedAwaitingPort:
            return true
        case .present, .applied:
            return false
        }
    }
}
