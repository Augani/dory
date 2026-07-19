import CryptoKit
import Darwin
import Foundation

public enum DoryUpgradeError: Error, Sendable, Equatable, CustomStringConvertible {
    case activeTransaction(UUID)
    case invalidCandidate(String)
    case insufficientSpace(location: String, required: UInt64, available: UInt64)
    case incompatibleSchema(current: Int, target: Int, readable: ClosedRange<Int>)
    case unsafeRollback(current: Int, target: Int, rollbackReadable: ClosedRange<Int>)
    case invalidState(String)
    case unsafePath(String)
    case invalidSnapshot(String)
    case filesystem(String)

    public var description: String {
        switch self {
        case .activeTransaction(let id):
            "upgrade transaction \(id.uuidString.lowercased()) still needs completion or recovery"
        case .invalidCandidate(let detail): "invalid update candidate: \(detail)"
        case .insufficientSpace(let location, let required, let available):
            "not enough free space at \(location) (need \(required) bytes, have \(available))"
        case .incompatibleSchema(let current, let target, let readable):
            "data schema \(current) cannot upgrade to \(target); candidate reads \(readable.lowerBound)...\(readable.upperBound)"
        case .unsafeRollback(let current, let target, let rollbackReadable):
            "data schema \(target) cannot be reopened safely by the prior app (prior app reads \(rollbackReadable.lowerBound)...\(rollbackReadable.upperBound), current \(current))"
        case .invalidState(let detail): "invalid upgrade transaction state: \(detail)"
        case .unsafePath(let path): "unsafe upgrade path: \(path)"
        case .invalidSnapshot(let detail): "invalid upgrade snapshot: \(detail)"
        case .filesystem(let detail): detail
        }
    }
}

public enum DoryUpgradeState: String, Codable, Sendable, Equatable {
    case preflight
    case snapshotting
    case readyToInstall
    case installing
    case smokeTesting
    case succeeded
    case rollingBack
    case rolledBack
    case recoveryRequired
    case failed

    public var terminal: Bool {
        self == .succeeded || self == .rolledBack || self == .recoveryRequired || self == .failed
    }
}

public struct DoryUpgradeSchemaContract: Codable, Sendable, Equatable {
    public var currentDataSchema: Int
    public var targetDataSchema: Int
    public var candidateMinimumReadableSchema: Int
    public var candidateMaximumReadableSchema: Int
    public var priorMinimumReadableSchema: Int
    public var priorMaximumReadableSchema: Int

    public init(
        currentDataSchema: Int,
        targetDataSchema: Int,
        candidateMinimumReadableSchema: Int,
        candidateMaximumReadableSchema: Int,
        priorMinimumReadableSchema: Int,
        priorMaximumReadableSchema: Int
    ) {
        self.currentDataSchema = currentDataSchema
        self.targetDataSchema = targetDataSchema
        self.candidateMinimumReadableSchema = candidateMinimumReadableSchema
        self.candidateMaximumReadableSchema = candidateMaximumReadableSchema
        self.priorMinimumReadableSchema = priorMinimumReadableSchema
        self.priorMaximumReadableSchema = priorMaximumReadableSchema
    }

    public var candidateReadableRange: ClosedRange<Int> {
        candidateMinimumReadableSchema...max(candidateMinimumReadableSchema, candidateMaximumReadableSchema)
    }

    public var priorReadableRange: ClosedRange<Int> {
        priorMinimumReadableSchema...max(priorMinimumReadableSchema, priorMaximumReadableSchema)
    }

    public var rollbackSafe: Bool { priorReadableRange.contains(targetDataSchema) }

    public func validate() throws {
        guard currentDataSchema > 0, targetDataSchema > 0,
              candidateMinimumReadableSchema > 0,
              candidateMaximumReadableSchema >= candidateMinimumReadableSchema,
              priorMinimumReadableSchema > 0,
              priorMaximumReadableSchema >= priorMinimumReadableSchema,
              candidateReadableRange.contains(currentDataSchema),
              candidateReadableRange.contains(targetDataSchema) else {
            throw DoryUpgradeError.incompatibleSchema(
                current: currentDataSchema,
                target: targetDataSchema,
                readable: candidateReadableRange
            )
        }
    }
}

