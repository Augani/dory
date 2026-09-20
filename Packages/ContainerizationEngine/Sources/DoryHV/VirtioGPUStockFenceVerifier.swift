import CryptoKit
import Foundation

public enum VirtioGPUStockFenceVerificationOutcome: Sendable, Equatable {
    case verified(proofSHA256: String)
    case violated
}

/// Observes the first bounded set of scanout-bound blob flushes for a stock Linux guest.
/// A pending producer-context fence at flush arrival is the observable pre-6.13 ordering bug:
/// RESOURCE_FLUSH reached the host before prepare_fb waited for the producing GPU work.
public final class VirtioGPUStockFenceVerifier: @unchecked Sendable {
    public static let productionCleanFlushCount = 30

    private let lock = NSLock()
    private let requiredCleanFlushes: Int
    private var cleanFlushes = 0
    private var transcript = Data("dory.stock-fence-verification.v1\0".utf8)
    private var terminalOutcome: VirtioGPUStockFenceVerificationOutcome?

    public init(requiredCleanFlushes: Int = productionCleanFlushCount) {
        self.requiredCleanFlushes = max(1, requiredCleanFlushes)
    }

    /// Returns a value exactly once, when the observation window verifies or violates.
    public func observeScanoutBlobFlush(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        producerFencePending: Bool
    ) -> VirtioGPUStockFenceVerificationOutcome? {
        lock.withLock {
            guard terminalOutcome == nil else { return nil }
            if producerFencePending {
                terminalOutcome = .violated
                return .violated
            }
            var resource = resourceID.littleEndian
            var generation = resourceGeneration.littleEndian
            withUnsafeBytes(of: &resource) { transcript.append(contentsOf: $0) }
            withUnsafeBytes(of: &generation) { transcript.append(contentsOf: $0) }
            cleanFlushes += 1
            guard cleanFlushes == requiredCleanFlushes else { return nil }
            let proof = SHA256.hash(data: transcript).map {
                String(format: "%02x", $0)
            }.joined()
            let outcome = VirtioGPUStockFenceVerificationOutcome.verified(
                proofSHA256: proof
            )
            terminalOutcome = outcome
            return outcome
        }
    }
}
