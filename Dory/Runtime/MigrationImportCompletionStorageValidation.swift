import DoryOperations
import Foundation

extension MigrationImportAssetStagingExecution {
    func validateFinalVolume(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        let manifest: MigrationVolumeVerificationManifest = try stagedManifest(staged)
        let specificationData = try session.lease.readSpecification(
            digest: object.specificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            MigrationVolumeContract.self,
            from: specificationData
        ), manifest.schemaVersion == MigrationVolumeVerificationManifest.schemaVersion,
           manifest.operationID == session.prepared.identity.id,
           manifest.sourceVolume == object.source.sourceID,
           manifest.targetVolume == object.normalizedTargetName,
           manifest.specificationDigest == object.specificationDigest,
           manifest.targetFingerprint == staged.verifiedTarget.fingerprint,
           staged.verifiedTarget.id == specification.name else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let sourceVolumes = try await environment.source.migrationSnapshot().volumes.filter {
            $0.name == object.source.sourceID
        }
        guard sourceVolumes.count == 1,
              try MigrationOperationPlanBuilder.digest(
                MigrationVolumeContract(volume: sourceVolumes[0])
              ) == object.sourceFingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        try await requireExactTargetVolume(specification, object: object)
        let receipt = try await environment.transfers.verifyVolume(
            MigrationVolumeTransferRequest(
                operationID: session.prepared.identity.id,
                sourceAuthorityHash: session.prepared.ownership.sourceAuthorityHash,
                sourceVolume: object.source.sourceID,
                targetVolume: object.normalizedTargetName
            ),
            from: environment.source,
            to: environment.target
        )
        try requireExactVolumeReceipt(receipt, manifest: manifest, object: object)
        let fingerprint = try MigrationImportAssetCanonical.targetFingerprint(
            specificationDigest: object.specificationDigest,
            targetManifestDigest: receipt.targetManifestSha256
        )
        guard fingerprint == staged.verifiedTarget.fingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return DoryOperationTargetIdentity(id: specification.name, fingerprint: fingerprint)
    }

    func validateFinalNetwork(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        let manifest: MigrationNetworkVerificationManifest = try stagedManifest(staged)
        let specificationData = try session.lease.readSpecification(
            digest: object.specificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            MigrationNetworkContract.self,
            from: specificationData
        ), manifest.schemaVersion == MigrationNetworkVerificationManifest.schemaVersion,
           manifest.operationID == session.prepared.identity.id,
           manifest.sourceNetwork == object.source.sourceID,
           manifest.targetNetwork == object.normalizedTargetName,
           manifest.specificationDigest == object.specificationDigest,
           manifest.targetFingerprint == staged.verifiedTarget.fingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let sourceContract = try await currentNetworkContract(
            named: object.source.sourceID,
            on: environment.source,
            object: object
        )
        guard try MigrationOperationPlanBuilder.digest(sourceContract) == object.sourceFingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let inspected = try await requireExactTargetNetwork(specification, object: object)
        let inspectedDigest = MigrationImportAssetCanonical.digest(inspected)
        guard inspectedDigest == manifest.inspectedContractDigest,
              try session.lease.readManifest(digest: inspectedDigest) == inspected else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let fingerprint = try MigrationImportAssetCanonical.targetFingerprint(
            specificationDigest: object.specificationDigest,
            targetManifestDigest: inspectedDigest
        )
        guard fingerprint == staged.verifiedTarget.fingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return DoryOperationTargetIdentity(id: specification.name, fingerprint: fingerprint)
    }
}

private extension MigrationImportAssetStagingExecution {
    func requireExactVolumeReceipt(
        _ receipt: MigrationVolumeTransferReceipt,
        manifest: MigrationVolumeVerificationManifest,
        object: DoryOperationPlannedObject
    ) throws {
        guard receipt.sourceManifestSha256 == manifest.sourceManifestDigest,
              receipt.targetManifestSha256 == manifest.targetManifestDigest,
              MigrationImportAssetCanonical.digest(receipt.sourceManifest)
                == manifest.sourceManifestDigest,
              MigrationImportAssetCanonical.digest(receipt.targetManifest)
                == manifest.targetManifestDigest,
              try session.lease.readManifest(digest: manifest.sourceManifestDigest)
                == receipt.sourceManifest,
              try session.lease.readManifest(digest: manifest.targetManifestDigest)
                == receipt.targetManifest,
              receipt.sourceEntryCount == manifest.sourceEntryCount,
              receipt.verifiedTargetEntryCount == manifest.targetEntryCount,
              receipt.excludedSocketCount == manifest.excludedSocketCount,
              receipt.containsDeviceNodes == manifest.containsDeviceNodes else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func currentNetworkContract(
        named name: String,
        on runtime: any ContainerRuntime,
        object: DoryOperationPlannedObject
    ) async throws -> MigrationNetworkContract {
        let matches = try await runtime.migrationSnapshot().networks.filter { $0.name == name }
        guard matches.count == 1,
              let response = await runtime.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
              ), response.isSuccess,
              let contract = try? MigrationNetworkContract(
                network: matches[0],
                inspectedData: response.body
              ) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return contract
    }
}