public struct DoryUpgradeCandidate: Codable, Sendable, Equatable {
    public var version: String
    public var build: String
    public var sourceURL: String
    public var downloadBytes: UInt64
    public var installationType: String
    public var enclosureSignatureDeclared: Bool
    public var archiveSignatureValidated: Bool
    public var componentCatalogSchema: Int
    public var schema: DoryUpgradeSchemaContract

    public init(
        version: String,
        build: String,
        sourceURL: String,
        downloadBytes: UInt64,
        installationType: String,
        enclosureSignatureDeclared: Bool,
        archiveSignatureValidated: Bool = false,
        componentCatalogSchema: Int,
        schema: DoryUpgradeSchemaContract
    ) {
        self.version = version
        self.build = build
        self.sourceURL = sourceURL
        self.downloadBytes = downloadBytes
        self.installationType = installationType
        self.enclosureSignatureDeclared = enclosureSignatureDeclared
        self.archiveSignatureValidated = archiveSignatureValidated
        self.componentCatalogSchema = componentCatalogSchema
        self.schema = schema
    }

    public func validate() throws {
        guard !version.isEmpty, !build.isEmpty, build.allSatisfy(\.isNumber), downloadBytes > 0,
              installationType == "application", componentCatalogSchema == DoryComponentCatalog.schemaVersion,
              enclosureSignatureDeclared,
              let url = URL(string: sourceURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw DoryUpgradeError.invalidCandidate(
                "requires a signed HTTPS application enclosure, positive byte count, numeric build, and supported component catalog schema"
            )
        }
        try schema.validate()
    }
}

public struct DoryUpgradeAppSnapshot: Codable, Sendable, Equatable {
    public var bundlePath: String
    public var backupPath: String
    public var version: String
    public var build: String
    public var executableSHA256: String
    public var teamIdentifier: String
    public var designatedRequirement: String

    public init(
        bundlePath: String,
        backupPath: String,
        version: String,
        build: String,
        executableSHA256: String,
        teamIdentifier: String,
        designatedRequirement: String
    ) {
        self.bundlePath = bundlePath
        self.backupPath = backupPath
        self.version = version
        self.build = build
        self.executableSHA256 = executableSHA256.lowercased()
        self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement
    }
}

public struct DoryUpgradeConfigurationSnapshot: Codable, Sendable, Equatable {
    public var originalPath: String
    public var snapshotPath: String?
    public var existed: Bool
    public var sha256: String?
    public var bytes: UInt64
}

public struct DoryUpgradeDataSnapshot: Codable, Sendable, Equatable {
    public var archivePath: String
    public var verification: DoryDataDriveArchiveVerification
    public var verifiedAt: String

    public init(
        archivePath: String,
        verification: DoryDataDriveArchiveVerification,
        verifiedAt: Date = Date()
    ) {
        self.archivePath = archivePath
        self.verification = verification
        self.verifiedAt = DoryUpgradeTransactionStore.timestamp(verifiedAt)
    }
}

public struct DoryUpgradePreflightCheck: Codable, Sendable, Equatable {
    public var id: String
    public var passed: Bool
    public var detail: String
}

public struct DoryUpgradeSmokeCheck: Codable, Sendable, Equatable {
    public var id: String
    public var required: Bool
    public var passed: Bool
    public var detail: String

    public init(id: String, required: Bool = true, passed: Bool, detail: String) {
        self.id = id
        self.required = required
        self.passed = passed
        self.detail = detail
    }
}

