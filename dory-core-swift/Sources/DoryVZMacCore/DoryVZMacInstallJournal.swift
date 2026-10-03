import Foundation

public enum DoryVZMacInstallPhase: String, Codable, Sendable, Equatable {
    case validatingRestore = "validating-restore"
    case installing
    case completed
    case failed
}

public enum DoryVZMacInstallJournalError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalid(String)
    case failureRecording(installation: String, metadata: String)

    public var description: String {
        switch self {
        case .invalid(let detail): "invalid VZMac install journal: \(detail)"
        case .failureRecording(let installation, let metadata):
            "VZMac installation failed: \(installation); failure metadata requires recovery: \(metadata)"
        }
    }
}

public struct DoryVZMacInstallJournal: Codable, Sendable, Equatable {
    public static let schema = "dory.vzmac-install-operation@1"
    public static let maximumErrorUTF8Bytes = 4_096
    public static let maximumJournalBytes = 1_048_576

    public let schema: String
    public let operationID: UUID
    public let startedAt: String
    public let updatedAt: String
    public let phase: DoryVZMacInstallPhase
    public let progress: Double
    public let restoreImageSHA256: String
    public let machineIdentifierSHA256: String
    public let error: String?

    public init(
        schema: String = Self.schema,
        operationID: UUID,
        startedAt: String,
        updatedAt: String,
        phase: DoryVZMacInstallPhase,
        progress: Double,
        restoreImageSHA256: String,
        machineIdentifierSHA256: String,
        error: String?
    ) {
        self.schema = schema
        self.operationID = operationID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.progress = progress
        self.restoreImageSHA256 = restoreImageSHA256
        self.machineIdentifierSHA256 = machineIdentifierSHA256
        self.error = error
    }

    public func validate() throws {
        guard schema == Self.schema,
              operationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              ISO8601DateFormatter().date(from: startedAt) != nil,
              ISO8601DateFormatter().date(from: updatedAt) != nil,
              progress.isFinite,
              (0...1).contains(progress),
              isInstallJournalSHA256(restoreImageSHA256),
              isInstallJournalSHA256(machineIdentifierSHA256) else {
            throw DoryVZMacInstallJournalError.invalid("metadata is malformed")
        }
        switch phase {
        case .completed:
            guard progress == 1, error == nil else {
                throw DoryVZMacInstallJournalError.invalid("completed phase is inconsistent")
            }
        case .failed:
            guard let error, !error.isEmpty,
                  error.utf8.count <= Self.maximumErrorUTF8Bytes else {
                throw DoryVZMacInstallJournalError.invalid("failed phase has no bounded error")
            }
        case .validatingRestore, .installing:
            guard error == nil else {
                throw DoryVZMacInstallJournalError.invalid("active phase contains an error")
            }
        }
    }

    public func updating(
        phase: DoryVZMacInstallPhase,
        progress: Double,
        error: String? = nil,
        at date: Date = Date()
    ) -> Self {
        Self(
            operationID: operationID,
            startedAt: startedAt,
            updatedAt: ISO8601DateFormatter().string(from: date),
            phase: phase,
            progress: progress,
            restoreImageSHA256: restoreImageSHA256,
            machineIdentifierSHA256: machineIdentifierSHA256,
            error: error
        )
    }

    public func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DoryVZMacMetadataFile.write(
            encoder.encode(self), to: url, maximumBytes: Self.maximumJournalBytes
        )
    }

    public static func load(from url: URL) throws -> Self {
        let journal: Self
        do {
            journal = try JSONDecoder().decode(
                Self.self,
                from: DoryVZMacMetadataFile.read(from: url, maximumBytes: maximumJournalBytes)
            )
        } catch {
            throw DoryVZMacInstallJournalError.invalid("journal cannot be safely read or decoded")
        }
        try journal.validate()
        return journal
    }
}

private func isInstallJournalSHA256(_ digest: String) -> Bool {
    digest.count == 64 && digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
}

func lastObservedInstallProgress(from url: URL) -> Double {
    guard let journal = try? DoryVZMacInstallJournal.load(from: url) else {
        return 0
    }
    return journal.progress
}
