import CoreServices
import Darwin
import Foundation

public struct HostFSEventChange: Sendable, Equatable {
    public var hostPath: String
    public var guestPath: String
    public var flags: UInt32
    public var eventID: UInt64
    /// Only the pathname reported by FSEvents may invalidate data pages. Namespace fanout to a
    /// surviving hard-link alias carries metadata/nlink semantics, never permission to discard
    /// that alias's potentially dirty cache.
    public var permitsContentInvalidation: Bool
    /// The stream reported a changed directory rather than one exact file. The coherence
    /// coordinator expands this only over HostFS bindings already known in that directory.
    public var isDirectoryAggregate: Bool

    public init(
        hostPath: String,
        guestPath: String,
        flags: UInt32,
        eventID: UInt64,
        permitsContentInvalidation: Bool = true,
        isDirectoryAggregate: Bool = false
    ) {
        self.hostPath = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        self.guestPath = guestPath
        self.flags = flags
        self.eventID = eventID
        self.permitsContentInvalidation = permitsContentInvalidation
        self.isDirectoryAggregate = isDirectoryAggregate
    }

    /// FSEvents asks clients to rescan after any of these markers. Continuing to serve cached
    /// dentries after a dropped event would make the host and guest disagree, so the coherence
    /// coordinator must degrade immediately instead of treating this as an ordinary path edit.
    public var requiresRescan: Bool {
        let mask = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged |
            // HostFS pins root/directory descriptors. A detach/remount can replace the filesystem
            // identity underneath those fds even when RootChanged is not co-reported.
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
        )
        return flags & mask != 0
    }

    /// A same-mode chmod generated solely to wake Linux watchers is expected to return as an inode
    /// metadata event. Only this narrow shape is eligible for one-shot echo suppression; content,
    /// namespace, xattr, ownership, overflow, and root events always make the round trip.
    public var isMetadataOnly: Bool {
        // macOS reports fchmod(2) as ItemChangeOwner even when uid/gid are unchanged. Treat both
        // metadata classifications as echo-eligible; the path token still prevents an unrelated
        // chmod from being discarded.
        let metadata = UInt32(
            kFSEventStreamEventFlagItemInodeMetaMod |
            kFSEventStreamEventFlagItemChangeOwner
        )
        let substantive = UInt32(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemFinderInfoMod |
            kFSEventStreamEventFlagItemXattrMod |
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
        )
        return !requiresRescan && flags & metadata != 0 && flags & substantive == 0
    }

    /// FSEvents may coalesce remove/create or both sides of an atomic replacement into one path.
    /// DELETE is correct only while that name is actually absent; if a new object already occupies
    /// it, INVAL_ENTRY preserves the replacement's watch/dentry semantics.
    public var representsRemoval: Bool {
        let namespaceMask = UInt32(
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        guard flags & namespaceMask != 0 else {
            return false
        }
        var info = stat()
        if lstat(hostPath, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}

public struct HostFSEventShare: Sendable, Equatable {
    public var hostRoot: String
    /// FSEvents may return either the spelling used to create its stream or the canonical realpath
    /// spelling (for example `/var` versus `/private/var`). Mapping accepts both.
    public var hostRootAliases: [String]
    public var guestRoot: String

    public init(hostRoot: String, guestRoot: String) {
        let supplied = URL(fileURLWithPath: hostRoot).standardizedFileURL.path
        let canonical = URL(fileURLWithPath: supplied)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        self.hostRoot = supplied
        self.hostRootAliases = Array(Set([supplied, canonical])).sorted { $0.count > $1.count }
        if guestRoot.count > 1, guestRoot.hasSuffix("/") {
            self.guestRoot = String(guestRoot.dropLast())
        } else {
            self.guestRoot = guestRoot
        }
    }

    public func mapHostPathToGuest(_ path: String) -> String? {
        guard let relative = relativePath(forHostPath: path) else { return nil }
        guard !relative.isEmpty else { return guestRoot }
        return guestRoot == "/" ? "/" + relative : guestRoot + "/" + relative
    }

    /// Returns the narrowest stable FSEvents root for an accessed path: the first real child of
    /// this broad export. Watching `$HOME/Projects` preserves arbitrary bind reachability without
    /// subscribing the host daemon to every change anywhere under `$HOME`.
    public func topLevelObservationRoot(forHostPath path: String) -> String? {
        guard let (normalized, root) = normalizedPathAndRootInsideShare(path), normalized != root else {
            return nil
        }
        let prefix = root == "/" ? "/" : root + "/"
        let relative = normalized.dropFirst(prefix.count)
        guard let first = relative.split(separator: "/", omittingEmptySubsequences: true).first else {
            return nil
        }
        return root == "/" ? "/" + first : root + "/" + first
    }

    /// Predicts the exact path the guest agent will chmod. Missing/deleted entries fall back to the
    /// nearest existing regular file or directory, but never above this share root. Symlinks are not
    /// nudged because the guest opens its final component with O_NOFOLLOW.
    public func nudgeTarget(forHostPath path: String) -> (host: String, guest: String)? {
        guard let (initialCandidate, boundary) = normalizedPathAndRootInsideShare(path) else {
            return nil
        }
        var candidate = initialCandidate
        while true {
            var info = stat()
            if lstat(candidate, &info) == 0 {
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) {
                    guard let guest = mapHostPathToGuest(candidate) else { return nil }
                    return (candidate, guest)
                }
            } else if errno != ENOENT && errno != ENOTDIR && errno != ELOOP {
                return nil
            }
            guard candidate != boundary else { return nil }
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard isPath(parent, inside: boundary), parent != candidate else { return nil }
            candidate = parent
        }
    }

    private func relativePath(forHostPath path: String) -> String? {
        guard let (normalized, root) = normalizedPathAndRootInsideShare(path) else { return nil }
        if normalized == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        return String(normalized.dropFirst(prefix.count))
    }

    private func normalizedPathAndRootInsideShare(_ path: String) -> (String, String)? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let root = hostRootAliases.first(where: { isPath(normalized, inside: $0) }) else {
            return nil
        }
        return (normalized, root)
    }

    private func isPath(_ candidate: String, inside root: String) -> Bool {
        if candidate == root { return true }
        let prefix = root == "/" ? "/" : root + "/"
        return candidate.hasPrefix(prefix)
    }
}

