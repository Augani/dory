import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryHV

struct DoryFSWorkerCoherenceSinkTests {
    @Test func exactInFlightAndCompletedReplaysExecuteTheTransactionOnce() async throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 31)
        let capability = try coherenceCapability(1)
        let failures = CoherenceFailureRecorder()
        let gate = CoherenceHandlerGate()
        let sink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            onFailure: failures.record
        )
        #expect(sink.installHandler { _ in await gate.run() })
        let frame = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 90,
            nudge: "Sources/main.swift"
        )

        let first = Task { await sink.deliverForTesting(frame) }
        while !(await gate.hasStarted) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let inFlightReplay = Task { await sink.deliverForTesting(frame) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await gate.release()

        let firstReply = await first.value
        let inFlightReply = await inFlightReplay.value
        let completedReply = await sink.deliverForTesting(frame)
        let expected = DoryFSWorkerCoherenceCodec.encode(
            try DoryFSWorkerCoherenceAcknowledgement(
                generation: generation,
                shareCapabilityID: capability,
                batchID: 90
            )
        )
        #expect(firstReply == expected)
        #expect(inFlightReply == expected)
        #expect(completedReply == expected)
        let invocationCount = await gate.invocationCount
        #expect(invocationCount == 1)
        #expect(failures.error == nil)
        let statistics = sink.statistics
        #expect(statistics.receivedBatchCount == 3)
        #expect(statistics.replayedBatchCount == 2)
        #expect(statistics.completedBatchCount == 1)
        #expect(statistics.inFlightBatchCount == 0)
        #expect(!statistics.terminalFailureLatched)
    }

    @Test func conflictingReplayIsTerminalAndNeverReachesTheHandler() async throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 32)
        let capability = try coherenceCapability(2)
        let failures = CoherenceFailureRecorder()
        let counter = CoherenceInvocationCounter()
        let sink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            onFailure: failures.record
        )
        #expect(sink.installHandler { _ in await counter.increment() })
        let accepted = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 7,
            nudge: "first"
        )
        let conflict = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 7,
            nudge: "second"
        )

        #expect(!(await sink.deliverForTesting(accepted)).isEmpty)
        #expect((await sink.deliverForTesting(conflict)).isEmpty)
        #expect(failures.error == .conflictingReplay)
        let invocationCount = await counter.value
        #expect(invocationCount == 1)
        #expect(sink.statistics.terminalFailureLatched)
    }

    @Test func foreignGenerationAndSkippedSequenceFailStop() async throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 33)
        let capability = try coherenceCapability(3)
        let staleFailures = CoherenceFailureRecorder()
        let staleSink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            onFailure: staleFailures.record
        )
        #expect(staleSink.installHandler { _ in })
        let foreignFrame = try coherenceFrame(
            generation: try DoryFSWorkerGeneration(rawValue: 34),
            capability: capability,
            batchID: 1,
            nudge: "foreign"
        )
        #expect((await staleSink.deliverForTesting(foreignFrame)).isEmpty)
        #expect(staleFailures.error == .staleGeneration)

        let sequenceFailures = CoherenceFailureRecorder()
        let sequenceSink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            onFailure: sequenceFailures.record
        )
        #expect(sequenceSink.installHandler { _ in })
        #expect(!(await sequenceSink.deliverForTesting(try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 11,
            nudge: "eleven"
        ))).isEmpty)
        #expect((await sequenceSink.deliverForTesting(try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 13,
            nudge: "thirteen"
        ))).isEmpty)
        #expect(sequenceFailures.error == .batchSequenceViolation)
    }
}

private actor CoherenceHandlerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0
    private(set) var hasStarted = false

    func run() async {
        invocationCount += 1
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CoherenceInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class CoherenceFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DoryFSWorkerCoherenceSinkError?

    var error: DoryFSWorkerCoherenceSinkError? { lock.withLock { stored } }

    func record(_ error: DoryFSWorkerCoherenceSinkError) {
        lock.withLock {
            if stored == nil { stored = error }
        }
    }
}

private func coherenceCapability(_ byte: UInt8) throws -> DoryFSShareCapabilityID {
    try DoryFSShareCapabilityID(rawValue: UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, byte
    )))
}

private func coherenceFrame(
    generation: DoryFSWorkerGeneration,
    capability: DoryFSShareCapabilityID,
    batchID: UInt64,
    nudge: String
) throws -> Data {
    try DoryFSWorkerCoherenceCodec.encode(DoryFSWorkerCoherenceBatch(
        generation: generation,
        shareCapabilityID: capability,
        batchID: batchID,
        invalidations: [.inode(nodeID: 1, offset: -1, length: 0)],
        nudgeRelativePaths: [nudge]
    ))
}
