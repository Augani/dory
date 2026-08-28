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
        try relay.activate()

        #expect(try await waitForNudge("atomic-install.txt", in: exchange))
        #expect(failures.error == nil)
        let active = relay.statistics
        #expect(active.running)
        #expect(active.requiredObservationShareCount == active.observedRequiredShareCount)
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

        try Data("guest write".utf8).write(
            to: share.root.appendingPathComponent("same-worker-pid.txt")
        )
        relay.flushObservationStreams()
        try await Task.sleep(nanoseconds: 50_000_000)
        relay.flushObservationStreams()
        #expect(exchange.exactFrames.isEmpty)

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
