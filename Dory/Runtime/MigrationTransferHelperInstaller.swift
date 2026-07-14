import Foundation

struct MigrationTransferHelperInstallation: Sendable, Equatable {
    let imageID: String
    let ownershipReference: String
    let restoreDanglingImageAfterCleanup: Bool
}

extension MigrationTransferHelperAsset {
    func install(
        on runtime: any ContainerRuntime,
        operationID: UUID
    ) async throws -> MigrationTransferHelperInstallation {
        guard runtime.supportsImageArchiveTransfer,
              runtime.supportsImageLoadReceipt,
              runtime.supportsRawProxy else {
            throw MigrationTransferHelperError.incompatibleEngine(
                "image archive receipts and the raw Docker API are required"
            )
        }
        let repository = "dory.internal/operation-\(operationID.uuidString.lowercased())"
        let tag = "transfer-helper"
        let ownershipReference = "\(repository):\(tag)"
        let baseline = try await imageInventory(on: runtime)
        var loadedImageID: String?
        var priorInspection: TransferHelperImageInspection?
        var tagAttempted = false
        do {
            let imageID = try await loadSignedArchive(on: runtime)
            loadedImageID = imageID
            if baseline.contains(imageID) {
                priorInspection = await inspectImage(imageID: imageID, on: runtime)
            }
            try await verifyLoadedImage(imageID, on: runtime)
            tagAttempted = true
            try await runtime.tagImage(source: imageID, repo: repository, tag: tag)
            return MigrationTransferHelperInstallation(
                imageID: imageID,
                ownershipReference: ownershipReference,
                restoreDanglingImageAfterCleanup: priorInspection.map {
                    $0.id == imageID && ($0.repoTags ?? []).allSatisfy { $0 == "<none>:<none>" }
                } ?? false
            )
        } catch {
            let rollbackFailures = await rollbackFailedInstallation(
                baseline: baseline,
                loadedImageID: loadedImageID,
                ownershipReference: ownershipReference,
                priorInspection: priorInspection,
                tagAttempted: tagAttempted,
                on: runtime
            )
            if rollbackFailures.isEmpty { throw error }
            throw MigrationTransferHelperError.engineOperation(
                "install helper failed (\(error)); rollback failed: "
                    + rollbackFailures.joined(separator: "; ")
            )
        }
    }

    private func rollbackFailedInstallation(
        baseline: Set<String>,
        loadedImageID: String?,
        ownershipReference: String,
        priorInspection: TransferHelperImageInspection?,
        tagAttempted: Bool,
        on runtime: any ContainerRuntime
    ) async -> [String] {
        var failures: [String] = []
        if tagAttempted {
            do {
                try await runtime.removeImage(id: ownershipReference)
            } catch {
                failures.append("remove attempted operation tag: \(error)")
            }
        }
        do {
            let current = try await imageInventory(on: runtime)
            for imageID in current.subtracting(baseline).sorted() {
                do {
                    try await runtime.removeImage(id: imageID)
                } catch {
                    failures.append("remove newly loaded image \(imageID): \(error)")
                }
            }
        } catch {
            failures.append("inspect helper rollback inventory: \(error)")
        }
        if let loadedImageID,
           priorInspection != nil,
           (priorInspection?.repoTags ?? []).allSatisfy({ $0 == "<none>:<none>" }) {
            do {
                let restoredID = try await loadSignedArchive(on: runtime)
                guard restoredID == loadedImageID else {
                    throw MigrationTransferHelperError.incompatibleEngine(
                        "restored helper image ID changed"
                    )
                }
                try await verifyLoadedImage(restoredID, on: runtime)
            } catch {
                failures.append("restore pre-existing dangling image: \(error)")
            }
        }
        return failures
    }

