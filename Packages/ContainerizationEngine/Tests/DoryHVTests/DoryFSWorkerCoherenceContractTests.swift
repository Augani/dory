import DoryFSWorkerContracts
import Foundation
import Testing

struct DoryFSWorkerCoherenceContractTests {
    @Test func boundedBatchAcknowledgementAndStatusRoundTripExactly() throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 42)
        let capability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "10203040-5060-7080-90a0-b0c0d0e0f001"))
        )
        let batch = try DoryFSWorkerCoherenceBatch(
            generation: generation,
            shareCapabilityID: capability,
            batchID: 7,
            invalidations: [
                .delete(parentNodeID: 1, childNodeID: 2, name: "old"),
                .entry(parentNodeID: 1, name: "new", flags: 0),
                .inode(nodeID: 2, offset: -1, length: 0),
            ],
            nudgeRelativePaths: ["", "Sources/main.swift"]
        )

        let frame = try DoryFSWorkerCoherenceCodec.encode(batch)
        #expect(frame.count <= DoryFSWorkerCoherenceCodec.maximumFrameBytes)
        #expect(try DoryFSWorkerCoherenceCodec.decodeBatch(frame) == batch)
        #expect(try DoryFSWorkerCoherenceCodec.encode(
            DoryFSWorkerCoherenceCodec.decodeBatch(frame)
        ) == frame)

        let acknowledgement = try DoryFSWorkerCoherenceAcknowledgement(accepting: batch)
        let acknowledgementFrame = DoryFSWorkerCoherenceCodec.encode(acknowledgement)
        #expect(
            try DoryFSWorkerCoherenceCodec.decodeAcknowledgement(acknowledgementFrame)
                == acknowledgement
        )

        let status = try DoryFSWorkerCoherenceStatus(
            generation: generation,
            running: true,
            configuredShareCount: 2,
            invalidationOnlyShareCount: 1,
            watcherNudgeShareCount: 1,
            requiredObservationShareCount: 2,
            observedRequiredShareCount: 2,
            observationStreamCount: 2,
            pendingEventCount: 1,
            pendingEventLimit: 65_536,
            receivedEventCount: 11,
            deliveredBatchCount: 9,
            failedBatchCount: 0,
            eventLossCount: 0
        )
        let statusFrame = DoryFSWorkerCoherenceStatusCodec.encode(status)
        #expect(statusFrame.count == DoryFSWorkerCoherenceStatusCodec.byteCount)
        #expect(try DoryFSWorkerCoherenceStatusCodec.decode(statusFrame) == status)
    }

    @Test func pathAuthorityOrderingAndCountArithmeticFailClosed() throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 1)
        let capability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "10203040-5060-7080-90a0-b0c0d0e0f002"))
        )

        #expect(throws: DoryFSWorkerCoherenceCodecError.invalidRelativePath("../host")) {
            _ = try DoryFSWorkerCoherenceBatch(
                generation: generation,
                shareCapabilityID: capability,
                batchID: 1,
                invalidations: [],
                nudgeRelativePaths: ["../host"]
            )
        }
        #expect(throws: DoryFSWorkerCoherenceCodecError.nonCanonicalOrdering) {
            _ = try DoryFSWorkerCoherenceBatch(
                generation: generation,
                shareCapabilityID: capability,
                batchID: 1,
                invalidations: [
                    .inode(nodeID: 2, offset: -1, length: 0),
                    .entry(parentNodeID: 1, name: "new", flags: 0),
                ],
                nudgeRelativePaths: []
            )
        }
        #expect(throws: DoryFSWorkerCoherenceStatusCodecError.invalidCounts) {
            _ = try DoryFSWorkerCoherenceStatus(
                generation: generation,
                running: false,
                configuredShareCount: 0,
                invalidationOnlyShareCount: .max,
                watcherNudgeShareCount: .max,
                requiredObservationShareCount: 0,
                observedRequiredShareCount: 0,
                observationStreamCount: 0,
                pendingEventCount: 0,
                pendingEventLimit: 65_536,
                receivedEventCount: 0,
                deliveredBatchCount: 0,
                failedBatchCount: 0,
                eventLossCount: 0
            )
        }
    }

    @Test func malformedOrNonCanonicalFramesAreRejected() throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 2)
        let capability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "10203040-5060-7080-90a0-b0c0d0e0f003"))
        )
        let batch = try DoryFSWorkerCoherenceBatch(
            generation: generation,
            shareCapabilityID: capability,
            batchID: 2,
            invalidations: [.inode(nodeID: 1, offset: 0, length: -1)],
            nudgeRelativePaths: []
        )
        let canonical = try DoryFSWorkerCoherenceCodec.encode(batch)

        var reserved = canonical
        reserved[7] = 1
        #expect(throws: DoryFSWorkerCoherenceCodecError.nonzeroReservedField) {
            _ = try DoryFSWorkerCoherenceCodec.decodeBatch(reserved)
        }

        var trailing = canonical
        trailing.append(0)
        #expect(throws: DoryFSWorkerCoherenceCodecError.frameLengthMismatch(
            declared: UInt32(canonical.count),
            actual: trailing.count
        )) {
            _ = try DoryFSWorkerCoherenceCodec.decodeBatch(trailing)
        }
    }
}
