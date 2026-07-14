import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationVolumeReadbackTests {
    @Test func rescansBothSidesWithoutCopyingOrRepairing() async throws {
        let fixture = try VolumeReadbackFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.sourceManifest
        target.targetManifest = fixture.targetManifest

        let receipt = try await MigrationVolumeTransfer(helperAsset: fixture.asset).verify(
            fixture.request,
            from: source,
            to: target
        )

        #expect(receipt.sourceManifest == fixture.sourceManifest)
        #expect(receipt.targetManifest == fixture.targetManifest)
        #expect(source.createdSpecs.map(\.command) == [
            ["scan", "--root", "/data", "--output", "/manifest.json"],
            ["scan", "--root", "/data", "--output", "/manifest.json"]
        ])
        #expect(target.createdSpecs.map(\.command) == [[
            "scan", "--root", "/data", "--output", "/manifest.json"
        ]])
        #expect(target.receivedDataArchive.isEmpty)
        #expect(target.receivedManifestArchive.isEmpty)
        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
        #expect(source.removedImages.count == 1)
        #expect(target.removedImages.count == 1)
    }

    @Test func targetMismatchFailsClosedAndCleansHelpers() async throws {
        let fixture = try VolumeReadbackFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.sourceManifest
        target.targetManifest = fixture.changedTargetManifest

        await #expect(throws: MigrationVolumeTransferError.targetMismatch) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).verify(
                fixture.request,
                from: source,
                to: target
            )
        }

        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
        #expect(source.removedImages.count == 1)
        #expect(target.removedImages.count == 1)
    }
}

@MainActor
private struct VolumeReadbackFixture {
    let asset: MigrationTransferHelperAsset
    let request: MigrationVolumeTransferRequest
    let sourceManifest: Data
    let targetManifest: Data
    let changedTargetManifest: Data

    init() throws {
        let transfer = try TransferFixture()
        asset = transfer.asset
        request = transfer.request
        sourceManifest = transfer.sourceManifest
        targetManifest = transfer.targetManifest
        changedTargetManifest = transfer.changedTargetManifest
    }
}
