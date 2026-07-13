import DoryOperations
import Foundation

extension MigrationImportAssetStagingExecution {
    mutating func stageNetwork(_ object: DoryOperationPlannedObject) async throws {
        let specificationData = try session.lease.readSpecification(
            digest: object.specificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            MigrationNetworkContract.self,
            from: specificationData
        ), specification.name == object.normalizedTargetName,
           object.collisionDecision == .create else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        try await requireNetworkAbsent(object)
        created.append(.network(name: specification.name, expectedLabels: specification.labels))
        let body = try MigrationImportAssetCanonical.networkCreateBody(specification)
        guard let response = await environment.target.proxyRequest(
            method: "POST",
            path: "/networks/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ) else {
            throw MigrationImportAssetStagingError.targetRequest(
                "Docker API became unavailable while creating network \(specification.name)"
            )
        }
        guard response.isSuccess else {
            let detail = String(data: response.body, encoding: .utf8) ?? response.reason
            throw MigrationImportAssetStagingError.targetRequest(
                "network \(specification.name) was rejected with HTTP "
                    + "\(response.statusCode): \(detail)"
            )
        }
        let inspectedContract = try await requireExactTargetNetwork(
            specification,
            object: object
        )
        try publishNetworkEvidence(
            inspectedContract,
            object: object,
            specification: specification
        )
    }

    mutating func publishNetworkEvidence(
        _ inspectedContract: Data,
        object: DoryOperationPlannedObject,
        specification: MigrationNetworkContract
    ) throws {
        let inspectedDigest = try session.lease.publishManifest(inspectedContract)
        let targetFingerprint = try MigrationImportAssetCanonical.targetFingerprint(
            specificationDigest: object.specificationDigest,
            targetManifestDigest: inspectedDigest
        )
        let manifest = try MigrationImportAssetCanonical.data(MigrationNetworkVerificationManifest(
            operationID: session.prepared.identity.id,
            object: object,
            inspectedContractDigest: inspectedDigest,
            targetFingerprint: targetFingerprint
        ))
        let manifestDigest = try session.lease.publishManifest(manifest)
        try session.lease.publishStagedObject(DoryOperationStagedObject(
            source: object.source,
            verifiedTarget: DoryOperationTargetIdentity(
                id: specification.name,
                fingerprint: targetFingerprint
            ),
            verificationManifestDigest: manifestDigest,
            disposition: .createdOperationOwned
        ))
        state = try session.lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: state.revision,
            stepID: "staging.network-verified"
        )
    }

    func requireNetworkAbsent(_ object: DoryOperationPlannedObject) async throws {
        let snapshot = try await environment.target.migrationSnapshot()
        guard !snapshot.networks.contains(where: { $0.name == object.normalizedTargetName }) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func requireExactTargetNetwork(
        _ specification: MigrationNetworkContract,
        object: DoryOperationPlannedObject
    ) async throws -> Data {
        let matches = try await environment.target.migrationSnapshot().networks.filter {
            $0.name == specification.name
        }
        guard matches.count == 1,
              matches[0].driver == specification.driver,
              matches[0].scope.lowercased() == "local",
              matches[0].labels == specification.labels,
              let response = await environment.target.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(specification.name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
              ), response.isSuccess,
              let actual = try? MigrationNetworkContract(
                network: matches[0],
                inspectedData: response.body
              ),
              let expectedObject = try? JSONSerialization.jsonObject(
                with: specification.portableCreateContract
              ),
              let actualObject = try? JSONSerialization.jsonObject(
                with: actual.portableCreateContract
              ),
              MigrationImportAssetCanonical.jsonContains(
                expected: expectedObject,
                actual: actualObject
              ) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return actual.portableCreateContract
    }

    func rollbackNetwork(
        _ name: String,
        expectedLabels: [String: String],
        failures: inout [String]
    ) async {
        do {
            let before = try await environment.target.migrationSnapshot().networks.filter {
                $0.name == name
            }
            guard before.count <= 1 else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .network, sourceID: name)
                )
            }
            if let network = before.first {
                guard owns(network.labels, expected: expectedLabels) else {
                    throw MigrationImportAssetStagingError.targetDrift(
                        .init(kind: .network, sourceID: name)
                    )
                }
                try await environment.target.removeNetwork(name: name)
            }
            let after = try await environment.target.migrationSnapshot()
            guard !after.networks.contains(where: { $0.name == name }) else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .network, sourceID: name)
                )
            }
        } catch {
            failures.append("remove staged network \(name): \(error)")
        }
    }
}
