import Foundation

public enum DoryOperationStagingDisposition: String, Codable, Sendable, Equatable {
    case createdOperationOwned
    case recoveredOperationOwned
    case reusedPreexisting
}

/// Durable proof that one planned object was written and read back successfully, but has not yet
/// been published to users. Final evidence is a separate record created after publication.
public struct DoryOperationStagedObject: Codable, Sendable, Equatable {
    public let source: DoryOperationObjectKey
    public let verifiedTarget: DoryOperationTargetIdentity
    public let verificationManifestDigest: String
    public let disposition: DoryOperationStagingDisposition

    public init(
        source: DoryOperationObjectKey,
        verifiedTarget: DoryOperationTargetIdentity,
        verificationManifestDigest: String,
        disposition: DoryOperationStagingDisposition
    ) {
        self.source = source
        self.verifiedTarget = verifiedTarget
        self.verificationManifestDigest = verificationManifestDigest
        self.disposition = disposition
    }

    var isValid: Bool {
        verifiedTarget.isValid
            && DoryOperationJournalStore.isDigest(verificationManifestDigest)
            && (disposition != .reusedPreexisting || source.kind == .image)
    }
}

/// Durable, content-addressed verification data for one semantic operation. Manifests retain the
/// exact read-back bytes used by an executor, while evidence files retain the verified target
/// identity for every selected object. A semantic journal cannot transition to completed until a
/// mechanically complete ledger has been published from these files.
extension DoryOperationLease {
    public static let maximumManifestBytes = 64 * 1_024 * 1_024