public struct DoryUpgradeTransactionRecord: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.upgrade.transaction"
    public static let schemaVersion = 1

    public var kind: String
    public var schemaVersion: Int
    public var id: UUID
    public var state: DoryUpgradeState
    public var createdAt: String
    public var updatedAt: String
    public var priorVersion: String
    public var priorBuild: String
    public var candidate: DoryUpgradeCandidate
    public var driveID: UUID
    public var drivePath: String
    public var preflight: [DoryUpgradePreflightCheck]
    public var componentSelection: DoryComponentSelectionSnapshot
    public var appSnapshot: DoryUpgradeAppSnapshot?
    public var configurationSnapshots: [DoryUpgradeConfigurationSnapshot]
    public var dataSnapshot: DoryUpgradeDataSnapshot?
    public var markerVolume: String?
    public var baselinePorts: [UInt16]
    public var kubernetesExpected: Bool
    public var smokeChecks: [DoryUpgradeSmokeCheck]
    public var error: String?
    public var recoveryDirectory: String?

    public var rollbackSafe: Bool { candidate.schema.rollbackSafe }
}

public struct DoryUpgradePreflightInput: Sendable, Equatable {
    public var candidate: DoryUpgradeCandidate
    public var priorVersion: String
    public var priorBuild: String
    public var drive: DoryDataDrive
    public var hostAvailableBytes: UInt64
    public var dataDestinationAvailableBytes: UInt64
    public var estimatedDataSnapshotBytes: UInt64
    public var baselinePorts: [UInt16]
    public var kubernetesExpected: Bool

    public init(
        candidate: DoryUpgradeCandidate,
        priorVersion: String,
        priorBuild: String,
        drive: DoryDataDrive,
        hostAvailableBytes: UInt64,
        dataDestinationAvailableBytes: UInt64,
        estimatedDataSnapshotBytes: UInt64,
        baselinePorts: [UInt16] = [],
        kubernetesExpected: Bool = false
    ) {
        self.candidate = candidate
        self.priorVersion = priorVersion
        self.priorBuild = priorBuild
        self.drive = drive
        self.hostAvailableBytes = hostAvailableBytes
        self.dataDestinationAvailableBytes = dataDestinationAvailableBytes
        self.estimatedDataSnapshotBytes = estimatedDataSnapshotBytes
        self.baselinePorts = baselinePorts
        self.kubernetesExpected = kubernetesExpected
    }
}

/// Durable, owner-controlled journal for the Sparkle/app/component/data-schema transaction. It
/// intentionally never restores data automatically; the verified archive is recovery authority,
/// while app/config/component rollback is permitted only when the prior schema range can reopen the
/// candidate's target schema.
public struct DoryUpgradeTransactionStore: Sendable {
    public static let hostSafetyBytes: UInt64 = 512 * 1_024 * 1_024
    public static let dataSafetyBytes: UInt64 = 256 * 1_024 * 1_024

    public let home: String
    public let root: String

    public init(home: String = DoryDataDrive.processHome()) throws {
        let standardized = try DoryDataDrive.canonicalPath(home)
        guard standardized.hasPrefix("/"), standardized != "/" else {
            throw DoryUpgradeError.unsafePath(home)
        }
        self.home = standardized
        root = standardized + "/.dory/upgrades"
    }

