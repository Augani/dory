import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportContainerPublicationTests: StrictInventoryTestCase {
    @Test func pausedContainerIsPublishedAndReturnedToPausedState() async throws {
        let context = try await makeContext(name: "paused-container") { fixture in
            fixture.source.snapshotValue.containers[0].status = .paused
        }
        defer { context.cleanup() }

        let state = try await MigrationImportAssetStager.stage(
            session: context.session,
            environment: context.environment
        )

        #expect(state.phase == .completed)
        #expect(state.status == .completed)
        #expect(context.fixture.target.snapshotValue.containers[0].status == .paused)
        #expect(context.fixture.target.startedContainers == ["strict-created-1"])
        #expect(context.fixture.target.pausedContainers == ["strict-created-1"])
        #expect(context.fixture.source.snapshotValue.containers[0].status == .paused)
    }

    @Test func containerStartFailureRollsBackThePublishedClosure() async throws {
        let context = try await makeContext(name: "container-start-failure") { fixture in
            configureStatelessSource(fixture, status: .running)
            fixture.target.failContainerStart = true
        }
        defer { context.cleanup() }

        await #expect(throws: StrictMigrationRuntime.TestMutationFailure.injected) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.containers.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(context.fixture.target.removedContainers == ["strict-created-1"])
        let record = try context.session.lease.read()
        #expect(record.state.phase == .publishing)
        #expect(record.state.status == .failed)
    }

    @Test func incompleteContainerRollbackEntersNeedsRecovery() async throws {
        let context = try await makeContext(name: "container-recovery") { fixture in
            configureStatelessSource(fixture, status: .running)
            fixture.target.failContainerStart = true
            fixture.target.failContainerRemoval = true
        }
        defer { context.cleanup() }

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.containers.map(\.name) == ["app"])
        let record = try context.session.lease.read()
        #expect(record.state.phase == .publishing)
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
    }

    @Test func finalImageReadbackDriftRollsBackThePublishedClosure() async throws {
        let context = try await makeContext(name: "final-image-drift") { _ in }
        defer { context.cleanup() }
        context.transfers.mutateFinalImageReadback = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.containers.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.phase == .validating)
        #expect(record.state.status == .failed)
    }

    @Test func finalVolumeReadbackDriftRollsBackThePublishedClosure() async throws {
        let context = try await makeContext(name: "final-volume-drift") { _ in }
        defer { context.cleanup() }
        context.transfers.mutateFinalVolumeReadback = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.containers.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.phase == .validating)
        #expect(record.state.status == .failed)
    }

    @Test func unownedTargetDriftIsPreservedBeforeAnyWrite() async throws {
        let context = try await makeContext(name: "unowned-target-drift") { _ in }
        defer { context.cleanup() }
        let unrelatedID = "sha256:" + String(repeating: "f", count: 64)
        context.fixture.target.snapshotValue.images.append(DockerImage(
            repository: "unrelated",
            tag: "latest",
            imageID: unrelatedID,
            size: "1 B",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1
        ))

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.map(\.imageID) == [unrelatedID])
        #expect(context.fixture.target.snapshotValue.containers.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.phase == .staging)
        #expect(record.state.status == .failed)
    }

    @Test func finalHelperCleanupFailureRequiresRecoveryAfterObjectRollback() async throws {
        let context = try await makeContext(name: "final-helper-cleanup") { _ in }
        defer { context.cleanup() }
        context.transfers.failFinalVolumeCleanup = true

        await #expect(throws: MigrationVolumeTransferError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.containers.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.phase == .validating)
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
    }
}

@MainActor
private extension MigrationImportContainerPublicationTests {
    struct Context {
        let fixture: StrictInventoryFixture
        let session: MigrationImportStagingSession
        let environment: MigrationImportAssetStagingEnvironment
        let transfers: AssetStagingTransfers
        let home: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func makeContext(
        name: String,
        configure: (StrictInventoryFixture) -> Void
    ) async throws -> Context {
        let fixture = makeFixture()
        configure(fixture)
        let prepared = try await collect(fixture)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-container-publish-\(name)-\(UUID().uuidString)")
        let store = try DoryOperationJournalStore(home: home.path)
        let session = try await MigrationImportTransaction.openStagingSession(
            prepared: prepared,
            environment: MigrationImportTransactionEnvironment(
                source: fixture.source,
                target: fixture.target,
                journalStore: store,
                currentAvailableHostBytes: prepared.capacity.availableHostBytes,
                transferHelper: .appleSiliconV1,
                sharedHome: "/Users/test",
                hostArchitecture: "arm64"
            )
        )
        let transfers = AssetStagingTransfers()
        return Context(
            fixture: fixture,
            session: session,
            environment: MigrationImportAssetStagingEnvironment(
                source: fixture.source,
                target: fixture.target,
                transfers: transfers,
                sharedHome: "/Users/test"
            ),
            transfers: transfers,
            home: home
        )
    }

    func configureStatelessSource(
        _ fixture: StrictInventoryFixture,
        status: RunState
    ) {
        fixture.source.snapshotValue.containers[0].status = status
        fixture.source.snapshotValue.volumes = []
        fixture.source.writableSizes["container-id"] = 0
        fixture.source.containerInspections["container-id"] = containerInspection(mount: nil)
        fixture.source.systemDiskUsage = dockerUsage(
            images: 12_000_000,
            containers: 0
        )
    }
}