public enum HostFSEventRelayError: Error, Equatable, Sendable {
    case streamCreationFailed
    case streamStartFailed
    case suppressionLedgerFull(limit: Int)
    case repeatedSyntheticEcho(path: String)
}

public enum HostShareCoherenceStartupError: Error, Equatable, Sendable {
    case eventRelayUnavailable(productionShareCount: Int)
}

/// Production host shares are safe only while their host-change observation path is live. This
/// applies to writable shares and read-only shares alike: read-only guest mappings can still retain
/// stale host page cache. Engine startup therefore fails instead of running any production share
/// without the relay; an empty production-share set has no such requirement.
public enum HostShareCoherenceStartupPolicy {
    public static func requireEventRelay(
        started: Bool,
        productionShareCount: Int
    ) throws {
        guard productionShareCount > 0 else { return }
        guard started else {
            throw HostShareCoherenceStartupError.eventRelayUnavailable(
                productionShareCount: productionShareCount
            )
        }
    }
}

public final class FSEventBatcher: @unchecked Sendable {
    public typealias SendBatch = @Sendable ([HostFSEventChange]) async throws -> Void

    /// An npm install can emit tens of thousands of distinct FileEvents before the asynchronous
    /// coherence round trip finishes. Keep one bounded batch comfortably above that ordinary
    /// developer workload: treating it as an observation loss needlessly restarts the VM even
    /// though CoreServices delivered every path. A true FSEvents dropped-event marker still takes
    /// the existing fail-closed recovery path, and this remains a hard cap against unbounded use.
    public static let defaultPendingLimit = 65_536

