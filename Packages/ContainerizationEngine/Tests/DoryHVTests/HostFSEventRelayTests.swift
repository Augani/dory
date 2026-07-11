import CoreServices
import Foundation
import Testing
@testable import DoryHV

struct HostFSEventRelayTests {
    @Test func productionStreamUsesBoundedDirectoryEventsAndSelfFiltering() {
        let flags = HostFSEventRelay.streamCreateFlags
        #expect(flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) == 0)
        #expect(flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer) == 0)
        #expect(flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf) != 0)
        #expect(flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot) != 0)
    }

    @Test func streamProcessingQueuePreservesDeliveredBatchOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-fsevents-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = BatchSink()
        let relay = HostFSEventRelay(
            shares: [HostFSEventShare(hostRoot: root.path, guestRoot: "/work")],
            debounceMilliseconds: 1,
            send: { changes in await sink.append(changes) }
        )
        #expect(relay.start())
        defer { relay.stop() }

        relay.recordFromStream(
            hostPaths: [root.appendingPathComponent("first").path],
            flags: [0],
            eventIDs: [1]
        )
        relay.recordFromStream(
            hostPaths: [root.appendingPathComponent("second").path],
            flags: [0],
            eventIDs: [2]
        )
        for _ in 0..<100 where await sink.batches.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let flattened = await sink.batches.flatMap { $0.map(\.guestPath) }
        #expect(flattened == ["/work/first", "/work/second"])
    }
    @Test func productionSharesRequireAStartedRelayIncludingReadOnlyShares() throws {
        #expect(throws: HostShareCoherenceStartupError.eventRelayUnavailable(
            productionShareCount: 1
        )) {
            try HostShareCoherenceStartupPolicy.requireEventRelay(
                started: false,
                productionShareCount: 1
            )
        }

        // EngineMode counts every configured production endpoint, not only writable endpoints.
        // No relay is required only when there is no production host share at all.
        try HostShareCoherenceStartupPolicy.requireEventRelay(
            started: true,
            productionShareCount: 1
        )
        try HostShareCoherenceStartupPolicy.requireEventRelay(
            started: false,
            productionShareCount: 0
        )
    }

    @Test func defaultRelayDebounceIsOneMillisecond() {
        // FSEvents already coalesces a callback. Keep only a minimal cross-callback window instead
        // of adding the former 50 ms delay to every host replacement.
        #expect(HostFSEventRelay.defaultDebounceMilliseconds == 1)
    }

    @Test func streamWatchesRootAndIgnoresSelfOriginatedGuestMutations() {
        let flags = HostFSEventRelay.streamCreateFlags
        #expect((flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) != 0)
        #expect((flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)) != 0)
        #expect((flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagMarkSelf)) != 0)
        #expect((flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) == 0)
        #expect(HostFSEventRelay.ignoresOwnEvent(UInt32(kFSEventStreamEventFlagOwnEvent)))
        #expect(!HostFSEventRelay.ignoresOwnEvent(UInt32(kFSEventStreamEventFlagItemModified)))
    }

    @Test func mapsHostPathsIntoLongestMatchingGuestShare() async throws {
        let batcher = FSEventBatcher(
            shares: [
                HostFSEventShare(hostRoot: "/Users/me", guestRoot: "/Users/me"),
                HostFSEventShare(hostRoot: "/Users/me/Project", guestRoot: "/workspace"),
            ],
            send: { _ in }
        )

        #expect(batcher.mapHostPathToGuest("/Users/me") == "/Users/me")
        #expect(batcher.mapHostPathToGuest("/Users/me/Project/Sources/App.swift") == "/workspace/Sources/App.swift")
        #expect(batcher.mapHostPathToGuest("/Users/melissa/file") == nil)
    }

    @Test func coalescesFlagsAndKeepsLatestEventIDPerPath() async throws {
        let sink = BatchSink()
        let batcher = FSEventBatcher(
            shares: [HostFSEventShare(hostRoot: "/host", guestRoot: "/guest")],
            send: { changes in await sink.append(changes) }
        )

        batcher.enqueue(
            hostPaths: ["/host/b.txt", "/host/a.txt", "/host/b.txt", "/outside/nope"],
            flags: [1, 2, 4, 8],
            eventIDs: [10, 11, 12, 13]
        )
        try await batcher.flushNow()
        try await batcher.flushNow()

        let batches = await sink.batches
        #expect(batches.count == 1)
        #expect(batches[0].map(\.guestPath) == ["/guest/a.txt", "/guest/b.txt"])
        #expect(batches[0][1].flags == 5)
        #expect(batches[0][1].eventID == 12)
    }

    @Test func failedSendIsRequeuedInsteadOfDropped() async throws {
        let sink = BatchSink(failuresRemaining: 1)
        let batcher = FSEventBatcher(
            shares: [HostFSEventShare(hostRoot: "/host", guestRoot: "/guest")],
            send: { changes in try await sink.appendOrFail(changes) }
        )
        batcher.enqueue(hostPaths: ["/host/a.txt"])

        await #expect(throws: BatchSink.Failure.self) {
            try await batcher.flushNow()
        }
        #expect(batcher.hasPending)
        try await batcher.flushNow()
        #expect(await sink.batches.map { $0.map(\.guestPath) } == [["/guest/a.txt"]])
    }

    @Test func stopDuringFailedDetachedFlushSuppressesFailureAndRetry() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fsevent-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sender = SuspendedFailingRelaySender()
        let failures = RelayFailureRecorder()
        let relay = HostFSEventRelay(
            shares: [HostFSEventShare(hostRoot: root.path, guestRoot: "/guest")],
            debounceMilliseconds: 1,
            send: { changes in try await sender.send(changes) },
            onFailure: { error in failures.append(error) }
        )
        defer { relay.stop() }
        #expect(relay.start())

        relay.record(hostPaths: [root.appendingPathComponent("pending.txt").path])
        await sender.waitUntilFirstAttemptStarts()
        relay.stop()
        await sender.releaseFirstAttempt()

        // Give the detached flush enough time to observe its failure and, if shutdown fencing is
        // broken, schedule the 2 ms retry. Neither callback is allowed after stop returns.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await sender.attemptCount == 1)
        #expect(failures.count == 0)
    }

    @Test func pendingWorkIsBoundedAndCollapsesToLossAwareRootRecovery() async throws {
        let sink = BatchSink()
        let batcher = FSEventBatcher(
            shares: [HostFSEventShare(hostRoot: "/host", guestRoot: "/guest")],
            pendingLimit: 2,
            send: { changes in await sink.append(changes) }
        )

        batcher.enqueue(
            hostPaths: ["/host/a", "/host/b", "/host/c", "/host/d"],
            flags: [0, 0, 0, 0],
            eventIDs: [1, 2, 3, 4]
        )
        #expect(batcher.pendingCount == 1)
        try await batcher.flushNow()

        let batch = try #require(await sink.batches.first)
        #expect(batch.count == 1)
        #expect(batch[0].hostPath == "/host")
        #expect(batch[0].requiresRescan)
        #expect(batch[0].eventID == 4)
    }

    @Test func defaultBatcherAcceptsANpmScaleDistinctPathBurstWithoutInventingLoss() async throws {
        let sink = BatchSink()
        let batcher = FSEventBatcher(
            shares: [HostFSEventShare(hostRoot: "/host", guestRoot: "/guest")],
            send: { changes in await sink.append(changes) }
        )
        let count = 12_000
        batcher.enqueue(
            hostPaths: (0..<count).map { "/host/node_modules/package-\($0)/index.js" },
            flags: Array(repeating: UInt32(kFSEventStreamEventFlagItemModified), count: count),
            eventIDs: (1...count).map(UInt64.init)
        )

        #expect(FSEventBatcher.defaultPendingLimit >= count)
        #expect(batcher.pendingCount == count)
        try await batcher.flushNow()

        let batch = try #require(await sink.batches.first)
        #expect(batch.count == count)
        #expect(batch.filter { $0.requiresRescan }.isEmpty)
    }

    @Test func nudgeTargetFallsBackToExistingParentWithoutLeavingShare() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fsevent-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let share = HostFSEventShare(hostRoot: root.path, guestRoot: "/workspace")

        let target = try #require(share.nudgeTarget(forHostPath: nested.appendingPathComponent("deleted.ts").path))
        #expect(target.host == nested.path)
        #expect(target.guest == "/workspace/src")
        #expect(share.nudgeTarget(forHostPath: root.deletingLastPathComponent().appendingPathComponent("outside").path) == nil)
    }

    @Test func mapsBothSuppliedSymlinkAndCanonicalFSEventRootSpellings() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fsevent-alias-\(UUID().uuidString)", isDirectory: true)
        let real = parent.appendingPathComponent("real", isDirectory: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: parent) }
        let share = HostFSEventShare(hostRoot: alias.path, guestRoot: "/workspace")

        #expect(share.mapHostPathToGuest(alias.appendingPathComponent("src/a.ts").path) == "/workspace/src/a.ts")
        #expect(share.mapHostPathToGuest(real.appendingPathComponent("src/a.ts").path) == "/workspace/src/a.ts")
        #expect(Set(share.hostRootAliases) == Set([alias.path, real.path]))
    }

    @Test func suppressionConsumesExactlyOneLaterMetadataEcho() throws {
        let suppressor = FSEventEchoSuppressor(limit: 2, lifetimeSeconds: 1)
        let metadata = UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsFile)
        let chmodMetadata = UInt32(kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemIsFile)
        let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        try suppressor.register(hostPath: "/host/a", sourceEventID: 10, now: 100)
        try suppressor.register(hostPath: "/host/a", sourceEventID: 10, now: 100)

        #expect(!suppressor.consumeIfSyntheticEcho(
            .init(hostPath: "/host/a", guestPath: "/guest/a", flags: content, eventID: 11),
            now: 100.1
        ))
        #expect(suppressor.consumeIfSyntheticEcho(
            .init(hostPath: "/host/a", guestPath: "/guest/a", flags: metadata, eventID: 11),
            now: 100.2
        ))
        #expect(suppressor.consumeIfSyntheticEcho(
            .init(hostPath: "/host/a", guestPath: "/guest/a", flags: chmodMetadata, eventID: 12),
            now: 100.3
        ))
        #expect(!suppressor.consumeIfSyntheticEcho(
            .init(hostPath: "/host/a", guestPath: "/guest/a", flags: metadata, eventID: 13),
            now: 100.4
        ))
    }

    @Test func droppedEventsRequireRescanAndAreNeverSuppressible() {
        let flags = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagItemInodeMetaMod
        )
        let change = HostFSEventChange(hostPath: "/host", guestPath: "/guest", flags: flags, eventID: 99)
        #expect(change.requiresRescan)
        #expect(!change.isMetadataOnly)
    }

    @Test func distinguishesRemovedAndOldRenamePathsFromRenameDestinations() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fsevent-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("new.ts")
        try Data("new".utf8).write(to: existing)
        let renameFlags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)

        #expect(HostFSEventChange(
            hostPath: root.appendingPathComponent("old.ts").path,
            guestPath: "/work/old.ts",
            flags: renameFlags,
            eventID: 1
        ).representsRemoval)
        #expect(!HostFSEventChange(
            hostPath: existing.path,
            guestPath: "/work/new.ts",
            flags: renameFlags,
            eventID: 2
        ).representsRemoval)
        #expect(!HostFSEventChange(
            hostPath: existing.path,
            guestPath: "/work/new.ts",
            flags: UInt32(kFSEventStreamEventFlagItemRemoved),
            eventID: 3
        ).representsRemoval)
        #expect(!HostFSEventChange(
            hostPath: existing.path,
            guestPath: "/work/new.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemCreated
            ),
            eventID: 4
        ).representsRemoval)
        #expect(HostFSEventChange(
            hostPath: root.appendingPathComponent("deleted.ts").path,
            guestPath: "/work/deleted.ts",
            flags: UInt32(kFSEventStreamEventFlagItemRemoved),
            eventID: 5
        ).representsRemoval)
    }
}

