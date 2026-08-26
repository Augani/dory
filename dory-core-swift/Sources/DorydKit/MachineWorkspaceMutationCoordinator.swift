import Foundation

/// Serializes mutations for one workspace without retaining idle locks or coupling unrelated
/// workspaces. Entries count both holders and waiters and are removed immediately after the last
/// lease releases, so adversarial workspace identifiers cannot grow an unbounded lock registry.
final class MachineWorkspaceMutationCoordinator: @unchecked Sendable {
    final class Lease {
        private let stateLock = NSLock()
        private var releaseOperation: (() -> Void)?

        fileprivate init(release: @escaping () -> Void) {
            releaseOperation = release
        }

        func release() {
            let operation = stateLock.withLock { () -> (() -> Void)? in
                defer { releaseOperation = nil }
                return releaseOperation
            }
            operation?()
        }

        deinit { release() }
    }

    private final class Entry {
        let lock = NSRecursiveLock()
        var users = 0
    }

    private struct Admission {
        let workspaceID: String
        let entry: Entry
    }

    private let stateLock = NSLock()
    private var entries: [String: Entry] = [:]

    func acquire(workspaceID: String) -> Lease {
        acquire(workspaceIDs: [workspaceID])
    }

    /// Acquires a deterministic set for operations such as clone and shutdown. Sorting prevents
    /// cross-workspace deadlock; de-duplication makes a same-source/destination request recursive
    /// only once.
    func acquire(workspaceIDs: [String]) -> Lease {
        let identifiers = Array(Set(workspaceIDs)).sorted()
        let admissions: [Admission] = stateLock.withLock {
            identifiers.map { workspaceID in
                let entry = entries[workspaceID] ?? Entry()
                entry.users += 1
                entries[workspaceID] = entry
                return Admission(workspaceID: workspaceID, entry: entry)
            }
        }
        for admission in admissions {
            admission.entry.lock.lock()
        }
        return Lease { [weak self] in
            for admission in admissions.reversed() {
                admission.entry.lock.unlock()
            }
            guard let self else { return }
            self.stateLock.withLock {
                for admission in admissions {
                    guard let current = self.entries[admission.workspaceID],
                          current === admission.entry,
                          current.users > 0 else { continue }
                    current.users -= 1
                    if current.users == 0 {
                        self.entries.removeValue(forKey: admission.workspaceID)
                    }
                }
            }
        }
    }

#if DEBUG
    var retainedEntryCountForTesting: Int {
        stateLock.withLock { entries.count }
    }
#endif
}
