import DoryOperations
import Foundation

enum MigrationImportCoordinatorError: Error, Sendable, Equatable, CustomStringConvertible {
    case hostStorageUnavailable
    case incompleteTerminalState(DoryOperationPhase, DoryOperationStatus)

    var description: String {
        switch self {
        case .hostStorageUnavailable:
            return "macOS did not report available host storage"
        case let .incompleteTerminalState(phase, status):
            return "migration stopped at \(phase.rawValue)/\(status.rawValue) without exact completion"
        }
    }
}

struct MigrationImportExecutionEnvironment: Sendable {
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    let journalStore: DoryOperationJournalStore
    let currentAvailableHostBytes: Int64
    let transferHelper: MigrationTransferHelperContract?
    let transfers: any MigrationImportAssetTransfers
    let sharedHome: String
    let hostArchitecture: String
}

/// The sole production entry point for competitor imports. Success is returned only after the
/// immutable plan, transaction journal, object readbacks, and completion ledger all agree.
enum MigrationImportCoordinator {
    static func migrate(
        from source: any ContainerRuntime,
        to target: any ContainerRuntime,
        sharedHome: String = NSHomeDirectory(),
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MigrationSummary {
        try Task.checkCancellation()
        progress?("Validating the exact source and Dory inventories…")
        let helper = try MigrationTransferHelperAsset.bundled()
        let availableHostBytes = try hostAvailableBytes(at: sharedHome)
        let prepared = try await MigrationStrictInventoryCollector.collect(
            from: source,
            to: target,
            availableHostBytes: availableHostBytes,
            sharedHome: sharedHome,
            transferHelper: MigrationTransferHelperContract(metadata: helper.metadata)
        )
        let store = try DoryOperationJournalStore(home: sharedHome)
        return try await execute(
            prepared: prepared,
            environment: MigrationImportExecutionEnvironment(
                source: source,
                target: target,
                journalStore: store,
                currentAvailableHostBytes: try hostAvailableBytes(at: sharedHome),
                transferHelper: MigrationTransferHelperContract(metadata: helper.metadata),
                transfers: MigrationImportLiveAssetTransfers(helperAsset: helper),
                sharedHome: sharedHome,
                hostArchitecture: productionHostArchitecture
            ),
            progress: progress
        )
    }

    static func execute(
        prepared: PreparedMigrationExecution,
        environment: MigrationImportExecutionEnvironment,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MigrationSummary {
        try Task.checkCancellation()
        progress?("Revalidating the import plan before writing…")
        let session = try await MigrationImportTransaction.openStagingSession(
            prepared: prepared,
            environment: MigrationImportTransactionEnvironment(
                source: environment.source,
                target: environment.target,
                journalStore: environment.journalStore,
                currentAvailableHostBytes: environment.currentAvailableHostBytes,
                transferHelper: environment.transferHelper,
                sharedHome: environment.sharedHome,
                hostArchitecture: environment.hostArchitecture
            )
        )
        progress?("Copying and verifying the complete dependency closure…")
        let state = try await MigrationImportAssetStager.stage(
            session: session,
            environment: MigrationImportAssetStagingEnvironment(
                source: environment.source,
                target: environment.target,
                transfers: environment.transfers,
                sharedHome: environment.sharedHome
            )
        )
        guard state.phase == .completed, state.status == .completed else {
            throw MigrationImportCoordinatorError.incompleteTerminalState(
                state.phase,
                state.status
            )
        }
        progress?("Import completed with exact readback evidence.")
        return summary(for: prepared)
    }

    static func summary(for prepared: PreparedMigrationExecution) -> MigrationSummary {
        var summary = MigrationSummary()
        for object in prepared.operation.completenessPlan.objects {
            switch object.source.kind {
            case .image:
                summary.imagesImported.append(object.normalizedTargetName)
            case .volume:
                summary.volumesCopied.append(object.normalizedTargetName)
            case .network:
                summary.networksCreated.append(object.normalizedTargetName)
            case .writableLayer:
                break
            case .container:
                summary.containersMigrated.append(object.normalizedTargetName)
                if object.acceptedFinalState == .createdStoppedAwaitingPort {
                    summary.containersAwaitingSourcePorts.append(object.normalizedTargetName)
                }
            }
        }
        summary.imagesImported.sort()
        summary.volumesCopied.sort()
        summary.networksCreated.sort()
        summary.containersMigrated.sort()
        summary.containersAwaitingSourcePorts.sort()
        return summary
    }

    private static func hostAvailableBytes(at path: String) throws -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        guard let bytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value,
              bytes >= 0 else {
            throw MigrationImportCoordinatorError.hostStorageUnavailable
        }
        return bytes
    }

    private nonisolated static var productionHostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported"
        #endif
    }
}
