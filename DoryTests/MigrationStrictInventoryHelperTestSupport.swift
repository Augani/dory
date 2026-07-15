import Foundation
@testable import Dory

@MainActor
extension StrictMigrationRuntime {
    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        guard let metadata = transferHelperMetadata else {
            throw RuntimeFeatureError.unsupported("test transfer helper is not configured")
        }
        var archive = Data()
        for try await chunk in stream { archive.append(chunk) }
        loadedTransferHelperArchives.append(archive)
        if !snapshotValue.images.contains(where: { $0.imageID == metadata.imageConfigDigest }) {
            snapshotValue.images.append(DockerImage(
                repository: "<none>",
                tag: "<none>",
                imageID: metadata.imageConfigDigest,
                size: "1 KB",
                created: "now",
                usedByCount: 0,
                sizeBytes: 1_024,
                labels: [
                    "dev.dory.component": "transfer-helper",
                    "dev.dory.helper.sha256": metadata.helperSha256,
                    "dev.dory.manifest.schema": "1"
                ]
            ))
        }
        return Data((
            #"{"stream":"Loaded image ID: \#(metadata.imageConfigDigest)\n"}"# + "\r\n"
        ).utf8)
    }
}
