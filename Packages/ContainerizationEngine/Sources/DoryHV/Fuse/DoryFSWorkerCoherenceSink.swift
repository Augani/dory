import DoryFSWorkerContracts
import Foundation

public enum DoryFSWorkerCoherenceSinkError: Error, Equatable, Sendable {
    case malformedFrame
    case staleGeneration
    case unknownCapability
    case handlerUnavailable
    case batchSequenceViolation
    case conflictingReplay
    case inFlightLimit(limit: Int)
    case deliveryFailed
}

public struct DoryFSWorkerCoherenceSinkStatistics: Equatable, Sendable {
    public let receivedBatchCount: UInt64
    public let replayedBatchCount: UInt64
    public let completedBatchCount: UInt64
    public let failedBatchCount: UInt64
    public let inFlightBatchCount: Int
    public let peakInFlightBatchCount: Int
    public let receivedBytes: UInt64
    public let acknowledgementBytes: UInt64
    public let totalLatencyNanoseconds: UInt64
    public let maximumLatencyNanoseconds: UInt64
    public let terminalFailureLatched: Bool
}

/// Data-only reverse XPC receiver. It binds every batch to the bootstrapped generation and
/// capability set, retains a bounded exact replay ledger, and emits an ACK only after the runner's
/// invalidation + guest-watcher transaction has completed.
final class DoryFSWorkerCoherenceXPCSink:
    NSObject,
    DoryFSWorkerCoherenceSinkXPCProtocol,
    @unchecked Sendable
{
    typealias Handler = @Sendable (DoryFSWorkerCoherenceBatch) async throws -> Void
    typealias Failure = @Sendable (DoryFSWorkerCoherenceSinkError) -> Void

    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?

        func install(_ handler: @escaping Handler) -> Bool {
            lock.withLock {
                guard self.handler == nil else { return false }
                self.handler = handler
                return true
            }
        }

        func current() -> Handler? { lock.withLock { handler } }
    }

    private final class StatisticsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var received: UInt64 = 0
        private var replayed: UInt64 = 0
        private var completed: UInt64 = 0
        private var failed: UInt64 = 0
        private var inFlight = 0
        private var peakInFlight = 0
        private var receivedBytes: UInt64 = 0
        private var acknowledgementBytes: UInt64 = 0
        private var totalLatencyNanoseconds: UInt64 = 0
        private var maximumLatencyNanoseconds: UInt64 = 0
        private var terminal = false

        func begin(byteCount: Int, replay: Bool) {
            lock.withLock {
                received = Self.add(received, 1)
                receivedBytes = Self.add(receivedBytes, UInt64(clamping: byteCount))
                if replay { replayed = Self.add(replayed, 1) }
            }
        }

        func beginUnique() {
            lock.withLock {
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
            }
        }

        func finish(replyBytes: Int, latencyNanoseconds: UInt64, succeeded: Bool) {
            lock.withLock {
                inFlight = max(0, inFlight - 1)
                totalLatencyNanoseconds = Self.add(totalLatencyNanoseconds, latencyNanoseconds)
                maximumLatencyNanoseconds = max(maximumLatencyNanoseconds, latencyNanoseconds)
                if succeeded {
                    completed = Self.add(completed, 1)
                    acknowledgementBytes = Self.add(
                        acknowledgementBytes,
                        UInt64(clamping: replyBytes)
                    )
                } else {
                    failed = Self.add(failed, 1)
                }
            }
        }

        func failTerminal() {
            lock.withLock {
                terminal = true
                failed = Self.add(failed, 1)
            }
        }

        var snapshot: DoryFSWorkerCoherenceSinkStatistics {
            lock.withLock {
                DoryFSWorkerCoherenceSinkStatistics(
                    receivedBatchCount: received,
                    replayedBatchCount: replayed,
                    completedBatchCount: completed,
                    failedBatchCount: failed,
                    inFlightBatchCount: inFlight,
                    peakInFlightBatchCount: peakInFlight,
                    receivedBytes: receivedBytes,
                    acknowledgementBytes: acknowledgementBytes,
                    totalLatencyNanoseconds: totalLatencyNanoseconds,
                    maximumLatencyNanoseconds: maximumLatencyNanoseconds,
                    terminalFailureLatched: terminal
                )
            }
        }

        private static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
            let (value, overflow) = left.addingReportingOverflow(right)
            return overflow ? UInt64.max : value
        }
    }

    private actor Processor {
        private struct Key: Hashable, Sendable {
            let generation: UInt64
            let capability: UUID
            let batchID: UInt64
        }

        private enum Outcome: Sendable {
            case success(Data)
            case failure
        }

        private enum Entry: Sendable {
            case running(exactFrame: Data, task: Task<Outcome, Never>)
            case completed(exactFrame: Data, acknowledgement: Data)
        }

        private static let completedLedgerLimit = 64
        private static let inFlightLimit = 8

        private let expectedGeneration: DoryFSWorkerGeneration
        private let capabilities: Set<DoryFSShareCapabilityID>
        private let handlerBox: HandlerBox
        private let statistics: StatisticsBox
        private let onFailure: Failure
        private var entries = [Key: Entry]()
        private var completedOrder = [Key]()
        private var inFlightCount = 0
        private var lastAcceptedBatchID: UInt64?
        private var terminal = false

        init(
            expectedGeneration: DoryFSWorkerGeneration,
            capabilities: Set<DoryFSShareCapabilityID>,
            handlerBox: HandlerBox,
            statistics: StatisticsBox,
            onFailure: @escaping Failure
        ) {
            self.expectedGeneration = expectedGeneration
            self.capabilities = capabilities
            self.handlerBox = handlerBox
            self.statistics = statistics
            self.onFailure = onFailure
        }

        func receive(_ exactFrame: Data) async -> Data {
            guard !terminal else { return Data() }
            let batch: DoryFSWorkerCoherenceBatch
            do {
                batch = try DoryFSWorkerCoherenceCodec.decodeBatch(exactFrame)
            } catch {
                fail(.malformedFrame)
                return Data()
            }
            guard batch.generation == expectedGeneration else {
                fail(.staleGeneration)
                return Data()
            }
            guard capabilities.contains(batch.shareCapabilityID) else {
                fail(.unknownCapability)
                return Data()
            }
            let key = Key(
                generation: batch.generation.rawValue,
                capability: batch.shareCapabilityID.rawValue,
                batchID: batch.batchID
            )
            if let existing = entries[key] {
                statistics.begin(byteCount: exactFrame.count, replay: true)
                switch existing {
                case .running(let retainedFrame, let task):
                    guard retainedFrame == exactFrame else {
                        fail(.conflictingReplay)
                        return Data()
                    }
                    return await reply(for: await task.value, key: key, exactFrame: exactFrame)
                case .completed(let retainedFrame, let acknowledgement):
                    guard retainedFrame == exactFrame else {
                        fail(.conflictingReplay)
                        return Data()
                    }
                    return acknowledgement
                }
            }

            guard sequenceAccepts(batch.batchID) else {
                fail(.batchSequenceViolation)
                return Data()
            }
            guard inFlightCount < Self.inFlightLimit else {
                fail(.inFlightLimit(limit: Self.inFlightLimit))
                return Data()
            }
            guard let handler = handlerBox.current() else {
                fail(.handlerUnavailable)
                return Data()
            }

            statistics.begin(byteCount: exactFrame.count, replay: false)
            statistics.beginUnique()
            inFlightCount += 1
            lastAcceptedBatchID = batch.batchID
            let started = ContinuousClock.now
            let task = Task.detached(priority: .userInitiated) { () -> Outcome in
                do {
                    try await handler(batch)
                    let acknowledgement = try DoryFSWorkerCoherenceAcknowledgement(
                        accepting: batch
                    )
                    return .success(DoryFSWorkerCoherenceCodec.encode(acknowledgement))
                } catch {
                    return .failure
                }
            }
            entries[key] = .running(exactFrame: exactFrame, task: task)
            let outcome = await task.value
            let elapsed = started.duration(to: .now)
            let nanoseconds = Self.nanoseconds(elapsed)
            inFlightCount = max(0, inFlightCount - 1)
            switch outcome {
            case .success(let acknowledgement):
                if case .running = entries[key] {
                    entries[key] = .completed(
                        exactFrame: exactFrame,
                        acknowledgement: acknowledgement
                    )
                    completedOrder.append(key)
                    evictCompletedIfNeeded()
                }
                statistics.finish(
                    replyBytes: acknowledgement.count,
                    latencyNanoseconds: nanoseconds,
                    succeeded: true
                )
                return acknowledgement
            case .failure:
                entries.removeValue(forKey: key)
                statistics.finish(
                    replyBytes: 0,
                    latencyNanoseconds: nanoseconds,
                    succeeded: false
                )
                fail(.deliveryFailed, recordStatistics: false)
                return Data()
            }
        }

        private func reply(
            for outcome: Outcome,
            key: Key,
            exactFrame: Data
        ) async -> Data {
            switch outcome {
            case .success(let acknowledgement):
                // The original waiter normally records the completed ledger first. Actor
                // reentrancy allows a replay waiter to resume first, so make completion idempotent.
                if case .running = entries[key] {
                    entries[key] = .completed(
                        exactFrame: exactFrame,
                        acknowledgement: acknowledgement
                    )
                    completedOrder.append(key)
                    evictCompletedIfNeeded()
                }
                return acknowledgement
            case .failure:
                return Data()
            }
        }

        private func sequenceAccepts(_ batchID: UInt64) -> Bool {
            guard let previous = lastAcceptedBatchID else { return batchID != 0 }
            let expected = previous == UInt64.max ? 1 : previous + 1
            return batchID == expected
        }

        private func evictCompletedIfNeeded() {
            while completedOrder.count > Self.completedLedgerLimit {
                let oldest = completedOrder.removeFirst()
                if case .completed? = entries[oldest] {
                    entries.removeValue(forKey: oldest)
                }
            }
        }

        private func fail(
            _ error: DoryFSWorkerCoherenceSinkError,
            recordStatistics: Bool = true
        ) {
            guard !terminal else { return }
            terminal = true
            if recordStatistics { statistics.failTerminal() }
            onFailure(error)
        }

        private static func nanoseconds(_ duration: Duration) -> UInt64 {
            let components = duration.components
            guard components.seconds >= 0 else { return 0 }
            let seconds = UInt64(clamping: components.seconds)
            let attoseconds = max(Int64(0), components.attoseconds)
            let nanos = UInt64(attoseconds / 1_000_000_000)
            let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
            if overflow { return UInt64.max }
            let (total, additionOverflow) = scaled.addingReportingOverflow(nanos)
            return additionOverflow ? UInt64.max : total
        }
    }

    private let handlerBox = HandlerBox()
    private let statisticsBox = StatisticsBox()
    private let processor: Processor

    init(
        expectedGeneration: DoryFSWorkerGeneration,
        capabilities: Set<DoryFSShareCapabilityID>,
        onFailure: @escaping Failure
    ) {
        processor = Processor(
            expectedGeneration: expectedGeneration,
            capabilities: capabilities,
            handlerBox: handlerBox,
            statistics: statisticsBox,
            onFailure: onFailure
        )
        super.init()
    }

    @discardableResult
    func installHandler(_ handler: @escaping Handler) -> Bool {
        handlerBox.install(handler)
    }

    var statistics: DoryFSWorkerCoherenceSinkStatistics { statisticsBox.snapshot }

    func deliverCoherence(_ frame: Data, withReply reply: @escaping (Data) -> Void) {
        let once = DoryFSWorkerCoherenceReplyOnce(reply)
        Task {
            let response = await processor.receive(frame)
            once.send(response)
        }
    }

    func deliverForTesting(_ frame: Data) async -> Data {
        await processor.receive(frame)
    }
}

private final class DoryFSWorkerCoherenceReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data) -> Void)?

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        let callback = lock.withLock { () -> ((Data) -> Void)? in
            defer { reply = nil }
            return reply
        }
        callback?(data)
    }
}
