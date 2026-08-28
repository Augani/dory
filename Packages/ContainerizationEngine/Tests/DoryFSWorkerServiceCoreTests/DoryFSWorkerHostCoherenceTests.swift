import DoryFSWorkerContracts
@testable import DoryFSWorkerServiceCore
import Foundation
import Testing

@Suite(.serialized)
struct DoryFSWorkerHostCoherenceTests {
    @Test func initiallyEmptyRootPublishesExactHostCreateForGuestWatcher() async throws {
        let share = try CoherenceTemporaryShare()
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(1)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 101),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }

        #expect(!relay.statistics.running)
        try relay.activate()
        let active = relay.statistics
        #expect(active.running)
        #expect(active.requiredObservationShareCount == 1)
        #expect(active.observedRequiredShareCount == 1)
        #expect(active.observationStreamCount == 1)

        try runExternal("/usr/bin/touch", [
            share.root.appendingPathComponent("created-by-host.txt").path,
        ])
        relay.flushObservationStreams()

        #expect(try await waitForNudge("created-by-host.txt", in: exchange))
        #expect(failures.error == nil)
        #expect(relay.statistics.deliveredBatchCount >= 1)
    }

    @Test func preactivationAtomicMoveIsReplayedAfterSinkHandshake() async throws {
        let share = try CoherenceTemporaryShare(stagingContents: Data("ready".utf8))
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(2)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 102),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }

        // This mutation occurs after the worker captured its FSEvents checkpoint but before any
        // stream or runner callback exists. Activation must replay it only after the sink is ready.
        try runExternal("/bin/mv", [
            share.staging.path,
            share.root.appendingPathComponent("atomic-install.txt").path,
        ])
        #expect(try await waitForPathToExist(
            share.root.appendingPathComponent("atomic-install.txt").path
        ))
        try relay.prepare()

        #expect(!relay.statistics.running)
        #expect(try await waitForPendingEvent(in: relay))
        #expect(exchange.exactFrames.isEmpty)

        try relay.activateDelivery()

        #expect(try await waitForNudge("atomic-install.txt", in: exchange))
        #expect(failures.error == nil)
        let active = relay.statistics
        #expect(active.running)
        #expect(active.requiredObservationShareCount == active.observedRequiredShareCount)
    }

    @Test func deliveryActivationRequiresPreparedObservation() throws {
        let share = try CoherenceTemporaryShare()
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(9)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 109),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }

        #expect(throws: DoryFSWorkerHostCoherenceError.observationUnavailable) {
            try relay.activateDelivery()
        }
        #expect(exchange.exactFrames.isEmpty)
        #expect(failures.error == nil)

        try relay.prepare()
        try relay.activateDelivery()

        #expect(relay.statistics.running)
        #expect(failures.error == nil)
    }

    @Test func transientDeliveryRetriesTheExactRetainedBatch() async throws {
        let share = try CoherenceTemporaryShare()
        let file = share.root.appendingPathComponent("known.txt")
        try Data("before".utf8).write(to: file)
        let hostFS = try HostFS(rootPath: share.root.path)
        _ = try hostFS.lookup(parent: HostFS.rootNodeID, name: "known.txt")
        let capability = try hostCoherenceCapability(3)
        let exchange = HostCoherenceExchangeRecorder(failFirstAttempt: true)
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 103),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }
        try relay.activate()

        try runExternal("/usr/bin/touch", [file.path])
        relay.flushObservationStreams()

        #expect(try await waitForAttempts(2, in: exchange))
        let frames = exchange.exactFrames
        #expect(frames.count >= 2)
        if frames.count >= 2 { #expect(frames[0] == frames[1]) }
        #expect(failures.error == nil)
        #expect(relay.statistics.deliveredBatchCount >= 1)
    }

    @Test func deliveryActivationReconcilesKnownInodeWithoutWaitingForFSEvents() throws {
        let share = try CoherenceTemporaryShare()
        let file = share.root.appendingPathComponent("edited-during-boot.txt")
        try Data("before".utf8).write(to: file)
        let hostFS = try HostFS(rootPath: share.root.path)
        let entry = try hostFS.lookup(parent: HostFS.rootNodeID, name: file.lastPathComponent)
        let capability = try hostCoherenceCapability(8)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 108),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }

        try relay.prepare()
        let prepared = relay.statistics
        #expect(!prepared.running)
        #expect(prepared.requiredObservationShareCount == 1)
        #expect(prepared.observedRequiredShareCount == 1)
        #expect(prepared.observationStreamCount == 1)

        try runExternal("/usr/bin/touch", [file.path])
        // Do not wait for the FSEvents callback. The activation-time known-inode sweep must make
        // cache safety independent of when fseventsd journals this edit.
        try relay.activateDelivery()

        #expect(relay.statistics.running)
        #expect(exchange.containsInodeInvalidation(entry.nodeID))
        #expect(relay.statistics.deliveredBatchCount >= 1)
        #expect(failures.error == nil)
    }

    @Test func activationIsNotPublishedUntilCatchupAcknowledgementCompletes() async throws {
        let share = try CoherenceTemporaryShare()
        let file = share.root.appendingPathComponent("blocked-activation.txt")
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(10)
        let exchange = BlockingHostCoherenceExchange()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 110),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer {
            exchange.release()
            relay.stop()
        }

        try relay.prepare()
        try runExternal("/usr/bin/touch", [file.path])
        #expect(try await waitForPendingEvent(in: relay))

        let first = Task.detached { try relay.activateDelivery() }
        #expect(try await exchange.waitUntilBlocked())
        #expect(!relay.statistics.running)

        let secondCompletion = HostCoherenceCompletionRecorder()
        let second = Task.detached {
            try relay.activateDelivery()
            secondCompletion.record()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!secondCompletion.completed)
        #expect(!relay.statistics.running)

        exchange.release()
        try await first.value
        try await second.value

        #expect(secondCompletion.completed)
        #expect(relay.statistics.running)
        #expect(exchange.containsNudge(file.lastPathComponent))
        #expect(failures.error == nil)
    }

    @Test func activationReplayRetainsCallbackContextUntilQueueDrain() async throws {
        let share = try CoherenceTemporaryShare()
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(11)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let cleanup = HostCoherenceBlockingHook()
        let completion = HostCoherenceCompletionRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 111),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        relay.activationReplayCleanupQueueTestHook = cleanup.block
        defer {
            cleanup.release()
            relay.stop()
        }

        try relay.prepare()
        let activation = Task.detached {
            try relay.activateDelivery()
            completion.record()
        }
        #expect(try await cleanup.waitUntilBlocked())
        #expect(!completion.completed)
        #expect(!relay.statistics.running)

        cleanup.release()
        try await activation.value

        #expect(completion.completed)
        #expect(relay.statistics.running)
        #expect(failures.error == nil)
    }

    @Test func ignoreSelfSuppressesWorkerMutationButAcceptsDifferentPID() async throws {
        let share = try CoherenceTemporaryShare()
        let hostFS = try HostFS(rootPath: share.root.path)
        let capability = try hostCoherenceCapability(4)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 104),
            shares: [(capability, hostFS, .invalidationAndWatcherNudge)],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }
        try relay.activate()
        let activationFrameCount = exchange.exactFrames.count

        try Data("guest write".utf8).write(
            to: share.root.appendingPathComponent("same-worker-pid.txt")
        )
        relay.flushObservationStreams()
        try await Task.sleep(nanoseconds: 50_000_000)
        relay.flushObservationStreams()
        #expect(exchange.exactFrames.count == activationFrameCount)

        try runExternal("/usr/bin/touch", [
            share.root.appendingPathComponent("different-pid.txt").path,
        ])
        relay.flushObservationStreams()
        #expect(try await waitForNudge("different-pid.txt", in: exchange))
        #expect(failures.error == nil)
    }

    @Test func readOnlyIdenticalAndNestedRootsRouteToEveryCapability() async throws {
        let share = try CoherenceTemporaryShare()
        let nested = share.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let file = nested.appendingPathComponent("shared.txt")
        try Data("before".utf8).write(to: file)
        let outer = try HostFS(rootPath: share.root.path, readOnly: true)
        let innerFirst = try HostFS(rootPath: nested.path, readOnly: true)
        let innerSecond = try HostFS(rootPath: nested.path, readOnly: true)
        let nestedEntry = try outer.lookup(parent: HostFS.rootNodeID, name: "nested")
        _ = try outer.lookup(parent: nestedEntry.nodeID, name: "shared.txt")
        _ = try innerFirst.lookup(parent: HostFS.rootNodeID, name: "shared.txt")
        _ = try innerSecond.lookup(parent: HostFS.rootNodeID, name: "shared.txt")
        let outerCapability = try hostCoherenceCapability(5)
        let innerFirstCapability = try hostCoherenceCapability(6)
        let innerSecondCapability = try hostCoherenceCapability(7)
        let exchange = HostCoherenceExchangeRecorder()
        let failures = HostCoherenceFailureRecorder()
        let relay = try DoryFSWorkerHostCoherence(
            generation: DoryFSWorkerGeneration(rawValue: 105),
            shares: [
                (outerCapability, outer, .invalidationOnly),
                (innerFirstCapability, innerFirst, .invalidationOnly),
                (innerSecondCapability, innerSecond, .invalidationOnly),
            ],
            exchange: exchange.exchange,
            onFailure: failures.record
        )
        defer { relay.stop() }
        try relay.activate()
        let active = relay.statistics
        #expect(active.configuredShareCount == 3)
        #expect(active.invalidationOnlyShareCount == 3)
        #expect(active.observationStreamCount == 3)
        #expect(active.observedRequiredShareCount == 3)

        try runExternal("/usr/bin/touch", [file.path])
        relay.flushObservationStreams()

        let capabilities = Set([outerCapability, innerFirstCapability, innerSecondCapability])
        #expect(try await waitForCapabilities(capabilities, in: exchange))
        let batches = exchange.recordedBatches.filter {
            capabilities.contains($0.shareCapabilityID)
        }
        #expect(Set(batches.map(\.shareCapabilityID)) == capabilities)
        #expect(batches.allSatisfy { !$0.invalidations.isEmpty })
        #expect(batches.allSatisfy { $0.nudgeRelativePaths.isEmpty })
        #expect(failures.error == nil)
    }
}

