import Foundation

/// Immutable per-share resource ceilings. Production uses one explicit profile; tests inject
/// smaller values through `HostFS` without environment switches or process-global state.
public struct FuseResourceLimits: Equatable, Sendable {
    public let maximumLiveNonRootNodes: Int
    public let maximumFileHandles: Int
    public let maximumDirectoryHandles: Int
    /// Stable cookie slots retained only after an entry is considered for a guest response. This
    /// is aggregate across every open directory in one share, not a per-handle multiplier.
    public let maximumDirectoryCursorEntries: Int
    /// Aggregate UTF-8 bytes retained by those stable cookie slots. Container overhead is bounded
    /// separately by the entry count; names themselves cannot amplify memory beyond this ceiling.
    public let maximumDirectoryCursorNameBytes: Int
    public let maximumAdvisoryLockOwners: Int
    public let maximumPendingBlockingLocks: Int

    /// Per-share logical ceilings for package-manager-scale directory trees. The separate worker
    /// process establishes its own bounded descriptor ceiling before accepting XPC authority;
    /// raising the VMM process cannot provide that capacity.
    public static let production = FuseResourceLimits(
        maximumLiveNonRootNodes: 65_536,
        maximumFileHandles: 16_384,
        maximumDirectoryHandles: 4_096,
        maximumDirectoryCursorEntries: 262_144,
        maximumDirectoryCursorNameBytes: 32 * 1_024 * 1_024,
        maximumAdvisoryLockOwners: 4_096,
        maximumPendingBlockingLocks: 1_024
    )

    public init(
        maximumLiveNonRootNodes: Int,
        maximumFileHandles: Int,
        maximumDirectoryHandles: Int,
        maximumDirectoryCursorEntries: Int = 262_144,
        maximumDirectoryCursorNameBytes: Int = 32 * 1_024 * 1_024,
        maximumAdvisoryLockOwners: Int,
        maximumPendingBlockingLocks: Int
    ) {
        precondition(maximumLiveNonRootNodes > 0)
        precondition(maximumFileHandles > 0)
        precondition(maximumDirectoryHandles > 0)
        precondition(maximumDirectoryCursorEntries > 0)
        precondition(maximumDirectoryCursorNameBytes > 0)
        precondition(maximumAdvisoryLockOwners > 0)
        precondition(maximumPendingBlockingLocks > 0)
        self.maximumLiveNonRootNodes = maximumLiveNonRootNodes
        self.maximumFileHandles = maximumFileHandles
        self.maximumDirectoryHandles = maximumDirectoryHandles
        self.maximumDirectoryCursorEntries = maximumDirectoryCursorEntries
        self.maximumDirectoryCursorNameBytes = maximumDirectoryCursorNameBytes
        self.maximumAdvisoryLockOwners = maximumAdvisoryLockOwners
        self.maximumPendingBlockingLocks = maximumPendingBlockingLocks
    }
}

public enum FuseResourceKind: String, CaseIterable, Equatable, Sendable {
    case liveNonRootNodes
    case fileHandles
    case directoryHandles
    case directoryCursorEntries
    case directoryCursorNameBytes
    case advisoryLockOwners
    case pendingBlockingLocks
}

public struct FuseResourceQuotaError: Error, Equatable, Sendable {
    public let resource: FuseResourceKind
    public let limit: Int

    public init(resource: FuseResourceKind, limit: Int) {
        self.resource = resource
        self.limit = limit
    }
}

public struct FuseResourceSnapshot: Equatable, Sendable {
    public let limits: FuseResourceLimits
    public let liveNonRootNodes: Int
    public let fileHandles: Int
    public let directoryHandles: Int
    public let directoryCursorEntries: Int
    public let directoryCursorNameBytes: Int
    public let advisoryLockOwners: Int
    public let pendingBlockingLocks: Int

    public init(
        limits: FuseResourceLimits,
        liveNonRootNodes: Int,
        fileHandles: Int,
        directoryHandles: Int,
        directoryCursorEntries: Int,
        directoryCursorNameBytes: Int,
        advisoryLockOwners: Int,
        pendingBlockingLocks: Int
    ) {
        self.limits = limits
        self.liveNonRootNodes = liveNonRootNodes
        self.fileHandles = fileHandles
        self.directoryHandles = directoryHandles
        self.directoryCursorEntries = directoryCursorEntries
        self.directoryCursorNameBytes = directoryCursorNameBytes
        self.advisoryLockOwners = advisoryLockOwners
        self.pendingBlockingLocks = pendingBlockingLocks
    }
}

/// One atomic counter authority for all resources owned by a share. Callers keep the returned token
/// for exactly as long as the admitted resource remains live; explicit release is idempotent and
/// deinit is a rollback fence for every failed partial admission.
final class FuseResourceQuota: @unchecked Sendable {
    let limits: FuseResourceLimits

