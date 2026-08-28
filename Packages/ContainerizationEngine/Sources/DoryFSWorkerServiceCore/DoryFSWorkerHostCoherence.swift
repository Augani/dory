import CoreServices
import Darwin
import DoryFSWorkerContracts
import Foundation

public enum DoryFSWorkerHostCoherenceError: Error, Equatable, Sendable {
    case observationUnavailable
    case eventLoss
    case pendingOverflow(limit: Int)
    case invalidAcknowledgement
    case acknowledgementUnavailable
    case planOverflow
    case capabilityAuthorityUnavailable
}

public struct DoryFSWorkerHostCoherenceStatistics: Equatable, Sendable {
    public let running: Bool
    public let configuredShareCount: Int
    public let invalidationOnlyShareCount: Int
    public let watcherNudgeShareCount: Int
    public let requiredObservationShareCount: Int
    public let observedRequiredShareCount: Int
    public let observationStreamCount: Int
    public let pendingEventCount: Int
    public let pendingEventLimit: Int
    public let receivedEventCount: UInt64
    public let deliveredBatchCount: UInt64
    public let failedBatchCount: UInt64
    public let eventLossCount: UInt64
}

/// Same-process host-event authority for one filesystem worker generation. Guest FUSE mutations
/// execute in this process, so `IgnoreSelf` and the explicit `OwnEvent` check can distinguish them
/// from edits made by host applications. Moving this stream back to the runner would destroy that
/// source attribution and reflect guest writes back as synthetic host edits.
final class DoryFSWorkerHostCoherence: @unchecked Sendable {
    typealias Exchange = @Sendable (Data) throws -> Data
    typealias Failure = @Sendable (DoryFSWorkerHostCoherenceError) -> Void

    private final class Endpoint: @unchecked Sendable {
        let capability: DoryFSShareCapabilityID
        let hostFS: HostFS
        let root: String
        let watcherNudgesEnabled: Bool
        let policy: DoryFSShareCoherencePolicy

        init(
            capability: DoryFSShareCapabilityID,
            hostFS: HostFS,
            policy: DoryFSShareCoherencePolicy
        ) {
            self.capability = capability
            self.hostFS = hostFS
            root = hostFS.eventRootPath
            self.policy = policy
            watcherNudgesEnabled = policy == .invalidationAndWatcherNudge
        }

        func contains(_ path: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }

        func relativePath(_ path: String) -> String? {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard contains(normalized) else { return nil }
            if normalized == root { return "" }
            return String(normalized.dropFirst(root.count + 1))
        }

    }

    private struct Change: Sendable {
        var path: String
        var flags: UInt32
        var eventID: UInt64
        var directoryAggregate: Bool

        var requiresFailStop: Bool {
            let mask = UInt32(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagEventIdsWrapped |
                kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagMount |
                kFSEventStreamEventFlagUnmount
            )
            return flags & mask != 0
        }

