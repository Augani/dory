import Dispatch
import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryHV

struct DoryFSWorkerContractTests {
    @Test func exactFramesRoundTripAndRejectTrailingOrReservedBytes() throws {
        let capability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        )
        let generation = try DoryFSWorkerGeneration(rawValue: 7)
        let request = try DoryFSWorkerRequest(
            generation: generation,
            shareCapabilityID: capability,
            requestID: 9,
            correlationID: 11,
            opcodeClass: .mutation,
            responseCapacity: 512,
            deadlineUptimeNanoseconds: 123_456,
            payload: Data([1, 2, 3, 4])
        )
        let encoded = try DoryFSWorkerFrameCodec.encode(
            .execute(request),
            maximumFrameBytes: 1_024
        )
        #expect(try DoryFSWorkerFrameCodec.decodeClientFrame(
            encoded,
            maximumFrameBytes: 1_024
        ) == .execute(request))

        var reserved = encoded
        reserved[68] = 1
        #expect(throws: DoryFSWorkerContractError.nonzeroReservedField) {
            _ = try DoryFSWorkerFrameCodec.decodeClientFrame(
                reserved,
                maximumFrameBytes: 1_024
            )
        }

        var trailing = encoded
        trailing.append(0)
        #expect(throws: DoryFSWorkerContractError.payloadLengthMismatch(declared: 4, actual: 5)) {
            _ = try DoryFSWorkerFrameCodec.decodeClientFrame(
                trailing,
                maximumFrameBytes: 1_024
            )
        }

        #expect(throws: DoryFSWorkerContractError.frameTooLarge(
            limit: DoryFSWorkerFrameCodec.headerByteCount + 3,
            actual: DoryFSWorkerFrameCodec.headerByteCount + 4
        )) {
            _ = try DoryFSWorkerFrameCodec.encode(
                .execute(request),
                maximumFrameBytes: DoryFSWorkerFrameCodec.headerByteCount + 3
            )
        }
    }

    @Test func replyDispositionIsTypedAndExact() throws {
        let fixture = try workerFixture()
        let rejected = try DoryFSWorkerReply(
            generation: fixture.generation,
            shareCapabilityID: fixture.capability,
            requestID: 20,
            correlationID: 30,
            outcome: .rejected(.resourceExhausted)
        )
        let encoded = try DoryFSWorkerFrameCodec.encode(
            .reply(rejected),
            maximumFrameBytes: 512
        )
        #expect(try DoryFSWorkerFrameCodec.decodeServiceFrame(
            encoded,
            maximumFrameBytes: 512
        ) == .reply(rejected))

        var invalid = encoded
        invalid[65] = 99
        #expect(throws: DoryFSWorkerContractError.unknownReplyDisposition(99)) {
            _ = try DoryFSWorkerFrameCodec.decodeServiceFrame(
                invalid,
                maximumFrameBytes: 512
            )
        }
    }

    @Test func nestedRPCAndServiceDecodersRetainBoundedPayloadSlices() throws {
        let capability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        )
        let request = try DoryFSWorkerRequest(
            generation: DoryFSWorkerGeneration(rawValue: 7),
            shareCapabilityID: capability,
            requestID: 9,
            correlationID: 11,
            opcodeClass: .data,
            responseCapacity: 512,
            deadlineUptimeNanoseconds: 123_456,
            payload: Data(repeating: 0xA5, count: 4_096)
        )
        let inner = try DoryFSWorkerFrameCodec.encode(
            .execute(request),
            maximumFrameBytes: 8_192
        )
        let outer = try DoryFSWorkerRPCResultCodec.encode(
            .success(inner),
            maximumPayloadBytes: 8_192
        )
        guard case .success(let retainedInner) = try DoryFSWorkerRPCResultCodec.decode(
            outer,
            maximumPayloadBytes: 8_192
        ) else {
            Issue.record("expected successful nested worker frame")
            return
        }
        #expect(retainedInner.startIndex == DoryFSWorkerRPCResultCodec.headerByteCount)

        guard case .execute(let decoded) = try DoryFSWorkerFrameCodec.decodeClientFrame(
            retainedInner,
            maximumFrameBytes: 8_192
        ) else {
            Issue.record("expected decoded worker request")
            return
        }
        #expect(decoded == request)
        #expect(
            decoded.payload.startIndex
                == DoryFSWorkerRPCResultCodec.headerByteCount
                    + DoryFSWorkerFrameCodec.headerByteCount
        )
    }
}