    private let lock = NSLock()
    private var counts: [FuseResourceKind: Int] = [:]

    init(limits: FuseResourceLimits) {
        self.limits = limits
    }

    func acquire(_ resource: FuseResourceKind) throws -> FuseResourceToken {
        try lock.withLock {
            let current = counts[resource, default: 0]
            let limit = limit(for: resource)
            guard current < limit else {
                throw FuseResourceQuotaError(resource: resource, limit: limit)
            }
            counts[resource] = current + 1
            return FuseResourceToken(resource: resource, quota: self)
        }
    }

    /// Atomically reserves one stable directory cookie and its retained UTF-8 name. Keeping the
    /// two counters under one lock avoids a partially admitted slot when either aggregate limit is
    /// exhausted.
    func reserveDirectoryCursorEntry(nameByteCount: Int) throws {
        precondition(nameByteCount > 0)
        try lock.withLock {
            let entryCount = counts[.directoryCursorEntries, default: 0]
            guard entryCount < limits.maximumDirectoryCursorEntries else {
                throw FuseResourceQuotaError(
                    resource: .directoryCursorEntries,
                    limit: limits.maximumDirectoryCursorEntries
                )
            }
            let nameBytes = counts[.directoryCursorNameBytes, default: 0]
            let (newNameBytes, overflow) = nameBytes.addingReportingOverflow(nameByteCount)
            guard !overflow, newNameBytes <= limits.maximumDirectoryCursorNameBytes else {
                throw FuseResourceQuotaError(
                    resource: .directoryCursorNameBytes,
                    limit: limits.maximumDirectoryCursorNameBytes
                )
            }
            counts[.directoryCursorEntries] = entryCount + 1
            counts[.directoryCursorNameBytes] = newNameBytes
        }
    }

    func releaseDirectoryCursor(entries: Int, nameBytes: Int) {
        guard entries > 0 || nameBytes > 0 else { return }
        precondition(entries >= 0 && nameBytes >= 0)
        lock.withLock {
            let currentEntries = counts[.directoryCursorEntries, default: 0]
            let currentNameBytes = counts[.directoryCursorNameBytes, default: 0]
            precondition(currentEntries >= entries, "unbalanced directory cursor entry release")
            precondition(currentNameBytes >= nameBytes, "unbalanced directory cursor byte release")
            updateCount(.directoryCursorEntries, to: currentEntries - entries)
            updateCount(.directoryCursorNameBytes, to: currentNameBytes - nameBytes)
        }
    }

    func snapshot() -> FuseResourceSnapshot {
        lock.withLock {
            FuseResourceSnapshot(
                limits: limits,
                liveNonRootNodes: counts[.liveNonRootNodes, default: 0],
                fileHandles: counts[.fileHandles, default: 0],
                directoryHandles: counts[.directoryHandles, default: 0],
                directoryCursorEntries: counts[.directoryCursorEntries, default: 0],
                directoryCursorNameBytes: counts[.directoryCursorNameBytes, default: 0],
                advisoryLockOwners: counts[.advisoryLockOwners, default: 0],
                pendingBlockingLocks: counts[.pendingBlockingLocks, default: 0]
            )
        }
    }

    fileprivate func release(_ resource: FuseResourceKind) {
        lock.withLock {
            let current = counts[resource, default: 0]
            precondition(current > 0, "unbalanced FUSE resource token release")
            updateCount(resource, to: current - 1)
        }
    }

    private func updateCount(_ resource: FuseResourceKind, to value: Int) {
        if value == 0 {
            counts.removeValue(forKey: resource)
        } else {
            counts[resource] = value
        }
    }

    private func limit(for resource: FuseResourceKind) -> Int {
        switch resource {
        case .liveNonRootNodes: limits.maximumLiveNonRootNodes
        case .fileHandles: limits.maximumFileHandles
        case .directoryHandles: limits.maximumDirectoryHandles
        case .directoryCursorEntries: limits.maximumDirectoryCursorEntries
        case .directoryCursorNameBytes: limits.maximumDirectoryCursorNameBytes
        case .advisoryLockOwners: limits.maximumAdvisoryLockOwners
        case .pendingBlockingLocks: limits.maximumPendingBlockingLocks
        }
    }
}

final class FuseResourceToken: @unchecked Sendable {
    let resource: FuseResourceKind

    private let lock = NSLock()
    private var quota: FuseResourceQuota?

    fileprivate init(resource: FuseResourceKind, quota: FuseResourceQuota) {
        self.resource = resource
        self.quota = quota
    }

    func release() {
        let quota = lock.withLock { () -> FuseResourceQuota? in
            let current = self.quota
            self.quota = nil
            return current
        }
        quota?.release(resource)
    }

    deinit {
        release()
    }
}
