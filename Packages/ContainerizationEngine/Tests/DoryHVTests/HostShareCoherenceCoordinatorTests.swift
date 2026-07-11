import CoreServices
import Foundation
import Testing
@testable import DoryHV

struct HostShareCoherenceCoordinatorTests {
    @Test func relayFailureClosesReadinessGateUntilPendingBatchSucceeds() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: RecordingGuestFSEventSender()
        )

        #expect(await coordinator.relayDeliveryIsCaughtUp)
        coordinator.relayDeliveryFailed("guest still booting")
        #expect(await !coordinator.relayDeliveryIsCaughtUp)
        #expect(!fixture.backend.coherentCachingActive)

        coordinator.relayDeliverySucceeded()
        #expect(await coordinator.relayDeliveryIsCaughtUp)
    }

    @Test func cacheReadinessDoesNotProbeGuestBeforeVirtioFSIsEligible() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let guest = RecordingGuestFSEventSender()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: guest
        )

        #expect(try await !coordinator.activateCachingIfReady())
        #expect(await guest.sendCount == 0)
        #expect(!fixture.backend.coherentCachingActive)
    }

    @Test func eventLossRequestsVMRestartInsteadOfPretendingRootInvalidationIsRecursive() async throws {
        let first = try CoherenceFixture()
        let second = try CoherenceFixture()
        defer {
            first.remove()
            second.remove()
        }
        let guest = RecordingGuestFSEventSender()
        let fatals = FatalReasonRecorder(backends: [first.backend, second.backend])
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [first.endpoint, second.endpoint],
            guestEvents: guest,
            onFatalRecoveryRequired: { reason in fatals.append(reason) }
        )
        let dropped = HostFSEventChange(
            hostPath: first.root.path,
            guestPath: "/workspace",
            flags: UInt32(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagKernelDropped
            ),
            eventID: 42
        )

        try await coordinator.process([dropped])

        #expect(await coordinator.isDegraded)
        #expect(!first.backend.coherentCachingActive)
        #expect(!second.backend.coherentCachingActive)
        #expect(await guest.sendCount == 0)
        #expect(fatals.reasons.count == 1)
        #expect(fatals.reasons[0].contains("lost"))
        #expect(fatals.gateSnapshots == [[true, true]])
        #expect(first.backend.requestPublicationGateClosed)
        #expect(second.backend.requestPublicationGateClosed)
        #expect(try await !coordinator.activateCachingIfReady())
    }

    @Test func startupEventCanNudgeInZeroCacheModeBeforeNotificationsAreReady() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("edit.ts")
        try Data("host edit".utf8).write(to: file)
        let guest = RecordingGuestFSEventSender()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: guest
        )

        try await coordinator.process([HostFSEventChange(
            hostPath: file.path,
            guestPath: "/workspace/edit.ts",
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            eventID: 7
        )])

        #expect(await !coordinator.isDegraded)
        #expect(await guest.batches == [["/workspace/edit.ts"]])
    }

    @Test func directoryAggregateExpandsOnlyToKnownImmediatePathsWithContentInvalidation() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("edit.ts")
        try Data("host edit".utf8).write(to: file)
        let entry = try fixture.backend.hostFS.lookup(parent: HostFS.rootNodeID, name: "edit.ts")

        let expanded = HostShareCoherenceCoordinator.expandedDirectoryChange(HostFSEventChange(
            hostPath: fixture.root.path,
            guestPath: "/workspace",
            flags: 0,
            eventID: 8,
            isDirectoryAggregate: true
        ), endpoint: fixture.endpoint)

        #expect(expanded.map(\.guestPath) == ["/workspace", "/workspace/edit.ts"])
        let fileChange = try #require(expanded.first { $0.guestPath == "/workspace/edit.ts" })
        let snapshot = try #require(fixture.backend.hostFS.invalidationSnapshot(forHostPath: file.path))
        let invalidations = HostShareCoherenceCoordinator.plannedInvalidations(
            for: fileChange,
            snapshot: snapshot
        ).values
        #expect(invalidations.contains(.inode(nodeID: entry.nodeID, offset: 0, length: -1)))
    }

    @Test func atomicReplacementDeletesStaleIdentityWithoutInvalidatingItsPages() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("atomic.ts")
        try Data("replacement".utf8).write(to: file)
        let change = HostFSEventChange(
            hostPath: file.path,
            guestPath: "/workspace/atomic.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemCreated
            ),
            eventID: 70
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [20, 21],
                staleNodeIDs: [20],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "atomic.ts"
            )
        ).values)

        #expect(invalidations.contains(.delete(
            parentNodeID: HostFS.rootNodeID,
            childNodeID: 20,
            name: "atomic.ts"
        )))
        #expect(invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "atomic.ts"
        )))
        #expect(invalidations.contains(.inode(nodeID: 21, offset: -1, length: 0)))
        #expect(invalidations.contains(.inode(nodeID: 20, offset: -1, length: 0)))
        #expect(!invalidations.contains(.inode(nodeID: 20, offset: 0, length: -1)))
        #expect(invalidations.count == 4)
    }

    @Test func nonFinalAtomicReplacementPreservesOldAliasPagesAndInvalidatesNewData() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let replaced = fixture.root.appendingPathComponent("atomic-alias.ts")
        try Data("replacement".utf8).write(to: replaced)
        let change = HostFSEventChange(
            hostPath: replaced.path,
            guestPath: "/workspace/atomic-alias.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 701
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [22, 23],
                staleNodeIDs: [22],
                survivingLinkNodeIDs: [22],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "atomic-alias.ts"
            )
        ).values)

        #expect(invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "atomic-alias.ts"
        )))
        #expect(invalidations.contains(.inode(nodeID: 22, offset: -1, length: 0)))
        #expect(!invalidations.contains(.inode(nodeID: 22, offset: 0, length: -1)))
        #expect(!invalidations.containsDelete(childNodeID: 22))
        #expect(invalidations.contains(.inode(nodeID: 23, offset: 0, length: -1)))
        #expect(invalidations.count == 3)
    }

    @Test func removalDeletesOldIdentityWithoutInvalidatingItsPagesOrReplacementEntry() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("removed.ts")
        let change = HostFSEventChange(
            hostPath: missing.path,
            guestPath: "/workspace/removed.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 71
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [30],
                staleNodeIDs: [30],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "removed.ts"
            )
        ).values)

        #expect(invalidations.contains(.delete(
            parentNodeID: HostFS.rootNodeID,
            childNodeID: 30,
            name: "removed.ts"
        )))
        #expect(invalidations.contains(.inode(nodeID: 30, offset: -1, length: 0)))
        #expect(!invalidations.contains(.inode(nodeID: 30, offset: 0, length: -1)))
        #expect(invalidations.count == 2)
    }

    @Test func nonFinalHardLinkRemovalInvalidatesOnlyEntryAndLinkCount() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let missingAlias = fixture.root.appendingPathComponent("removed-alias.ts")
        let change = HostFSEventChange(
            hostPath: missingAlias.path,
            guestPath: "/workspace/removed-alias.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 711
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [31],
                staleNodeIDs: [31],
                survivingLinkNodeIDs: [31],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "removed-alias.ts"
            )
        ).values)

        #expect(invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "removed-alias.ts"
        )))
        #expect(invalidations.contains(.inode(nodeID: 31, offset: -1, length: 0)))
        #expect(!invalidations.containsDelete(childNodeID: 31))
        #expect(!invalidations.contains(.inode(nodeID: 31, offset: 0, length: -1)))
        #expect(invalidations.count == 2)
    }

    @Test func renameSourceDeletesItsDentryEvenWhenTheMovedInodeStillHasALink() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("renamed-away.ts")
        let destination = fixture.root.appendingPathComponent("renamed-to.ts")
        try Data("moved".utf8).write(to: source)
        try FileManager.default.moveItem(at: source, to: destination)
        let change = HostFSEventChange(
            hostPath: source.path,
            guestPath: "/workspace/renamed-away.ts",
            flags: UInt32(kFSEventStreamEventFlagItemRenamed),
            eventID: 714
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [33],
                staleNodeIDs: [33],
                // The moved inode has nlink=1 through its new, not-yet-looked-up name. This is
                // not an ordinary surviving hard-link alias: the old dentry must be deleted.
                survivingLinkNodeIDs: [33],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "renamed-away.ts"
            )
        ).values)

        #expect(invalidations.contains(.delete(
            parentNodeID: HostFS.rootNodeID,
            childNodeID: 33,
            name: "renamed-away.ts"
        )))
        #expect(invalidations.contains(.inode(nodeID: 33, offset: -1, length: 0)))
        #expect(!invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "renamed-away.ts"
        )))
    }

    @Test func removalFlagsFannedToSurvivingAliasDoNotDeleteItsCurrentDentry() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let survivingAlias = fixture.root.appendingPathComponent("surviving-alias.ts")
        try Data("still linked".utf8).write(to: survivingAlias)
        let change = HostFSEventChange(
            hostPath: survivingAlias.path,
            guestPath: "/workspace/surviving-alias.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 712,
            permitsContentInvalidation: false
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [32],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "surviving-alias.ts"
            )
        ).values)

        #expect(invalidations == [.inode(nodeID: 32, offset: -1, length: 0)])
        #expect(!invalidations.containsDelete(childNodeID: 32))
    }

    @Test func hostHardLinkSnapshotPlansEntryNotDeleteForRemovedAlias() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let removed = fixture.root.appendingPathComponent("removed.txt")
        let surviving = fixture.root.appendingPathComponent("surviving.txt")
        try Data("shared".utf8).write(to: removed)
        try FileManager.default.linkItem(at: removed, to: surviving)
        let hostFS = fixture.backend.hostFS
        let first = try hostFS.lookup(parent: HostFS.rootNodeID, name: "removed.txt")
        #expect(
            try hostFS.lookup(parent: HostFS.rootNodeID, name: "surviving.txt").nodeID
                == first.nodeID
        )
        try FileManager.default.removeItem(at: removed)

        let removedChange = HostFSEventChange(
            hostPath: removed.path,
            guestPath: "/workspace/removed.txt",
            flags: UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 713
        )
        let removedSnapshot = try #require(hostFS.invalidationSnapshot(forHostPath: removed.path))
        let removedInvalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: removedChange,
            snapshot: removedSnapshot
        ).values)

        #expect(removedSnapshot.survivingLinkNodeIDs == [first.nodeID])
        #expect(removedInvalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "removed.txt"
        )))
        #expect(removedInvalidations.contains(.inode(
            nodeID: first.nodeID,
            offset: -1,
            length: 0
        )))
        #expect(!removedInvalidations.containsDelete(childNodeID: first.nodeID))

        // Alias fanout reuses the original removal flags. The surviving pathname is current, so it
        // receives only nlink/attribute invalidation and keeps its dentry.
        let survivingChange = HostFSEventChange(
            hostPath: surviving.path,
            guestPath: "/workspace/surviving.txt",
            flags: removedChange.flags,
            eventID: removedChange.eventID,
            permitsContentInvalidation: false
        )
        let survivingSnapshot = try #require(hostFS.invalidationSnapshot(forHostPath: surviving.path))
        let survivingInvalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: survivingChange,
            snapshot: survivingSnapshot
        ).values)
        #expect(survivingInvalidations == [.inode(
            nodeID: first.nodeID,
            offset: -1,
            length: 0
        )])
    }

    @Test func inPlaceContentChangeInvalidatesCurrentInodeDataPages() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("content.ts")
        try Data("changed in place".utf8).write(to: file)
        let change = HostFSEventChange(
            hostPath: file.path,
            guestPath: "/workspace/content.ts",
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            eventID: 72
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [40],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "content.ts"
            )
        ).values)

        #expect(invalidations.contains(.inode(nodeID: 40, offset: 0, length: -1)))
        // No ENTRY invalidation: the pinned identity is verified unchanged, so the dentry still
        // maps to the same inode. fuse_reverse_inval_entry runs d_invalidate, which detaches every
        // mount below the dentry — an in-place sibling write must never unmount a container bind.
        #expect(!invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "content.ts"
        )))
        #expect(invalidations.count == 1)
    }

    @Test func coalescedCreateAndModifyStillInvalidatesCurrentInodeDataPages() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("created-and-modified.ts")
        try Data("host write".utf8).write(to: file)
        let change = HostFSEventChange(
            hostPath: file.path,
            guestPath: "/workspace/created-and-modified.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemModified
            ),
            eventID: 721
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [41],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "created-and-modified.ts"
            )
        ).values)

        #expect(invalidations == [.inode(nodeID: 41, offset: 0, length: -1)])
    }

    @Test func metadataAndXattrChangesInvalidateAttributesWithoutTouchingDataPages() throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("metadata.ts")
        try Data("unchanged data".utf8).write(to: file)
        let change = HostFSEventChange(
            hostPath: file.path,
            guestPath: "/workspace/metadata.ts",
            flags: UInt32(
                kFSEventStreamEventFlagItemInodeMetaMod |
                kFSEventStreamEventFlagItemXattrMod
            ),
            eventID: 73
        )
        let invalidations = Array(HostShareCoherenceCoordinator.plannedInvalidations(
            for: change,
            snapshot: HostFSInvalidationSnapshot(
                nodeIDs: [50],
                parentNodeIDs: [HostFS.rootNodeID],
                entryName: "metadata.ts"
            )
        ).values)

        #expect(invalidations.contains(.inode(nodeID: 50, offset: -1, length: 0)))
        #expect(!invalidations.contains(.inode(nodeID: 50, offset: 0, length: -1)))
        // Metadata-only change with a verified-unchanged identity: attribute invalidation is
        // sufficient; the name→inode mapping did not change so the dentry must survive (see
        // the d_invalidate/mount-detach rationale in plannedInvalidations).
        #expect(!invalidations.contains(.entry(
            parentNodeID: HostFS.rootNodeID,
            name: "metadata.ts"
        )))
        #expect(invalidations.count == 1)
    }

    @Test func overlappingHostSharesFanOutToEveryGuestAlias() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-coherence-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shared.ts")
        try Data("shared".utf8).write(to: file)
        let first = try VirtioFS(tag: "alias-one", hostFS: HostFS(rootPath: root.path))
        let second = try VirtioFS(tag: "alias-two", hostFS: HostFS(rootPath: root.path))
        let guest = RecordingGuestFSEventSender()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [
                HostShareCoherenceEndpoint(
                    share: HostFSEventShare(hostRoot: root.path, guestRoot: "/one"),
                    backend: first
                ),
                HostShareCoherenceEndpoint(
                    share: HostFSEventShare(hostRoot: root.path, guestRoot: "/two"),
                    backend: second
                ),
            ],
            guestEvents: guest
        )

        try await coordinator.process([HostFSEventChange(
            hostPath: file.path,
            guestPath: "/one/shared.ts",
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            eventID: 8
        )])

        #expect(await guest.batches == [["/one/shared.ts", "/two/shared.ts"]])
        #expect(await !coordinator.isDegraded)
    }

    @Test func destinationOnlyNamespaceEventSynthesizesAWatcherNudgeForCachedSource() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("rename-source.txt")
        let destination = fixture.root.appendingPathComponent("rename-destination.txt")
        try Data("source".utf8).write(to: source)
        let known = try fixture.backend.hostFS.lookup(
            parent: HostFS.rootNodeID,
            name: "rename-source.txt"
        )
        fixture.backend.hostFS.retainLookup(nodeID: known.nodeID)
        try FileManager.default.moveItem(at: source, to: destination)
        #expect(
            fixture.backend.hostFS.knownStaleHostPathsForNamespaceReconciliation()
                .map { URL(fileURLWithPath: $0).lastPathComponent } == ["rename-source.txt"]
        )

        let guest = RecordingGuestFSEventSender()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: guest
        )
        try await coordinator.process([HostFSEventChange(
            hostPath: destination.path,
            guestPath: "/workspace/rename-destination.txt",
            // APFS can coalesce a rename into a destination-only ItemCreated event.
            flags: UInt32(kFSEventStreamEventFlagItemCreated),
            eventID: 81
        )])

        // The destination is the only directly nudgeable path when it was not cached before the
        // rename.  Crucially, the synthesized source has already been reconciled so its DELETE
        // notification is emitted before this watcher nudge is delivered.
        #expect(await guest.batches == [["/workspace/rename-destination.txt"]])
        let snapshot = try #require(
            fixture.backend.hostFS.invalidationSnapshot(forHostPath: source.path)
        )
        #expect(snapshot.staleNodeIDs == [known.nodeID])
    }

    @Test func retryUsesExactFailedIndicesWithoutRepeatingSuccessfulPaths() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("a.ts")
        let second = fixture.root.appendingPathComponent("b.ts")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let guest = ScriptedGuestFSEventSender(results: [
            .init(pathCount: 2, failedIndices: [1]), // a.ts succeeded; b.ts is retryable.
            .init(pathCount: 1, failedIndices: []),  // Retry sends only b.ts with a fresh ID.
        ])
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: guest
        )
        let changes = [first, second].map { file in
            HostFSEventChange(
                hostPath: file.path,
                guestPath: "/workspace/\(file.lastPathComponent)",
                flags: UInt32(kFSEventStreamEventFlagItemModified),
                eventID: 10
            )
        }

        await #expect(throws: HostShareCoherenceError.self) {
            try await coordinator.process(changes)
        }
        try await coordinator.process(changes)

        #expect(await guest.batches == [
            ["/workspace/a.ts", "/workspace/b.ts"],
            ["/workspace/b.ts"],
        ])
        let operationIDs = await guest.operationIDs
        #expect(operationIDs.count == 2)
        #expect(operationIDs[0] != operationIDs[1])
    }

    @Test func lostResponseReplaysExactOperationBeforeNewlyMergedTargets() async throws {
        let fixture = try CoherenceFixture()
        defer { fixture.remove() }
        let files = ["a.ts", "b.ts", "c.ts"].map { fixture.root.appendingPathComponent($0) }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
        let guest = ScriptedGuestFSEventSender(steps: [
            .failure(.timedOut),
            .result(.init(pathCount: 2, failedIndices: [])),
            .result(.init(pathCount: 1, failedIndices: [])),
        ])
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [fixture.endpoint],
            guestEvents: guest
        )
        let changes = files.enumerated().map { index, file in
            HostFSEventChange(
                hostPath: file.path,
                guestPath: "/workspace/\(file.lastPathComponent)",
                flags: UInt32(kFSEventStreamEventFlagItemModified),
                eventID: UInt64(20 + index)
            )
        }

        await #expect(throws: GuestFSEventBridgeError.timedOut) {
            try await coordinator.process(Array(changes.prefix(2)))
        }
        try await coordinator.process(changes)

        #expect(await guest.batches == [
            ["/workspace/a.ts", "/workspace/b.ts"],
            ["/workspace/a.ts", "/workspace/b.ts"],
            ["/workspace/c.ts"],
        ])
        let operationIDs = await guest.operationIDs
        #expect(operationIDs[0] == operationIDs[1])
        #expect(operationIDs[1] != operationIDs[2])
    }
}