    public func begin(_ input: DoryUpgradePreflightInput) throws -> DoryUpgradeTransactionRecord {
        try input.candidate.validate()
        try input.drive.validateManifest()
        let manifest = try input.drive.readManifest()
        guard manifest.schemaVersion == input.candidate.schema.currentDataSchema else {
            throw DoryUpgradeError.incompatibleSchema(
                current: manifest.schemaVersion,
                target: input.candidate.schema.targetDataSchema,
                readable: input.candidate.schema.candidateReadableRange
            )
        }
        if let active = try latestNonterminal() { throw DoryUpgradeError.activeTransaction(active.id) }
        let componentSelection = try DoryComponentStore(drive: input.drive).captureSelection()
        let (doubleDownload, downloadOverflow) = input.candidate.downloadBytes.multipliedReportingOverflow(by: 2)
        let (hostRequired, hostOverflow) = doubleDownload.addingReportingOverflow(Self.hostSafetyBytes)
        guard !downloadOverflow, !hostOverflow else {
            throw DoryUpgradeError.invalidCandidate("declared enclosure size overflows capacity accounting")
        }
        guard input.hostAvailableBytes >= hostRequired else {
            throw DoryUpgradeError.insufficientSpace(
                location: root,
                required: hostRequired,
                available: input.hostAvailableBytes
            )
        }
        let (dataRequired, dataOverflow) = input.estimatedDataSnapshotBytes.addingReportingOverflow(Self.dataSafetyBytes)
        guard !dataOverflow else {
            throw DoryUpgradeError.invalidCandidate("estimated data snapshot size overflows capacity accounting")
        }
        let (combinedRequired, combinedOverflow) = hostRequired.addingReportingOverflow(dataRequired)
        guard !combinedOverflow else {
            throw DoryUpgradeError.invalidCandidate("combined update and snapshot size overflows capacity accounting")
        }
        guard input.hostAvailableBytes >= combinedRequired else {
            throw DoryUpgradeError.insufficientSpace(
                location: root,
                required: combinedRequired,
                available: input.hostAvailableBytes
            )
        }
        guard input.dataDestinationAvailableBytes >= dataRequired else {
            throw DoryUpgradeError.insufficientSpace(
                location: root,
                required: dataRequired,
                available: input.dataDestinationAvailableBytes
            )
        }

        let id = UUID()
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(transactionDirectory(id))
        let now = Self.timestamp(Date())
        let record = DoryUpgradeTransactionRecord(
            kind: DoryUpgradeTransactionRecord.kind,
            schemaVersion: DoryUpgradeTransactionRecord.schemaVersion,
            id: id,
            state: .preflight,
            createdAt: now,
            updatedAt: now,
            priorVersion: input.priorVersion,
            priorBuild: input.priorBuild,
            candidate: input.candidate,
            driveID: manifest.id,
            drivePath: input.drive.root,
            preflight: [
                .init(id: "candidate.signature", passed: true, detail: "Sparkle feed was accepted and a 64-byte Ed25519 enclosure signature is declared; archive validation is required before replacement"),
                .init(id: "candidate.enclosure", passed: true, detail: "HTTPS application enclosure declares \(input.candidate.downloadBytes) bytes"),
                .init(id: "host.free-space", passed: true, detail: "\(input.hostAvailableBytes) bytes available; \(combinedRequired) required for archive, app and data snapshot"),
                .init(id: "data.free-space", passed: true, detail: "\(input.dataDestinationAvailableBytes) bytes available; \(dataRequired) required"),
                .init(id: "data.drive", passed: true, detail: "drive \(manifest.id.uuidString.lowercased()) schema \(manifest.schemaVersion) is ready"),
                .init(id: "data.schema-path", passed: true, detail: "\(input.candidate.schema.currentDataSchema) -> \(input.candidate.schema.targetDataSchema); rollbackSafe=\(input.candidate.schema.rollbackSafe)"),
                .init(id: "components", passed: true, detail: "\(componentSelection.components.count) active optional component(s) fingerprint-verified"),
            ],
            componentSelection: componentSelection,
            appSnapshot: nil,
            configurationSnapshots: [],
            dataSnapshot: nil,
            markerVolume: nil,
            baselinePorts: Array(Set(input.baselinePorts)).sorted(),
            kubernetesExpected: input.kubernetesExpected,
            smokeChecks: [],
            error: nil,
            recoveryDirectory: nil
        )
        try write(record)
        return record
    }

    public func load(_ id: UUID) throws -> DoryUpgradeTransactionRecord {
        let data = try readPrivateFile(recordPath(id), maximumBytes: 4 * 1_024 * 1_024)
        let decoder = JSONDecoder()
        guard let value = try? decoder.decode(DoryUpgradeTransactionRecord.self, from: data),
              value.kind == DoryUpgradeTransactionRecord.kind,
              value.schemaVersion == DoryUpgradeTransactionRecord.schemaVersion,
              value.id == id else {
            throw DoryUpgradeError.invalidState(recordPath(id))
        }
        return value
    }