    private let shares: [HostFSEventShare]
    private let send: SendBatch
    private let pendingLimit: Int
    private let eventsAreDirectoryAggregates: Bool
    private let lock = NSLock()
    private var pending: [String: HostFSEventChange] = [:]
    private var pendingRequiresRescan = false
    private var receivedEventCount: UInt64 = 0
    private var deliveredBatchCount: UInt64 = 0
    private var failedBatchCount: UInt64 = 0
    private var rescanCollapseCount: UInt64 = 0

    public init(
        shares: [HostFSEventShare],
        pendingLimit: Int = FSEventBatcher.defaultPendingLimit,
        eventsAreDirectoryAggregates: Bool = false,
        send: @escaping SendBatch
    ) {
        // Longest root first makes nested shares deterministic.
        self.shares = shares.sorted { $0.hostRoot.count > $1.hostRoot.count }
        self.pendingLimit = max(1, pendingLimit)
        self.eventsAreDirectoryAggregates = eventsAreDirectoryAggregates
        self.send = send
    }

    public func enqueue(hostPaths: [String], flags: [UInt32], eventIDs: [UInt64]) {
        guard hostPaths.count == flags.count, flags.count == eventIDs.count else { return }
        let changes = zip(hostPaths.indices, hostPaths).compactMap { index, path in
            mapHostPath(path, flags: flags[index], eventID: eventIDs[index])
        }
        guard !changes.isEmpty else { return }
        let batchLatestEventID = changes.map(\.eventID).max() ?? 0
        lock.withLock {
            receivedEventCount &+= UInt64(changes.count)
            for change in changes {
                if change.requiresRescan {
                    FileHandle.standardError.write(Data(
                        "dory-hv: FSEvents rescan marker path=\(change.hostPath) flags=0x\(String(change.flags, radix: 16)) event=\(change.eventID)\n".utf8
                    ))
                }
                if pendingRequiresRescan { break }
                if pending[change.hostPath] == nil, pending.count >= pendingLimit {
                    let latest = max(batchLatestEventID, pending.values.map(\.eventID).max() ?? 0)
                    collapseToRescanLocked(latestEventID: latest, reason: "pending-overflow")
                    break
                }
                if var existing = pending[change.hostPath] {
                    existing.flags |= change.flags
                    existing.eventID = max(existing.eventID, change.eventID)
                    pending[change.hostPath] = existing
                } else {
                    pending[change.hostPath] = change
                }
            }
        }
    }

    public func enqueue(hostPaths: [String]) {
        enqueue(
            hostPaths: hostPaths,
            flags: Array(repeating: 0, count: hostPaths.count),
            eventIDs: Array(repeating: 0, count: hostPaths.count)
        )
    }

    public func flushNow() async throws {
        let changes = lock.withLock { () -> [HostFSEventChange] in
            let changes = pending.values.sorted {
                $0.guestPath == $1.guestPath ? $0.hostPath < $1.hostPath : $0.guestPath < $1.guestPath
            }
            pending.removeAll(keepingCapacity: true)
            pendingRequiresRescan = false
            return changes
        }
        guard !changes.isEmpty else { return }
        do {
            try await send(changes)
            lock.withLock { deliveredBatchCount &+= 1 }
        } catch {
            lock.withLock {
                failedBatchCount &+= 1
                let latest = max(
                    changes.map(\.eventID).max() ?? 0,
                    pending.values.map(\.eventID).max() ?? 0
                )
                if pendingRequiresRescan
                    || changes.contains(where: \.requiresRescan)
                    || pending.count + changes.count > pendingLimit {
                    collapseToRescanLocked(latestEventID: latest, reason: "retry-overflow-or-rescan")
                } else {
                    for change in changes {
                        if var newer = pending[change.hostPath] {
                            newer.flags |= change.flags
                            newer.eventID = max(newer.eventID, change.eventID)
                            pending[change.hostPath] = newer
                        } else {
                            pending[change.hostPath] = change
                        }
                    }
                }
            }
            throw error
        }
    }