private extension Array where Element == VirtioFSInvalidation {
    func containsInode(nodeID: UInt64) -> Bool {
        contains { invalidation in
            guard case .inode(let candidate, _, _) = invalidation else { return false }
            return candidate == nodeID
        }
    }

    func containsDelete(childNodeID: UInt64) -> Bool {
        contains { invalidation in
            guard case .delete(_, let candidate, _) = invalidation else { return false }
            return candidate == childNodeID
        }
    }
}

private final class FatalReasonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let backends: [VirtioFS]
    private var storage = [String]()
    private var gateSnapshotStorage = [[Bool]]()

    var reasons: [String] { lock.withLock { storage } }
    var gateSnapshots: [[Bool]] { lock.withLock { gateSnapshotStorage } }

    init(backends: [VirtioFS] = []) {
        self.backends = backends
    }

    func append(_ reason: String) {
        let snapshot = backends.map(\.requestPublicationGateClosed)
        lock.withLock {
            storage.append(reason)
            gateSnapshotStorage.append(snapshot)
        }
    }
}

private final class CoherenceFixture {
    let root: URL
    let backend: VirtioFS
    let endpoint: HostShareCoherenceEndpoint

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-coherence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hostFS = try HostFS(rootPath: root.path)
        backend = try VirtioFS(tag: "coherence", hostFS: hostFS)
        endpoint = HostShareCoherenceEndpoint(
            share: HostFSEventShare(hostRoot: root.path, guestRoot: "/workspace"),
            backend: backend
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecordingGuestFSEventSender: GuestFSEventSending {
    private(set) var sendCount = 0
    private(set) var batches = [[String]]()
    private(set) var operationIDs = [UInt64]()

    func send(operationID: UInt64, paths: [String]) async throws -> GuestFSEventBatchResult {
        sendCount += 1
        operationIDs.append(operationID)
        batches.append(paths)
        return GuestFSEventBatchResult(pathCount: UInt32(paths.count), failedIndices: [])
    }
}

private actor ScriptedGuestFSEventSender: GuestFSEventSending {
    enum Step: Sendable {
        case result(GuestFSEventBatchResult)
        case failure(GuestFSEventBridgeError)
    }

    private var steps: [Step]
    private(set) var batches = [[String]]()
    private(set) var operationIDs = [UInt64]()

    init(results: [GuestFSEventBatchResult]) {
        self.steps = results.map(Step.result)
    }

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(operationID: UInt64, paths: [String]) async throws -> GuestFSEventBatchResult {
        operationIDs.append(operationID)
        batches.append(paths)
        guard !steps.isEmpty else {
            return GuestFSEventBatchResult(pathCount: UInt32(paths.count), failedIndices: [])
        }
        switch steps.removeFirst() {
        case .result(let result): return result
        case .failure(let error): throw error
        }
    }
}
