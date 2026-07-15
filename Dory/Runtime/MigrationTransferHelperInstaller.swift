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
        var loadedEntryAfterLoad: MigrationImageTargetInventory.Entry?
        var priorInspection: TransferHelperImageInspection?
        var tagAttempted = false
        do {
            let imageID = try await loadSignedArchive(on: runtime)
            loadedImageID = imageID
            loadedEntryAfterLoad = try await imageInventory(on: runtime).entries.first {
                $0.id == imageID
            }
            guard loadedEntryAfterLoad != nil else {
                throw MigrationTransferHelperError.engineOperation(
                    "loaded helper image is absent from the target inventory"
                )
            }
            if baseline.entries.contains(where: { $0.id == imageID }) {
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
                loadedEntryAfterLoad: loadedEntryAfterLoad,
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
        baseline: MigrationImageTargetInventory,
        loadedImageID: String?,
        loadedEntryAfterLoad: MigrationImageTargetInventory.Entry?,
        ownershipReference: String,
        priorInspection: TransferHelperImageInspection?,
        tagAttempted: Bool,
        on runtime: any ContainerRuntime
    ) async -> [String] {
        var failures: [String] = []
        if tagAttempted {
            do {
                try await removeOperationReference(
                    ownershipReference,
                    expectedImageID: loadedImageID,
                    from: runtime
                )
            } catch {
                failures.append("remove attempted operation tag: \(error)")
            }
        }
        do {
            let current = try await imageInventory(on: runtime)
            let candidate: MigrationImageTargetInventory.Entry?
            if let loadedImageID,
               !baseline.entries.contains(where: { $0.id == loadedImageID }) {
                guard let expected = loadedEntryAfterLoad else {
                    throw MigrationTransferHelperError.engineOperation(
                        "loaded helper ownership evidence is missing"
                    )
                }
                if let observed = current.entries.first(where: { $0.id == loadedImageID }) {
                    guard observed == expected else {
                        throw MigrationTransferHelperError.engineOperation(
                            "loaded helper ownership changed before rollback"
                        )
                    }
                    candidate = observed
                } else {
                    candidate = nil
                }
            } else if loadedImageID == nil {
                candidate = try await inferUnreceiptedHelperEntry(
                    baseline: baseline,
                    current: current,
                    on: runtime
                )
            } else {
                candidate = nil
            }
            if let candidate {
                guard candidate.references.isEmpty else {
                    throw MigrationTransferHelperError.engineOperation(
                        "loaded helper image is externally referenced"
                    )
                }
                try await runtime.removeImageForRollback(id: candidate.id)
                let after = try await imageInventory(on: runtime)
                guard !after.entries.contains(where: { $0.id == candidate.id }) else {
                    throw MigrationTransferHelperError.engineOperation(
                        "loaded helper image survived rollback"
                    )
                }
            }
        } catch {
            failures.append("remove operation-owned helper image: \(error)")
        }
        if let loadedImageID,
           priorInspection != nil,
           (priorInspection?.repoTags ?? []).allSatisfy({ $0 == "<none>:<none>" }) {
            do {
                let current = try await imageInventory(on: runtime)
                if !current.entries.contains(where: { $0.id == loadedImageID }) {
                    let restoredID = try await loadSignedArchive(on: runtime)
                    guard restoredID == loadedImageID else {
                        throw MigrationTransferHelperError.incompatibleEngine(
                            "restored helper image ID changed"
                        )
                    }
                    try await verifyLoadedImage(restoredID, on: runtime)
                }
            } catch {
                failures.append("restore pre-existing dangling image: \(error)")
            }
        }
        return failures
    }

    private func inferUnreceiptedHelperEntry(
        baseline: MigrationImageTargetInventory,
        current: MigrationImageTargetInventory,
        on runtime: any ContainerRuntime
    ) async throws -> MigrationImageTargetInventory.Entry? {
        let baselineIDs = Set(baseline.entries.map(\.id))
        let added = current.entries.filter { !baselineIDs.contains($0.id) }
        var verified: [MigrationImageTargetInventory.Entry] = []
        for entry in added {
            if (try? await verifyLoadedImage(entry.id, on: runtime)) != nil {
                verified.append(entry)
            }
        }
        guard verified.count <= 1 else {
            throw MigrationTransferHelperError.engineOperation(
                "multiple unreceipted images match the signed helper"
            )
        }
        guard let candidate = verified.first else { return nil }
        guard candidate.references.isEmpty else {
            throw MigrationTransferHelperError.engineOperation(
                "unreceipted helper image gained an external reference"
            )
        }
        return candidate
    }

    func removeInstallation(
        _ installation: MigrationTransferHelperInstallation,
        from runtime: any ContainerRuntime
    ) async throws {
        do {
            try await removeOperationReference(
                installation.ownershipReference,
                expectedImageID: installation.imageID,
                from: runtime
            )
            if installation.restoreDanglingImageAfterCleanup {
                // Removing the temporary last tag may garbage-collect an image that was dangling
                // before Dory arrived. Reloading the same content-addressed archive restores that
                // pre-operation engine state without inventing a mutable tag.
                let current = try await imageInventory(on: runtime)
                if !current.entries.contains(where: { $0.id == installation.imageID }) {
                    let restoredID = try await loadSignedArchive(on: runtime)
                    guard restoredID == installation.imageID else {
                        throw MigrationTransferHelperError.incompatibleEngine(
                            "restored helper image ID changed"
                        )
                    }
                    try await verifyLoadedImage(restoredID, on: runtime)
                }
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
    ) async throws -> MigrationImageTargetInventory {
        let images = try await runtime.migrationSnapshot().images
        do {
            return try MigrationImageTransferExecution.targetInventory(images: images)
        } catch {
            throw MigrationTransferHelperError.engineOperation("helper image inventory: \(error)")
        }
    }

    private func removeOperationReference(
        _ reference: String,
        expectedImageID: String?,
        from runtime: any ContainerRuntime
    ) async throws {
        let canonicalReference = MigrationOperationPlanBuilder.canonicalImageReference(reference)
        let before = try await imageInventory(on: runtime)
        let matches = before.entries.filter { $0.references.contains(canonicalReference) }
        guard matches.count <= 1 else {
            throw MigrationTransferHelperError.engineOperation(
                "operation helper tag resolves to multiple images"
            )
        }
        guard let match = matches.first else { return }
        guard let expectedImageID, match.id == expectedImageID else {
            throw MigrationTransferHelperError.engineOperation(
                "operation helper tag ownership changed"
            )
        }
        try await runtime.removeImageForRollback(id: canonicalReference)
        let after = try await imageInventory(on: runtime)
        guard !after.entries.contains(where: {
            $0.references.contains(canonicalReference)
        }) else {
            throw MigrationTransferHelperError.engineOperation(
                "operation helper tag survived rollback"
            )
        }
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