    public var hasPending: Bool {
        lock.withLock { !pending.isEmpty }
    }

    public func discardPending() {
        lock.withLock {
            pending.removeAll(keepingCapacity: false)
            pendingRequiresRescan = false
        }
    }

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    public var diagnostics: FSEventBatcherDiagnostics {
        lock.withLock {
            FSEventBatcherDiagnostics(
                pendingCount: pending.count,
                pendingLimit: pendingLimit,
                pendingRequiresRescan: pendingRequiresRescan,
                receivedEventCount: receivedEventCount,
                deliveredBatchCount: deliveredBatchCount,
                failedBatchCount: failedBatchCount,
                rescanCollapseCount: rescanCollapseCount
            )
        }
    }

    public func mapHostPathToGuest(_ path: String) -> String? {
        shares.lazy.compactMap { $0.mapHostPathToGuest(path) }.first
    }

    public func mapHostPath(_ path: String, flags: UInt32, eventID: UInt64) -> HostFSEventChange? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let guest = mapHostPathToGuest(normalized) else { return nil }
        return HostFSEventChange(
            hostPath: normalized,
            guestPath: guest,
            flags: flags,
            eventID: eventID,
            isDirectoryAggregate: eventsAreDirectoryAggregates
        )
    }

    private func collapseToRescanLocked(latestEventID: UInt64, reason: String) {
        FileHandle.standardError.write(Data(
            "dory-hv: FSEvents batch collapsed reason=\(reason) pending=\(pending.count) event=\(latestEventID)\n".utf8
        ))
        pending.removeAll(keepingCapacity: true)
        pendingRequiresRescan = true
        rescanCollapseCount &+= 1
        let flags = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped
        )
        for share in shares {
            pending[share.hostRoot] = HostFSEventChange(
                hostPath: share.hostRoot,
                guestPath: share.guestRoot,
                flags: flags,
                eventID: latestEventID
            )
        }
    }
}

public struct FSEventBatcherDiagnostics: Codable, Equatable, Sendable {
    public var pendingCount: Int
    public var pendingLimit: Int
    public var pendingRequiresRescan: Bool
    public var receivedEventCount: UInt64
    public var deliveredBatchCount: UInt64
    public var failedBatchCount: UInt64
    public var rescanCollapseCount: UInt64
}

public struct HostFSEventRelayDiagnostics: Codable, Equatable, Sendable {
    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var configuredRoots: [String]
    public var observationRoots: [String]
    public var running: Bool
    public var flushScheduled: Bool
    public var consecutiveFailures: Int
    public var batcher: FSEventBatcherDiagnostics

    public init(
        generatedAt: Date = Date(),
        configuredRoots: [String],
        observationRoots: [String],
        running: Bool,
        flushScheduled: Bool,
        consecutiveFailures: Int,
        batcher: FSEventBatcherDiagnostics
    ) {
        self.schema = "dev.dory.host-share.resources"
        self.version = 1
        self.generatedAt = generatedAt
        self.configuredRoots = configuredRoots
        self.observationRoots = observationRoots
        self.running = running
        self.flushScheduled = flushScheduled
        self.consecutiveFailures = consecutiveFailures
        self.batcher = batcher
    }
}

/// Watches configured host roots and emits loss-aware, retryable batches. This type deliberately
/// does not decide cache policy; the coordinator must invalidate the guest kernel and await its
/// completion barrier before sending a watcher nudge.
public final class HostFSEventRelay: @unchecked Sendable {
    public typealias SendBatch = FSEventBatcher.SendBatch
    public typealias FailureHandler = @Sendable (any Error) -> Void
    @usableFromInline
    static let defaultDebounceMilliseconds: UInt64 = 1

