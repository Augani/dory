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
    private var workerGeneration: UInt64
    private var cleanFlushes = 0
    private var transcript: Data
    private var terminalOutcome: VirtioGPUStockFenceVerificationOutcome?

    public init(
        requiredCleanFlushes: Int = productionCleanFlushCount,
        workerGeneration: UInt64 = 0
    ) {
        self.requiredCleanFlushes = max(1, requiredCleanFlushes)
        self.workerGeneration = workerGeneration
        self.transcript = Self.makeTranscript(workerGeneration: workerGeneration)
    }

    /// A replacement worker starts a fresh observation window. An old in-flight flush may
    /// finish later, but cannot count toward this generation's proof.
    /// Returns whether a prior guest producer-fence violation still requires software fallback.
    @discardableResult
    public func beginWorkerGeneration(_ generation: UInt64) -> Bool {
        lock.withLock {
            let violated = terminalOutcome == .violated
            guard generation > workerGeneration else { return violated }
            workerGeneration = generation
            cleanFlushes = 0
            transcript = Self.makeTranscript(workerGeneration: generation)
            // A violation is a property of the guest's producer ordering, not merely the
            // worker process. Replacing the worker must never reenable unsafe scanout.
            terminalOutcome = violated ? .violated : nil
            return violated
        }
    }

    /// Returns a value exactly once, when the observation window verifies or violates.
    public func observeScanoutBlobFlush(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        producerFencePending: Bool,
        workerGeneration: UInt64 = 0
    ) -> VirtioGPUStockFenceVerificationOutcome? {
        lock.withLock {
            guard workerGeneration == self.workerGeneration else { return nil }
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

    private static func makeTranscript(workerGeneration: UInt64) -> Data {
        var transcript = Data("dory.stock-fence-verification.v2\0".utf8)
        var generation = workerGeneration.littleEndian
        withUnsafeBytes(of: &generation) { transcript.append(contentsOf: $0) }
        return transcript
    }
}
