import Darwin
import Foundation

private struct DoryDataOperationAuthorityFingerprint: Codable {
    let path: String
    let identity: String
    let format: String
}

/// Durable orchestration for full-drive backup and restore.
///
/// The archive layer owns byte transfer and atomic publication. This layer binds those effects to
/// the shared operation journal, resumes the exact same source/target pair after interruption, and
/// mirrors the authoritative journal into every available Dory drive.
public enum DoryDataDriveTransaction {
    @discardableResult
    public static func backup(
        from drive: DoryDataDrive,
        to requestedDestination: String,
        fileManager: FileManager = .default
    ) throws -> DoryDataDriveArchiveVerification {
        try drive.validateManifest(fileManager: fileManager)
        let destination = try canonicalBackupPath(requestedDestination)
        let manifest = try drive.readManifest(fileManager: fileManager)
        let desiredPlan = try backupPlan(
            drive: drive,
            manifest: manifest,
            destination: destination
        )
        let store = try DoryOperationJournalStore(home: drive.home)
        let acquired = try acquireOrBegin(desiredPlan, store: store)
        if !acquired.resumed, pathEntryExists(destination) {
            try fail(acquired.lease, needsRecovery: false)
            throw DoryDataDriveArchiveError.invalidDestination(destination)
        }

        let partial = DoryDataDriveArchive.operationPartialPath(
            destination: destination,
            operationID: acquired.lease.operationID
        )
        do {
            let verification: DoryDataDriveArchiveVerification
            if pathEntryExists(destination) {
                let existing = try DoryDataDriveArchive.verifyBackup(at: destination)
                let record = try acquired.lease.read()
                guard record.state.phase.index >= DoryOperationPhase.publishing.index,
                      existing.backupOperationID == acquired.lease.operationID else {
                    throw DoryDataDriveArchiveError.invalidDestination(destination)
                }
                try advance(acquired.lease, to: .validating, operation: "backup")
                verification = existing
            } else {
                verification = try DoryDataDriveArchive.createBackupPayload(
                    from: drive,
                    to: destination,
                    operationID: acquired.lease.operationID,
                    phase: { try advance(acquired.lease, to: $0, operation: "backup") },
                    fileManager: fileManager
                )
            }
            try complete(acquired.lease, mirrorTo: drive, operation: "backup")
            return verification
        } catch {
            try? fail(
                acquired.lease,
                needsRecovery: pathEntryExists(destination) || pathEntryExists(partial)
            )
            throw error
        }
    }

    @discardableResult
    public static func restore(
        at requestedArchive: String,
        to drive: DoryDataDrive,
        fileManager: FileManager = .default
    ) throws -> DoryDataDriveArchiveVerification {
        let archive = try canonicalBackupPath(requestedArchive)
        let source = try DoryDataDriveArchive.verifyBackup(at: archive)
        let desiredPlan = try restorePlan(archive: archive, verification: source, drive: drive)
        let store = try DoryOperationJournalStore(home: drive.home)
        let acquired = try acquireOrBegin(desiredPlan, store: store)
        if !acquired.resumed, try drive.inspect(fileManager: fileManager) != .absent {
            try fail(acquired.lease, needsRecovery: false)
            throw DoryDataDriveArchiveError.invalidDestination(drive.root)
        }

        let partial = DoryDataDriveArchive.operationPartialPath(
            destination: drive.root,
            operationID: acquired.lease.operationID
        )
        let summaryRelativePath = "operations/"
            + acquired.lease.operationID.uuidString.lowercased() + ".json"
        do {
            if try drive.inspect(fileManager: fileManager) == .ready {
                let record = try acquired.lease.read()
                let marker = DoryDataDriveArchive.restoreOwnerMatches(
                    drive: drive,
                    operationID: acquired.lease.operationID,
                    archiveManifestDigest: source.archiveManifestDigest
                )
                let summary = try summaryMatches(acquired.lease, drive: drive)
                guard record.state.phase.index >= DoryOperationPhase.publishing.index,
                      marker || summary else {
                    throw DoryDataDriveArchiveError.invalidDestination(drive.root)
                }
                try advance(acquired.lease, to: .validating, operation: "restore")
            } else {
                _ = try DoryDataDriveArchive.restoreBackupPayload(
                    at: archive,
                    to: drive,
                    operationID: acquired.lease.operationID,
                    phase: { try advance(acquired.lease, to: $0, operation: "restore") },
                    fileManager: fileManager
                )
            }

            // Persist ownership before removing the publication marker. A crash at either side of
            // that removal can therefore prove the target belongs to this exact journal.
            try acquired.lease.mirrorSummary(to: drive)
            let verification = try DoryDataDriveArchive.finalizePublishedRestore(
                archive: archive,
                drive: drive,
                operationID: acquired.lease.operationID,
                summaryRelativePath: summaryRelativePath,
                hasDurableSummary: try summaryMatches(acquired.lease, drive: drive),
                fileManager: fileManager
            )
            try complete(acquired.lease, mirrorTo: drive, operation: "restore")
            return verification
        } catch {
            try? fail(
                acquired.lease,
                needsRecovery: pathEntryExists(drive.root) || pathEntryExists(partial)
            )
            throw error
        }
    }

