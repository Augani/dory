import Testing
@testable import DoryHV

@Suite struct VirtioGPUStockFenceVerifierTests {
    @Test func thirtyCleanFlushesProduceOneStableProof() {
        let verifier = VirtioGPUStockFenceVerifier()
        for generation in 1..<30 {
            #expect(verifier.observeScanoutBlobFlush(
                resourceID: 7,
                resourceGeneration: UInt64(generation),
                producerFencePending: false
            ) == nil)
        }
        let terminal = verifier.observeScanoutBlobFlush(
            resourceID: 7,
            resourceGeneration: 30,
            producerFencePending: false
        )
        guard case .verified(let proof) = terminal else {
            Issue.record("expected verification after 30 clean flushes")
            return
        }
        #expect(proof.count == 64)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 7,
            resourceGeneration: 31,
            producerFencePending: false
        ) == nil)
    }

    @Test func pendingProducerFenceViolatesImmediatelyAndTerminally() {
        let verifier = VirtioGPUStockFenceVerifier(requiredCleanFlushes: 2)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: false
        ) == nil)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: true
        ) == .violated)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: false
        ) == nil)
    }
}
