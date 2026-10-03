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

    @Test func replacementRequiresFreshGenerationAndCompleteObservationWindow() {
        let verifier = VirtioGPUStockFenceVerifier(
            requiredCleanFlushes: 2,
            workerGeneration: 7
        )
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: false,
            workerGeneration: 7
        ) == nil)
        let firstOutcome = verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 2,
            producerFencePending: false,
            workerGeneration: 7
        )
        guard case .verified(let firstProof) = firstOutcome else {
            Issue.record("first worker did not produce a proof")
            return
        }

        verifier.beginWorkerGeneration(8)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 3,
            producerFencePending: true,
            workerGeneration: 7
        ) == nil)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: false,
            workerGeneration: 8
        ) == nil)
        let replacementOutcome = verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 2,
            producerFencePending: false,
            workerGeneration: 8
        )
        guard case .verified(let replacementProof) = replacementOutcome else {
            Issue.record("replacement worker did not produce a proof")
            return
        }
        #expect(replacementProof != firstProof)
        verifier.beginWorkerGeneration(7)
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 6,
            producerFencePending: false,
            workerGeneration: 7
        ) == nil)
    }

    @Test func workerReplacementDoesNotEraseGuestFenceViolation() {
        let verifier = VirtioGPUStockFenceVerifier(
            requiredCleanFlushes: 2,
            workerGeneration: 7
        )
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: true,
            workerGeneration: 7
        ) == .violated)
        #expect(verifier.beginWorkerGeneration(8))
        #expect(verifier.observeScanoutBlobFlush(
            resourceID: 9,
            resourceGeneration: 1,
            producerFencePending: false,
            workerGeneration: 8
        ) == nil)
    }
}