    private let shares: [HostFSEventShare]
    private let batcher: FSEventBatcher
    private let debounceNanoseconds: UInt64
    private let onFailure: FailureHandler
    private let observeRootsOnDemand: Bool
    private let queue = DispatchQueue(label: "dev.dory.hostfs.fsevents")
    /// CoreServices owns `queue` and can report UserDropped when its callback cannot drain quickly
    /// enough. URL normalization, share mapping, and pending-dictionary merging are substantially
    /// more expensive than copying one delivered batch, so perform them on a separate ordered queue
    /// and return the FSEvents callback promptly.
    private let processingQueue = DispatchQueue(label: "dev.dory.hostfs.fsevents.processing")
    private let lock = NSLock()
    private var streams: [String: FSEventStreamRef] = [:]
    private var callbackBoxes: [String: CallbackBox] = [:]
    private var flushScheduled = false
    private var consecutiveFailures = 0
    private var running = false
    private var lifecycleGeneration: UInt64 = 0

    static let streamCreateFlags = FSEventStreamCreateFlags(
        // Directory-level events keep a whole-home share from producing one record per package
        // file. HostShareCoherenceCoordinator expands each changed directory only over immediate
        // HostFS bindings the guest already knows, retaining precise cache and watcher behavior.
        // RootChanged is emitted only with WatchRoot. Without it a renamed/deleted share root
        // could silently leave positive cache state attached to an obsolete host directory.
        kFSEventStreamCreateFlagWatchRoot |
        // HostFS mutations and watcher nudges run in this same dory-hv process. Excluding
        // self-originated events prevents guest writes from being reflected back into the
        // guest while preserving edits made by editors and tools on macOS.
        kFSEventStreamCreateFlagIgnoreSelf |
        // Ask FSEvents to mark any self event that still reaches the stream. IgnoreSelf normally
        // suppresses it, but relying on that suppression alone lets a package-manager create storm
        // be mistaken for an external host edit when the system reports it anyway.
        kFSEventStreamCreateFlagMarkSelf |
        kFSEventStreamCreateFlagUseCFTypes
    )