    static func backupPlan(
        drive: DoryDataDrive,
        manifest: DoryDataDriveManifest,
        destination: String
    ) throws -> DoryOperationPlan {
        let sourceFingerprint = try fingerprint(
            path: drive.root,
            identity: manifest.id.uuidString.lowercased() + "|"
                + (manifest.volume?.uuid.uuidString.lowercased() ?? "internal") + "|"
                + manifest.createdAt,
            format: "dorydrive-v\(manifest.schemaVersion)"
        )
        let targetFingerprint = try fingerprint(
            path: destination,
            identity: "new",
            format: "dorybackup-v1"
        )
        return DoryOperationPlan(
            kind: .driveBackup,
            source: DoryOperationAuthority(
                kind: .dataDrive,
                id: manifest.id.uuidString.lowercased(),
                fingerprint: sourceFingerprint
            ),
            target: DoryOperationAuthority(
                kind: .backupArchive,
                id: destination,
                fingerprint: targetFingerprint
            ),
            selectionDigest: digest("full-drive\0\(sourceFingerprint)"),
            dependencyClosureDigest: digest("all-drive-entries\0sparse\0metadata"),
            successCriteriaDigest: digest("dorybackup-v1\0readback\0atomic-completion")
        )
    }

    static func restorePlan(
        archive: String,
        verification: DoryDataDriveArchiveVerification,
        drive: DoryDataDrive
    ) throws -> DoryOperationPlan {
        let targetFingerprint = try fingerprint(
            path: drive.root,
            identity: verification.sourceDriveID.uuidString.lowercased() + "|"
                + (try targetVolumeIdentity(for: drive.root)),
            format: "dorydrive-v\(DoryDataDrive.schemaVersion)"
        )
        return DoryOperationPlan(
            kind: .driveRestore,
            source: DoryOperationAuthority(
                kind: .backupArchive,
                id: archive,
                fingerprint: verification.archiveManifestDigest
            ),
            target: DoryOperationAuthority(
                kind: .dataDrive,
                id: verification.sourceDriveID.uuidString.lowercased(),
                fingerprint: targetFingerprint
            ),
            selectionDigest: digest("full-archive\0\(verification.archiveManifestDigest)"),
            dependencyClosureDigest: digest("all-archive-entries\0sparse\0metadata"),
            successCriteriaDigest: digest("dorydrive-v1\0readback\0exclusive-publication")
        )
    }

    private static func acquireOrBegin(
        _ desired: DoryOperationPlan,
        store: DoryOperationJournalStore
    ) throws -> (lease: DoryOperationLease, resumed: Bool) {
        let unfinished = try store.list().filter {
            $0.state.status != .completed && $0.state.status != .failed
        }
        if let matching = unfinished.first(where: { plansMatch($0.plan, desired) }) {
            return (try store.acquire(matching.plan.id), true)
        }
        return (try store.begin(desired), false)
    }

    private static func plansMatch(_ lhs: DoryOperationPlan, _ rhs: DoryOperationPlan) -> Bool {
        lhs.kind == rhs.kind
            && lhs.source == rhs.source
            && lhs.target == rhs.target
            && lhs.selectionDigest == rhs.selectionDigest
            && lhs.dependencyClosureDigest == rhs.dependencyClosureDigest
            && lhs.successCriteriaDigest == rhs.successCriteriaDigest
    }

