import Foundation

/// Separate from guest renderer commands: only the owning signed runner sends this RPC after
/// admitting an opaque campaign grant. No PID, signal number, path or guest bytes are accepted.
public struct DoryRendererWorkerQualificationCrashRequest: Codable, Sendable, Equatable {
    public static let maximumByteCount = 512
    public let version: UInt16
    public let workspaceID: UUID
    public let workerGeneration: UInt64
    public let challenge: UUID
    public let deadlineUptimeNanoseconds: UInt64

    public init(workspaceID: UUID, workerGeneration: UInt64, challenge: UUID,
                deadlineUptimeNanoseconds: UInt64) {
        version = 1
        self.workspaceID = workspaceID
        self.workerGeneration = workerGeneration
        self.challenge = challenge
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }

    public var isValid: Bool {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        return version == 1 && workspaceID != zero && challenge != zero && workerGeneration > 0
            && deadlineUptimeNanoseconds > 0
    }

    public func encoded() throws -> Data {
        guard isValid else { throw DoryRendererWorkerContractError.nonCanonicalEncoding }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumByteCount else {
            throw DoryRendererWorkerContractError.frameTooLarge(limit: Self.maximumByteCount, actual: bytes.count)
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumByteCount else {
            throw DoryRendererWorkerContractError.frameTooLarge(limit: maximumByteCount, actual: bytes.count)
        }
        let request = try JSONDecoder().decode(Self.self, from: bytes)
        guard request.isValid, try request.encoded() == bytes else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return request
    }
}
