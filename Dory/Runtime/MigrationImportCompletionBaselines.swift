import DoryOperations
import Foundation

extension MigrationImportAssetStagingExecution {
    func requireExactAuthoritiesAndSourceClosure() async throws {
        async let currentSourceAuthority = MigrationDockerAuthority.read(from: environment.source)
        async let currentTargetAuthority = MigrationDockerAuthority.read(from: environment.target)
        async let currentSource = environment.source.migrationSnapshot()
        async let currentWritableSizes = environment.source.migrationContainerWritableSizes()
        guard try await currentSourceAuthority == session.prepared.sourceAuthority,
              try await currentTargetAuthority == session.prepared.targetAuthority else {
            throw MigrationImportAssetStagingError.invalidSession(
                "source or target Docker authority changed during migration"
            )
        }
        let snapshot = try await currentSource
        let writableSizes = try await currentWritableSizes
        let baseline = session.prepared.source.snapshot
        guard sourceImageIDs(snapshot) == sourceImageIDs(baseline),
              snapshot.volumes.map(\.name).sorted() == baseline.volumes.map(\.name).sorted(),
              customNetworkNames(snapshot) == customNetworkNames(baseline),
              snapshot.containers.map(\.id).sorted() == baseline.containers.map(\.id).sorted(),
              Set(writableSizes.keys) == Set(baseline.containers.map(\.id)) else {
            throw MigrationImportAssetStagingError.invalidSession(
                "the exact source object closure changed during migration"
            )
        }
    }

    func verifiedUnselectedSourceInventoryDigest() async throws -> String {
        let plan = session.prepared.operation.completenessPlan
        let sourceBaseline = try session.lease.readManifest(
            digest: plan.sourceInventoryDigest
        )
        let unselectedBaseline = try session.lease.readManifest(
            digest: plan.unselectedSourceInventoryDigest
        )
        guard let unselected = try? JSONDecoder().decode(
            [DoryOperationInventoryObject].self,
            from: unselectedBaseline
        ), Set(unselected.map(\.key)).isDisjoint(with: plan.selectedObjectKeys),
           MigrationImportAssetCanonical.digest(sourceBaseline) == plan.sourceInventoryDigest,
           MigrationImportAssetCanonical.digest(unselectedBaseline)
            == plan.unselectedSourceInventoryDigest else {
            throw MigrationImportAssetStagingError.invalidSession(
                "the durable selected and omitted source baselines are invalid"
            )
        }
        let currentSource = try await currentSourceOperationInventory()
        let current = try DoryOperationPlanner.inventoryBaselines(
            inventory: currentSource,
            plan: plan
        )
        guard current.sourceInventory == sourceBaseline,
              current.unselectedSourceInventory == unselectedBaseline else {
            throw MigrationImportAssetStagingError.invalidSession(
                "selected or deliberately omitted source objects changed during migration"
            )
        }
        return MigrationImportAssetCanonical.digest(current.unselectedSourceInventory)
    }

    func verifiedUnownedTargetInventoryDigest(
        staged: [DoryOperationStagedObject]
    ) async throws -> String {
        let plan = session.prepared.operation.completenessPlan
        var snapshot = try await environment.target.migrationSnapshot()
        for object in staged where object.disposition != .reusedPreexisting {
            switch object.source.kind {
            case .image, .writableLayer:
                let identity = MigrationOperationPlanBuilder.normalizedImageID(
                    object.verifiedTarget.id
                )
                snapshot.images.removeAll {
                    MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == identity
                }
            case .volume:
                snapshot.volumes.removeAll { $0.name == object.verifiedTarget.id }
            case .network:
                snapshot.networks.removeAll { $0.name == object.verifiedTarget.id }
            case .container:
                snapshot.containers.removeAll { $0.name == object.verifiedTarget.id }
            }
        }
        let specifications = try await targetContainerSpecifications(snapshot)
        let networkInspections = try await targetNetworkInspections(snapshot)
        let current = try MigrationOperationPlanBuilder.canonicalData(MigrationTargetInventory(
            snapshot: snapshot,
            containerSpecifications: specifications,
            networkInspections: networkInspections
        ))
        let baseline = try session.lease.readManifest(
            digest: plan.context.unownedTargetInventoryDigest
        )
        guard current == baseline,
              MigrationImportAssetCanonical.digest(current)
                == plan.context.unownedTargetInventoryDigest else {
            throw MigrationImportAssetStagingError.invalidSession(
                "unowned target objects changed during migration"
            )
        }
        return MigrationImportAssetCanonical.digest(current)
    }
}

