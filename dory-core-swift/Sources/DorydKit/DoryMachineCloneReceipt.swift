import Foundation

public enum DoryMachineCloneStorageMode: String, Codable, Sendable, Equatable, Hashable {
    /// APFS owns shared-extent reference accounting. The clone has no path or lifetime dependency
    /// on its source snapshot: deleting either file releases only that file's extent references.
    case apfsCopyOnWrite = "apfs-copy-on-write"
}

/// Durable, path-free evidence for a machine created from an immutable snapshot.
///
/// The receipt is minted only after `fclonefileat` succeeds and the cloned root disk hashes to the
/// snapshot's immutable artifact evidence. It is not an authorization to read the source and does
/// not keep the source snapshot alive; APFS provides the reference accounting and deletion safety.
public struct DoryMachineCloneReceipt: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var sourceMachineID: String
    public var sourceSnapshotID: String
    public var sourceRootfsSHA256: String
    public var sourceRootfsByteCount: UInt64
    public var storageMode: DoryMachineCloneStorageMode
    public var createdAtUnixMilliseconds: Int64

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        sourceMachineID: String,
        sourceSnapshotID: String,
        sourceRootfsSHA256: String,
        sourceRootfsByteCount: UInt64,
        storageMode: DoryMachineCloneStorageMode = .apfsCopyOnWrite,
        createdAtUnixMilliseconds: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.sourceMachineID = sourceMachineID
        self.sourceSnapshotID = sourceSnapshotID
        self.sourceRootfsSHA256 = sourceRootfsSHA256
        self.sourceRootfsByteCount = sourceRootfsByteCount
        self.storageMode = storageMode
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && Self.isValidIdentifier(sourceMachineID)
            && Self.isValidIdentifier(sourceSnapshotID)
            && sourceRootfsSHA256.count == 64
            && sourceRootfsSHA256.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
            && sourceRootfsByteCount > 0
            && createdAtUnixMilliseconds > 0
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }
}