private enum HostCoherenceRecorderError: Error {
    case transientFailure
    case processFailed(Int32)
    case timedOut
}

private final class HostCoherenceExchangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failFirstAttempt: Bool
    private var frames = [Data]()
    private var batches = [DoryFSWorkerCoherenceBatch]()

    init(failFirstAttempt: Bool = false) {
        self.failFirstAttempt = failFirstAttempt
    }

    var exactFrames: [Data] { lock.withLock { frames } }
    var recordedBatches: [DoryFSWorkerCoherenceBatch] { lock.withLock { batches } }

    func containsNudge(_ path: String) -> Bool {
        lock.withLock { batches.contains { $0.nudgeRelativePaths.contains(path) } }
    }

    func containsInodeInvalidation(_ nodeID: UInt64) -> Bool {
        lock.withLock {
            batches.contains { batch in
                batch.invalidations.contains { invalidation in
                    if case .inode(let candidate, _, _) = invalidation {
                        return candidate == nodeID
                    }
                    return false
                }
            }
        }
    }

    func exchange(_ frame: Data) throws -> Data {
        let batch = try DoryFSWorkerCoherenceCodec.decodeBatch(frame)
        let attempt = lock.withLock { () -> Int in
            frames.append(frame)
            batches.append(batch)
            return frames.count
        }
        if failFirstAttempt, attempt == 1 {
            throw HostCoherenceRecorderError.transientFailure
        }
        return DoryFSWorkerCoherenceCodec.encode(
            try DoryFSWorkerCoherenceAcknowledgement(accepting: batch)
        )
    }
}