private extension MigrationImportAssetStagingExecution {
    func currentSourceOperationInventory() async throws -> [DoryOperationInventoryObject] {
        let snapshot = try await environment.source.migrationSnapshot()
        let writableSizes = try await environment.source.migrationContainerWritableSizes()
        var containerSpecifications: [String: ContainerSpec] = [:]
        for container in snapshot.containers.sorted(by: { $0.id < $1.id }) {
            containerSpecifications[container.id] = try await MigrationContainerInspector.inspect(
                container,
                on: environment.source,
                sharedHome: environment.sharedHome,
                validatePortability: false
            )
        }
        var networkInspections: [String: Data] = [:]
        for network in snapshot.networks.filter({
            !MigrationOperationPlanBuilder.defaultNetworks.contains($0.name)
        }).sorted(by: { $0.name < $1.name }) {
            guard let response = await environment.source.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(network.name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            ), response.isSuccess,
                  (try? MigrationNetworkContract(
                    network: network,
                    inspectedData: response.body
                  )) != nil else {
                throw MigrationImportAssetStagingError.invalidSession(
                    "source network \(network.name) cannot be re-inspected"
                )
            }
            networkInspections[network.name] = response.body
        }
        let source = MigrationOperationSource(
            snapshot: snapshot,
            authorityID: session.prepared.source.authorityID,
            containerSpecifications: containerSpecifications,
            networkInspections: networkInspections,
            writableLayerSizes: writableSizes
        )
        return try MigrationOperationPlanBuilder.sourceInventory(
            source,
            ownership: session.prepared.ownership
        )
    }

    func sourceImageIDs(_ snapshot: RuntimeSnapshot) -> [String] {
        snapshot.images.map(MigrationOperationPlanBuilder.stableImageSourceID).sorted()
    }

    func customNetworkNames(_ snapshot: RuntimeSnapshot) -> [String] {
        snapshot.networks.filter {
            !MigrationOperationPlanBuilder.defaultNetworks.contains($0.name)
        }.map(\.name).sorted()
    }

    func targetContainerSpecifications(
        _ snapshot: RuntimeSnapshot
    ) async throws -> [String: ContainerSpec] {
        var specifications: [String: ContainerSpec] = [:]
        for container in snapshot.containers.sorted(by: { $0.id < $1.id }) {
            specifications[container.id] = try await MigrationContainerInspector.inspect(
                container,
                on: environment.target,
                sharedHome: environment.sharedHome,
                validatePortability: false
            )
        }
        guard specifications.count == snapshot.containers.count else {
            throw MigrationImportAssetStagingError.invalidSession(
                "unowned target container identities are not unique"
            )
        }
        return specifications
    }

    func targetNetworkInspections(
        _ snapshot: RuntimeSnapshot
    ) async throws -> [String: Data] {
        var inspections: [String: Data] = [:]
        for network in snapshot.networks.sorted(by: { $0.name < $1.name }) {
            guard let response = await environment.target.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(network.name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            ), response.isSuccess,
                  (try? MigrationNetworkContract(
                    network: network,
                    inspectedData: response.body
                  )) != nil else {
                throw MigrationImportAssetStagingError.invalidSession(
                    "unowned target network \(network.name) cannot be re-inspected"
                )
            }
            inspections[network.name] = response.body
        }
        guard inspections.count == snapshot.networks.count else {
            throw MigrationImportAssetStagingError.invalidSession(
                "unowned target network identities are not unique"
            )
        }
        return inspections
    }
}