    public func latestNonterminal() throws -> DoryUpgradeTransactionRecord? {
        try records().first { !$0.state.terminal }
    }

    public func latest() throws -> DoryUpgradeTransactionRecord? {
        try records().first
    }

    public func records() throws -> [DoryUpgradeTransactionRecord] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        try validatePrivateDirectory(root)
        let records = try FileManager.default.contentsOfDirectory(atPath: root).compactMap { name -> DoryUpgradeTransactionRecord? in
            guard let id = UUID(uuidString: name) else { return nil }
            return try load(id)
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func advance(
        _ id: UUID,
        to state: DoryUpgradeState,
        error: String? = nil
    ) throws -> DoryUpgradeTransactionRecord {
        try update(id) { record in
            guard Self.transitionAllowed(from: record.state, to: state) else {
                throw DoryUpgradeError.invalidState("cannot move \(record.state.rawValue) -> \(state.rawValue)")
            }
            record.state = state
            record.error = error
        }
    }

    @discardableResult
    public func attachAppSnapshot(
        _ id: UUID,
        snapshot: DoryUpgradeAppSnapshot
    ) throws -> DoryUpgradeTransactionRecord {
        guard snapshot.bundlePath.hasPrefix("/"), snapshot.backupPath.hasPrefix(transactionDirectory(id) + "/"),
              snapshot.executableSHA256.count == 64, snapshot.executableSHA256.allSatisfy(\.isHexDigit),
              !snapshot.teamIdentifier.isEmpty, !snapshot.designatedRequirement.isEmpty else {
            throw DoryUpgradeError.invalidSnapshot("last-good application metadata")
        }
        return try update(id) { $0.appSnapshot = snapshot }
    }

    @discardableResult
    public func captureConfiguration(_ id: UUID) throws -> DoryUpgradeTransactionRecord {
        let directory = transactionDirectory(id) + "/config"
        try ensurePrivateDirectory(directory)
        var snapshots: [DoryUpgradeConfigurationSnapshot] = []
        for (index, original) in configurationAllowlist.enumerated() {
            let snapshot = directory + "/\(index).bin"
            if pathExists(original) {
                let data = try readPrivateFile(original, maximumBytes: 32 * 1_024 * 1_024)
                try writePrivateFile(data, to: snapshot)
                snapshots.append(.init(
                    originalPath: original,
                    snapshotPath: snapshot,
                    existed: true,
                    sha256: Self.digest(data),
                    bytes: UInt64(data.count)
                ))
            } else {
                snapshots.append(.init(originalPath: original, snapshotPath: nil, existed: false, sha256: nil, bytes: 0))
            }
        }
        return try update(id) { $0.configurationSnapshots = snapshots }
    }

    @discardableResult
    public func attachDataSnapshot(
        _ id: UUID,
        archivePath: String
    ) throws -> DoryUpgradeTransactionRecord {
        let record = try load(id)
        let verification = try DoryDataDriveArchive.verifyBackup(at: archivePath)
        guard verification.sourceDriveID == record.driveID else {
            throw DoryUpgradeError.invalidSnapshot("backup belongs to another data drive")
        }
        let snapshot = DoryUpgradeDataSnapshot(archivePath: archivePath, verification: verification)
        return try update(id) { $0.dataSnapshot = snapshot }
    }

    @discardableResult
    public func setRuntimeMarker(
        _ id: UUID,
        volume: String,
        ports: [UInt16],
        kubernetesExpected: Bool
    ) throws -> DoryUpgradeTransactionRecord {
        guard !volume.isEmpty, volume.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            throw DoryUpgradeError.invalidSnapshot("upgrade marker volume name")
        }
        return try update(id) {
            $0.markerVolume = volume
            $0.baselinePorts = Array(Set(ports)).sorted()
            $0.kubernetesExpected = kubernetesExpected
        }
    }