private final class BlockingHostCoherenceExchange: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    private var batches = [DoryFSWorkerCoherenceBatch]()

    func exchange(_ frame: Data) throws -> Data {
        let batch = try DoryFSWorkerCoherenceCodec.decodeBatch(frame)
        condition.lock()
        batches.append(batch)
        blocked = true
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 5)
        while !released {
            guard condition.wait(until: deadline) else {
                condition.unlock()
                throw HostCoherenceRecorderError.timedOut
            }
        }
        condition.unlock()
        return DoryFSWorkerCoherenceCodec.encode(
            try DoryFSWorkerCoherenceAcknowledgement(accepting: batch)
        )
    }

    func waitUntilBlocked() async throws -> Bool {
        for _ in 0..<200 {
            if condition.withLock({ blocked }) { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func containsNudge(_ path: String) -> Bool {
        condition.withLock {
            batches.contains { $0.nudgeRelativePaths.contains(path) }
        }
    }
}

private final class HostCoherenceCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    var completed: Bool { lock.withLock { didComplete } }

    func record() {
        lock.withLock { didComplete = true }
    }
}

private final class HostCoherenceBlockingHook: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    func block() {
        condition.lock()
        blocked = true
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 5)
        while !released, condition.wait(until: deadline) {}
        condition.unlock()
    }

    func waitUntilBlocked() async throws -> Bool {
        for _ in 0..<200 {
            if condition.withLock({ blocked }) { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private final class HostCoherenceFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DoryFSWorkerHostCoherenceError?

    var error: DoryFSWorkerHostCoherenceError? { lock.withLock { stored } }

    func record(_ error: DoryFSWorkerHostCoherenceError) {
        lock.withLock {
            if stored == nil { stored = error }
        }
    }
}

private final class CoherenceTemporaryShare {
    let base: URL
    let root: URL
    let staging: URL

    init(stagingContents: Data? = nil) throws {
        base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
            "dory-host-coherence-\(UUID().uuidString)",
            isDirectory: true
        )
        root = base.appendingPathComponent("share", isDirectory: true)
        staging = base.appendingPathComponent("staging", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let stagingContents { try stagingContents.write(to: staging) }
    }

    deinit { try? FileManager.default.removeItem(at: base) }
}

private func hostCoherenceCapability(_ byte: UInt8) throws -> DoryFSShareCapabilityID {
    try DoryFSShareCapabilityID(rawValue: UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 1, byte
    )))
}

private func runExternal(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw HostCoherenceRecorderError.processFailed(process.terminationStatus)
    }
}

private func waitForPathToExist(_ path: String) async throws -> Bool {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: path) { return true }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

private func waitForPendingEvent(
    in relay: DoryFSWorkerHostCoherence
) async throws -> Bool {
    for _ in 0..<200 {
        relay.flushObservationStreams()
        if relay.statistics.pendingEventCount > 0 { return true }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

private func waitForNudge(
    _ path: String,
    in recorder: HostCoherenceExchangeRecorder
) async throws -> Bool {
    for _ in 0..<200 {
        if recorder.containsNudge(path) { return true }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

private func waitForAttempts(
    _ count: Int,
    in recorder: HostCoherenceExchangeRecorder
) async throws -> Bool {
    for _ in 0..<200 {
        if recorder.exactFrames.count >= count { return true }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

private func waitForCapabilities(
    _ capabilities: Set<DoryFSShareCapabilityID>,
    in recorder: HostCoherenceExchangeRecorder
) async throws -> Bool {
    for _ in 0..<200 {
        let observed = Set(recorder.recordedBatches.map(\.shareCapabilityID))
        if capabilities.isSubset(of: observed) { return true }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}
