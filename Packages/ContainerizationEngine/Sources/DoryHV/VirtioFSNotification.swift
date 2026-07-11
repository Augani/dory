import Foundation

/// Cache invalidations delivered through the negotiated virtio-fs notification queue.
///
/// The byte layout matches Linux's `fuse_notify_inval_*_out` payloads. Notifications use a
/// `fuse_out_header` with `unique == 0` and the positive FUSE notification code in `error`.
public enum VirtioFSInvalidation: Equatable, Sendable {
    case inode(nodeID: UInt64, offset: Int64 = 0, length: Int64 = 0)
    case entry(parentNodeID: UInt64, name: String, flags: UInt32 = 0)
    /// Invalidates a cached name and, when `childNodeID` still matches Linux's dentry, delivers
    /// `IN_DELETE_SELF` to watches installed directly on that child inode. Unlike `.entry`, this
    /// mirrors `FUSE_NOTIFY_DELETE` and therefore preserves delete semantics for chokidar's
    /// per-file watches without creating a transient file in the shared directory.
    case delete(parentNodeID: UInt64, childNodeID: UInt64, name: String)

    public static let invalidateInodeCode: UInt32 = 2
    public static let invalidateEntryCode: UInt32 = 3
    public static let deleteCode: UInt32 = 6
    public static let maximumEntryNameByteCount = 255

    public func encoded() throws -> [UInt8] {
        switch self {
        case let .inode(nodeID, offset, length):
            var bytes = Self.header(length: FuseOutHeader.byteCount + 24, code: Self.invalidateInodeCode)
            bytes.appendLE(nodeID)
            bytes.appendLE(UInt64(bitPattern: offset))
            bytes.appendLE(UInt64(bitPattern: length))
            return bytes

        case let .entry(parentNodeID, name, flags):
            let nameBytes = try Self.validatedNameBytes(name)

            let length = FuseOutHeader.byteCount + 16 + nameBytes.count + 1
            var bytes = Self.header(length: length, code: Self.invalidateEntryCode)
            bytes.appendLE(parentNodeID)
            bytes.appendLE(UInt32(nameBytes.count))
            bytes.appendLE(flags)
            bytes.append(contentsOf: nameBytes)
            bytes.append(0)
            return bytes

        case let .delete(parentNodeID, childNodeID, name):
            let nameBytes = try Self.validatedNameBytes(name)

            let length = FuseOutHeader.byteCount + 24 + nameBytes.count + 1
            var bytes = Self.header(length: length, code: Self.deleteCode)
            bytes.appendLE(parentNodeID)
            bytes.appendLE(childNodeID)
            bytes.appendLE(UInt32(nameBytes.count))
            bytes.appendLE(UInt32(0)) // fuse_notify_delete_out.padding
            bytes.append(contentsOf: nameBytes)
            bytes.append(0)
            return bytes
        }
    }

    private static func validatedNameBytes(_ name: String) throws -> [UInt8] {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty,
              name != ".", name != "..",
              nameBytes.count <= maximumEntryNameByteCount,
              !nameBytes.contains(0), !nameBytes.contains(UInt8(ascii: "/")) else {
            throw VirtioFSNotificationError.invalidEntryName(name)
        }
        return nameBytes
    }

    private static func header(length: Int, code: UInt32) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        bytes.appendLE(UInt32(length))
        bytes.appendLE(code)
        bytes.appendLE(UInt64(0))
        return bytes
    }
}

public enum VirtioFSNotificationError: Error, Equatable, Sendable {
    case invalidEntryName(String)
    case featureNotNegotiated
    case backpressure(limit: Int)
    case messageTooLarge(limit: Int)
    case invalidGuestBuffer
    case transportReset
    case requestDrainTimedOut(activeRequests: Int)
    case acknowledgementTimedOut
    case timedOut
}

/// Completes after Linux has consumed every notification in a submission and reposted its buffers.
///
/// Waiting for this barrier before relaying a guest-visible watcher event guarantees that the
/// invalidation has already run in the guest kernel. A transport reset fails outstanding barriers.
public final class VirtioFSNotificationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var completionError: VirtioFSNotificationError?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(notificationCount: Int) {
        remaining = notificationCount
    }

    public var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remaining == 0
    }

    public func wait() async throws {
        let waiterID = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if remaining > 0, !Task.isCancelled {
                    waiters[waiterID] = continuation
                    lock.unlock()
                    return
                }
                let error = completionError
                let cancelled = Task.isCancelled
                lock.unlock()

                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }
    }

    public func wait(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VirtioFSNotificationError.timedOut
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func acknowledge() {
        finishOne(error: nil)
    }

    func fail(_ error: VirtioFSNotificationError) {
        var continuations = [CheckedContinuation<Void, any Error>]()
        lock.lock()
        guard remaining > 0 else {
            lock.unlock()
            return
        }
        remaining = 0
        completionError = error
        continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func finishOne(error: VirtioFSNotificationError?) {
        var continuations = [CheckedContinuation<Void, any Error>]()
        lock.lock()
        guard remaining > 0 else {
            lock.unlock()
            return
        }
        if let error {
            remaining = 0
            completionError = error
        } else {
            remaining -= 1
        }
        guard remaining == 0 else {
            lock.unlock()
            return
        }
        continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        let completionError = self.completionError
        lock.unlock()

        for continuation in continuations {
            if let completionError {
                continuation.resume(throwing: completionError)
            } else {
                continuation.resume()
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
