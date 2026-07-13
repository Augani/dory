import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportTransactionTests: StrictInventoryTestCase {
    @Test func publishesAndRevalidatesTheExactPlanBeforeStaging() async throws {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try DoryOperationJournalStore(home: home)

        let session = try await MigrationImportTransaction.openStagingSession(
            prepared: prepared,
            environment: environment(fixture, store: store, home: home)
        )

        #expect(session.state.phase == .staging)
        #expect(session.state.status == .running)
        #expect(session.state.revision == 2)
        #expect(try session.lease.readCompletenessPlan() == prepared.operation.completenessPlan)
        #expect(try session.lease.events().map(\.stepID) == [
            "operation.created",
            "preflight.revalidate",
            "staging.begin"
        ])
        #expect(fixture.target.snapshotValue.containers.isEmpty)
        #expect(fixture.target.snapshotValue.images.isEmpty)
        #expect(fixture.target.snapshotValue.volumes.isEmpty)
        #expect(fixture.target.snapshotValue.networks.isEmpty)
    }

    @Test func driftAfterJournalPublicationFailsTerminallyBeforeTargetWrites() async throws {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        fixture.source.snapshotValue.images[0].sizeBytes += 1
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try DoryOperationJournalStore(home: home)

        await #expect(throws: MigrationImportTransactionError.planDrift) {
            _ = try await MigrationImportTransaction.openStagingSession(
                prepared: prepared,
                environment: environment(fixture, store: store, home: home)
            )
        }

        let record = try store.read(prepared.identity.id)
        #expect(record.state.phase == .quiescing)
        #expect(record.state.status == .failed)
        #expect(record.state.result == .failed)
        #expect(record.state.lastEvent.stepID == "preflight.failed")
        #expect(fixture.target.snapshotValue.containers.isEmpty)
        #expect(fixture.target.snapshotValue.images.isEmpty)
        #expect(fixture.target.snapshotValue.volumes.isEmpty)
        #expect(fixture.target.snapshotValue.networks.isEmpty)
    }

    @Test func reducedHostCapacityFailsTerminallyBeforeTargetWrites() async throws {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try DoryOperationJournalStore(home: home)
        let available = prepared.capacity.requiredHostBytes - 1

        await #expect(throws: MigrationImportTransactionError.insufficientHostStorage(
            required: prepared.capacity.requiredHostBytes,
            available: available
        )) {
            _ = try await MigrationImportTransaction.openStagingSession(
                prepared: prepared,
                environment: environment(
                    fixture,
                    store: store,
                    home: home,
                    availableHostBytes: available
                )
            )
        }

        let record = try store.read(prepared.identity.id)
        #expect(record.state.status == .failed)
        #expect(record.state.revision == 2)
    }
}

private extension MigrationImportTransactionTests {
    func environment(
        _ fixture: StrictInventoryFixture,
        store: DoryOperationJournalStore,
        home: String,
        availableHostBytes: Int64 = 100_000_000_000
    ) -> MigrationImportTransactionEnvironment {
        MigrationImportTransactionEnvironment(
            source: fixture.source,
            target: fixture.target,
            journalStore: store,
            currentAvailableHostBytes: availableHostBytes,
            transferHelper: .appleSiliconV1,
            sharedHome: home,
            hostArchitecture: "arm64"
        )
    }

    func temporaryHome() throws -> String {
        let path = NSTemporaryDirectory() + "dory-import-transaction-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }
}