    /// `dory-hv` performs the host syscalls for guest FUSE mutations. Those paths are already
    /// coherent in its HostFS state and must not be fed back through the host-edit invalidation
    /// pipeline. The explicit OwnEvent check is the fail-safe complement to IgnoreSelf.
    static func ignoresOwnEvent(_ flags: UInt32) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagOwnEvent) != 0
    }

    public init(
        shares: [HostFSEventShare],
        debounceMilliseconds: UInt64 = HostFSEventRelay.defaultDebounceMilliseconds,
        observeRootsOnDemand: Bool = false,
        send: @escaping SendBatch,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        self.shares = shares
        self.batcher = FSEventBatcher(
            shares: shares,
            eventsAreDirectoryAggregates: true,
            send: send
        )
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
        self.observeRootsOnDemand = observeRootsOnDemand
        self.onFailure = onFailure
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        guard !shares.isEmpty else { return false }
        let alreadyRunning = lock.withLock { running }
        if alreadyRunning { return true }
        lock.withLock {
            lifecycleGeneration &+= 1
            running = true
            flushScheduled = false
            consecutiveFailures = 0
        }
        if observeRootsOnDemand { return true }
        for root in shares.map(\.hostRoot) {
            guard startStream(root: root) else {
                stop()
                return false
            }
        }
        return true
    }

    /// Adds one narrow observation root without disturbing existing streams. This is synchronous:
    /// the FUSE lookup that discovered the path does not return until the stream is live.
    @discardableResult
    public func observe(hostPath: String) -> Bool {
        guard lock.withLock({ running }) else { return false }
        let roots = shares.compactMap { $0.topLevelObservationRoot(forHostPath: hostPath) }
        guard let root = roots.sorted(by: { $0.count > $1.count }).first else { return true }
        if lock.withLock({ streams[root] != nil }) { return true }
        return startStream(root: root)
    }

    public var observationRoots: [String] {
        lock.withLock { streams.keys.sorted() }
    }

    public var diagnostics: HostFSEventRelayDiagnostics {
        let state = lock.withLock {
            (
                roots: streams.keys.sorted(),
                running: running,
                flushScheduled: flushScheduled,
                failures: consecutiveFailures
            )
        }
        return HostFSEventRelayDiagnostics(
            configuredRoots: shares.map(\.hostRoot).sorted(),
            observationRoots: state.roots,
            running: state.running,
            flushScheduled: state.flushScheduled,
            consecutiveFailures: state.failures,
            batcher: batcher.diagnostics
        )
    }

    private func startStream(root: String) -> Bool {
        let box = CallbackBox(relay: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, eventFlags, eventIDs in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
                var paths = [String]()
                var flags = [UInt32]()
                var ids = [UInt64]()
                paths.reserveCapacity(count)
                flags.reserveCapacity(count)
                ids.reserveCapacity(count)
                for index in 0..<count {
                    guard let path = pathsArray.object(at: index) as? String else { continue }
                    let flagsValue = UInt32(eventFlags[index])
                    guard !HostFSEventRelay.ignoresOwnEvent(flagsValue) else { continue }
                    paths.append(path)
                    flags.append(flagsValue)
                    ids.append(UInt64(eventIDs[index]))
                }
                box.relay?.recordFromStream(hostPaths: paths, flags: flags, eventIDs: ids)
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            Self.streamCreateFlags
        ) else {
            onFailure(HostFSEventRelayError.streamCreationFailed)
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            onFailure(HostFSEventRelayError.streamStartFailed)
            return false
        }
        let accepted = lock.withLock { () -> Bool in
            guard running, streams[root] == nil else { return false }
            streams[root] = created
            callbackBoxes[root] = box
            return true
        }
        if !accepted {
            FSEventStreamStop(created)
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
        return true
    }

    public func stop() {
        let existing = lock.withLock { () -> (streams: [FSEventStreamRef], boxes: [CallbackBox]) in
            let existingStreams = Array(streams.values)
            let existingBoxes = Array(callbackBoxes.values)
            streams.removeAll()
            callbackBoxes.removeAll()
            lifecycleGeneration &+= 1
            running = false
            flushScheduled = false
            consecutiveFailures = 0
            return (existingStreams, existingBoxes)
        }
        batcher.discardPending()
        for stream in existing.streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // FSEventStreamContext retains an unretained pointer to each box. The local tuple keeps all
        // boxes alive until every corresponding stream has stopped, invalidated, and released.
        _ = existing.boxes
    }

    public func record(hostPaths: [String], flags: [UInt32], eventIDs: [UInt64]) {
        guard lock.withLock({ running }) else { return }
        batcher.enqueue(hostPaths: hostPaths, flags: flags, eventIDs: eventIDs)
        scheduleFlush()
    }

    func recordFromStream(hostPaths: [String], flags: [UInt32], eventIDs: [UInt64]) {
        guard let generation = lock.withLock({ running ? lifecycleGeneration : nil }) else { return }
        processingQueue.async { [weak self] in
            guard let self,
                  self.lock.withLock({ self.running && self.lifecycleGeneration == generation }) else {
                return
            }
            self.batcher.enqueue(hostPaths: hostPaths, flags: flags, eventIDs: eventIDs)
            self.scheduleFlush()
        }
    }

    public func record(hostPaths: [String]) {
        guard lock.withLock({ running }) else { return }
        batcher.enqueue(hostPaths: hostPaths)
        scheduleFlush()
    }

    private func scheduleFlush() {
        let scheduled = lock.withLock { () -> (delay: UInt64, generation: UInt64)? in
            guard running, !flushScheduled else { return nil }
            flushScheduled = true
            let backoff = min(UInt64(2_000_000_000), debounceNanoseconds << min(consecutiveFailures, 5))
            return (backoff, lifecycleGeneration)
        }
        guard let scheduled else {
            if !lock.withLock({ running }) { batcher.discardPending() }
            return
        }
        Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: scheduled.delay)
            guard self.lock.withLock({
                self.running && self.lifecycleGeneration == scheduled.generation
            }) else {
                self.batcher.discardPending()
                return
            }
            do {
                try await self.batcher.flushNow()
                self.lock.withLock {
                    if self.running, self.lifecycleGeneration == scheduled.generation {
                        self.consecutiveFailures = 0
                    }
                }
            } catch {
                let shouldReport = self.lock.withLock { () -> Bool in
                    guard self.running,
                          self.lifecycleGeneration == scheduled.generation else { return false }
                    self.consecutiveFailures += 1
                    return true
                }
                if shouldReport { self.onFailure(error) }
            }
            let shouldReschedule = self.lock.withLock { () -> Bool in
                guard self.running,
                      self.lifecycleGeneration == scheduled.generation else { return false }
                self.flushScheduled = false
                return self.batcher.hasPending
            }
            if shouldReschedule {
                self.scheduleFlush()
            } else if !self.lock.withLock({
                self.running && self.lifecycleGeneration == scheduled.generation
            }) {
                self.batcher.discardPending()
            }
        }
    }
}

