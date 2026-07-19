import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportCoordinatorTests: StrictInventoryTestCase {
    @Test func productionCoordinatorReturnsSuccessOnlyAfterExactCompletion() async throws {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-import-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)

        let summary = try await MigrationImportCoordinator.execute(
            prepared: prepared,
            environment: MigrationImportExecutionEnvironment(
                source: fixture.source,
                target: fixture.target,
                journalStore: store,
                currentAvailableHostBytes: prepared.capacity.availableHostBytes,
                transferHelper: .appleSiliconV1,
                transfers: AssetStagingTransfers(),
                sharedHome: "/Users/test",
                hostArchitecture: "arm64"
            )
        )

        #expect(summary.imagesImported == ["ghcr.io/example/app:v1"])
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.networksCreated == ["backend"])
        #expect(summary.containersMigrated == ["app"])
        #expect(summary.failures.isEmpty)
        #expect(try store.read(prepared.identity.id).state.status == .completed)
    }

    @Test func summaryCountsThePlannedClosureWithoutCountingWritableLayersTwice() async throws {
        let prepared = try await collect(makeFixture())

        let summary = MigrationImportCoordinator.summary(for: prepared)

        #expect(summary.total == 4)
        #expect(summary.imagesImported.count == 1)
        #expect(summary.volumesCopied.count == 1)
        #expect(summary.networksCreated.count == 1)
        #expect(summary.containersMigrated.count == 1)
    }

    @Test func partialImageImportCompletesWithExactOmittedInventoryEvidence() async throws {
        let fixture = makeFixture()
        fixture.source.containerInspections["container-id"] = containerInspection(mount: [
            "Type": "bind",
            "Source": "/Users/test/private-source",
            "Target": "/workspace/private-source",
            "ReadOnly": true,
        ])
        fixture.source.networkInspections["backend"] = networkInspection(driver: "overlay")
        let imageID = MigrationOperationPlanBuilder.stableImageSourceID(
            fixture.source.snapshotValue.images[0]
        )
        let prepared = try await collect(
            fixture,
            transferHelper: nil,
            userSelection: [DoryOperationObjectKey(kind: .image, sourceID: imageID)]
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-partial-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let summary = try await MigrationImportCoordinator.execute(
            prepared: prepared,
            environment: MigrationImportExecutionEnvironment(
                source: fixture.source,
                target: fixture.target,
                journalStore: try DoryOperationJournalStore(home: home.path),
                currentAvailableHostBytes: prepared.capacity.availableHostBytes,
                transferHelper: nil,
                transfers: AssetStagingTransfers(),
                sharedHome: "/Users/test",
                hostArchitecture: "arm64"
            )
        )

        #expect(summary.imagesImported == ["ghcr.io/example/app:v1"])
        #expect(summary.volumesCopied.isEmpty)
        #expect(summary.networksCreated.isEmpty)
        #expect(summary.containersMigrated.isEmpty)
        #expect(summary.completeness?.verified.count == 1)
        #expect(summary.completeness?.omitted.count == 4)
        #expect(summary.completeness?.omittedInventoryDigest.isEmpty == false)
    }

    @Test func partialImportRejectsOmittedSourceDriftBeforeCompletion() async throws {
        let fixture = makeFixture()
        let imageID = MigrationOperationPlanBuilder.stableImageSourceID(
            fixture.source.snapshotValue.images[0]
        )
        let prepared = try await collect(
            fixture,
            transferHelper: nil,
            userSelection: [DoryOperationObjectKey(kind: .image, sourceID: imageID)]
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-partial-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let transfers = AssetStagingTransfers()
        transfers.mutateOmittedSourceVolumeAfterImageTransfer = true

        await #expect(throws: MigrationImportAssetStagingError.invalidSession(
            "selected or deliberately omitted source objects changed during migration"
        )) {
            _ = try await MigrationImportCoordinator.execute(
                prepared: prepared,
                environment: MigrationImportExecutionEnvironment(
                    source: fixture.source,
                    target: fixture.target,
                    journalStore: try DoryOperationJournalStore(home: home.path),
                    currentAvailableHostBytes: prepared.capacity.availableHostBytes,
                    transferHelper: nil,
                    transfers: transfers,
                    sharedHome: "/Users/test",
                    hostArchitecture: "arm64"
                )
            )
        }
        #expect(fixture.target.snapshotValue.images.isEmpty)
    }

    @Test func exactPreflightOverridesLegacyHeuristicsAndSurfacesExactFailures() async throws {
        let prepared = try await collect(makeFixture())
        var inventory = MigrationInventory(
            sourceName: "legacy",
            images: 0,
            containers: 0,
            volumes: 1,
            volumeNames: [],
            volumeHelperImageAvailable: false
        )

        inventory.acceptStrictValidation(prepared)

        #expect(!inventory.isImportBlocked)
        #expect(inventory.sourceName == "OrbStack")
        #expect(inventory.images == 1)
        #expect(inventory.containers == 1)
        #expect(inventory.volumeNames == ["db-data"])
        #expect(inventory.volumeHelperImageAvailable)

        inventory.rejectStrictValidation(MigrationStrictInventoryError.unsafe("source changed"))
        #expect(inventory.isImportBlocked)
        #expect(inventory.attentionItems == [
            "Exact import validation blocked before writes: "
                + "migration cannot start safely: source changed"
        ])
    }
}
