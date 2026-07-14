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
}