private actor BatchSink {
    struct Failure: Error {}

    private(set) var batches: [[HostFSEventChange]] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func append(_ changes: [HostFSEventChange]) {
        batches.append(changes)
    }

    func appendOrFail(_ changes: [HostFSEventChange]) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure()
        }
        batches.append(changes)
    }
}

private actor SuspendedFailingRelaySender {
    struct Failure: Error {}

    private(set) var attemptCount = 0
    private var firstAttemptRelease: CheckedContinuation<Void, Never>?
    private var firstAttemptWaiters = [CheckedContinuation<Void, Never>]()

    func send(_ changes: [HostFSEventChange]) async throws {
        _ = changes
        attemptCount += 1
        if attemptCount == 1 {
            await withCheckedContinuation { continuation in
                firstAttemptRelease = continuation
                let waiters = firstAttemptWaiters
                firstAttemptWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters { waiter.resume() }
            }
        }
        throw Failure()
    }

    func waitUntilFirstAttemptStarts() async {
        guard firstAttemptRelease == nil else { return }
        await withCheckedContinuation { continuation in
            firstAttemptWaiters.append(continuation)
        }
    }

    func releaseFirstAttempt() {
        firstAttemptRelease?.resume()
        firstAttemptRelease = nil
    }
}

private final class RelayFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = [any Error]()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }

    func append(_ error: any Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
