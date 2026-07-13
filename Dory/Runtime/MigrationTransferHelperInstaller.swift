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
        guard runtime.supportsImageArchiveTransfer, runtime.supportsRawProxy else {
            throw MigrationTransferHelperError.incompatibleEngine(
                "image archive loading and the raw Docker API are required"
            )
        }
        let imageID = metadata.imageConfigDigest
        let repository = "dory.internal/operation-\(operationID.uuidString.lowercased())"
        let tag = "transfer-helper"
        let ownershipReference = "\(repository):\(tag)"
        let priorInspection = await inspectImage(imageID: imageID, on: runtime)
        do {
            try await runtime.loadImage(tar: archive)
            try await verifyLoadedImage(imageID, on: runtime)
            try await runtime.tagImage(source: imageID, repo: repository, tag: tag)
        } catch {
            let rollbackFailures = await rollbackFailedInstallation(
                imageID: imageID,
                ownershipReference: ownershipReference,
                priorInspection: priorInspection,
                on: runtime
            )
            if rollbackFailures.isEmpty { throw error }
            throw MigrationTransferHelperError.engineOperation(
                "install helper failed (\(error)); rollback failed: "
                    + rollbackFailures.joined(separator: "; ")
            )
        }
        return MigrationTransferHelperInstallation(
            imageID: imageID,
            ownershipReference: ownershipReference,
            restoreDanglingImageAfterCleanup: priorInspection.map {
                $0.id == imageID && ($0.repoTags ?? []).allSatisfy { $0 == "<none>:<none>" }
            } ?? false
        )
    }

    private func rollbackFailedInstallation(
        imageID: String,
        ownershipReference: String,
        priorInspection: TransferHelperImageInspection?,
        on runtime: any ContainerRuntime
    ) async -> [String] {
        var failures: [String] = []
        do {
            try await runtime.removeImage(id: ownershipReference)
        } catch {
            failures.append("remove attempted operation tag: \(error)")
        }
        if priorInspection == nil {
            do {
                try await runtime.removeImage(id: imageID)
            } catch {
                failures.append("remove newly loaded image: \(error)")
            }
        } else if (priorInspection?.repoTags ?? []).allSatisfy({ $0 == "<none>:<none>" }) {
            do {
                try await runtime.loadImage(tar: archive)
                try await verifyLoadedImage(imageID, on: runtime)
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
                try await runtime.loadImage(tar: archive)
                try await verifyLoadedImage(installation.imageID, on: runtime)
            }
        } catch {
            throw MigrationTransferHelperError.engineOperation(
                "remove operation-owned helper tag: \(error)"
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
