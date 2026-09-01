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

    @Test func finalTransactionFrameAcknowledgementReplayCommitsOnlyOnce() async throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 35)
        let capability = try coherenceCapability(5)
        let failures = CoherenceFailureRecorder()
        let counter = CoherenceInvocationCounter()
        let sink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            onFailure: failures.record
        )
        #expect(sink.installHandler { _ in await counter.increment() })
        let frame = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 91,
            transactionID: 90,
            transactionIndex: 1,
            transactionCount: 2,
            nudge: "final"
        )
        let expected = DoryFSWorkerCoherenceCodec.encode(
            try DoryFSWorkerCoherenceAcknowledgement(
                generation: generation,
                shareCapabilityID: capability,
                batchID: 91,
                transactionID: 90,
                transactionIndex: 1,
                transactionCount: 2
            )
        )

        #expect(await sink.deliverForTesting(frame) == expected)
        #expect(await sink.deliverForTesting(frame) == expected)
        let invocationCount = await counter.value
        #expect(invocationCount == 1)
        #expect(failures.error == nil)
        #expect(sink.statistics.replayedBatchCount == 1)
    }

    @Test func inFlightReplayFinalizesBeforeNextSequentialFrameAdmission() async throws {
        let generation = try DoryFSWorkerGeneration(rawValue: 36)
        let capability = try coherenceCapability(6)
        let failures = CoherenceFailureRecorder()
        let handler = CoherenceHandlerGate()
        let originalCompletion = CoherenceOneShotGate()
        let sink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: generation,
            capabilities: [capability],
            uniqueCompletionTestHook: originalCompletion.run,
            onFailure: failures.record
        )
        #expect(sink.installHandler { _ in await handler.run() })
        let firstFrame = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 90,
            nudge: "first"
        )
        let nextFrame = try coherenceFrame(
            generation: generation,
            capability: capability,
            batchID: 91,
            nudge: "next"
        )

        let first = Task { await sink.deliverForTesting(firstFrame) }
        while await handler.invocationCount < 1 { await Task.yield() }
        let replay = Task { await sink.deliverForTesting(firstFrame) }
        await handler.release()
        while !(await originalCompletion.hasStarted) { await Task.yield() }

        let replayReply = await replay.value
        #expect(!replayReply.isEmpty)
        let next = Task { await sink.deliverForTesting(nextFrame) }
        while await handler.invocationCount < 2 { await Task.yield() }
        await handler.release()
        #expect(!(await next.value).isEmpty)

        await originalCompletion.release()
        #expect(await first.value == replayReply)
        #expect(failures.error == nil)
        #expect(sink.statistics.completedBatchCount == 2)
        #expect(sink.statistics.inFlightBatchCount == 0)
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

private actor CoherenceOneShotGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private var hasBlocked = false

    func run() async {
        guard !hasBlocked else { return }
        hasBlocked = true
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
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
    transactionID: UInt64? = nil,
    transactionIndex: UInt16 = 0,
    transactionCount: UInt16 = 1,
    nudge: String
) throws -> Data {
    try DoryFSWorkerCoherenceCodec.encode(DoryFSWorkerCoherenceBatch(
        generation: generation,
        shareCapabilityID: capability,
        batchID: batchID,
        transactionID: transactionID,
        transactionIndex: transactionIndex,
        transactionCount: transactionCount,
        invalidations: [.inode(nodeID: 1, offset: -1, length: 0)],
        nudgeRelativePaths: [nudge]
    ))
}