struct DoryFSWorkerBrokerTests {
    @Test func boundaryReservationsRecoverOnlyAfterTypedReplies() async throws {
        let limits = try brokerLimits(
            request: 4,
            response: 4,
            inFlight: 2,
            aggregateRequest: 8,
            aggregateResponse: 8
        )
        let fixture = try workerFixture(limits: limits)
        let deadline = futureDeadline(seconds: 10)
        let first = Task {
            try await fixture.broker.execute(
                correlationID: 101,
                opcodeClass: .metadata,
                request: Data([1, 2, 3, 4]),
                responseCapacity: 4,
                deadlineUptimeNanoseconds: deadline
            )
        }
        let second = Task {
            try await fixture.broker.execute(
                correlationID: 102,
                opcodeClass: .data,
                request: Data([5, 6, 7, 8]),
                responseCapacity: 4,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 2 })

        await expectBrokerError(.inFlightLimit(limit: 2)) {
            try await fixture.broker.execute(
                correlationID: 103,
                opcodeClass: .metadata,
                request: Data([9]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: deadline
            )
        }

        try fixture.channel.completeRequest(correlationID: 101, payload: Data([10]))
        let firstExecution = try await first.value
        #expect(firstExecution.response == Data([10]))
        let awaitingPublication = await fixture.broker.snapshot()
        #expect(awaitingPublication.inFlightRequests == 2)
        #expect(awaitingPublication.pendingPublications == 1)
        try await fixture.broker.commitPublication(firstExecution.publication)
        #expect(await fixture.broker.snapshot().inFlightRequests == 1)

        let replacement = Task {
            try await fixture.broker.execute(
                correlationID: 103,
                opcodeClass: .metadata,
                request: Data([9]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 3 })
        try fixture.channel.completeRequest(correlationID: 102, payload: Data([11]))
        try fixture.channel.completeRequest(correlationID: 103, payload: Data([12]))
        let secondExecution = try await second.value
        let replacementExecution = try await replacement.value
        #expect(secondExecution.response == Data([11]))
        #expect(replacementExecution.response == Data([12]))
        try await fixture.broker.commitPublication(secondExecution.publication)
        try await fixture.broker.commitPublication(replacementExecution.publication)

        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.inFlightRequests == 0)
        #expect(snapshot.aggregateRequestBytes == 0)
        #expect(snapshot.aggregateResponseReservations == 0)
        #expect(snapshot.completedRequests == 3)
        #expect(snapshot.rejectedAdmissions == 1)
    }

    @Test func requestResponseAndAggregateBoundsRejectBeforeChannelAdmission() async throws {
        let limits = try brokerLimits(
            request: 4,
            response: 4,
            inFlight: 4,
            aggregateRequest: 5,
            aggregateResponse: 5
        )
        let fixture = try workerFixture(limits: limits)
        let deadline = futureDeadline(seconds: 10)

        await expectBrokerError(.requestTooLarge(limit: 4, actual: 5)) {
            try await fixture.broker.execute(
                correlationID: 1,
                opcodeClass: .data,
                request: Data(repeating: 1, count: 5),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: deadline
            )
        }
        await expectBrokerError(.responseCapacityTooLarge(limit: 4, actual: 5)) {
            try await fixture.broker.execute(
                correlationID: 2,
                opcodeClass: .data,
                request: Data([1]),
                responseCapacity: 5,
                deadlineUptimeNanoseconds: deadline
            )
        }

        let admitted = Task {
            try await fixture.broker.execute(
                correlationID: 3,
                opcodeClass: .data,
                request: Data([1, 2, 3]),
                responseCapacity: 3,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        await expectBrokerError(.aggregateRequestLimit(limit: 5, requested: 6)) {
            try await fixture.broker.execute(
                correlationID: 4,
                opcodeClass: .data,
                request: Data([1, 2, 3]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: deadline
            )
        }
        await expectBrokerError(.aggregateResponseLimit(limit: 5, requested: 6)) {
            try await fixture.broker.execute(
                correlationID: 5,
                opcodeClass: .data,
                request: Data([1]),
                responseCapacity: 3,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(fixture.channel.sendCount == 1)
        try fixture.channel.completeRequest(at: 0, payload: Data([9]))
        let execution = try await admitted.value
        try await fixture.broker.commitPublication(execution.publication)
    }

    @Test func typedWorkerRejectionReturnsAllReservations() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let rejected = Task {
            try await fixture.broker.execute(
                correlationID: 20,
                opcodeClass: .metadata,
                request: Data([1, 2]),
                responseCapacity: 4,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        try fixture.channel.rejectRequest(
            correlationID: 20,
            code: .resourceExhausted
        )
        await expectTaskError(.workerRejected(.resourceExhausted), task: rejected)
        let recovered = await fixture.broker.snapshot()
        #expect(recovered.state == .active)
        #expect(recovered.inFlightRequests == 0)
        #expect(recovered.aggregateRequestBytes == 0)
        #expect(recovered.aggregateResponseReservations == 0)

        let replacement = Task {
            try await fixture.broker.execute(
                correlationID: 21,
                opcodeClass: .metadata,
                request: Data([3]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 2 })
        try fixture.channel.completeRequest(correlationID: 21, payload: Data([4]))
        let execution = try await replacement.value
        #expect(execution.response == Data([4]))
        try await fixture.broker.commitPublication(execution.publication)
    }

    @Test func concurrentAdmissionNeverExceedsTheAtomicInFlightLimit() async throws {
        let limits = try brokerLimits(
            request: 2,
            response: 2,
            inFlight: 4,
            aggregateRequest: 8,
            aggregateResponse: 8
        )
        let fixture = try workerFixture(limits: limits)
        let deadline = futureDeadline(seconds: 10)
        let tasks = (1...32).map { correlationID in
            Task { () -> Result<DoryFSWorkerExecution, DoryFSWorkerBrokerError> in
                do {
                    return .success(try await fixture.broker.execute(
                        correlationID: UInt64(correlationID),
                        opcodeClass: .metadata,
                        request: Data([1]),
                        responseCapacity: 1,
                        deadlineUptimeNanoseconds: deadline
                    ))
                } catch let error as DoryFSWorkerBrokerError {
                    return .failure(error)
                } catch {
                    Issue.record("unexpected error: \(error)")
                    return .failure(.channelFailure(.unavailable))
                }
            }
        }
        #expect(await eventually { fixture.channel.sendCount == 4 })
        #expect(await fixture.broker.snapshot().inFlightRequests == 4)
        try fixture.channel.completeAllRequests(payload: Data([7]))

        var successes = 0
        var rejections = 0
        for task in tasks {
            switch await task.value {
            case .success(let execution):
                successes += 1
                #expect(execution.response == Data([7]))
                try await fixture.broker.commitPublication(execution.publication)
            case .failure(.inFlightLimit(limit: 4)):
                rejections += 1
            case .failure(let error):
                Issue.record("unexpected broker error: \(error)")
            }
        }
        #expect(successes == 4)
        #expect(rejections == 28)
        #expect(await fixture.broker.snapshot().inFlightRequests == 0)
    }

    @Test func interruptionFailsAllWorkAndLateRepliesCannotReviveGeneration() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let deadline = futureDeadline(seconds: 10)
        let first = Task {
            try await fixture.broker.execute(
                correlationID: 1,
                opcodeClass: .metadata,
                request: Data([1]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: deadline
            )
        }
        let second = Task {
            try await fixture.broker.execute(
                correlationID: 2,
                opcodeClass: .mutation,
                request: Data([2]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 2 })
        fixture.channel.emit(.interrupted)
        await expectTaskError(.channelInterrupted, task: first)
        await expectTaskError(.channelInterrupted, task: second)
        #expect(await eventually { await fixture.broker.snapshot().state == .interrupted })

        try fixture.channel.completeRequest(at: 0, payload: Data([9]))
        try fixture.channel.completeRequest(at: 1, payload: Data([9]))
        #expect(await eventually { await fixture.broker.snapshot().lateReplies == 2 })
        await expectBrokerError(.notActive(.interrupted)) {
            try await fixture.broker.execute(
                correlationID: 3,
                opcodeClass: .metadata,
                request: Data([3]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: deadline
            )
        }
    }

    @Test func explicitInterruptTargetsTheBrokerRequestWithoutReleasingItsReservation() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let operation = Task {
            try await fixture.broker.execute(
                correlationID: 40,
                opcodeClass: .mutation,
                request: Data([1]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        let interrupted = try await fixture.broker.interrupt(
            correlationID: 40,
            deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
        )
        #expect(interrupted)
        #expect(fixture.channel.oneWayCount == 1)
        guard case .interrupt(let frame) = try fixture.channel.oneWayClientFrame(at: 0) else {
            Issue.record("expected interrupt frame")
            return
        }
        #expect(frame.targetCorrelationID == 40)
        #expect(await fixture.broker.snapshot().inFlightRequests == 1)

        try fixture.channel.completeRequest(correlationID: 40, payload: Data([2]))
        let execution = try await operation.value
        #expect(execution.response == Data([2]))
        let unpublished = await fixture.broker.snapshot()
        #expect(unpublished.inFlightRequests == 1)
        #expect(unpublished.pendingPublications == 1)
        #expect(unpublished.sentInterrupts == 1)
        try await fixture.broker.commitPublication(execution.publication)
        #expect(await fixture.broker.snapshot().inFlightRequests == 0)
    }

    @Test func staleGenerationReplyIsAChannelProtocolViolation() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let task = Task {
            try await fixture.broker.execute(
                correlationID: 50,
                opcodeClass: .metadata,
                request: Data([1]),
                responseCapacity: 4,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        let request = try fixture.channel.request(at: 0)
        let staleGeneration = try DoryFSWorkerGeneration(rawValue: request.generation.rawValue + 1)
        let reply = try DoryFSWorkerReply(
            generation: staleGeneration,
            shareCapabilityID: request.shareCapabilityID,
            requestID: request.requestID,
            correlationID: request.correlationID,
            outcome: .completed(Data([1]))
        )
        try fixture.channel.complete(
            at: 0,
            with: DoryFSWorkerFrameCodec.encode(
                .reply(reply),
                maximumFrameBytes: fixture.limits.maximumFrameBytes
            )
        )
        await expectTaskError(.replyIdentityMismatch, task: task)
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.state == .protocolViolation)
        #expect(snapshot.protocolViolations == 1)
        #expect(fixture.channel.invalidateCount == 1)
    }

    @Test func absoluteRequestDeadlineInvalidatesUnresponsiveGeneration() async throws {
        let limits = try brokerLimits(
            operationNanoseconds: 200_000_000,
            drainNanoseconds: 200_000_000
        )
        let fixture = try workerFixture(limits: limits)
        let task = Task {
            try await fixture.broker.execute(
                correlationID: 70,
                opcodeClass: .mutation,
                request: Data([1]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        await expectTaskError(.requestDeadlineExpired(correlationID: 70), task: task)
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.state == .invalidated)
        #expect(snapshot.inFlightRequests == 0)
        #expect(fixture.channel.invalidateCount == 1)
        #expect(fixture.channel.oneWayCount == 2)
        guard case .interrupt(let interrupt) = try fixture.channel.oneWayClientFrame(at: 0) else {
            Issue.record("deadline did not emit a typed interrupt frame")
            return
        }
        #expect(interrupt.targetCorrelationID == 70)
        guard case .invalidate = try fixture.channel.oneWayClientFrame(at: 1) else {
            Issue.record("deadline did not invalidate the worker generation")
            return
        }
    }

    @Test func drainStopsAdmissionWaitsForWorkAndRequiresExactAck() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let operation = Task {
            try await fixture.broker.execute(
                correlationID: 80,
                opcodeClass: .data,
                request: Data([1]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        let drain = Task {
            try await fixture.broker.drain(
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { await fixture.broker.snapshot().state == .draining })
        await expectBrokerError(.notActive(.draining)) {
            try await fixture.broker.execute(
                correlationID: 81,
                opcodeClass: .metadata,
                request: Data([2]),
                responseCapacity: 1,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(fixture.channel.sendCount == 1)

        try fixture.channel.completeRequest(at: 0, payload: Data([3]))
        let execution = try await operation.value
        #expect(execution.response == Data([3]))
        #expect(fixture.channel.sendCount == 1)
        try await fixture.broker.commitPublication(execution.publication)
        #expect(await eventually { fixture.channel.sendCount == 2 })
        let drainFrame = try fixture.channel.clientFrame(at: 1)
        guard case .drain(let request) = drainFrame else {
            Issue.record("expected drain frame")
            return
        }
        let ack = DoryFSWorkerDrained(
            generation: request.generation,
            shareCapabilityID: request.shareCapabilityID
        )
        try fixture.channel.complete(
            at: 1,
            with: DoryFSWorkerFrameCodec.encode(
                .drained(ack),
                maximumFrameBytes: fixture.limits.maximumFrameBytes
            )
        )
        try await drain.value
        #expect(await fixture.broker.snapshot().state == .drained)
        await fixture.broker.invalidate()
        #expect(await fixture.broker.snapshot().state == .invalidated)
    }

    @Test func completedShareTeardownRetainsSharedChannelForSiblingBroker() async throws {
        let fixture = try workerFixture(limits: brokerLimits())
        let siblingCapability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"))
        )
        let sibling = DoryFSWorkerBroker(
            shareCapabilityID: siblingCapability,
            generation: fixture.generation,
            limits: fixture.limits,
            channel: fixture.channel
        )

        try await fixture.broker.completeConnectionTeardown()

        #expect(await fixture.broker.snapshot().state == .drained)
        #expect(await sibling.snapshot().state == .active)
        #expect(fixture.channel.invalidateCount == 0)

        let operation = Task {
            try await sibling.execute(
                correlationID: 91,
                opcodeClass: .metadata,
                request: Data([1]),
                responseCapacity: 2,
                deadlineUptimeNanoseconds: futureDeadline(seconds: 10)
            )
        }
        #expect(await eventually { fixture.channel.sendCount == 1 })
        try fixture.channel.completeRequest(correlationID: 91, payload: Data([2]))
        let execution = try await operation.value
        try await sibling.commitPublication(execution.publication)
        #expect(await sibling.snapshot().state == .active)
        #expect(fixture.channel.invalidateCount == 0)

        await sibling.invalidate()
        #expect(fixture.channel.invalidateCount == 1)
    }
}

private struct WorkerFixture {
    let capability: DoryFSShareCapabilityID
    let generation: DoryFSWorkerGeneration
    let limits: DoryFSWorkerLimits
    let channel: RecordingDoryFSWorkerChannel
    let broker: DoryFSWorkerBroker
}

private func workerFixture(
    limits: DoryFSWorkerLimits = try! brokerLimits()
) throws -> WorkerFixture {
    let capability = try DoryFSShareCapabilityID(
        rawValue: #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
    )
    let generation = try DoryFSWorkerGeneration(rawValue: 1)
    let channel = RecordingDoryFSWorkerChannel(maximumFrameBytes: limits.maximumFrameBytes)
    return WorkerFixture(
        capability: capability,
        generation: generation,
        limits: limits,
        channel: channel,
        broker: DoryFSWorkerBroker(
            shareCapabilityID: capability,
            generation: generation,
            limits: limits,
            channel: channel
        )
    )
}

private func brokerLimits(
    request: Int = 16,
    response: Int = 16,
    inFlight: Int = 4,
    aggregateRequest: Int = 64,
    aggregateResponse: Int = 64,
    operationNanoseconds: UInt64 = 15_000_000_000,
    drainNanoseconds: UInt64 = 15_000_000_000
) throws -> DoryFSWorkerLimits {
    try DoryFSWorkerLimits(
        maximumRequestBytes: request,
        maximumResponseBytes: response,
        maximumFrameBytes: 512,
        maximumInFlightRequests: inFlight,
        maximumAggregateRequestBytes: aggregateRequest,
        maximumAggregateResponseBytes: aggregateResponse,
        maximumOperationNanoseconds: operationNanoseconds,
        maximumDrainNanoseconds: drainNanoseconds
    )
}

private func futureDeadline(seconds: UInt64) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
}

private func eventually(
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func expectBrokerError<Success>(
    _ expected: DoryFSWorkerBrokerError,
    operation: () async throws -> Success
) async {
    do {
        _ = try await operation()
        Issue.record("expected broker error \(expected)")
    } catch let error as DoryFSWorkerBrokerError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func expectTaskError<Success>(
    _ expected: DoryFSWorkerBrokerError,
    task: Task<Success, any Error>
) async {
    do {
        _ = try await task.value
        Issue.record("expected task error \(expected)")
    } catch let error as DoryFSWorkerBrokerError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected task error: \(error)")
    }
}

private final class RecordingDoryFSWorkerChannel: DoryFSWorkerChannel, @unchecked Sendable {
    private struct PendingSend {
        let frame: Data
        let completion: @Sendable (Result<Data, DoryFSWorkerChannelFailure>) -> Void
    }

    private let lock = NSLock()
    private let maximumFrameBytes: Int
    private var lifecycleHandler: (@Sendable (DoryFSWorkerChannelEvent) -> Void)?
    private var sends = [PendingSend]()
    private var oneWayFrames = [Data]()
    private var invalidations = 0

    init(maximumFrameBytes: Int) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    ) {
        lock.lock()
        lifecycleHandler = handler
        lock.unlock()
    }

    func send(
        frame: Data,
        completion: @escaping @Sendable (Result<Data, DoryFSWorkerChannelFailure>) -> Void
    ) {
        lock.lock()
        sends.append(PendingSend(frame: frame, completion: completion))
        lock.unlock()
    }

    func sendOneWay(frame: Data) {
        lock.lock()
        oneWayFrames.append(frame)
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }

    var sendCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sends.count
    }

    var oneWayCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return oneWayFrames.count
    }

    var invalidateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalidations
    }

    func emit(_ event: DoryFSWorkerChannelEvent) {
        lock.lock()
        let handler = lifecycleHandler
        lock.unlock()
        handler?(event)
    }

    func clientFrame(at index: Int) throws -> DoryFSWorkerClientFrame {
        lock.lock()
        let frame = sends[index].frame
        lock.unlock()
        return try DoryFSWorkerFrameCodec.decodeClientFrame(
            frame,
            maximumFrameBytes: maximumFrameBytes
        )
    }

    func request(at index: Int) throws -> DoryFSWorkerRequest {
        guard case .execute(let request) = try clientFrame(at: index) else {
            throw DoryFSWorkerBrokerError.replyIdentityMismatch
        }
        return request
    }

    func oneWayClientFrame(at index: Int) throws -> DoryFSWorkerClientFrame {
        lock.lock()
        let frame = oneWayFrames[index]
        lock.unlock()
        return try DoryFSWorkerFrameCodec.decodeClientFrame(
            frame,
            maximumFrameBytes: maximumFrameBytes
        )
    }

    func completeRequest(at index: Int, payload: Data) throws {
        let request = try request(at: index)
        let reply = try DoryFSWorkerReply(
            generation: request.generation,
            shareCapabilityID: request.shareCapabilityID,
            requestID: request.requestID,
            correlationID: request.correlationID,
            outcome: .completed(payload)
        )
        try complete(
            at: index,
            with: DoryFSWorkerFrameCodec.encode(
                .reply(reply),
                maximumFrameBytes: maximumFrameBytes
            )
        )
    }

    func completeRequest(correlationID: UInt64, payload: Data) throws {
        lock.lock()
        let frames = sends.map(\.frame)
        lock.unlock()
        for (index, frame) in frames.enumerated() {
            guard case .execute(let request) = try DoryFSWorkerFrameCodec.decodeClientFrame(
                frame,
                maximumFrameBytes: maximumFrameBytes
            ) else { continue }
            if request.correlationID == correlationID {
                try completeRequest(at: index, payload: payload)
                return
            }
        }
        throw DoryFSWorkerBrokerError.unknownCorrelationID(correlationID)
    }

    func rejectRequest(
        correlationID: UInt64,
        code: DoryFSWorkerRejectionCode
    ) throws {
        lock.lock()
        let frames = sends.map(\.frame)
        lock.unlock()
        for (index, frame) in frames.enumerated() {
            guard case .execute(let request) = try DoryFSWorkerFrameCodec.decodeClientFrame(
                frame,
                maximumFrameBytes: maximumFrameBytes
            ) else { continue }
            if request.correlationID == correlationID {
                let reply = try DoryFSWorkerReply(
                    generation: request.generation,
                    shareCapabilityID: request.shareCapabilityID,
                    requestID: request.requestID,
                    correlationID: request.correlationID,
                    outcome: .rejected(code)
                )
                try complete(
                    at: index,
                    with: DoryFSWorkerFrameCodec.encode(
                        .reply(reply),
                        maximumFrameBytes: maximumFrameBytes
                    )
                )
                return
            }
        }
        throw DoryFSWorkerBrokerError.unknownCorrelationID(correlationID)
    }

    func completeAllRequests(payload: Data) throws {
        let count = sendCount
        for index in 0..<count {
            if case .execute = try clientFrame(at: index) {
                try completeRequest(at: index, payload: payload)
            }
        }
    }

    func complete(at index: Int, with response: Data) throws {
        lock.lock()
        let completion = sends[index].completion
        lock.unlock()
        completion(.success(response))
    }
}