    @discardableResult
    public func publishManifest(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= Self.maximumManifestBytes else {
            throw DoryOperationJournalError.invalidRecord("operation verification manifest size")
        }
        try ensureEvidenceIsWritable()
        let digest = DoryOperationJournalStore.digest(data)
        let path = try manifestsDirectory() + "/objects/" + digest
        if DoryOperationJournalStore.pathEntryExists(path) {
            guard try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: Self.maximumManifestBytes
            ) == data else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return digest
        }
        try DoryOperationJournalStore.publish(data, to: path)
        return digest
    }

    public func readManifest(digest: String) throws -> Data {
        guard DoryOperationJournalStore.isDigest(digest) else {
            throw DoryOperationJournalError.invalidRecord(digest)
        }
        let path = try manifestsDirectory() + "/objects/" + digest
        let data = try DoryOperationJournalStore.secureRead(
            path,
            maximumBytes: Self.maximumManifestBytes
        )
        guard !data.isEmpty, DoryOperationJournalStore.digest(data) == digest else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        return data
    }

    public func publishStagedObject(_ staged: DoryOperationStagedObject) throws {
        try ensureEvidenceIsWritable()
        let record = try read()
        let plan = try readCompletenessPlan()
        guard record.state.phase == .staging || record.state.phase == .verifying,
              staged.isValid,
              plan.selectedObjectKeys.contains(staged.source) else {
            throw DoryOperationJournalError.invalidRecord("unplanned staged operation object")
        }
        _ = try readManifest(digest: staged.verificationManifestDigest)
        let data = try DoryOperationJournalStore.encoded(staged, pretty: false)
        let path = try stagedDirectory() + "/" + Self.evidenceFileName(for: staged.source)
        if DoryOperationJournalStore.pathEntryExists(path) {
            guard try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            ) == data else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return
        }
        try DoryOperationJournalStore.publish(data, to: path)
    }

    public func readStagedObjects() throws -> [DoryOperationStagedObject] {
        let directory = try stagedDirectory()
        let entries = try evidenceEntries(in: directory)
        let selected = Set(try readCompletenessPlan().selectedObjectKeys)
        var staged: [DoryOperationStagedObject] = []
        for entry in entries {
            let path = directory + "/" + entry
            let data = try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            )
            guard let item = try? JSONDecoder().decode(DoryOperationStagedObject.self, from: data),
                  let canonical = try? DoryOperationJournalStore.encoded(item, pretty: false),
                  item.isValid,
                  selected.contains(item.source),
                  entry == Self.evidenceFileName(for: item.source),
                  data == canonical else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            _ = try readManifest(digest: item.verificationManifestDigest)
            staged.append(item)
        }
        return staged.sorted { $0.source < $1.source }
    }

    public func publishObjectEvidence(_ evidence: DoryOperationObjectEvidence) throws {
        try ensureEvidenceIsWritable()
        let record = try read()
        let plan = try readCompletenessPlan()
        let staged = try readStagedObjects().first { $0.source == evidence.source }
        let completionPath = try manifestsDirectory() + "/completion-ledger.json"
        guard record.state.phase == .publishing || record.state.phase == .validating,
              evidence.isValid,
              plan.selectedObjectKeys.contains(evidence.source),
              staged?.verifiedTarget == evidence.verifiedTarget,
              staged?.verificationManifestDigest == evidence.verificationManifestDigest,
              !DoryOperationJournalStore.pathEntryExists(completionPath) else {
            throw DoryOperationJournalError.invalidRecord("unplanned operation evidence")
        }
        _ = try readManifest(digest: evidence.verificationManifestDigest)
        let data = try DoryOperationJournalStore.encoded(evidence, pretty: false)
        let path = try evidenceDirectory() + "/" + Self.evidenceFileName(for: evidence.source)
        if DoryOperationJournalStore.pathEntryExists(path) {
            guard try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            ) == data else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return
        }
        try DoryOperationJournalStore.publish(data, to: path)
    }

    public func readObjectEvidence() throws -> [DoryOperationObjectEvidence] {
        let directory = try evidenceDirectory()
        let entries = try evidenceEntries(in: directory)
        let staged = Dictionary(uniqueKeysWithValues: try readStagedObjects().map {
            ($0.source, $0)
        })
        var evidence: [DoryOperationObjectEvidence] = []
        for entry in entries {
            let path = directory + "/" + entry
            let data = try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            )
            guard let item = try? JSONDecoder().decode(DoryOperationObjectEvidence.self, from: data),
                  let canonical = try? DoryOperationJournalStore.encoded(item, pretty: false),
                  item.isValid,
                  staged[item.source]?.verifiedTarget == item.verifiedTarget,
                  staged[item.source]?.verificationManifestDigest == item.verificationManifestDigest,
                  entry == Self.evidenceFileName(for: item.source),
                  data == canonical else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            _ = try readManifest(digest: item.verificationManifestDigest)
            evidence.append(item)
        }
        return evidence.sorted { $0.source < $1.source }
    }

    public func publishCompletionLedger(_ ledger: DoryOperationCompletionLedger) throws {
        try ensureEvidenceIsWritable()
        guard try read().state.phase == .validating else {
            throw DoryOperationJournalError.invalidRecord("completion ledger phase")
        }
        let plan = try readCompletenessPlan()
        let durableEvidence = try readObjectEvidence()
        let proposedEvidence = ledger.evidence.sorted { $0.source < $1.source }
        let evaluation = try ledger.evaluate(against: plan)
        guard evaluation.isComplete, proposedEvidence == durableEvidence else {
            throw DoryOperationJournalError.invalidRecord("incomplete operation ledger")
        }
        let data = try DoryOperationJournalStore.encoded(ledger, pretty: true)
        let path = try manifestsDirectory() + "/completion-ledger.json"
        if DoryOperationJournalStore.pathEntryExists(path) {
            guard try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            ) == data else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return
        }
        try DoryOperationJournalStore.publish(data, to: path)
    }

    public func readCompletionLedger() throws -> DoryOperationCompletionLedger {
        let path = try manifestsDirectory() + "/completion-ledger.json"
        let data = try DoryOperationJournalStore.secureRead(
            path,
            maximumBytes: DoryOperationSpecification.maximumBytes
        )
        guard let ledger = try? JSONDecoder().decode(DoryOperationCompletionLedger.self, from: data),
              let canonical = try? DoryOperationJournalStore.encoded(ledger, pretty: true),
              data == canonical,
              ledger.evidence.sorted(by: { $0.source < $1.source }) == (try readObjectEvidence()),
              try ledger.evaluate(against: readCompletenessPlan()).isComplete else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        return ledger
    }

    private func manifestsDirectory() throws -> String {
        let directory = operationDirectory + "/manifests"
        try DoryOperationJournalStore.validatePrivateDirectory(directory)
        try DoryOperationJournalStore.validatePrivateDirectory(directory + "/objects")
        return directory
    }

    private func evidenceDirectory() throws -> String {
        let directory = try manifestsDirectory() + "/evidence"
        try DoryOperationJournalStore.validatePrivateDirectory(directory)
        return directory
    }

    private func stagedDirectory() throws -> String {
        let directory = try manifestsDirectory() + "/staged"
        try DoryOperationJournalStore.validatePrivateDirectory(directory)
        return directory
    }

    private func evidenceEntries(in directory: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { !Self.isUnpublishedPartial($0) }
                .sorted()
        } catch {
            throw DoryOperationJournalError.filesystem(
                "list operation evidence at \(directory): \(error)"
            )
        }
    }

    private func ensureEvidenceIsWritable() throws {
        let record = try read()
        guard record.state.status != .completed,
              record.state.status != .failed else {
            throw DoryOperationJournalError.invalidRecord(
                "terminal operation evidence is immutable"
            )
        }
    }

    private static func evidenceFileName(for key: DoryOperationObjectKey) -> String {
        let identity = key.kind.rawValue + "\u{0}" + key.sourceID
        return DoryOperationJournalStore.digest(Data(identity.utf8)) + ".json"
    }

    private static func isUnpublishedPartial(_ name: String) -> Bool {
        guard name.first == ".", name.hasSuffix(".partial") else { return false }
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 5
            && DoryOperationJournalStore.isDigest(String(components[1]))
            && components[2] == "json"
            && UUID(uuidString: String(components[3])) != nil
    }
}
