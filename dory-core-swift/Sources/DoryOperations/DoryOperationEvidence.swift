import Foundation

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

    public func publishObjectEvidence(_ evidence: DoryOperationObjectEvidence) throws {
        try ensureEvidenceIsWritable()
        let plan = try readCompletenessPlan()
        let completionPath = try manifestsDirectory() + "/completion-ledger.json"
        guard evidence.isValid,
              plan.selectedObjectKeys.contains(evidence.source),
              !DoryOperationJournalStore.pathEntryExists(completionPath) else {
            throw DoryOperationJournalError.invalidRecord("unplanned operation evidence")
        }
        _ = try readManifest(digest: evidence.verificationManifestDigest)
        let data = try DoryOperationJournalStore.encoded(evidence, pretty: false)
        let path = try evidenceDirectory() + "/" + Self.evidenceFileName(for: evidence.source)
        try DoryOperationJournalStore.publish(data, to: path)
    }

    public func readObjectEvidence() throws -> [DoryOperationObjectEvidence] {
        let directory = try evidenceDirectory()
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            throw DoryOperationJournalError.filesystem(
                "list operation evidence at \(directory): \(error)"
            )
        }
        var evidence: [DoryOperationObjectEvidence] = []
        for entry in entries.sorted() {
            if Self.isUnpublishedPartial(entry) { continue }
            let path = directory + "/" + entry
            let data = try DoryOperationJournalStore.secureRead(
                path,
                maximumBytes: DoryOperationSpecification.maximumBytes
            )
            guard let item = try? JSONDecoder().decode(DoryOperationObjectEvidence.self, from: data),
                  let canonical = try? DoryOperationJournalStore.encoded(item, pretty: false),
                  item.isValid,
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
