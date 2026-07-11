import CoreServices
import Foundation

public struct HostShareCoherenceEndpoint: @unchecked Sendable {
    public let share: HostFSEventShare
    public let backend: VirtioFS
    public let watcherNudgesEnabled: Bool

    public init(
        share: HostFSEventShare,
        backend: VirtioFS,
        watcherNudgesEnabled: Bool = true
    ) {
        self.share = share
        self.backend = backend
        self.watcherNudgesEnabled = watcherNudgesEnabled
    }
}

public enum HostShareCoherenceError: Error, Equatable, Sendable {
    case guestNudgeFailed(path: String)
    case guestNudgeOperationExpired(operationID: UInt64)
}

/// Orders host-originated edits so Linux never receives a watcher wakeup while its virtio-fs cache
/// still contains the old object. Batches are actor-serialized; transport failures are retryable,
/// while lossy FSEvents markers permanently return the affected VM to zero-cache safety. When the
/// export root and reverse-notification channel remain intact, loss is recovered in place by
/// invalidating every still-live FUSE identity rather than rebooting the Docker VM.
public actor HostShareCoherenceCoordinator {
    /// Host edits fail closed quickly: dirty guest writeback was observed escaping a two-second
    /// reverse-notification wait. VirtioFS keeps its generic timeout; coherence uses this tighter
    /// deadline so the VM restart boundary wins before delayed dirty pages can overwrite host data.
    static let reverseInvalidationFailCloseDeadline: Duration = .seconds(1)

    private let endpoints: [HostShareCoherenceEndpoint]
    private let guestEvents: any GuestFSEventSending
    private let onDegraded: @Sendable (String) -> Void
    private let onFatalRecoveryRequired: @Sendable (String) -> Void
    private let relayHealth: RelayDeliveryHealth
    private var batchInProgress = false
    private var batchWaiters = [CheckedContinuation<Void, Never>]()
    private var cachingWasActivated = false
    private var cacheValidityMayRemain = false
    private var cacheExpiryDeadline: TimeInterval?
    private var notificationDeliveryBroken = false
    private var deliveredNudges = Set<NudgeKey>()
    private var pendingNudgeOperation: PendingNudgeOperation?
    private var fatalRecoveryRequested = false
    private(set) public var isDegraded = false

    public init(
        endpoints: [HostShareCoherenceEndpoint],
        guestEvents: any GuestFSEventSending,
        onDegraded: @escaping @Sendable (String) -> Void = { _ in },
        onFatalRecoveryRequired: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let sortedEndpoints = endpoints.sorted { $0.share.hostRoot.count > $1.share.hostRoot.count }
        self.endpoints = sortedEndpoints
        self.guestEvents = guestEvents
        self.onDegraded = onDegraded
        self.onFatalRecoveryRequired = onFatalRecoveryRequired
        self.relayHealth = RelayDeliveryHealth {
            // This callback runs synchronously on the relay failure path. Revoking response TTLs
            // here closes the actor-reentrancy window while the readiness health frame is in flight.
            for endpoint in sortedEndpoints {
                endpoint.backend.deactivateCoherentCaching()
            }
        }
    }

    /// Turns on bounded positive caching only after both halves of the coherence path are live:
    /// every virtio-fs device has negotiated/reposted its stable notification buffers and the guest
    /// watcher service answers an empty health frame. A partial activation is rolled back.
    ///
    /// `false` means "not ready" (or permanently degraded), so callers may poll during guest boot
    /// without treating an expected startup race as an engine failure.
    public func activateCachingIfReady() async throws -> Bool {
        let cacheableEndpoints = endpoints.filter(\.watcherNudgesEnabled)
        guard !isDegraded,
              !batchInProgress,
              pendingNudgeOperation == nil,
              !cacheableEndpoints.isEmpty else { return false }
        guard let relayGeneration = relayHealth.readyGeneration else { return false }
        guard cacheableEndpoints.allSatisfy({
            $0.backend.cacheActivationEligibility.isEligible
        }) else {
            return false
        }

        // Operation zero is reserved for this idempotent empty health probe. Normal batches always
        // use a fresh nonzero ID and retain it across any uncertain transport result.
        let health = try await guestEvents.send(operationID: 0, paths: [])
        guard health.touched == 0,
              health.failed == 0,
              !isDegraded,
              !batchInProgress else { return false }

        let activated = relayHealth.whileReady(generation: relayGeneration) {
            for endpoint in cacheableEndpoints {
                guard endpoint.backend.activateCoherentCaching() == .activated else {
                    for rollback in cacheableEndpoints {
                        rollback.backend.deactivateCoherentCaching()
                    }
                    return false
                }
            }
            return true
        }
        guard activated else { return false }
        cachingWasActivated = true
        cacheValidityMayRemain = true
        cacheExpiryDeadline = nil
        return true
    }

    /// Relay and lifecycle failures use the same fail-closed transition as delivery failures.
    public func markDegraded(_ reason: String) {
        degrade(reason)
    }

    /// Marks the relay behind synchronously, before actor bookkeeping can race a suspended cache
    /// readiness probe. A successful retry marks it caught up again; after caching has ever been
    /// enabled, the actor also makes the downgrade permanent for this VM session.
    public nonisolated func relayDeliveryFailed(_ reason: String) {
        relayHealth.markFailed()
        Task { await recordRelayDeliveryFailure(reason) }
    }

    /// Called only after the coordinator has completed invalidation and watcher delivery for the
    /// relay's pending batch. This is the point at which a startup retry is genuinely caught up.
    public nonisolated func relayDeliverySucceeded() {
        relayHealth.markSucceeded()
    }

    var relayDeliveryIsCaughtUp: Bool {
        relayHealth.readyGeneration != nil
    }

    private func recordRelayDeliveryFailure(_ reason: String) {
        if cachingWasActivated || isDegraded {
            degrade(reason)
        }
    }

    public func process(_ incoming: [HostFSEventChange]) async throws {
        guard !incoming.isEmpty else { return }
        await beginBatch()
        defer { endBatch() }
        let requiresRescan = incoming.contains(where: \.requiresRescan)
        if requiresRescan {
            requireFatalRecovery(
                "FSEvents lost host-share changes; restarting VM to discard unknown descendant cache state"
            )
            return
        }
        let changes = incoming

        let prepared = prepare(changes)
        if !notificationDeliveryBroken {
            var attemptedNotificationChannel = false
            do {
                for item in prepared {
                    // Negative dentries and directory handles are never cached, so an empty list is
                    // normal during guest boot. Any known positive inode/entry, however, may own
                    // open-file page cache even while metadata TTL is zero and must be invalidated.
                    guard !item.invalidations.isEmpty else { continue }
                    attemptedNotificationChannel = true
                    let batchLimit = max(1, min(128, item.endpoint.backend.notificationBacklogLimit))
                    try await item.endpoint.backend.invalidateAtomically(
                        item.invalidations,
                        maximumBatchSize: batchLimit,
                        timeout: Self.reverseInvalidationFailCloseDeadline
                    )
                }
            } catch {
                if attemptedNotificationChannel || cachingWasActivated || isDegraded {
                    notificationDeliveryBroken = true
                    requireFatalRecovery(
                        "host-share reverse invalidation failed; restarting VM to discard uncertain page cache: \(error)"
                    )
                    return
                }
            }
        } else {
            // The first failure permanently disabled caching for this VM. Do not add another
            // fail-close wait to later host edits; the one-time expiry wait below is enough.
            if cacheValidityMayRemain {
                try await waitForPreviouslyIssuedCacheValidity()
            }
        }

        do {
            // A prior response may have been lost after the guest performed its fchmod operations.
            // Replay that exact ordered request and ID before considering this (possibly merged)
            // FSEvents batch. The guest then returns its cached result without repeating the work.
            try await deliverPendingNudgeOperation()
            var nudgeTargets: [String: NudgeTarget] = [:]
            for item in prepared {
                guard item.endpoint.watcherNudgesEnabled else { continue }
                for change in item.changes {
                    guard let target = item.endpoint.share.nudgeTarget(forHostPath: change.hostPath) else {
                        continue
                    }
                    // Key by guest path, not host path: one host directory may intentionally be
                    // exposed at multiple guest aliases and every mount needs its own watcher event.
                    if var existing = nudgeTargets[target.guest] {
                        existing.eventID = max(existing.eventID, change.eventID)
                        nudgeTargets[target.guest] = existing
                    } else {
                        nudgeTargets[target.guest] = NudgeTarget(
                            guestPath: target.guest,
                            eventID: change.eventID
                        )
                    }
                }
            }

            let sortedTargets = nudgeTargets.values
                .filter { !wasNudgeDelivered($0) }
                .sorted { $0.guestPath < $1.guestPath }
            for targets in sortedTargets.chunked(maximumCount: GuestFSEventBatchCodec.maximumPaths) {
                pendingNudgeOperation = PendingNudgeOperation(
                    operationID: GuestFSEventOperationIDs.next(),
                    targets: targets,
                    createdAt: ProcessInfo.processInfo.systemUptime
                )
                try await deliverPendingNudgeOperation()
            }
            retireDeliveredNudges(coveredBy: Array(nudgeTargets.values))
        } catch {
            // Close the readiness gate before returning control to FSEventBatcher. Its external
            // failure callback is necessarily a few instructions later, and cache polling must not
            // exploit that gap while this batch remains retryable.
            relayHealth.markFailed()
            if cachingWasActivated || isDegraded {
                degrade("host-share watcher delivery failed: \(error)")
            }
            throw error
        }
    }

    private struct PreparedEndpoint {
        var endpoint: HostShareCoherenceEndpoint
        var changes: [HostFSEventChange]
        var invalidations: [VirtioFSInvalidation]
    }

    private struct NudgeTarget: Sendable {
        var guestPath: String
        var eventID: UInt64
    }

    private struct NudgeKey: Hashable, Sendable {
        var guestPath: String
        var eventID: UInt64
    }

    private struct PendingNudgeOperation: Sendable {
        var operationID: UInt64
        var targets: [NudgeTarget]
        var createdAt: TimeInterval
    }

    private func deliverPendingNudgeOperation() async throws {
        guard let operation = pendingNudgeOperation else { return }
        let age = ProcessInfo.processInfo.systemUptime - operation.createdAt
        guard age < GuestFSEventBatchCodec.maximumOperationRetryAgeSeconds else {
            // The guest's dedupe entry may expire after 120 seconds. Never cross that boundary and
            // risk turning an uncertain prior success into a second watcher event.
            requireFatalRecovery(
                "guest watcher operation \(operation.operationID) exceeded its safe retry window; restarting VM"
            )
            throw HostShareCoherenceError.guestNudgeOperationExpired(
                operationID: operation.operationID
            )
        }

        let result: GuestFSEventBatchResult
        do {
            result = try await guestEvents.send(
                operationID: operation.operationID,
                paths: operation.targets.map(\.guestPath)
            )
        } catch let error as GuestFSEventBridgeError {
            switch error {
            case .operationIDConflict, .dedupeCapacityExhausted,
                 .tooManyPaths, .invalidOperationID, .invalidPath, .oversizedFrame:
                // Conflict/capacity status proves this payload did not execute; local validation
                // failures happen before connection I/O. Discard the ID so a later attempt starts
                // a logically new, still-safe operation.
                pendingNudgeOperation = nil
            case .guestExecutionFailed:
                // A caught guest panic may have happened after a subset of side effects. Retain the
                // ID and fail closed; allocating a new operation could duplicate that unknown work.
                requireFatalRecovery(
                    "guest watcher operation \(operation.operationID) has indeterminate execution; restarting VM"
                )
            default:
                // Timeout, disconnect, or a malformed response leaves delivery uncertain. Retain
                // the exact ID and ordered paths so the guest dedupe store resolves the ambiguity.
                break
            }
            throw error
        }

        guard result.pathCount == UInt32(operation.targets.count) else {
            throw GuestFSEventBridgeError.invalidResponse
        }
        // A valid response is durable in the guest dedupe window. It is now safe to retire this
        // operation: successful indices are final, while failed indices receive a fresh ID later.
        pendingNudgeOperation = nil
        let failed = Set(result.failedIndices.map(Int.init))
        for (index, target) in operation.targets.enumerated() where !failed.contains(index) {
            recordDeliveredNudge(target)
        }
        if let failedIndex = result.failedIndices.first.map(Int.init) {
            let path = operation.targets[failedIndex].guestPath
            throw HostShareCoherenceError.guestNudgeFailed(path: path)
        }
    }

    private func prepare(
        _ changes: [HostFSEventChange],
        exactRecoveryEndpoints: Bool = false
    ) -> [PreparedEndpoint] {
        var grouped: [Int: (
            changes: [HostFSEventChange],
            invalidations: [String: VirtioFSInvalidation],
            deletedNodeIDs: Set<UInt64>
        )] = [:]
        for endpointIndex in endpoints.indices {
            let endpoint = endpoints[endpointIndex]
            var endpointChanges = [String: HostFSEventChange]()
            for change in changes {
                let matchesEndpoint: Bool
                if exactRecoveryEndpoints {
                    matchesEndpoint = endpoint.share.hostRoot == change.hostPath
                        && endpoint.share.guestRoot == change.guestPath
                } else {
                    matchesEndpoint = endpoint.share.mapHostPathToGuest(change.hostPath) != nil
                }
                guard matchesEndpoint else { continue }
                let expanded: [HostFSEventChange]
                if change.isDirectoryAggregate {
                    expanded = Self.expandedDirectoryChange(change, endpoint: endpoint)
                } else {
                    expanded = [change]
                }
                for exact in expanded {
                    if var existing = endpointChanges[exact.hostPath] {
                        existing.flags |= exact.flags
                        existing.eventID = max(existing.eventID, exact.eventID)
                        endpointChanges[exact.hostPath] = existing
                    } else {
                        endpointChanges[exact.hostPath] = exact
                    }
                }
            }

            // FSEvents can coalesce a rename to its destination path only and may classify that
            // destination as either renamed or created. Reconcile cached bindings whose pinned
            // identity no longer belongs at their old path so Linux sees a source-side
            // DELETE/ENTRY notification as well as the destination update. Do this only for a
            // namespace mutation and never during an exact loss-recovery root batch.
            let namespaceMutationMask = UInt32(
                kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
            )
            if !exactRecoveryEndpoints,
               endpointChanges.values.contains(where: { $0.flags & namespaceMutationMask != 0 }) {
                let sourceEventID = endpointChanges.values.map(\.eventID).max() ?? 0
                let synthesizedFlags = UInt32(
                    kFSEventStreamEventFlagItemRemoved |
                    kFSEventStreamEventFlagItemRenamed
                )
                for stalePath in endpoint.backend.hostFS
                    .knownStaleHostPathsForNamespaceReconciliation()
                    where endpointChanges[stalePath] == nil {
                    guard let guestPath = endpoint.share.mapHostPathToGuest(stalePath) else { continue }
                    endpointChanges[stalePath] = HostFSEventChange(
                        hostPath: stalePath,
                        guestPath: guestPath,
                        flags: synthesizedFlags,
                        eventID: sourceEventID
                    )
                }
            }

            for change in endpointChanges.values.sorted(by: {
                $0.hostPath == $1.hostPath ? $0.eventID < $1.eventID : $0.hostPath < $1.hostPath
            }) {
                let aliasPaths: [String]
                if change.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                    // A paired FSEvents rename has distinct source and destination records. Do not
                    // fan a destination's flags onto the source identity: the source must retain
                    // its absent-path classification so it can emit FUSE_NOTIFY_DELETE.
                    aliasPaths = [change.hostPath]
                } else {
                    aliasPaths = endpoint.backend.hostFS
                        .knownIdentityAliasHostPaths(forHostPath: change.hostPath)
                }
                for aliasPath in aliasPaths {
                    guard let guestPath = endpoint.share.mapHostPathToGuest(aliasPath),
                          let snapshot = endpoint.backend.hostFS
                            .invalidationSnapshot(forHostPath: aliasPath) else {
                        continue
                    }
                    let effectiveChange = HostFSEventChange(
                        hostPath: aliasPath,
                        guestPath: guestPath,
                        flags: change.flags,
                        eventID: change.eventID,
                        permitsContentInvalidation: aliasPath == change.hostPath
                    )
                    // A whole-home share receives unrelated macOS activity continuously. If neither
                    // the path nor its exact parent has ever been resolved by the guest, Linux cannot
                    // hold a dentry/inode cache or directory watch, so relaying it only creates noise.
                    guard !snapshot.nodeIDs.isEmpty || !snapshot.parentNodeIDs.isEmpty else { continue }
                    grouped[endpointIndex, default: ([], [:], [])].changes.append(effectiveChange)

                    let planned = Self.plannedInvalidations(
                        for: effectiveChange,
                        snapshot: snapshot
                    )
                    // The host mutation has already happened. Tombstone identities proven stale
                    // before Linux receives DELETE/INVAL_INODE so an open-file GETATTR that omits
                    // FUSE_GETATTR_FH observes the old inode's authoritative post-mutation nlink.
                    endpoint.backend.hostFS.reconcileHostInvalidation(
                        forHostPath: aliasPath,
                        staleNodeIDs: snapshot.staleNodeIDs
                    )
                    let deletedNodeIDs = Set(planned.values.compactMap { invalidation -> UInt64? in
                        guard case .delete(_, let childNodeID, _) = invalidation else { return nil }
                        return childNodeID
                    })
                    grouped[endpointIndex]?.deletedNodeIDs.formUnion(deletedNodeIDs)
                    for nodeID in deletedNodeIDs {
                        grouped[endpointIndex]?.invalidations.removeValue(forKey: "i:\(nodeID)")
                    }

                    for (key, invalidation) in planned {
                        if case .inode(let nodeID, _, _) = invalidation,
                           grouped[endpointIndex]?.deletedNodeIDs.contains(nodeID) == true {
                            continue
                        }
                        let existing = grouped[endpointIndex]?.invalidations[key]
                        grouped[endpointIndex]?.invalidations[key] = Self.mergeInvalidation(
                            invalidation,
                            preservingStronger: existing
                        )
                    }
                }
            }
        }

        return grouped.keys.sorted().map { index in
            let group = grouped[index]!
            var invalidations = group.invalidations
            // DELETE disconnects the stale dentry but does not reliably expire an open inode's
            // cached attributes. Re-add attribute-only invalidation after cross-alias merging; a
            // content invalidation must never win for a final unlinked/replaced identity.
            for nodeID in group.deletedNodeIDs {
                invalidations["i:\(nodeID)"] = .inode(
                    nodeID: nodeID,
                    offset: -1,
                    length: 0
                )
            }
            return PreparedEndpoint(
                endpoint: endpoints[index],
                changes: group.changes,
                invalidations: invalidations.keys.sorted().compactMap { invalidations[$0] }
            )
        }
    }

    static func expandedDirectoryChange(
        _ change: HostFSEventChange,
        endpoint: HostShareCoherenceEndpoint
    ) -> [HostFSEventChange] {
        guard change.isDirectoryAggregate else { return [change] }
        let conservativeFlags = UInt32(
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemInodeMetaMod
        )
        return endpoint.backend.hostFS
            .knownHostPaths(inHostDirectory: change.hostPath)
            .compactMap { path in
                guard let guestPath = endpoint.share.mapHostPathToGuest(path) else { return nil }
                return HostFSEventChange(
                    hostPath: path,
                    guestPath: guestPath,
                    flags: conservativeFlags,
                    eventID: change.eventID
                )
            }
    }

    /// Builds one path's reverse invalidations without touching coordinator state. Kept internal so
    /// tests can lock down the distinction between pathname replacement and inode data lifetime.
    static func plannedInvalidations(
        for change: HostFSEventChange,
        snapshot: HostFSInvalidationSnapshot
    ) -> [String: VirtioFSInvalidation] {
        var invalidations = [String: VirtioFSInvalidation]()
        let representsRemoval = change.representsRemoval
        let namespaceMask = UInt32(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        let deletionCandidates: Set<UInt64>
        if representsRemoval {
            // Alias fanout carries the original removal flags to every hard-link name. Only the
            // pathname whose identity is actually stale was removed; deleting every current alias
            // would incorrectly disconnect surviving dentries that share the same node ID.
            deletionCandidates = Set(snapshot.staleNodeIDs + snapshot.unverifiedNodeIDs)
        } else if change.flags & namespaceMask != 0 {
            deletionCandidates = Set(snapshot.staleNodeIDs + snapshot.unverifiedNodeIDs)
        } else {
            // An inode identity mismatch proves replacement even if FSEvents happened to classify
            // the batch as content-only. Synthetic identities have no prior identity to compare.
            deletionCandidates = Set(snapshot.staleNodeIDs)
        }
        let survivingLinks = Set(snapshot.survivingLinkNodeIDs)
        // A host rename removes this *dentry* even when the moved inode still has nlink > 0 at
        // its new name. Treat it as a DELETE for the source directory entry so Linux watchers see
        // the removal. Ordinary nonfinal unlinks retain their entry-only hard-link semantics.
        let representsRenameSource = representsRemoval
            && change.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let nonFinalUnlinks = representsRenameSource
            ? Set<UInt64>()
            : deletionCandidates.intersection(survivingLinks)
        let deleteNodeIDs = representsRenameSource
            ? deletionCandidates.sorted()
            : deletionCandidates.subtracting(survivingLinks).sorted()

        // DELETE detaches a final stale pathname identity and can produce IN_DELETE_SELF. A nonfinal
        // hard-link unlink must instead invalidate only that entry plus inode attributes/nlink: the
        // shared inode is still live through another name. Final stale objects also need an
        // attribute-only inode invalidation because DELETE does not reliably expire an open inode's
        // cached nlink. Never data-invalidate stale/final objects: an open fd or mmap must retain its
        // old pages and dirty writes must keep their old target.
        let staleNodeIDs = Set(snapshot.staleNodeIDs)
        let deletedNodeIDs = Set(deleteNodeIDs)
        // A namespace event is fanned out to every known hard-link alias. If this alias has no stale
        // identity, its inode data did not change merely because another name was replaced/removed;
        // touching its pages could spuriously conflict with a dirty mmap. The exact changed path has
        // deletion candidates and may still need content invalidation for its current replacement.
        let hasNamespaceMutation = change.flags & namespaceMask != 0
        // APFS may coalesce a prior create and a later same-inode host write into one event. The
        // exact changed pathname must still invalidate its data pages even when that coalesced
        // namespace event has no stale identity; otherwise a dirty guest MAP_SHARED folio can
        // survive the host write. Alias fanout strips ItemModified above, so this remains local to
        // the path that FSEvents actually reported.
        let invalidatesContent = change.permitsContentInvalidation
            && change.flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        for nodeID in snapshot.nodeIDs where !deletedNodeIDs.contains(nodeID) {
            if nonFinalUnlinks.contains(nodeID) {
                invalidations["i:\(nodeID)"] = .inode(nodeID: nodeID, offset: -1, length: 0)
            } else if !staleNodeIDs.contains(nodeID) {
                invalidations["i:\(nodeID)"] = invalidatesContent
                    ? .inode(nodeID: nodeID, offset: 0, length: -1)
                    // offset < 0 makes fuse_reverse_inval_inode invalidate attributes/ACLs only.
                    : .inode(nodeID: nodeID, offset: -1, length: 0)
            }
        }
        for nodeID in deleteNodeIDs {
            invalidations["i:\(nodeID)"] = .inode(nodeID: nodeID, offset: -1, length: 0)
        }

        guard let name = snapshot.entryName else { return invalidations }
        if !snapshot.parentNodeIDs.isEmpty, !deleteNodeIDs.isEmpty {
            // DELETE must precede INVAL_ENTRY for this name. ENTRY first would remove the cached
            // dentry before Linux can match DELETE's child ID and notify the old inode's watch.
            for parentNodeID in snapshot.parentNodeIDs {
                for childNodeID in deleteNodeIDs {
                    invalidations["d:\(parentNodeID):\(childNodeID):\(name)"] = .delete(
                        parentNodeID: parentNodeID,
                        childNodeID: childNodeID,
                        name: name
                    )
                }
            }
        }
        // ENTRY invalidation is a namespace operation: it is only needed when the name→inode
        // mapping may have changed (a stale pinned identity proves replacement; a synthetic
        // identity cannot be compared). For a verified-unchanged path the positive dentry still
        // maps to the same inode, and Linux's fuse_reverse_inval_entry runs d_invalidate, which
        // detaches every mount below the dentry — a host write to a *sibling* file must never
        // unmount a container's bind of this directory out from under it.
        let identityMayHaveChanged = !snapshot.staleNodeIDs.isEmpty
            || !snapshot.unverifiedNodeIDs.isEmpty
        let shouldInvalidateEntry = representsRemoval
            ? !nonFinalUnlinks.isEmpty
            : identityMayHaveChanged
        if shouldInvalidateEntry, !snapshot.nodeIDs.isEmpty {
            // Negative dentries are never cached. A known old/current identity means the pathname may
            // have a positive dentry, so invalidate it after DELETE to reveal the current replacement.
            // For a nonfinal hard-link removal ENTRY is the namespace operation: DELETE would falsely
            // signal that the shared inode itself died while another link remains.
            for parentNodeID in snapshot.parentNodeIDs {
                invalidations["e:\(parentNodeID):\(name)"] = .entry(
                    parentNodeID: parentNodeID,
                    name: name
                )
            }
        }
        return invalidations
    }

    /// Multiple hard-link aliases can plan the same inode. A content invalidation must dominate an
    /// attribute-only invalidation regardless of FSEvents batch iteration order.
    private static func mergeInvalidation(
        _ incoming: VirtioFSInvalidation,
        preservingStronger existing: VirtioFSInvalidation?
    ) -> VirtioFSInvalidation {
        guard let existing else { return incoming }
        if case .inode(_, 0, -1) = existing,
           case .inode(_, -1, 0) = incoming {
            return existing
        }
        return incoming
    }

    private func degrade(_ reason: String) {
        // This is synchronous and happens before diagnostics/callbacks: every later response will
        // advertise zero validity even if the notification transport is still technically alive.
        if cachingWasActivated, cacheValidityMayRemain, cacheExpiryDeadline == nil {
            cacheExpiryDeadline = ProcessInfo.processInfo.systemUptime
                + Double(VirtioFS.maximumCoherentCacheValiditySeconds)
                + 0.1
        }
        for endpoint in endpoints {
            endpoint.backend.deactivateCoherentCaching()
        }
        // A loss burst may be reported in several batches.  Caching is already disabled after
        // the first one, so repeat diagnostics add noise without communicating a new state.
        guard !isDegraded else { return }
        isDegraded = true
        onDegraded(reason)
    }

    private func requireFatalRecovery(_ reason: String) {
        // Unknown host edits make every endpoint unsafe, including read-only mounts with stale
        // open-file page cache. Establish the publication boundary synchronously and for all
        // aliases before diagnostics or the VM-stop callback can run. A late notification ack or
        // guest-controlled device reset cannot reopen this one-way backend latch.
        for endpoint in endpoints {
            endpoint.backend.failStopRequestPublication()
        }
        degrade(reason)
        if !fatalRecoveryRequested {
            fatalRecoveryRequested = true
            onFatalRecoveryRequired(reason)
        }
    }

    private func beginBatch() async {
        if !batchInProgress {
            batchInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            batchWaiters.append(continuation)
        }
    }

    private func endBatch() {
        if batchWaiters.isEmpty {
            batchInProgress = false
        } else {
            // Ownership passes directly to the oldest waiter; keep the gate closed so a new caller
            // cannot overtake it between continuation resumption and actor re-entry.
            batchWaiters.removeFirst().resume()
        }
    }

    private func waitForPreviouslyIssuedCacheValidity() async throws {
        guard cacheValidityMayRemain else { return }
        if cacheExpiryDeadline == nil {
            cacheExpiryDeadline = ProcessInfo.processInfo.systemUptime
                + Double(VirtioFS.maximumCoherentCacheValiditySeconds)
                + 0.1
        }
        if let deadline = cacheExpiryDeadline {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        cacheValidityMayRemain = false
        cacheExpiryDeadline = nil
    }

    private func wasNudgeDelivered(_ target: NudgeTarget) -> Bool {
        deliveredNudges.contains(NudgeKey(guestPath: target.guestPath, eventID: target.eventID))
    }

    private func recordDeliveredNudge(_ target: NudgeTarget) {
        deliveredNudges.insert(NudgeKey(guestPath: target.guestPath, eventID: target.eventID))
    }

    private func retireDeliveredNudges(coveredBy targets: [NudgeTarget]) {
        guard !deliveredNudges.isEmpty, !targets.isEmpty else { return }
        let covered = Dictionary(targets.map { ($0.guestPath, $0.eventID) }) { _, newer in newer }
        deliveredNudges = deliveredNudges.filter { key in
            guard let through = covered[key.guestPath] else { return true }
            return key.eventID > through
        }
    }
}

/// A small synchronous gate shared by the FSEvents callback and the actor. Holding its lock across
/// activation makes failure-vs-activation ordering total: either activation wins and the failure
/// immediately revokes it, or failure wins and activation is refused for that generation.
private final class RelayDeliveryHealth: @unchecked Sendable {
    private let lock = NSLock()
    private let onFailure: @Sendable () -> Void
    private var generation: UInt64 = 1
    private var caughtUp = true

    init(onFailure: @escaping @Sendable () -> Void) {
        self.onFailure = onFailure
    }

    var readyGeneration: UInt64? {
        lock.withLock { caughtUp ? generation : nil }
    }

    func markFailed() {
        lock.withLock {
            generation &+= 1
            caughtUp = false
            onFailure()
        }
    }

    func markSucceeded() {
        lock.withLock {
            generation &+= 1
            caughtUp = true
        }
    }

    func whileReady(generation expected: UInt64, _ body: () -> Bool) -> Bool {
        lock.withLock {
            guard caughtUp, generation == expected else { return false }
            return body()
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        let size = Swift.max(1, maximumCount)
        var result = [[Element]]()
        result.reserveCapacity((count + size - 1) / size)
        var start = 0
        while start < count {
            let end = Swift.min(count, start + size)
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}
