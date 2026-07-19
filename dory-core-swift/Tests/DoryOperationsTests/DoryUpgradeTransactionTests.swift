@testable import DoryOperations
import Foundation
import XCTest

final class DoryUpgradeTransactionTests: XCTestCase {
    func testPreflightRejectsUnsignedCandidateAndUnsafeSchemaPath() throws {
        let fixture = try Fixture("preflight-reject")
        defer { fixture.cleanup() }
        var candidate = fixture.candidate
        candidate.enclosureSignatureDeclared = false

        XCTAssertThrowsError(try fixture.store.begin(fixture.input(candidate: candidate))) { error in
            XCTAssertTrue("\(error)".contains("signed HTTPS"))
        }

        candidate.enclosureSignatureDeclared = true
        candidate.schema.candidateMinimumReadableSchema = 2
        XCTAssertThrowsError(try fixture.store.begin(fixture.input(candidate: candidate))) { error in
            XCTAssertTrue("\(error)".contains("data schema"))
        }
    }

    func testTransactionRequiresLastGoodAppConfigDataAndRuntimeMarker() throws {
        let fixture = try Fixture("complete-snapshot")
        defer { fixture.cleanup() }
        var record = try fixture.store.begin(fixture.input())
        record = try fixture.store.advance(record.id, to: .snapshotting)
        XCTAssertThrowsError(try fixture.store.validateReadyToInstall(record.id))

        let appBackup = fixture.store.appBackupPath(record.id)
        try FileManager.default.createDirectory(atPath: appBackup, withIntermediateDirectories: true)
        _ = try fixture.store.attachAppSnapshot(record.id, snapshot: DoryUpgradeAppSnapshot(
            bundlePath: "/Applications/Dory.app",
            backupPath: appBackup,
            version: "0.3.2",
            build: "43",
            executableSHA256: String(repeating: "a", count: 64),
            teamIdentifier: "TEAM123",
            designatedRequirement: "identifier com.pythonxi.Dory"
        ))
        let config = fixture.home + "/.dory/config.json"
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: config).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try Data("{\"engine\":\"before\"}".utf8).write(to: URL(fileURLWithPath: config))
        _ = try fixture.store.captureConfiguration(record.id)
        let archive = fixture.store.dataBackupPath(record.id)
        _ = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        _ = try fixture.store.attachDataSnapshot(record.id, archivePath: archive)
        _ = try fixture.store.setRuntimeMarker(
            record.id,
            volume: "dory-upgrade-\(record.id.uuidString.lowercased())",
            ports: [8080, 8080, 8443],
            kubernetesExpected: true
        )