/// One-shot ledger for the metadata-only FSEvent produced by a guest watcher nudge. Cache
/// invalidation still runs for a consumed echo; only the second guest nudge is suppressed.
public final class FSEventEchoSuppressor: @unchecked Sendable {
    private struct Token {
        var sourceEventID: UInt64
        var expiresAt: TimeInterval
        var remainingEchoes: Int
    }

    private let lock = NSLock()
    private let limit: Int
    private let lifetimeSeconds: TimeInterval
    private var tokens: [String: Token] = [:]

    public init(limit: Int = 8_192, lifetimeSeconds: TimeInterval = 2) {
        self.limit = max(1, limit)
        self.lifetimeSeconds = max(0.05, lifetimeSeconds)
    }

    public func register(hostPath: String, sourceEventID: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        let path = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        try lock.withLock {
            expireLocked(now: now)
            guard tokens[path] != nil || tokens.count < limit else {
                throw HostFSEventRelayError.suppressionLedgerFull(limit: limit)
            }
            tokens[path] = Token(
                sourceEventID: max(tokens[path]?.sourceEventID ?? 0, sourceEventID),
                expiresAt: now + lifetimeSeconds,
                // One token per nudge. A small burst on one path can legitimately have several
                // in-flight chmod echoes, so count them rather than overwriting a one-shot token.
                remainingEchoes: min(32, (tokens[path]?.remainingEchoes ?? 0) + 1)
            )
        }
    }

    public func consumeIfSyntheticEcho(
        _ change: HostFSEventChange,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard change.isMetadataOnly else { return false }
        return lock.withLock {
            expireLocked(now: now)
            guard var token = tokens[change.hostPath],
                  change.eventID == 0 || change.eventID > token.sourceEventID else { return false }
            token.remainingEchoes -= 1
            if token.remainingEchoes == 0 {
                tokens.removeValue(forKey: change.hostPath)
            } else {
                tokens[change.hostPath] = token
            }
            return true
        }
    }

    public func clear() {
        lock.withLock { tokens.removeAll(keepingCapacity: false) }
    }

    private func expireLocked(now: TimeInterval) {
        tokens = tokens.filter { $0.value.expiresAt > now }
    }
}

private final class CallbackBox {
    weak var relay: HostFSEventRelay?

    init(relay: HostFSEventRelay) {
        self.relay = relay
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
