import Foundation

/// Private, content-addressed input needed to resume one planned object without reinspecting a
/// potentially changed source. The digest is computed from the exact bytes that are persisted.
public struct DoryOperationSpecification: Sendable, Equatable {
    public static let maximumBytes = 64 * 1_024 * 1_024

    public let digest: String
    public let data: Data

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw DoryOperationJournalError.invalidPlan("operation specification size")
        }
        self.data = data
        digest = DoryOperationJournalStore.digest(data)
    }

    public init<T: Encodable>(canonical value: T) throws {
        try self.init(data: DoryOperationJournalStore.encoded(value, pretty: false))
    }

    var isValid: Bool {
        !data.isEmpty
            && data.count <= Self.maximumBytes
            && DoryOperationJournalStore.isDigest(digest)
            && DoryOperationJournalStore.digest(data) == digest
    }
}