    @discardableResult
    public func markArchiveValidated(_ id: UUID) throws -> DoryUpgradeTransactionRecord {
        try update(id) { $0.candidate.archiveSignatureValidated = true }
    }

    @discardableResult
    public func recordSmoke(
        _ id: UUID,
        checks: [DoryUpgradeSmokeCheck]
    ) throws -> DoryUpgradeTransactionRecord {
        guard !checks.isEmpty, Set(checks.map(\.id)).count == checks.count else {
            throw DoryUpgradeError.invalidSnapshot("post-update smoke evidence")
        }
        return try update(id) { $0.smokeChecks = checks }
    }

    public func validateReadyToInstall(_ id: UUID) throws {
        let record = try load(id)
        guard record.appSnapshot != nil,
              !record.configurationSnapshots.isEmpty,
              record.dataSnapshot != nil,
              record.markerVolume != nil else {
            throw DoryUpgradeError.invalidState("last-good app, config, data and volume-marker snapshots are all required")
        }
    }

    public func restoreConfigurationAndComponents(_ id: UUID) throws {
        let record = try load(id)
        guard record.rollbackSafe else {
            throw DoryUpgradeError.unsafeRollback(
                current: record.candidate.schema.currentDataSchema,
                target: record.candidate.schema.targetDataSchema,
                rollbackReadable: record.candidate.schema.priorReadableRange
            )
        }
        let drive = try DoryDataDrive(home: home, overrideRoot: record.drivePath)
        try drive.validateManifest()
        try DoryComponentStore(drive: drive).restoreSelection(record.componentSelection)
        for snapshot in record.configurationSnapshots {
            guard configurationAllowlist.contains(snapshot.originalPath) else {
                throw DoryUpgradeError.unsafePath(snapshot.originalPath)
            }
            if snapshot.existed {
                guard let source = snapshot.snapshotPath,
                      source.hasPrefix(transactionDirectory(id) + "/config/"),
                      let expected = snapshot.sha256 else {
                    throw DoryUpgradeError.invalidSnapshot(snapshot.originalPath)
                }
                let data = try readPrivateFile(source, maximumBytes: 32 * 1_024 * 1_024)
                guard Self.digest(data) == expected else {
                    throw DoryUpgradeError.invalidSnapshot("config digest changed: \(source)")
                }
                try writePrivateFile(data, to: snapshot.originalPath)
            } else if pathExists(snapshot.originalPath) {
                _ = try readPrivateFile(snapshot.originalPath, maximumBytes: 32 * 1_024 * 1_024)
                guard unlink(snapshot.originalPath) == 0 else {
                    throw DoryUpgradeError.filesystem("remove post-update config \(snapshot.originalPath): errno \(errno)")
                }
            }
        }
    }