        try fixture.store.validateReadyToInstall(record.id)
        record = try fixture.store.advance(record.id, to: .readyToInstall)
        record = try fixture.store.markArchiveValidated(record.id)
        record = try fixture.store.advance(record.id, to: .installing)
        XCTAssertTrue(record.candidate.archiveSignatureValidated)
        XCTAssertEqual(record.baselinePorts, [8080, 8443])
        XCTAssertEqual(record.dataSnapshot?.verification.sourceDriveID, try fixture.drive.readManifest().id)
    }

    func testRollbackRestoresConfigButNeverReplacesDurableData() throws {
        let fixture = try Fixture("rollback")
        defer { fixture.cleanup() }
        var record = try fixture.store.begin(fixture.input())
        record = try fixture.store.advance(record.id, to: .snapshotting)
        let config = fixture.home + "/.dory/config.json"
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: config).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: URL(fileURLWithPath: config))
        _ = try fixture.store.captureConfiguration(record.id)
        try Data("after".utf8).write(to: URL(fileURLWithPath: config))
        let durableSentinel = fixture.drive.root + "/durable-sentinel"
        try Data("new-schema-data".utf8).write(to: URL(fileURLWithPath: durableSentinel))

        try fixture.store.restoreConfigurationAndComponents(record.id)

        XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOfFile: durableSentinel, encoding: .utf8), "new-schema-data")
    }

    func testUnsafeSchemaRollbackExportsRecoveryInsteadOfRestoring() throws {
        let fixture = try Fixture("unsafe-schema")
        defer { fixture.cleanup() }
        var candidate = fixture.candidate
        candidate.schema.targetDataSchema = 2
        candidate.schema.candidateMaximumReadableSchema = 2
        candidate.schema.priorMaximumReadableSchema = 1
        let record = try fixture.store.begin(fixture.input(candidate: candidate))

        XCTAssertThrowsError(try fixture.store.restoreConfigurationAndComponents(record.id)) { error in
            XCTAssertTrue("\(error)".contains("cannot be reopened safely"))
        }
        let recovery = try fixture.store.exportRecovery(record.id, reason: "smoke failed after schema migration")
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: recovery + "/recovery.json"))
        ) as? [String: Any]
        XCTAssertEqual(payload?["durableDataWasRolledBack"] as? Bool, false)
        XCTAssertEqual(payload?["dataSchema"] as? Int, 2)
    }

    func testSymlinkedJournalCannotBeLoadedOrReplaced() throws {
        let fixture = try Fixture("journal-symlink")
        defer { fixture.cleanup() }
        let record = try fixture.store.begin(fixture.input())
        let path = fixture.store.transactionDirectory(record.id) + "/transaction.json"
        let outside = fixture.home + "/outside"
        try Data("outside".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(Darwin.symlink(outside, path), 0)

        XCTAssertThrowsError(try fixture.store.load(record.id))
        XCTAssertThrowsError(try fixture.store.latestNonterminal())
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "outside")
    }

    func testLatestIncludesTerminalEvidenceButActiveLookupDoesNot() throws {
        let fixture = try Fixture("latest-terminal")
        defer { fixture.cleanup() }
        let record = try fixture.store.begin(fixture.input())
        _ = try fixture.store.advance(record.id, to: .failed, error: "fixture failure")

        XCTAssertNil(try fixture.store.latestNonterminal())
        XCTAssertEqual(try fixture.store.latest()?.id, record.id)
        XCTAssertEqual(try fixture.store.records().map(\.id), [record.id])
    }
}

private final class Fixture {
    let home: String
    let drive: DoryDataDrive
    let store: DoryUpgradeTransactionStore

    init(_ name: String) throws {
        home = "/tmp/dory-upgrade-\(name)-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        drive = try DoryDataDrive(home: home)
        try drive.prepare()
        store = try DoryUpgradeTransactionStore(home: home)
    }

    var candidate: DoryUpgradeCandidate {
        DoryUpgradeCandidate(
            version: "0.4.0",
            build: "44",
            sourceURL: "https://updates.example.test/Dory-0.4.0.zip",
            downloadBytes: 1024,
            installationType: "application",
            enclosureSignatureDeclared: true,
            componentCatalogSchema: DoryComponentCatalog.schemaVersion,
            schema: DoryUpgradeSchemaContract(
                currentDataSchema: DoryDataDrive.schemaVersion,
                targetDataSchema: DoryDataDrive.schemaVersion,
                candidateMinimumReadableSchema: DoryDataDrive.schemaVersion,
                candidateMaximumReadableSchema: DoryDataDrive.schemaVersion,
                priorMinimumReadableSchema: DoryDataDrive.schemaVersion,
                priorMaximumReadableSchema: DoryDataDrive.schemaVersion
            )
        )
    }

    func input(candidate: DoryUpgradeCandidate? = nil) -> DoryUpgradePreflightInput {
        DoryUpgradePreflightInput(
            candidate: candidate ?? self.candidate,
            priorVersion: "0.3.2",
            priorBuild: "43",
            drive: drive,
            hostAvailableBytes: 8 * 1_024 * 1_024 * 1_024,
            dataDestinationAvailableBytes: 8 * 1_024 * 1_024 * 1_024,
            estimatedDataSnapshotBytes: 1_024
        )
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}
