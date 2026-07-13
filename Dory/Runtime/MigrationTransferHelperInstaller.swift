import Foundation

struct MigrationTransferHelperInstallation: Sendable, Equatable {
    let imageID: String
    let ownershipReference: String
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
        try await runtime.loadImage(tar: archive)
        let imageID = metadata.imageConfigDigest
        try await verifyLoadedImage(imageID, on: runtime)
        let repository = "dory.internal/operation-\(operationID.uuidString.lowercased())"
        let tag = "transfer-helper"
        do {
            try await runtime.tagImage(source: imageID, repo: repository, tag: tag)
        } catch {
            throw MigrationTransferHelperError.engineOperation("tag exact helper image: \(error)")
        }
        return MigrationTransferHelperInstallation(
            imageID: imageID,
            ownershipReference: "\(repository):\(tag)"
        )
    }

    private func verifyLoadedImage(
        _ imageID: String,
        on runtime: any ContainerRuntime
    ) async throws {
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
}

private struct TransferHelperImageInspection: Decodable {
    let id: String
    let architecture: String
    let operatingSystem: String
    let config: TransferHelperImageConfiguration?
    let rootFS: TransferHelperRootFilesystem?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case architecture = "Architecture"
        case operatingSystem = "Os"
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