    func removeInstallation(
        _ installation: MigrationTransferHelperInstallation,
        from runtime: any ContainerRuntime
    ) async throws {
        do {
            try await runtime.removeImage(id: installation.ownershipReference)
            if installation.restoreDanglingImageAfterCleanup {
                // Removing the temporary last tag may garbage-collect an image that was dangling
                // before Dory arrived. Reloading the same content-addressed archive restores that
                // pre-operation engine state without inventing a mutable tag.
                let restoredID = try await loadSignedArchive(on: runtime)
                guard restoredID == installation.imageID else {
                    throw MigrationTransferHelperError.incompatibleEngine(
                        "restored helper image ID changed"
                    )
                }
                try await verifyLoadedImage(restoredID, on: runtime)
            }
        } catch {
            throw MigrationTransferHelperError.engineOperation(
                "remove operation-owned helper tag: \(error)"
            )
        }
    }

    private func loadSignedArchive(
        on runtime: any ContainerRuntime
    ) async throws -> String {
        let bytes = archive
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(bytes)
            continuation.finish()
        }
        let response = try await runtime.loadImageThrowingWithResponse(stream: stream)
        let receipt = try MigrationImageLoadReceipt.parse(response)
        guard MigrationImageTransferExecution.canonicalImageID(receipt.loadedImageID) != nil else {
            throw MigrationTransferHelperError.incompatibleEngine(
                "loaded helper receipt is not an immutable image ID"
            )
        }
        return receipt.loadedImageID
    }

    private func imageInventory(
        on runtime: any ContainerRuntime
    ) async throws -> Set<String> {
        let images = try await runtime.migrationSnapshot().images
        let identifiers = images.compactMap {
            MigrationImageTransferExecution.canonicalImageID($0.imageID)
        }
        guard identifiers.count == images.count,
              Set(identifiers).count == identifiers.count else {
            throw MigrationTransferHelperError.engineOperation(
                "helper image inventory has invalid identities"
            )
        }
        return Set(identifiers)
    }

    private func verifyLoadedImage(
        _ imageID: String,
        on runtime: any ContainerRuntime
    ) async throws {
        guard let inspection = await inspectImage(imageID: imageID, on: runtime) else {
            throw MigrationTransferHelperError.engineOperation("inspect loaded helper image")
        }
        guard inspection.id == imageID,
              inspection.architecture == "arm64",
              inspection.operatingSystem == "linux",
              inspection.config?.entrypoint == ["/dory-transfer-helper"],
              inspection.config?.user == "0",
              inspection.config?.workingDirectory == "/",
              inspection.config?.labels?["dev.dory.component"] == "transfer-helper",
              inspection.config?.labels?["dev.dory.helper.sha256"] == metadata.helperSha256,
              inspection.config?.labels?["dev.dory.manifest.schema"] == "1",
              inspection.rootFS?.layers == [metadata.layerDiffId] else {
            throw MigrationTransferHelperError.incompatibleEngine(
                "loaded image identity, platform, entrypoint, labels, or layer differs from the signed asset"
            )
        }
    }

    private func inspectImage(
        imageID: String,
        on runtime: any ContainerRuntime
    ) async -> TransferHelperImageInspection? {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/images/\(DockerImageOps.pathComponent(imageID))/json",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess,
              let inspection = try? JSONDecoder().decode(
                  TransferHelperImageInspection.self,
                  from: response.body
              ) else {
            return nil
        }
        return inspection
    }
}

private struct TransferHelperImageInspection: Decodable {
    let id: String
    let architecture: String
    let operatingSystem: String
    let repoTags: [String]?
    let config: TransferHelperImageConfiguration?
    let rootFS: TransferHelperRootFilesystem?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case architecture = "Architecture"
        case operatingSystem = "Os"
        case repoTags = "RepoTags"
        case config = "Config"
        case rootFS = "RootFS"
    }
}

private struct TransferHelperImageConfiguration: Decodable {
    let entrypoint: [String]?
    let labels: [String: String]?
    let user: String?
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case entrypoint = "Entrypoint"
        case labels = "Labels"
        case user = "User"
        case workingDirectory = "WorkingDir"
    }
}

private struct TransferHelperRootFilesystem: Decodable {
    let layers: [String]?

    enum CodingKeys: String, CodingKey {
        case layers = "Layers"
    }
}