        func representsRemoval(pathIsMissing: Bool) -> Bool {
            let mask = UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
            )
            return flags & mask != 0 && pathIsMissing
        }
    }

    private final class CallbackBox {
        weak var relay: DoryFSWorkerHostCoherence?
        let capability: DoryFSShareCapabilityID

        init(relay: DoryFSWorkerHostCoherence, capability: DoryFSShareCapabilityID) {
            self.relay = relay
            self.capability = capability
        }
    }

    static let pendingEventLimit = 65_536
    static let acknowledgementAttempts = 2

    private static let streamFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot |
        kFSEventStreamCreateFlagIgnoreSelf |
        kFSEventStreamCreateFlagMarkSelf |
        kFSEventStreamCreateFlagUseCFTypes |
        kFSEventStreamCreateFlagFileEvents
    )

    private let generation: DoryFSWorkerGeneration
    /// Checkpoint taken while the worker's sealed root authorities are being assembled. Streams
    /// are intentionally not started until the runner exports its sink, but starting from this
    /// checkpoint lets FSEvents replay host mutations from that pre-activation interval after the
    /// sink is ready. Loss/wrap flags on that replay are terminal rather than silently skipped.
    private let preactivationEventID: FSEventStreamEventId
    private let endpoints: [DoryFSShareCapabilityID: Endpoint]
    private let exchange: Exchange
    private let onFailure: Failure
    private let streamQueue = DispatchQueue(label: "dev.dory.fs-worker.fsevents")
    private let lock = NSLock()
    private var streams = [String: FSEventStreamRef]()
    private var callbackBoxes = [String: CallbackBox]()
    private var requiredCapabilities = Set<DoryFSShareCapabilityID>()
    private var historyCaughtUpCapabilities = Set<DoryFSShareCapabilityID>()
    private var observedCapabilities = Set<DoryFSShareCapabilityID>()
    private var pending = [DoryFSShareCapabilityID: [String: Change]]()
    private var running = false
    private var activationCatchupInProgress = false
    private var activationComplete = false
    private var flushScheduled = false
    private var terminalFailureReported = false
    private var nextBatchID = UInt64.random(in: 1...UInt64.max)
    private var receivedEventCount: UInt64 = 0
    private var deliveredBatchCount: UInt64 = 0
    private var failedBatchCount: UInt64 = 0
    private var eventLossCount: UInt64 = 0

    init(
        generation: DoryFSWorkerGeneration,
        shares: [(DoryFSShareCapabilityID, HostFS, DoryFSShareCoherencePolicy)],
        exchange: @escaping Exchange,
        onFailure: @escaping Failure
    ) throws {
        self.generation = generation
        preactivationEventID = FSEventsGetCurrentEventId()
        endpoints = Dictionary(uniqueKeysWithValues: shares.map { capability, hostFS, policy in
            (
                capability,
                Endpoint(
                    capability: capability,
                    hostFS: hostFS,
                    policy: policy
                )
            )
        })
        self.exchange = exchange
        self.onFailure = onFailure
    }

    deinit {
        stop()
    }

    var statistics: DoryFSWorkerHostCoherenceStatistics {
        lock.withLock {
            DoryFSWorkerHostCoherenceStatistics(
                running: running && activationComplete,
                configuredShareCount: endpoints.count,
                invalidationOnlyShareCount: endpoints.values.filter {
                    $0.policy == .invalidationOnly
                }.count,
                watcherNudgeShareCount: endpoints.values.filter {
                    $0.policy == .invalidationAndWatcherNudge
                }.count,
                requiredObservationShareCount: requiredCapabilities.count,
                observedRequiredShareCount: observedCapabilities
                    .intersection(requiredCapabilities).count,
                observationStreamCount: streams.count,
                pendingEventCount: pending.values.reduce(0) { $0 + $1.count },
                pendingEventLimit: Self.pendingEventLimit,
                receivedEventCount: receivedEventCount,
                deliveredBatchCount: deliveredBatchCount,
                failedBatchCount: failedBatchCount,
                eventLossCount: eventLossCount
            )
        }
    }

    /// Runner invokes this only after exporting and installing its exact coherence handler. Root
    /// streams are armed before any guest request can resolve a child, closing the initially-empty
    /// share gap and retaining host mutations that race activation.
    func activate() throws {
        let shouldActivate = lock.withLock { () -> Bool in
            guard !terminalFailureReported, !running else { return false }
            running = true
            activationCatchupInProgress = true
            return true
        }
        guard shouldActivate else {
            guard lock.withLock({
                running && activationComplete && !terminalFailureReported
            }) else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
            return
        }
        do {
            for endpoint in endpoints.values.sorted(by: {
                $0.capability.rawValue.uuidString < $1.capability.rawValue.uuidString
            }) {
                try observe(
                    capability: endpoint.capability,
                    hostPath: endpoint.root
                )
            }
            for endpoint in endpoints.values {
                endpoint.hostFS.setEventObservationHandler { [weak self] _ in
                    guard let self,
                          self.lock.withLock({
                              self.running
                                  && self.observedCapabilities.contains(endpoint.capability)
                          }) else {
                        throw DoryFSWorkerHostCoherenceError.observationUnavailable
                    }
                }
            }
            // Drain the persistent history from the checkpoint captured at worker bootstrap before
            // activation returns. The runner sink is installed at this point, so no preactivation
            // host edit can be ACKed, dropped, or delivered into a missing handler window.
            flushObservationStreams()
            let catchup = lock.withLock { () -> (ready: Bool, mustFlush: Bool) in
                let ready = running
                    && requiredCapabilities.isSubset(of: historyCaughtUpCapabilities)
                guard ready else { return (false, false) }
                activationCatchupInProgress = false
                observedCapabilities = requiredCapabilities
                let mustFlush = !pending.isEmpty
                if mustFlush { flushScheduled = true }
                return (true, mustFlush)
            }
            guard catchup.ready else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
            if catchup.mustFlush { flush() }
            guard lock.withLock({ running && !terminalFailureReported }) else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
            lock.withLock { activationComplete = true }
        } catch {
            failStop(.observationUnavailable)
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
    }

    /// Makes every event that already reached FSEvents observable before returning. Activation
    /// uses this as its catch-up barrier; focused tests also use it to avoid timing the daemon's
    /// normal batching latency when asserting exact same-PID suppression and external delivery.
    func flushObservationStreams() {
        let active = lock.withLock { running ? Array(streams.values) : [] }
        for stream in active { FSEventStreamFlushSync(stream) }
    }

    func stop() {
        let retired = lock.withLock { () -> ([FSEventStreamRef], [CallbackBox]) in
            running = false
            activationCatchupInProgress = false
            activationComplete = false
            flushScheduled = false
            pending.removeAll(keepingCapacity: false)
            requiredCapabilities.removeAll(keepingCapacity: false)
            historyCaughtUpCapabilities.removeAll(keepingCapacity: false)
            observedCapabilities.removeAll(keepingCapacity: false)
            let retired = (Array(streams.values), Array(callbackBoxes.values))
            streams.removeAll(keepingCapacity: false)
            callbackBoxes.removeAll(keepingCapacity: false)
            return retired
        }
        for endpoint in endpoints.values {
            endpoint.hostFS.setEventObservationHandler(nil)
        }
        for stream in retired.0 {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        _ = retired.1
    }

    private func observe(
        capability: DoryFSShareCapabilityID,
        hostPath: String
    ) throws {
        guard let endpoint = endpoints[capability] else {
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        let observationRoot: String
        let expectedIdentity: HostFSEventPathIdentity
        do {
            observationRoot = try endpoint.hostFS.eventObservationRoot(
                forHostPath: hostPath
            )
            expectedIdentity = try endpoint.hostFS.eventObservationIdentity(
                forRootPath: observationRoot
            )
            guard try Self.pathnameIdentity(observationRoot) == expectedIdentity else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
        } catch let error as DoryFSWorkerHostCoherenceError {
            failStop(error)
            throw error
        } catch {
            failStop(.observationUnavailable)
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        let key = capability.rawValue.uuidString + ":" + observationRoot
        let alreadyObserved = lock.withLock { () -> Bool in
            requiredCapabilities.insert(capability)
            return streams[key] != nil
        }
        if alreadyObserved { return }
        guard lock.withLock({ running }) else {
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }

        let box = CallbackBox(relay: self, capability: capability)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, eventFlags, eventIDs in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)
                var changes = [Change]()
                changes.reserveCapacity(count)
                var historyDone = false
                for index in 0..<count {
                    guard let path = paths.object(at: index) as? String else { continue }
                    let flags = UInt32(eventFlags[index])
                    if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                        historyDone = true
                        continue
                    }
                    guard flags & UInt32(kFSEventStreamEventFlagOwnEvent) == 0 else { continue }
                    changes.append(Change(
                        path: URL(fileURLWithPath: path).standardizedFileURL.path,
                        flags: flags,
                        eventID: UInt64(eventIDs[index]),
                        directoryAggregate: false
                    ))
                }
                box.relay?.record(changes, capability: box.capability)
                if historyDone {
                    box.relay?.historyDidFinish(capability: box.capability)
                }
            },
            &context,
            [observationRoot] as CFArray,
            preactivationEventID,
            0.05,
            Self.streamFlags
        ) else {
            failStop(.observationUnavailable)
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        FSEventStreamSetDispatchQueue(stream, streamQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            failStop(.observationUnavailable)
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        do {
            guard try Self.pathnameIdentity(observationRoot) == expectedIdentity,
                  try endpoint.hostFS.eventObservationIdentity(
                      forRootPath: observationRoot
                  ) == expectedIdentity else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
        } catch {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            failStop(.observationUnavailable)
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        let accepted = lock.withLock { () -> Bool in
            guard running, streams[key] == nil else { return false }
            streams[key] = stream
            callbackBoxes[key] = box
            return true
        }
        if !accepted {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            guard lock.withLock({ running && streams[key] != nil }) else {
                throw DoryFSWorkerHostCoherenceError.observationUnavailable
            }
        }
    }

    private func historyDidFinish(capability: DoryFSShareCapabilityID) {
        lock.withLock {
            guard running, requiredCapabilities.contains(capability) else { return }
            historyCaughtUpCapabilities.insert(capability)
        }
    }

    private static func pathnameIdentity(_ path: String) throws -> HostFSEventPathIdentity {
        let descriptor = Darwin.open(
            path,
            O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DoryFSWorkerHostCoherenceError.observationUnavailable
        }
        return HostFSEventPathIdentity(
            device: UInt64(truncatingIfNeeded: status.st_dev),
            inode: UInt64(truncatingIfNeeded: status.st_ino),
            generation: UInt64(truncatingIfNeeded: status.st_gen)
        )
    }

    private func record(_ changes: [Change], capability: DoryFSShareCapabilityID) {
        guard !changes.isEmpty, endpoints[capability] != nil else { return }
        var terminal: DoryFSWorkerHostCoherenceError?
        lock.withLock {
            guard running else { return }
            receivedEventCount = Self.saturatingAdd(receivedEventCount, UInt64(changes.count))
            if changes.contains(where: \.requiresFailStop) {
                eventLossCount = Self.saturatingAdd(eventLossCount, 1)
                terminal = .eventLoss
                return
            }
            for change in changes {
                let currentCount = pending.values.reduce(0) { $0 + $1.count }
                if pending[capability]?[change.path] == nil,
                   currentCount >= Self.pendingEventLimit {
                    eventLossCount = Self.saturatingAdd(eventLossCount, 1)
                    terminal = .pendingOverflow(limit: Self.pendingEventLimit)
                    return
                }
                if var existing = pending[capability]?[change.path] {
                    existing.flags |= change.flags
                    existing.eventID = max(existing.eventID, change.eventID)
                    existing.directoryAggregate = existing.directoryAggregate || change.directoryAggregate
                    pending[capability]?[change.path] = existing
                } else {
                    pending[capability, default: [:]][change.path] = change
                }
            }
        }
        if let terminal {
            failStop(terminal)
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard running,
                  !activationCatchupInProgress,
                  !flushScheduled,
                  !pending.isEmpty else { return false }
            flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000)
            self?.flush()
        }
    }

    private func flush() {
        let batches = lock.withLock { () -> [(Endpoint, [Change])] in
            guard running else { return [] }
            let batches = pending.compactMap { capability, byPath -> (Endpoint, [Change])? in
                guard let endpoint = endpoints[capability] else { return nil }
                return (endpoint, byPath.values.sorted {
                    $0.path == $1.path ? $0.eventID < $1.eventID : $0.path < $1.path
                })
            }.sorted { $0.0.capability.rawValue.uuidString < $1.0.capability.rawValue.uuidString }
            pending.removeAll(keepingCapacity: true)
            return batches
        }

        do {
            for (endpoint, changes) in batches {
                if let batch = try plan(changes, endpoint: endpoint) {
                    try deliverRetainingUntilAcknowledged(batch)
                    lock.withLock {
                        deliveredBatchCount = Self.saturatingAdd(deliveredBatchCount, 1)
                    }
                }
            }
            lock.withLock {
                flushScheduled = false
            }
            scheduleFlush()
        } catch let error as DoryFSWorkerHostCoherenceError {
            lock.withLock {
                failedBatchCount = Self.saturatingAdd(failedBatchCount, 1)
                flushScheduled = false
            }
            failStop(error)
        } catch {
            lock.withLock {
                failedBatchCount = Self.saturatingAdd(failedBatchCount, 1)
                flushScheduled = false
            }
            failStop(.acknowledgementUnavailable)
        }
    }

    private func deliverRetainingUntilAcknowledged(
        _ batch: DoryFSWorkerCoherenceBatch
    ) throws {
        let exactFrame: Data
        do {
            exactFrame = try DoryFSWorkerCoherenceCodec.encode(batch)
        } catch {
            throw DoryFSWorkerHostCoherenceError.planOverflow
        }
        let expected = try DoryFSWorkerCoherenceAcknowledgement(accepting: batch)
        for _ in 0..<Self.acknowledgementAttempts {
            do {
                let reply = try exchange(exactFrame)
                guard try DoryFSWorkerCoherenceCodec.decodeAcknowledgement(reply) == expected else {
                    throw DoryFSWorkerHostCoherenceError.invalidAcknowledgement
                }
                return
            } catch let error as DoryFSWorkerHostCoherenceError {
                if error == .invalidAcknowledgement { throw error }
            } catch {
                continue
            }
        }
        throw DoryFSWorkerHostCoherenceError.acknowledgementUnavailable
    }

    private func plan(
        _ incoming: [Change],
        endpoint: Endpoint
    ) throws -> DoryFSWorkerCoherenceBatch? {
        var exactByPath = [String: Change]()
        for change in incoming {
            guard endpoint.contains(change.path) else { continue }
            if var existing = exactByPath[change.path] {
                existing.flags |= change.flags
                existing.eventID = max(existing.eventID, change.eventID)
                existing.directoryAggregate = existing.directoryAggregate || change.directoryAggregate
                exactByPath[change.path] = existing
            } else {
                exactByPath[change.path] = change
            }
        }

        let namespaceMask = UInt32(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        if exactByPath.values.contains(where: { $0.flags & namespaceMask != 0 }) {
            let eventID = exactByPath.values.map(\.eventID).max() ?? 0
            let flags = UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
            )
            for path in endpoint.hostFS.knownStaleHostPathsForNamespaceReconciliation()
                where exactByPath[path] == nil {
                exactByPath[path] = Change(
                    path: path,
                    flags: flags,
                    eventID: eventID,
                    directoryAggregate: false
                )
            }
        }

        var expanded = [String: Change]()
        let directoryFlags = UInt32(
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemInodeMetaMod
        )
        for change in exactByPath.values {
            let changes: [Change]
            if change.directoryAggregate {
                changes = endpoint.hostFS.knownHostPaths(inHostDirectory: change.path).map {
                    Change(
                        path: $0,
                        flags: directoryFlags,
                        eventID: change.eventID,
                        directoryAggregate: false
                    )
                }
            } else {
                changes = [change]
            }
            for exact in changes {
                if var existing = expanded[exact.path] {
                    existing.flags |= exact.flags
                    existing.eventID = max(existing.eventID, exact.eventID)
                    expanded[exact.path] = existing
                } else {
                    expanded[exact.path] = exact
                }
            }
        }

        var invalidations = [String: DoryFSWorkerCoherenceInvalidation]()
        var deletedNodeIDs = Set<UInt64>()
        var nudgePaths = Set<String>()
        for change in expanded.values.sorted(by: { $0.path < $1.path }) {
            let aliasPaths = change.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
                ? [change.path]
                : endpoint.hostFS.knownIdentityAliasHostPaths(forHostPath: change.path)
            for aliasPath in aliasPaths {
                guard let snapshot = endpoint.hostFS.invalidationSnapshot(forHostPath: aliasPath),
                      !snapshot.nodeIDs.isEmpty || !snapshot.parentNodeIDs.isEmpty else { continue }
                let pathIsMissing: Bool
                do {
                    pathIsMissing = try endpoint.hostFS.eventPathIsMissing(
                        forHostPath: aliasPath
                    )
                } catch {
                    throw DoryFSWorkerHostCoherenceError.capabilityAuthorityUnavailable
                }
                let planned = Self.plannedInvalidations(
                    change: Change(
                        path: aliasPath,
                        flags: change.flags,
                        eventID: change.eventID,
                        directoryAggregate: false
                    ),
                    snapshot: snapshot,
                    pathIsMissing: pathIsMissing,
                    permitsContentInvalidation: aliasPath == change.path
                )
                endpoint.hostFS.reconcileHostInvalidation(
                    forHostPath: aliasPath,
                    staleNodeIDs: snapshot.staleNodeIDs
                )
                for (key, invalidation) in planned {
                    if case .delete(_, let childNodeID, _) = invalidation {
                        deletedNodeIDs.insert(childNodeID)
                        invalidations.removeValue(forKey: "i:\(childNodeID)")
                    }
                    if case .inode(let nodeID, _, _) = invalidation,
                       deletedNodeIDs.contains(nodeID) {
                        continue
                    }
                    invalidations[key] = Self.merge(invalidation, preserving: invalidations[key])
                }
                if endpoint.watcherNudgesEnabled {
                    do {
                        if let relative = try endpoint.hostFS
                            .nearestEventNudgeRelativePath(forHostPath: aliasPath) {
                            nudgePaths.insert(relative)
                        }
                    } catch {
                        throw DoryFSWorkerHostCoherenceError.capabilityAuthorityUnavailable
                    }
                }
            }
        }
        for nodeID in deletedNodeIDs {
            invalidations["i:\(nodeID)"] = .inode(nodeID: nodeID, offset: -1, length: 0)
        }
        guard !invalidations.isEmpty || !nudgePaths.isEmpty else { return nil }
        let batchID = lock.withLock { () -> UInt64 in
            let value = nextBatchID
            nextBatchID = value == UInt64.max ? 1 : value + 1
            return value
        }
        do {
            return try DoryFSWorkerCoherenceBatch(
                generation: generation,
                shareCapabilityID: endpoint.capability,
                batchID: batchID,
                invalidations: invalidations.keys.sorted().compactMap { invalidations[$0] },
                nudgeRelativePaths: nudgePaths.sorted()
            )
        } catch {
            throw DoryFSWorkerHostCoherenceError.planOverflow
        }
    }

    private static func plannedInvalidations(
        change: Change,
        snapshot: HostFSInvalidationSnapshot,
        pathIsMissing: Bool,
        permitsContentInvalidation: Bool
    ) -> [String: DoryFSWorkerCoherenceInvalidation] {
        var result = [String: DoryFSWorkerCoherenceInvalidation]()
        let namespaceMask = UInt32(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        let deletionCandidates: Set<UInt64>
        if change.representsRemoval(pathIsMissing: pathIsMissing)
            || change.flags & namespaceMask != 0 {
            deletionCandidates = Set(snapshot.staleNodeIDs + snapshot.unverifiedNodeIDs)
        } else {
            deletionCandidates = Set(snapshot.staleNodeIDs)
        }
        let renameSource = change.representsRemoval(pathIsMissing: pathIsMissing)
            && change.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let survivingLinks = Set(snapshot.survivingLinkNodeIDs)
        let nonFinalUnlinks = renameSource
            ? Set<UInt64>()
            : deletionCandidates.intersection(survivingLinks)
        let deleteNodeIDs = renameSource
            ? deletionCandidates
            : deletionCandidates.subtracting(survivingLinks)
        let staleNodeIDs = Set(snapshot.staleNodeIDs)
        let invalidatesContent = permitsContentInvalidation
            && change.flags & UInt32(kFSEventStreamEventFlagItemModified) != 0

        for nodeID in snapshot.nodeIDs where !deleteNodeIDs.contains(nodeID) {
            if nonFinalUnlinks.contains(nodeID) {
                result["i:\(nodeID)"] = .inode(nodeID: nodeID, offset: -1, length: 0)
            } else if !staleNodeIDs.contains(nodeID) {
                result["i:\(nodeID)"] = invalidatesContent
                    ? .inode(nodeID: nodeID, offset: 0, length: -1)
                    : .inode(nodeID: nodeID, offset: -1, length: 0)
            }
        }
        for nodeID in deleteNodeIDs {
            result["i:\(nodeID)"] = .inode(nodeID: nodeID, offset: -1, length: 0)
        }
        guard let name = snapshot.entryName else { return result }
        for parentNodeID in snapshot.parentNodeIDs {
            for childNodeID in deleteNodeIDs.sorted() {
                result["d:\(parentNodeID):\(childNodeID):\(name)"] = .delete(
                    parentNodeID: parentNodeID,
                    childNodeID: childNodeID,
                    name: name
                )
            }
        }
        let identityMayHaveChanged = !snapshot.staleNodeIDs.isEmpty
            || !snapshot.unverifiedNodeIDs.isEmpty
        let shouldInvalidateEntry = change.representsRemoval(pathIsMissing: pathIsMissing)
            ? !nonFinalUnlinks.isEmpty
            : identityMayHaveChanged
        if shouldInvalidateEntry, !snapshot.nodeIDs.isEmpty {
            for parentNodeID in snapshot.parentNodeIDs {
                result["e:\(parentNodeID):\(name)"] = .entry(
                    parentNodeID: parentNodeID,
                    name: name,
                    flags: 0
                )
            }
        }
        return result
    }

    private static func merge(
        _ incoming: DoryFSWorkerCoherenceInvalidation,
        preserving existing: DoryFSWorkerCoherenceInvalidation?
    ) -> DoryFSWorkerCoherenceInvalidation {
        guard let existing else { return incoming }
        if case .inode(_, 0, -1) = existing,
           case .inode(_, -1, 0) = incoming {
            return existing
        }
        return incoming
    }

    private func failStop(_ error: DoryFSWorkerHostCoherenceError) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !terminalFailureReported else { return false }
            terminalFailureReported = true
            running = false
            return true
        }
        guard shouldReport else { return }
        // Revoke the event sources before surfacing terminal loss. Production exits the worker;
        // embedders and tests still get deterministic cleanup instead of live orphan streams.
        stop()
        onFailure(error)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
