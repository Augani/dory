import Darwin

public enum DoryFSWorkerProcessResourceError: Error, Equatable, Sendable {
    case readFileDescriptorLimit(Int32)
    case updateFileDescriptorLimit(Int32)
}

/// Establishes the descriptor ceiling in the process that actually owns filesystem roots, inode
/// identity pins, open file/directory handles, and advisory-lock descriptors. Raising the VMM's
/// limit cannot affect an XPC service, because resource limits are process-local.
public enum DoryFSWorkerProcessResources {
    public static let fileDescriptorCeiling: rlim_t = 262_144

    static func desiredFileDescriptorSoftLimit(
        current: rlim_t,
        hard: rlim_t,
        ceiling: rlim_t = fileDescriptorCeiling
    ) -> rlim_t {
        max(current, min(hard, ceiling))
    }

    @discardableResult
    public static func raiseFileDescriptorSoftLimit() throws -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            let savedErrno = errno
            throw DoryFSWorkerProcessResourceError.readFileDescriptorLimit(savedErrno)
        }

        let desired = desiredFileDescriptorSoftLimit(
            current: limit.rlim_cur,
            hard: limit.rlim_max
        )
        guard desired > limit.rlim_cur else { return limit.rlim_cur }
        limit.rlim_cur = desired
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            let savedErrno = errno
            throw DoryFSWorkerProcessResourceError.updateFileDescriptorLimit(savedErrno)
        }
        return desired
    }
}