    private static func advance(
        _ lease: DoryOperationLease,
        to target: DoryOperationPhase,
        operation: String
    ) throws {
        var record = try lease.read()
        if record.state.status != .running {
            record = DoryOperationRecord(
                plan: record.plan,
                state: try lease.transition(
                    to: record.state.phase,
                    status: .running,
                    expectedRevision: record.state.revision,
                    stepID: "drive.\(operation).resumed"
                )
            )
        }
        while record.state.phase.index < target.index {
            let next = DoryOperationPhase.allCases[record.state.phase.index + 1]
            record = DoryOperationRecord(
                plan: record.plan,
                state: try lease.transition(
                    to: next,
                    status: .running,
                    expectedRevision: record.state.revision,
                    stepID: "drive.\(operation).\(next.rawValue)"
                )
            )
        }
    }

    private static func complete(
        _ lease: DoryOperationLease,
        mirrorTo drive: DoryDataDrive,
        operation: String
    ) throws {
        try advance(lease, to: .validating, operation: operation)
        var record = try lease.read()
        if record.state.phase != .completed {
            let state = try lease.transition(
                to: .completed,
                status: .completed,
                expectedRevision: record.state.revision,
                stepID: "drive.\(operation).completed"
            )
            record = DoryOperationRecord(plan: record.plan, state: state)
        }
        try lease.mirrorSummary(to: drive)
        _ = record
    }

    private static func fail(
        _ lease: DoryOperationLease,
        needsRecovery: Bool
    ) throws {
        let record = try lease.read()
        guard record.state.status != .completed, record.state.status != .failed else { return }
        _ = try lease.transition(
            to: record.state.phase,
            status: needsRecovery ? .needsRecovery : .failed,
            expectedRevision: record.state.revision,
            stepID: needsRecovery ? "drive.operation.needs-recovery" : "drive.operation.failed",
            recoveryAction: needsRecovery ? "resume-same-operation" : nil
        )
    }

    private static func summaryMatches(
        _ lease: DoryOperationLease,
        drive: DoryDataDrive
    ) throws -> Bool {
        let record = try lease.read()
        let path = drive.operationsDirectory + "/"
            + lease.operationID.uuidString.lowercased() + ".json"
        guard let data = try? DoryOperationJournalStore.secureRead(
            path,
            maximumBytes: 1_024 * 1_024
        ), let summary = try? JSONDecoder().decode(DoryOperationSummary.self, from: data) else {
            return false
        }
        return summary.operationID == lease.operationID
            && summary.kind == record.plan.kind
            && summary.planDigest == record.state.planDigest
            && summary.revision == record.state.revision
            && summary.phase == record.state.phase
            && summary.status == record.state.status
    }

    private static func fingerprint(path: String, identity: String, format: String) throws -> String {
        let value = DoryDataOperationAuthorityFingerprint(
            path: path,
            identity: identity,
            format: format
        )
        return DoryOperationJournalStore.digest(
            try DoryOperationJournalStore.encoded(value, pretty: false)
        )
    }

    private static func digest(_ value: String) -> String {
        DoryOperationJournalStore.digest(Data(value.utf8))
    }

    private static func canonicalBackupPath(_ requested: String) throws -> String {
        guard requested.hasPrefix("/"), requested.hasSuffix(".dorybackup") else {
            throw DoryDataDriveArchiveError.invalidDestination(requested)
        }
        do {
            return try DoryDataDrive.canonicalPath(requested)
        } catch {
            throw DoryDataDriveArchiveError.invalidDestination(requested)
        }
    }

    private static func targetVolumeIdentity(for path: String) throws -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return "internal" }
        let volumeRoot = "/Volumes/\(components[2])"
        do {
            let values = try URL(fileURLWithPath: volumeRoot).resourceValues(forKeys: [
                .volumeUUIDStringKey,
                .volumeIsLocalKey,
                .volumeIsReadOnlyKey
            ])
            guard values.volumeIsLocal == true,
                  values.volumeIsReadOnly == false,
                  let uuid = values.volumeUUIDString,
                  UUID(uuidString: uuid) != nil else {
                throw DoryDataDriveArchiveError.invalidDestination(path)
            }
            return uuid.lowercased()
        } catch let error as DoryDataDriveArchiveError {
            throw error
        } catch {
            throw DoryDataDriveArchiveError.invalidDestination(path)
        }
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var status = stat()
        return path.withCString { lstat($0, &status) } == 0
    }
}