    @discardableResult
    public func exportRecovery(_ id: UUID, reason: String) throws -> String {
        let recovery = transactionDirectory(id) + "/recovery"
        try ensurePrivateDirectory(recovery)
        let record = try load(id)
        let payload: [String: Any] = [
            "schema": "dev.dory.upgrade.recovery",
            "version": 1,
            "transactionID": id.uuidString.lowercased(),
            "reason": reason,
            "durableDataWasRolledBack": false,
            "dataSchema": record.candidate.schema.targetDataSchema,
            "priorReadableDataSchema": [
                record.candidate.schema.priorMinimumReadableSchema,
                record.candidate.schema.priorMaximumReadableSchema,
            ],
            "verifiedBackup": record.dataSnapshot?.archivePath ?? NSNull(),
            "verifiedBackupManifestSHA256": record.dataSnapshot?.verification.archiveManifestDigest ?? NSNull(),
            "exportCommand": "dory data verify \(record.dataSnapshot?.archivePath ?? "<missing-backup>")",
            "restoreCommand": "dory data restore \(record.dataSnapshot?.archivePath ?? "<missing-backup>") <new-target.dorydrive>",
            "currentDrive": record.drivePath,
            "failedCandidate": "\(record.candidate.version) (\(record.candidate.build))",
            "lastGoodApp": record.appSnapshot?.backupPath ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writePrivateFile(data + Data("\n".utf8), to: recovery + "/recovery.json")
        _ = try update(id) { $0.recoveryDirectory = recovery }
        return recovery
    }

    public func transactionDirectory(_ id: UUID) -> String {
        root + "/" + id.uuidString.lowercased()
    }

    public func dataBackupPath(_ id: UUID) -> String {
        transactionDirectory(id) + "/last-good-data.dorybackup"
    }

    public func appBackupPath(_ id: UUID) -> String {
        transactionDirectory(id) + "/last-good-Dory.app"
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var configurationAllowlist: [String] {
        [
            home + "/.dory/config.json",
            home + "/.dory/corporate-connectivity.json",
            home + "/.dory/corporate-connectivity-state.json",
            home + "/Library/Application Support/Dory/data-drive-selection.json",
            home + "/Library/Preferences/com.pythonxi.Dory.plist",
        ]
    }

    private func recordPath(_ id: UUID) -> String { transactionDirectory(id) + "/transaction.json" }

    private func update(
        _ id: UUID,
        mutation: (inout DoryUpgradeTransactionRecord) throws -> Void
    ) throws -> DoryUpgradeTransactionRecord {
        var record = try load(id)
        try mutation(&record)
        record.updatedAt = Self.timestamp(Date())
        try write(record)
        return record
    }

    private func write(_ record: DoryUpgradeTransactionRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writePrivateFile(try encoder.encode(record) + Data("\n".utf8), to: recordPath(record.id))
    }

    private static func transitionAllowed(from: DoryUpgradeState, to: DoryUpgradeState) -> Bool {
        if from == to { return true }
        return switch (from, to) {
        case (.preflight, .snapshotting), (.snapshotting, .readyToInstall),
             (.readyToInstall, .installing), (.installing, .smokeTesting),
             (.smokeTesting, .succeeded), (.smokeTesting, .rollingBack),
             (.rollingBack, .rolledBack), (.rollingBack, .recoveryRequired),
             (.preflight, .failed), (.snapshotting, .failed), (.readyToInstall, .failed),
             (.installing, .failed), (.smokeTesting, .failed):
            true
        default:
            false
        }
    }

    private func ensurePrivateDirectory(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw DoryUpgradeError.filesystem("create upgrade directory \(path): \(error)")
            }
        }
        try validatePrivateDirectory(path)
        guard chmod(path, 0o700) == 0 else {
            throw DoryUpgradeError.filesystem("secure upgrade directory \(path): errno \(errno)")
        }
    }

    private func validatePrivateDirectory(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0 else {
            throw DoryUpgradeError.unsafePath(path)
        }
    }

    private func readPrivateFile(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DoryUpgradeError.unsafePath(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1,
              status.st_size >= 0, status.st_size <= maximumBytes else {
            try? handle.close()
            throw DoryUpgradeError.unsafePath(path)
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        guard data.count <= maximumBytes else { throw DoryUpgradeError.unsafePath(path) }
        return data
    }

    private func writePrivateFile(_ data: Data, to path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try ensurePrivateDirectory(parent)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid(), existing.st_nlink == 1 else {
                throw DoryUpgradeError.unsafePath(path)
            }
        } else if errno != ENOENT {
            throw DoryUpgradeError.filesystem("inspect upgrade record \(path): errno \(errno)")
        }
        let temporary = parent + "/.\(URL(fileURLWithPath: path).lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DoryUpgradeError.filesystem("create upgrade record: errno \(errno)") }
        defer { close(descriptor); unlink(temporary) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0,
              rename(temporary, path) == 0 else {
            throw DoryUpgradeError.filesystem("publish upgrade record \(path): errno \(errno)")
        }
        let directory = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    private func pathExists(_ path: String) -> Bool {
        var status = stat()
        if lstat(path, &status) == 0 { return true }
        return false
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
