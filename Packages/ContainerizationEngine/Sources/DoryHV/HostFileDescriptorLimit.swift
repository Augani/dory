import Darwin

public enum HostFileDescriptorLimitError: Error, Equatable {
    case read(Int32)
    case update(Int32)
}

/// Raises launchd's commonly low descriptor soft limit before HostFS starts pinning inode
/// identities. Existing higher limits are preserved; the requested increase is bounded so a
/// malformed hard limit cannot grant the VM process an unreasonable descriptor budget.
public enum HostFileDescriptorLimit {
    public static let ceiling: rlim_t = 262_144

    static func desiredSoftLimit(
        current: rlim_t,
        hard: rlim_t,
        ceiling: rlim_t = HostFileDescriptorLimit.ceiling
    ) -> rlim_t {
        max(current, min(hard, ceiling))
    }

    @discardableResult
    public static func raiseSoftLimit() throws -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            let savedErrno = errno
            throw HostFileDescriptorLimitError.read(savedErrno)
        }

        let desired = desiredSoftLimit(current: limit.rlim_cur, hard: limit.rlim_max)
        guard desired > limit.rlim_cur else { return limit.rlim_cur }
        limit.rlim_cur = desired
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            let savedErrno = errno
            throw HostFileDescriptorLimitError.update(savedErrno)
        }
        return desired
    }
}
