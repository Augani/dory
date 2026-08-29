import Darwin
import DoryFSWorkerContracts
import Foundation

private struct FuseResponseCachePolicy: Sendable {
    let entryValiditySeconds: UInt64
    let attrValiditySeconds: UInt64
}

/// A small fail-closed state machine shared by every FUSE response path. The only transition into
/// the cacheable state is driven by VirtioFS after its notification channel passes every readiness
/// gate. Environment variables and constructor flags cannot bypass that health check.
private final class FuseCachePolicy: @unchecked Sendable {
    /// Bound on entry/attr validity granted while the coherence channel is healthy. The reverse
    /// notification queue is the primary coherence mechanism (host edits invalidate within the
    /// FSEvents debounce, and event loss fail-stops the share), so this TTL is a backstop rather
    /// than the freshness contract. Raising it from 1s removed the per-second re-LOOKUP storm of
    /// every warm path during npm-scale workloads.
    static let maximumValiditySeconds: UInt64 = 30
    /// Negative dentries get a much shorter bound: directory-level FSEvents cannot name a
    /// brand-new host file that the guest never resolved, so no INVAL_ENTRY can retire a stale
    /// miss for an unknown name. One second caps that window while still absorbing the
    /// LOOKUP(ENOENT)-before-CREATE round trip that dominates package-manager install storms.
    static let negativeValiditySeconds: UInt64 = 1

    private let lock = NSLock()
    private var fuseInitCompleted = false
    private var active = false

    var isFuseInitCompleted: Bool {
        lock.withLock { fuseInitCompleted }
    }

    var isActive: Bool {
        lock.withLock { active }
    }

    var responsePolicy: FuseResponseCachePolicy {
        lock.withLock {
            let validity = active ? Self.maximumValiditySeconds : 0
            return FuseResponseCachePolicy(
                entryValiditySeconds: validity,
                attrValiditySeconds: validity
            )
        }
    }

    var negativeEntryValiditySeconds: UInt64 {
        lock.withLock { active ? Self.negativeValiditySeconds : 0 }
    }

    func markFuseInitCompleted() {
        lock.withLock { fuseInitCompleted = true }
    }

    @discardableResult
    func activate() -> Bool {
        lock.withLock {
            guard fuseInitCompleted else { return false }
            active = true
            return true
        }
    }

    func deactivate(resetFuseInit: Bool) {
        lock.withLock {
            active = false
            if resetFuseInit {
                fuseInitCompleted = false
            }
        }
    }
}

final class FuseServer: @unchecked Sendable {
    static let maximumCoherentCacheValiditySeconds = FuseCachePolicy.maximumValiditySeconds
    static let negativeCoherentCacheValiditySeconds = FuseCachePolicy.negativeValiditySeconds

    private let hostFS: HostFS
    private var resourceQuota: FuseResourceQuota { hostFS.resourceQuota }
    private let writebackCache: Bool
    private let killPrivV2: Bool
    private let fastCreateAttributes: Bool
    private let cachePolicy = FuseCachePolicy()
    private let anomalyLog = FuseAnomalyLog()
    private let lock = NSLock()
    private var nextFileHandle: UInt64 = 1
    private var nextDirectoryHandle: UInt64 = 1
    private var fileHandles: [UInt64: OpenFileHandle] = [:]
    private var directoryHandles: [UInt64: OpenDirectoryHandle] = [:]
    private var lockOwners: [AdvisoryLockOwnerKey: AdvisoryLockDescriptor] = [:]
    private let advisoryLockCondition = NSCondition()
    private var pendingBlockingLocks: Set<UInt64> = []
    private var pendingBlockingLockOwners: [UInt64: AdvisoryLockOwnerKey] = [:]
    private var pendingBlockingLockTokens: [UInt64: FuseResourceToken] = [:]
    private var cancelledBlockingLocks: Set<UInt64> = []
    var fileOperationLoadedTestHook: (() -> Void)?
    var directoryOperationLoadedTestHook: (() -> Void)?

    /// Reference ownership is the fd lifetime fence. Request queues may process WRITE/READ and
    /// RELEASE concurrently: removing the handle from `fileHandles` prevents new acquisitions,
    /// while any request that already loaded it keeps this object (and therefore the fd) alive.
    /// Closing in deinit makes RELEASE linearizable without a timer or a racy deferred-close queue.
    private final class OpenFileHandle: @unchecked Sendable {
        let fd: Int32
        let nodeID: UInt64
        let accessMode: HostFSAccessMode
        let append: Bool
        private let hostFS: HostFS
        private let resourceToken: FuseResourceToken

        init(
            fd: Int32,
            nodeID: UInt64,
            accessMode: HostFSAccessMode,
            append: Bool,
            hostFS: HostFS,
            resourceToken: FuseResourceToken
        ) {
            self.fd = fd
            self.nodeID = nodeID
            self.accessMode = accessMode
            self.append = append
            self.hostFS = hostFS
            self.resourceToken = resourceToken
        }

        deinit {
            hostFS.close(handle: fd)
            hostFS.releaseOpenHandle(nodeID: nodeID)
        }

        var permitsWrite: Bool { accessMode != .readOnly }

        func permitsRead(writebackCache: Bool) -> Bool {
            accessMode != .writeOnly || writebackCache
        }
    }

    private final class OpenDirectoryHandle: @unchecked Sendable {
        let nodeID: UInt64
        let cursor: HostFSDirectoryCursor
        /// FUSE offsets identify the next entry and must remain stable when names are added or
        /// removed. Slots append only as names are incrementally considered for a bounded response;
        /// they never contain attributes/nodes and never snapshot undiscovered directory contents.
        let operationLock = NSLock()
        var cookieNames: [String] = []
        var knownCookieNames: Set<String> = []
        var enumerationExhausted = false
        var terminalCursorQuotaError: FuseResourceQuotaError?
        var reservedCursorEntries = 0
        var reservedCursorNameBytes = 0
        private let hostFS: HostFS
        private let resourceQuota: FuseResourceQuota
        private let resourceToken: FuseResourceToken

        init(
            nodeID: UInt64,
            cursor: HostFSDirectoryCursor,
            hostFS: HostFS,
            resourceQuota: FuseResourceQuota,
            resourceToken: FuseResourceToken
        ) {
            self.nodeID = nodeID
            self.cursor = cursor
            self.hostFS = hostFS
            self.resourceQuota = resourceQuota
            self.resourceToken = resourceToken
        }

        func appendCookieName(_ name: String) throws {
            let nameBytes = name.utf8.count
            try resourceQuota.reserveDirectoryCursorEntry(nameByteCount: nameBytes)
            cookieNames.append(name)
            knownCookieNames.insert(name)
            reservedCursorEntries += 1
            reservedCursorNameBytes += nameBytes
        }

        deinit {
            resourceQuota.releaseDirectoryCursor(
                entries: reservedCursorEntries,
                nameBytes: reservedCursorNameBytes
            )
            hostFS.releaseOpenHandle(nodeID: nodeID)
        }
    }

    private struct AdvisoryLockOwnerKey: Hashable {
        let nodeID: UInt64
        let owner: UInt64
        let flock: Bool
    }

    private struct AdvisoryLockDescriptorAdmission {
        let key: AdvisoryLockOwnerKey
        let descriptor: AdvisoryLockDescriptor
    }

    /// macOS process locks alias inside one server process, so every guest lock owner receives an
    /// independently reopened file description. OFD record locks and flock(2) then preserve the
    /// kernel's owner isolation even though all FUSE requests execute inside dory-hv.
    private final class AdvisoryLockDescriptor: @unchecked Sendable {
        let fd: Int32
        let usesFlock: Bool
        let operationLock = NSLock()
        private let resourceToken: FuseResourceToken
        /// Protected by `FuseServer.lock`. Transient admissions keep a descriptor registered until
        /// all same-owner operations finish; a successful lock makes it persistent until FLUSH or
        /// RELEASE. This prevents one failed concurrent request from retiring another's owner.
        var activeAdmissions = 0
        var retainedByOwner = false

        init(fd: Int32, usesFlock: Bool, resourceToken: FuseResourceToken) {
            self.fd = fd
            self.usesFlock = usesFlock
            self.resourceToken = resourceToken
        }

        deinit {
            // Explicitly clear the owner's complete lock set before close. Attached files use a
            // genuinely independent open description, while Darwin's only safe reopen for an
            // already-unlinked inode is /dev/fd and may alias its pinned source description.
            if usesFlock {
                _ = flock(fd, LOCK_UN)
            } else {
                var record = flock()
                record.l_start = 0
                record.l_len = 0
                record.l_pid = 0
                record.l_type = Int16(F_UNLCK)
                record.l_whence = Int16(SEEK_SET)
                _ = fcntl(fd, F_OFD_SETLK, &record)
            }
            Darwin.close(fd)
        }
    }

    private enum RequestError: Error {
        case badFileDescriptor
    }

    /// FUSE file handles are opaque 64-bit values. Keep directory handles in a tagged high-bit
    /// namespace in addition to separate typed maps, so the two kinds can never collide.
    private static let directoryHandleTag: UInt64 = 1 << 63
    private static let handleSequenceMask: UInt64 = directoryHandleTag - 1

    private enum OpenFlag {
        static let noFlush: UInt32 = 1 << 5
    }

    /// Flags in FUSE_OPEN/FUSE_CREATE are Linux ABI values. Only O_ACCMODE happens to match Darwin;
    /// every other bit must be decoded explicitly before making a host syscall.
    private enum LinuxOpenFlag {
        static let accessMask: UInt32 = 0x3
        static let exclusive: UInt32 = 0x80
        static let truncate: UInt32 = 0x200
        static let append: UInt32 = 0x400
    }

    private struct FileOpenIntent {
        var accessMode: HostFSAccessMode
        var append: Bool
        var truncate: Bool
        var exclusive: Bool

        init?(wireFlags: UInt32) {
            guard let accessMode = HostFSAccessMode(
                rawValue: Int32(wireFlags & LinuxOpenFlag.accessMask)
            ) else { return nil }
            self.accessMode = accessMode
            self.append = wireFlags & LinuxOpenFlag.append != 0
            self.truncate = wireFlags & LinuxOpenFlag.truncate != 0
            self.exclusive = wireFlags & LinuxOpenFlag.exclusive != 0
        }
    }

    private func hostAccessMode(for intent: FileOpenIntent) -> HostFSAccessMode {
        intent.accessMode == .writeOnly && writebackCache ? .readWrite : intent.accessMode
    }

    public init(
        hostFS: HostFS,
        writebackCache: Bool = false,
        killPrivV2: Bool = true,
        fastCreateAttributes: Bool = false
    ) {
        self.hostFS = hostFS
        self.writebackCache = writebackCache
        self.killPrivV2 = killPrivV2
        // A synthetic create identity cannot distinguish the original inode from a host atomic
        // replacement that lands before the first getattr/open. Production always records the real
        // file key; tests may still opt in explicitly to exercise legacy reconciliation behavior.
        self.fastCreateAttributes = fastCreateAttributes
    }

    deinit {
        resetConnection()
    }

    public func handle(request: [UInt8]) -> [UInt8] {
        guard let header = try? FuseProtocol.decodeInHeader(request),
              Int(header.length) <= request.count,
              header.length >= UInt32(FuseInHeader.byteCount) else {
            return errorResponse(unique: 0, errno: EINVAL)
        }

        guard let opcode = FuseOpcode(rawValue: header.opcode) else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        return handle(header: header, opcode: opcode, request: request)
    }

    var fuseInitCompleted: Bool { cachePolicy.isFuseInitCompleted }
    var coherentCachingActive: Bool { cachePolicy.isActive }
    public var resourceSnapshot: FuseResourceSnapshot { resourceQuota.snapshot() }

    func markFuseInitCompleted() {
        cachePolicy.markFuseInitCompleted()
    }

    /// Internal by design: only VirtioFS owns the notification-health gates that make this safe.
    @discardableResult
    func activateCoherentCaching() -> Bool {
        cachePolicy.activate()
    }

    func deactivateCoherentCaching(resetFuseInit: Bool = false) {
        cachePolicy.deactivate(resetFuseInit: resetFuseInit)
    }

    func handle(header: FuseInHeader, opcode: FuseOpcode, request: [UInt8]) -> [UInt8] {
        guard Int(header.length) <= request.count,
              header.length >= UInt32(FuseInHeader.byteCount) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }

        let payload = request[Int(FuseInHeader.byteCount)..<Int(header.length)]
        do {
            switch opcode {
            case .initOp:
                let initIn = try FuseProtocol.decodeInitIn(Array(payload))
                let response = FuseProtocol.negotiateInit(
                    header: header,
                    request: initIn,
                    daxMapAlignmentLog2: nil,
                    writebackCache: writebackCache,
                    killPrivV2: killPrivV2
                )
                return response
            case .lookup:
                return try handleLookup(header: header, payload: payload)
            case .forget:
                handleForget(header: header, payload: payload)
                return []
            case .batchForget:
                handleBatchForget(payload: payload)
                return []
            case .readlink:
                return try handleReadlink(header: header)
            case .symlink:
                return try handleSymlink(header: header, payload: payload)
            case .link:
                return try handleLink(header: header, payload: payload)
            case .getattr:
                return try handleGetattr(header: header, payload: payload)
            case .setattr:
                return try handleSetattr(header: header, payload: payload)
            case .open:
                return try handleOpen(header: header, payload: payload)
            case .opendir:
                return try handleOpenDir(header: header)
            case .read:
                return try handleRead(header: header, payload: payload)
            case .write:
                return try handleWrite(header: header, payload: payload)
            case .readdirplus:
                return try handleReadDirPlus(header: header, payload: payload)
            case .statfs:
                return try handleStatFS(header: header)
            case .fsync:
                return try handleFsync(header: header, payload: payload)
            case .syncfs:
                // Linux treats ENOSYS as successful capability fallback and disables subsequent
                // SYNCFS requests for this connection. Do not claim filesystem-wide durability:
                // Darwin has no descriptor-scoped syncfs equivalent, and global sync() would
                // improperly flush unrelated host filesystems from a sandboxed share worker.
                return errorResponse(unique: header.unique, errno: ENOSYS)
            case .flush:
                return handleFlush(header: header, payload: payload)
            case .getlk:
                return try handleGetLock(header: header, payload: payload)
            case .setlk:
                return try handleSetLock(header: header, payload: payload, blocking: false)
            case .setlkw:
                return try handleSetLock(header: header, payload: payload, blocking: true)
            case .interrupt:
                handleInterrupt(payload: payload)
                return []
            case .getxattr:
                // ENOSYS (not ENODATA) latches fc->no_getxattr in the guest kernel, eliminating
                // the per-file security.capability round trip on create/write storms. This server
                // has no xattr storage, so "not implemented" is the accurate contract.
                return errorResponse(unique: header.unique, errno: ENOSYS)
            case .setxattr:
                return errorResponse(unique: header.unique, errno: EOPNOTSUPP)
            case .listxattr:
                return try handleListXattr(header: header, payload: payload)
            case .create:
                return try handleCreate(header: header, payload: payload)
            case .mkdir:
                return try handleMkdir(header: header, payload: payload)
            case .unlink:
                return try handleUnlink(header: header, payload: payload)
            case .rmdir:
                return try handleRmdir(header: header, payload: payload)
            case .rename:
                return try handleRename(header: header, payload: payload)
            case .release:
                return handleReleaseFile(header: header, payload: payload)
            case .releasedir:
                return handleReleaseDirectory(header: header, payload: payload)
            case .setupmapping, .removemapping:
                // Filesystem DAX bypasses the worker publication boundary and is intentionally
                // absent from the production worker. Plain virtio-fs remains the only share path.
                return errorResponse(unique: header.unique, errno: ENOSYS)
            case .destroy:
                // The service owner performs resource reset only after this exact success response
                // is committed into the used ring. Resetting here would race a failed publication.
                return successResponse(unique: header.unique, payload: [])
            default:
                return errorResponse(unique: header.unique, errno: ENOSYS)
            }
        } catch {
            return errorResponse(unique: header.unique, errno: mapError(error))
        }
    }

    private func handleLookup(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let name = try readCString(payload)
        guard let entry = try hostFS.lookupIfExists(parent: header.nodeID, name: name) else {
            let validity = cachePolicy.negativeEntryValiditySeconds
            guard validity > 0 else {
                return errorResponse(unique: header.unique, errno: ENOENT)
            }
            return successResponse(unique: header.unique, payload: encodeNegativeEntryOut(validity: validity))
        }
        hostFS.retainLookup(nodeID: entry.nodeID)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    /// A `fuse_entry_out` with `nodeid == 0` caches a bounded negative dentry. Grants no lookup
    /// reference, so rollback's FORGET of node 0 is a no-op by construction.
    private func encodeNegativeEntryOut(validity: UInt64) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 128)
        withUnsafeBytes(of: validity.littleEndian) { bytes in
            payload.replaceSubrange(16..<24, with: bytes)
        }
        return payload
    }

    private func handleForget(header: FuseInHeader, payload: ArraySlice<UInt8>) {
        // FORGET is deliberately one-way. Even a malformed payload must not produce a FUSE reply.
        guard let request = try? FuseProtocol.decodeForgetIn(Array(payload)) else { return }
        hostFS.forgetLookup(nodeID: header.nodeID, count: request.lookupCount)
    }

    private func handleBatchForget(payload: ArraySlice<UInt8>) {
        // BATCH_FORGET has the same no-reply contract as FORGET.
        guard let request = try? FuseProtocol.decodeBatchForgetIn(Array(payload)) else { return }
        for entry in request.entries {
            hostFS.forgetLookup(nodeID: entry.nodeID, count: entry.lookupCount)
        }
    }

    private func handleReadlink(header: FuseInHeader) throws -> [UInt8] {
        return try successResponse(unique: header.unique, payload: Array(hostFS.readlink(nodeID: header.nodeID).utf8))
    }

    private func handleSymlink(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let values = try readCStrings(payload, count: 2)
        let entry = try hostFS.symlink(
            parent: header.nodeID,
            name: values[0],
            target: values[1],
            ownerUID: header.uid,
            ownerGID: header.gid
        )
        hostFS.retainLookup(nodeID: entry.nodeID)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleLink(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let oldNodeID = payload.leUInt64(at: 0)
        let name = try readCString(payload.dropFirst(8))
        let entry = try hostFS.link(nodeID: oldNodeID, newParent: header.nodeID, name: name)
        hostFS.retainLookup(nodeID: entry.nodeID)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleGetattr(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let attrs = try getattrAttributes(header: header, payload: payload)
        return successResponse(unique: header.unique, payload: encodeAttrOut(attrs))
    }

    private func getattrAttributes(
        header: FuseInHeader,
        payload: ArraySlice<UInt8>
    ) throws -> HostFSAttributes {
        let request = try FuseProtocol.decodeGetattrIn(payload)
        guard request.flags.rawValue & ~FuseGetattrFlag.allKnown.rawValue == 0 else {
            throw HostFSError.invalidName("getattr flags")
        }
        guard request.flags.contains(.fileHandle) else {
            return try hostFS.getattr(nodeID: header.nodeID)
        }
        guard let openHandle = loadFile(handle: request.fileHandle),
              openHandle.nodeID == header.nodeID else {
            throw RequestError.badFileDescriptor
        }
        return try hostFS.getattr(nodeID: header.nodeID, handle: openHandle.fd)
    }

    private func handleSetattr(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let wire = try FuseProtocol.decodeSetattrIn(Array(payload))
        let valid = wire.valid
        guard valid.rawValue & ~FuseSetattrValid.allKnown.rawValue == 0 else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        guard !valid.contains(.atimeNow) || valid.contains(.atime),
              !valid.contains(.mtimeNow) || valid.contains(.mtime) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        if valid.contains(.atime), !valid.contains(.atimeNow), wire.atimeNsec >= 1_000_000_000 {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        if valid.contains(.mtime), !valid.contains(.mtimeNow), wire.mtimeNsec >= 1_000_000_000 {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        if valid.contains(.ctime), wire.ctimeNsec >= 1_000_000_000 {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }

        let openHandle: OpenFileHandle?
        if valid.contains(.fileHandle) {
            guard let candidate = loadFile(handle: wire.fileHandle), candidate.nodeID == header.nodeID else {
                anomalyLog.log(describeStaleHandle(wire.fileHandle, nodeID: header.nodeID, op: "SETATTR"))
                return errorResponse(unique: header.unique, errno: EBADF)
            }
            if valid.contains(.size), !candidate.permitsWrite {
                anomalyLog.log("SETATTR truncate on read-only handle=\(wire.fileHandle) node=\(header.nodeID)")
                return errorResponse(unique: header.unique, errno: EBADF)
            }
            openHandle = candidate
        } else {
            openHandle = nil
        }

        let atime: HostFSTimestampUpdate? = valid.contains(.atime)
            ? (valid.contains(.atimeNow)
                ? .now
                : .value(seconds: wire.atimeSeconds, nanoseconds: wire.atimeNsec))
            : nil
        let mtime: HostFSTimestampUpdate? = valid.contains(.mtime)
            ? (valid.contains(.mtimeNow)
                ? .now
                : .value(seconds: wire.mtimeSeconds, nanoseconds: wire.mtimeNsec))
            : nil
        let request = HostFSSetattrRequest(
            mode: valid.contains(.mode) ? wire.mode & 0o7777 : nil,
            uid: valid.contains(.uid) ? wire.uid : nil,
            gid: valid.contains(.gid) ? wire.gid : nil,
            size: valid.contains(.size) ? wire.size : nil,
            atime: atime,
            mtime: mtime,
            ctimeRequested: valid.contains(.ctime),
            killSuidGid: valid.contains(.killSuidGid)
        )
        let attributes = try hostFS.applySetattr(
            nodeID: header.nodeID,
            handle: openHandle?.fd,
            request: request
        )
        return successResponse(unique: header.unique, payload: encodeAttrOut(attributes))
    }

    private func handleOpen(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let intent = FileOpenIntent(wireFlags: payload.leUInt32(at: 0)) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        // With writeback caching Linux may issue READ for an O_WRONLY handle. Production keeps
        // writeback disabled; the opt-in mode therefore asks HostFS for a compatible RW descriptor
        // while retaining the guest's logical WRONLY authorization below.
        let hostAccess = hostAccessMode(for: intent)
        let handleToken = try resourceQuota.acquire(.fileHandles)
        let fd = try hostFS.openFileForFuseHandle(
            nodeID: header.nodeID,
            accessMode: hostAccess,
            append: intent.append && !writebackCache
        )
        let handle = storeRetainedFile(
            fd: fd,
            nodeID: header.nodeID,
            accessMode: intent.accessMode,
            append: intent.append,
            resourceToken: handleToken
        )
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: handle, openFlags: fileOpenFlags))
    }

    private func handleOpenDir(header: FuseInHeader) throws -> [UInt8] {
        let attributes = try hostFS.getattr(nodeID: header.nodeID)
        guard attributes.isDirectory else { throw HostFSError.notDirectory(header.nodeID) }
        let handle = try storeDirectory(nodeID: header.nodeID)
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: handle, openFlags: directoryOpenFlags))
    }

    private func handleRead(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        let offset = payload.leUInt64(at: 8)
        let size = min(Int(payload.leUInt32(at: 16)), HostFS.maxReadCount)
        guard let openHandle = loadFile(handle: handle),
              openHandle.nodeID == header.nodeID,
              openHandle.permitsRead(writebackCache: writebackCache) else {
            anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "READ"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        return try successResponse(unique: header.unique, payload: hostFS.read(handle: openHandle.fd, offset: offset, count: size))
    }

    /// Reverses only server-side lifetime grants from a successful response that never reached the
    /// used ring. Host namespace/data mutations remain committed; the guest never received the
    /// node or handle references that would otherwise authorize keeping these resources alive.
    func rollbackUnpublishedResponse(opcode: FuseOpcode, response: [UInt8]) {
        guard response.count >= FuseOutHeader.byteCount,
              Int32(bitPattern: response.leUInt32(at: 4)) == 0 else { return }
        let declaredLength = Int(response.leUInt32(at: 0))
        guard declaredLength >= FuseOutHeader.byteCount, declaredLength <= response.count else { return }
        let payloadStart = FuseOutHeader.byteCount

        switch opcode {
        case .lookup, .mkdir, .symlink, .link:
            guard declaredLength >= payloadStart + 8 else { return }
            hostFS.forgetLookup(nodeID: response.leUInt64(at: payloadStart), count: 1)
        case .create:
            guard declaredLength >= payloadStart + 128 + 8 else { return }
            let nodeID = response.leUInt64(at: payloadStart)
            let handle = response.leUInt64(at: payloadStart + 128)
            anomalyLog.log("rollback CREATE handle=\(handle) node=\(nodeID)")
            releaseFile(handle: handle)
            hostFS.forgetLookup(nodeID: nodeID, count: 1)
        case .open:
            guard declaredLength >= payloadStart + 8 else { return }
            anomalyLog.log("rollback OPEN handle=\(response.leUInt64(at: payloadStart))")
            releaseFile(handle: response.leUInt64(at: payloadStart))
        case .opendir:
            guard declaredLength >= payloadStart + 8 else { return }
            anomalyLog.log("rollback OPENDIR handle=\(response.leUInt64(at: payloadStart))")
            releaseDirectory(handle: response.leUInt64(at: payloadStart))
        case .readdirplus:
            var recordStart = payloadStart
            while recordStart < declaredLength {
                let nameLengthOffset = recordStart + 128 + 16
                guard nameLengthOffset + 4 <= declaredLength else { return }
                let nameLength = Int(response.leUInt32(at: nameLengthOffset))
                let recordLength = (128 + 24 + nameLength + 7) & ~7
                guard recordLength >= 152, recordStart + recordLength <= declaredLength else { return }
                hostFS.forgetLookup(nodeID: response.leUInt64(at: recordStart), count: 1)
                recordStart += recordLength
            }
        default:
            break
        }
    }

    /// Starts a fresh FUSE connection lifetime. VirtioFS calls this only after every admitted
    /// request from the previous transport epoch has finished using its descriptor snapshot.
    func resetConnection() {
        anomalyLog.log("resetConnection")
        cancelAllBlockingLocks()
        let openHandles: ([OpenFileHandle], [OpenDirectoryHandle], [AdvisoryLockDescriptor]) = lock.withLock {
            let files = Array(fileHandles.values)
            let directories = Array(directoryHandles.values)
            let locks = Array(lockOwners.values)
            fileHandles.removeAll(keepingCapacity: false)
            directoryHandles.removeAll(keepingCapacity: false)
            lockOwners.removeAll(keepingCapacity: false)
            return (files, directories, locks)
        }
        // Keep the removed handles alive until after the table lock is released. Their deinits
        // close descriptors and release HostFS open references after any in-flight request-owned
        // references have also drained.
        var openFiles = openHandles.0
        var openDirectories = openHandles.1
        var openLocks = openHandles.2
        openFiles.removeAll(keepingCapacity: false)
        openDirectories.removeAll(keepingCapacity: false)
        openLocks.removeAll(keepingCapacity: false)
        hostFS.resetFuseReferences()
        cachePolicy.deactivate(resetFuseInit: true)
        wakeAdvisoryLockWaiters()
    }

    private func handleWrite(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        let offset = payload.leUInt64(at: 8)
        let size = Int(payload.leUInt32(at: 16))
        guard payload.count >= 40 + size else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let openHandle = loadFile(handle: handle),
              openHandle.nodeID == header.nodeID,
              openHandle.permitsWrite else {
            anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "WRITE"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        fileOperationLoadedTestHook?()
        let written = try payload.withUnsafeBytes { raw -> Int in
            let base = raw.baseAddress?.advanced(by: 40)
            return try hostFS.write(
                handle: openHandle.fd,
                offset: offset,
                bytes: UnsafeRawBufferPointer(start: base, count: size),
                append: openHandle.append && !writebackCache
            )
        }
        if openHandle.append && !writebackCache {
            try hostFS.recordAppendWrite(nodeID: header.nodeID, handle: openHandle.fd)
        } else {
            hostFS.recordWrite(nodeID: header.nodeID, offset: offset, count: written)
        }
        killPrivilegeBitsIfRequested(writeFlags: payload.leUInt32(at: 20), fd: openHandle.fd)
        return successResponse(unique: header.unique, payloadByteCount: 8) { response in
            response.appendLE(UInt32(written))
            response.appendLE(UInt32(0))
        }
    }

    private func handleReadDirPlus(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        guard let offset = Int(exactly: payload.leUInt64(at: 8)) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        guard let directory = loadDirectory(handle: handle), directory.nodeID == header.nodeID else {
            anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "READDIRPLUS"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        let maxSize = Int(payload.leUInt32(at: 16))
        directoryOperationLoadedTestHook?()

        return try directory.operationLock.withLock {
            if let terminalError = directory.terminalCursorQuotaError {
                throw terminalError
            }
            guard offset <= directory.cookieNames.count else {
                return errorResponse(unique: header.unique, errno: EINVAL)
            }
            if offset == 0 {
                try hostFS.rewindDirectoryCursor(directory.cursor)
                directory.enumerationExhausted = false
            }

            var data = [UInt8]()
            data.reserveCapacity(min(maxSize, 64 * 1_024))
            var retainedNodeIDs: [UInt64] = []
            var slot = offset

            while data.count < maxSize {
                if slot == directory.cookieNames.count {
                    guard !directory.enumerationExhausted else { break }
                    let nextName: String?
                    do {
                        nextName = try hostFS.nextDirectoryName(from: directory.cursor)
                    } catch {
                        if data.isEmpty { throw error }
                        break
                    }
                    guard let nextName else {
                        directory.enumerationExhausted = true
                        break
                    }
                    guard !directory.knownCookieNames.contains(nextName) else { continue }
                    do {
                        try directory.appendCookieName(nextName)
                    } catch let quotaError as FuseResourceQuotaError {
                        // The host stream has advanced past a name we cannot retain as a stable
                        // cookie. Latch the cursor rather than silently skipping it. Entries already
                        // encoded in this reply remain valid; the next page reports EOVERFLOW.
                        directory.terminalCursorQuotaError = quotaError
                        if data.isEmpty { throw quotaError }
                        break
                    }
                }

                let name = directory.cookieNames[slot]
                let encodedLength = Self.direntPlusEncodedLength(nameByteCount: name.utf8.count)
                guard encodedLength <= maxSize - data.count else { break }

                let entry: HostFSEntry?
                do {
                    entry = try hostFS.lookupIfExists(parent: header.nodeID, name: name)
                } catch HostFSError.operationNotSupported {
                    // Unsupported host special files keep a stable hole in the cookie space.
                    slot += 1
                    continue
                } catch {
                    if data.isEmpty { throw error }
                    break
                }
                slot += 1
                guard let entry else {
                    // A removed name remains a hole so later cookies never shift left.
                    continue
                }
                let encoded = encodeDirentPlus(entry, offset: UInt64(slot))
                precondition(encoded.count == encodedLength)
                data.append(contentsOf: encoded)
                retainedNodeIDs.append(entry.nodeID)
            }

            hostFS.retainLookups(nodeIDs: retainedNodeIDs)
            return successResponse(unique: header.unique, payload: data)
        }
    }

    private func handleStatFS(header: FuseInHeader) throws -> [UInt8] {
        let stat = try hostFS.statfs()
        var data = [UInt8]()
        data.appendLE(stat.blocks)
        data.appendLE(stat.blocksFree)
        data.appendLE(stat.blocksAvailable)
        data.appendLE(stat.files)
        data.appendLE(stat.filesFree)
        data.appendLE(UInt32(clamping: stat.blockSize))
        data.appendLE(stat.nameMax)
        data.appendLE(UInt32(clamping: stat.blockSize))
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(UInt32(0)) }
        return successResponse(unique: header.unique, payload: data)
    }

    private func handleListXattr(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let size = payload.leUInt32(at: 0)
        guard size > 0 else {
            var data = [UInt8]()
            data.appendLE(UInt32(0))
            return successResponse(unique: header.unique, payload: data)
        }
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleFsync(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        guard let openHandle = loadFile(handle: handle), openHandle.nodeID == header.nodeID else {
            anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "FSYNC"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        try hostFS.fsync(handle: openHandle.fd)
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleFlush(header: FuseInHeader, payload: ArraySlice<UInt8>) -> [UInt8] {
        guard payload.count >= 24 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let openHandle = loadFile(handle: payload.leUInt64(at: 0)),
              openHandle.nodeID == header.nodeID else {
            anomalyLog.log(describeStaleHandle(payload.leUInt64(at: 0), nodeID: header.nodeID, op: "FLUSH"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        releaseAdvisoryLocks(nodeID: header.nodeID, owner: payload.leUInt64(at: 16))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleCreate(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let intent = FileOpenIntent(wireFlags: payload.leUInt32(at: 0)) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
        let name = try readCString(payload.dropFirst(16))
        let handleToken = try resourceQuota.acquire(.fileHandles)
        let created = try hostFS.createFileAndOpen(
            parent: header.nodeID,
            name: name,
            mode: mode,
            accessMode: hostAccessMode(for: intent),
            preferredIdentityAccessMode: .readWrite,
            exclusive: intent.exclusive,
            truncate: intent.truncate,
            append: intent.append && !writebackCache,
            syntheticAttributes: fastCreateAttributes,
            retainOpenHandle: true,
            ownerUID: header.uid,
            ownerGID: header.gid
        )
        let handle = storeRetainedFile(
            fd: created.fd,
            nodeID: created.entry.nodeID,
            accessMode: intent.accessMode,
            append: intent.append,
            resourceToken: handleToken
        )
        let entry = created.entry
        hostFS.retainLookup(nodeID: entry.nodeID)
        return successResponse(unique: header.unique, payloadByteCount: 144) { response in
            appendEntryOut(entry.attributes, to: &response)
            appendOpenOut(handle: handle, openFlags: fileOpenFlags, to: &response)
        }
    }

    private func handleMkdir(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 0))
        let name = try readCString(payload.dropFirst(8))
        let entry = try hostFS.mkdir(
            parent: header.nodeID,
            name: name,
            mode: mode,
            syntheticAttributes: fastCreateAttributes,
            ownerUID: header.uid,
            ownerGID: header.gid
        )
        hostFS.retainLookup(nodeID: entry.nodeID)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleUnlink(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        try hostFS.unlink(parent: header.nodeID, name: readCString(payload))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRmdir(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        try hostFS.rmdir(parent: header.nodeID, name: readCString(payload))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRename(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let newParent = payload.leUInt64(at: 0)
        let names = try readCStrings(payload.dropFirst(8), count: 2)
        _ = try hostFS.rename(parent: header.nodeID, name: names[0], newParent: newParent, newName: names[1])
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleReleaseFile(header: FuseInHeader, payload: ArraySlice<UInt8>) -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        if payload.count >= 24 {
            releaseAdvisoryLocks(nodeID: header.nodeID, owner: payload.leUInt64(at: 16))
        }
        releaseFile(handle: handle)
        return successResponse(unique: header.unique, payload: [])
    }

    private struct FuseLockRequest {
        let fileHandle: UInt64
        let owner: UInt64
        let start: UInt64
        let end: UInt64
        let type: UInt32
        let pid: UInt32
        let flags: UInt32

        init(_ payload: ArraySlice<UInt8>) throws {
            guard payload.count >= 48 else { throw FuseProtocolError.shortFrame }
            fileHandle = payload.leUInt64(at: 0)
            owner = payload.leUInt64(at: 8)
            start = payload.leUInt64(at: 16)
            end = payload.leUInt64(at: 24)
            type = payload.leUInt32(at: 32)
            pid = payload.leUInt32(at: 36)
            flags = payload.leUInt32(at: 40)
        }

        var isFlock: Bool { flags & 1 != 0 }
    }

    private func handleGetLock(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let request = try FuseLockRequest(payload)
        guard request.flags & ~UInt32(1) == 0,
              request.type == 0 || request.type == 1 else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        guard let openHandle = loadFile(handle: request.fileHandle),
              openHandle.nodeID == header.nodeID else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        // BSD flock has no query operation and Linux does not issue GETLK for flock requests.
        guard !request.isFlock else {
            return errorResponse(unique: header.unique, errno: EOPNOTSUPP)
        }
        let admission = try advisoryLockDescriptor(
            nodeID: header.nodeID,
            owner: request.owner,
            flock: false,
            openHandle: openHandle
        )
        defer {
            finishAdvisoryLockDescriptor(admission, retainOwner: false)
        }
        let descriptor = admission.descriptor
        var record = try darwinLockRecord(request)
        let rc = descriptor.operationLock.withLock {
            fcntl(descriptor.fd, F_OFD_GETLK, &record)
        }
        guard rc == 0 else { throw HostFSError.systemCall("F_OFD_GETLK", errno) }
        var response = [UInt8]()
        if record.l_type == F_UNLCK {
            response.appendLE(UInt64(0))
            response.appendLE(UInt64.max)
            response.appendLE(UInt32(2)) // Linux F_UNLCK
            response.appendLE(UInt32(0))
        } else {
            let start = UInt64(max(0, record.l_start))
            let end: UInt64 = record.l_len == 0
                ? UInt64.max
                : start + UInt64(record.l_len - 1)
            response.appendLE(start)
            response.appendLE(end)
            response.appendLE(record.l_type == F_RDLCK ? UInt32(0) : UInt32(1))
            response.appendLE(UInt32(max(0, record.l_pid)))
        }
        return successResponse(unique: header.unique, payload: response)
    }

    private func handleSetLock(
        header: FuseInHeader,
        payload: ArraySlice<UInt8>,
        blocking: Bool
    ) throws -> [UInt8] {
        let request = try FuseLockRequest(payload)
        guard request.flags & ~UInt32(1) == 0,
              request.type <= 2 else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        guard let openHandle = loadFile(handle: request.fileHandle),
              openHandle.nodeID == header.nodeID else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        if !request.isFlock, request.type == 1, !openHandle.permitsWrite {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        let admission = try advisoryLockDescriptor(
            nodeID: header.nodeID,
            owner: request.owner,
            flock: request.isFlock,
            openHandle: openHandle
        )
        var retainOwner = false
        defer {
            finishAdvisoryLockDescriptor(admission, retainOwner: retainOwner)
        }
        let descriptor = admission.descriptor
        let rc: Int32
        if request.isFlock {
            var operation: Int32
            switch request.type {
            case 0: operation = LOCK_SH
            case 1: operation = LOCK_EX
            default: operation = LOCK_UN
            }
            if request.type != 2 { operation |= LOCK_NB }
            rc = try performAdvisoryLock(
                requestUnique: header.unique,
                ownerKey: AdvisoryLockOwnerKey(
                    nodeID: header.nodeID,
                    owner: request.owner,
                    flock: request.isFlock
                ),
                blocking: blocking && request.type != 2,
                operation: request.isFlock ? "flock" : "F_OFD_SETLK"
            ) {
                descriptor.operationLock.withLock { flock(descriptor.fd, operation) }
            }
        } else {
            rc = try performAdvisoryLock(
                requestUnique: header.unique,
                ownerKey: AdvisoryLockOwnerKey(
                    nodeID: header.nodeID,
                    owner: request.owner,
                    flock: request.isFlock
                ),
                blocking: blocking && request.type != 2,
                operation: "F_OFD_SETLK"
            ) {
                var record = try darwinLockRecord(request)
                return descriptor.operationLock.withLock {
                    fcntl(descriptor.fd, F_OFD_SETLK, &record)
                }
            }
        }
        guard rc == 0 else { throw HostFSError.systemCall(request.isFlock ? "flock" : "F_OFD_SETLK", errno) }
        if request.type != 2 { retainOwner = true }
        if request.type == 2 { wakeAdvisoryLockWaiters() }
        return successResponse(unique: header.unique, payload: [])
    }

    /// A Darwin blocking fcntl/flock cannot be reliably cancelled from another FUSE queue. Poll
    /// the nonblocking primitive at a short bounded interval instead, allowing FUSE_INTERRUPT and
    /// transport reset to terminate SETLKW without leaking the request or blocking a vCPU.
    private func performAdvisoryLock(
        requestUnique: UInt64,
        ownerKey: AdvisoryLockOwnerKey,
        blocking: Bool,
        operation: String,
        attempt: () throws -> Int32
    ) throws -> Int32 {
        guard blocking else { return try attempt() }
        let resourceToken = try resourceQuota.acquire(.pendingBlockingLocks)
        do {
            try advisoryLockCondition.withLock {
                guard pendingBlockingLocks.insert(requestUnique).inserted else {
                    throw HostFSError.invalidName("duplicate blocking-lock request identity")
                }
                pendingBlockingLockOwners[requestUnique] = ownerKey
                pendingBlockingLockTokens[requestUnique] = resourceToken
                cancelledBlockingLocks.remove(requestUnique)
            }
        } catch {
            resourceToken.release()
            throw error
        }
        defer {
            let token = advisoryLockCondition.withLock { () -> FuseResourceToken? in
                pendingBlockingLocks.remove(requestUnique)
                pendingBlockingLockOwners.removeValue(forKey: requestUnique)
                cancelledBlockingLocks.remove(requestUnique)
                return pendingBlockingLockTokens.removeValue(forKey: requestUnique)
            }
            token?.release()
        }
        while true {
            advisoryLockCondition.lock()
            if cancelledBlockingLocks.contains(requestUnique) {
                advisoryLockCondition.unlock()
                throw HostFSError.systemCall(operation, EINTR)
            }
            let rc: Int32
            do {
                rc = try attempt()
            } catch {
                advisoryLockCondition.unlock()
                throw error
            }
            if rc == 0 {
                advisoryLockCondition.unlock()
                return 0
            }
            let savedErrno = errno
            guard savedErrno == EAGAIN || savedErrno == EACCES else {
                advisoryLockCondition.unlock()
                errno = savedErrno
                return rc
            }
            _ = advisoryLockCondition.wait(until: Date(timeIntervalSinceNow: 0.025))
            advisoryLockCondition.unlock()
        }
    }

    private func handleInterrupt(payload: ArraySlice<UInt8>) {
        guard payload.count >= 8 else { return }
        let interruptedUnique = payload.leUInt64(at: 0)
        let token = advisoryLockCondition.withLock { () -> FuseResourceToken? in
            guard pendingBlockingLocks.contains(interruptedUnique) else { return nil }
            // Keep the request identity registered until its worker observes cancellation. The
            // quota token can be returned immediately without allowing a duplicate unique ID to
            // erase the cancellation marker while the original request is still unwinding.
            cancelledBlockingLocks.insert(interruptedUnique)
            advisoryLockCondition.broadcast()
            return pendingBlockingLockTokens.removeValue(forKey: interruptedUnique)
        }
        token?.release()
    }

    func interrupt(requestUnique: UInt64) {
        var payload = [UInt8]()
        payload.appendLE(requestUnique)
        handleInterrupt(payload: payload[...])
    }

    func cancelAllRequests() {
        cancelAllBlockingLocks()
    }

    private func cancelAllBlockingLocks() {
        var tokens = advisoryLockCondition.withLock { () -> [FuseResourceToken] in
            cancelledBlockingLocks.formUnion(pendingBlockingLocks)
            let tokens = Array(pendingBlockingLockTokens.values)
            pendingBlockingLockTokens.removeAll(keepingCapacity: false)
            advisoryLockCondition.broadcast()
            return tokens
        }
        tokens.removeAll(keepingCapacity: false)
    }

    private func cancelBlockingLocks(nodeID: UInt64, owner: UInt64) {
        var tokens = advisoryLockCondition.withLock { () -> [FuseResourceToken] in
            let requests = pendingBlockingLockOwners.compactMap { unique, key in
                key.nodeID == nodeID && key.owner == owner ? unique : nil
            }
            cancelledBlockingLocks.formUnion(requests)
            let tokens = requests.compactMap {
                pendingBlockingLockTokens.removeValue(forKey: $0)
            }
            advisoryLockCondition.broadcast()
            return tokens
        }
        tokens.removeAll(keepingCapacity: false)
    }

    private func wakeAdvisoryLockWaiters() {
        advisoryLockCondition.withLock { advisoryLockCondition.broadcast() }
    }

    private func advisoryLockDescriptor(
        nodeID: UInt64,
        owner: UInt64,
        flock: Bool,
        openHandle: OpenFileHandle
    ) throws -> AdvisoryLockDescriptorAdmission {
        let key = AdvisoryLockOwnerKey(nodeID: nodeID, owner: owner, flock: flock)
        if let existing = lock.withLock({ () -> AdvisoryLockDescriptorAdmission? in
            guard let descriptor = lockOwners[key] else { return nil }
            descriptor.activeAdmissions += 1
            return AdvisoryLockDescriptorAdmission(key: key, descriptor: descriptor)
        }) {
            return existing
        }
        let resourceToken = try resourceQuota.acquire(.advisoryLockOwners)
        // HostFS performs a contained openat() and verifies the inode identity, producing a new
        // open description for each guest lock owner. This is essential on Darwin because simply
        // opening /dev/fd aliases the source description and collapses different guest owners.
        let fd = try hostFS.openFile(
            nodeID: nodeID,
            accessMode: openHandle.accessMode,
            append: false
        )
        let candidate = AdvisoryLockDescriptor(
            fd: fd,
            usesFlock: flock,
            resourceToken: resourceToken
        )
        return lock.withLock {
            if let existing = lockOwners[key] {
                existing.activeAdmissions += 1
                return AdvisoryLockDescriptorAdmission(key: key, descriptor: existing)
            }
            candidate.activeAdmissions = 1
            lockOwners[key] = candidate
            return AdvisoryLockDescriptorAdmission(key: key, descriptor: candidate)
        }
    }

    private func finishAdvisoryLockDescriptor(
        _ admission: AdvisoryLockDescriptorAdmission,
        retainOwner: Bool
    ) {
        var removed: AdvisoryLockDescriptor? = lock.withLock {
            let descriptor = admission.descriptor
            precondition(descriptor.activeAdmissions > 0, "unbalanced advisory-lock admission")
            descriptor.activeAdmissions -= 1
            if retainOwner { descriptor.retainedByOwner = true }
            guard lockOwners[admission.key] === descriptor,
                  descriptor.activeAdmissions == 0,
                  !descriptor.retainedByOwner else {
                return nil
            }
            return lockOwners.removeValue(forKey: admission.key)
        }
        let didRemove = removed != nil
        removed = nil
        if didRemove { wakeAdvisoryLockWaiters() }
    }

    private func darwinLockRecord(_ request: FuseLockRequest) throws -> flock {
        guard request.start <= request.end,
              request.start <= UInt64(Int64.max) else {
            throw HostFSError.invalidName("lock range")
        }
        var record = flock()
        record.l_start = off_t(request.start)
        if request.end == UInt64.max || request.end >= UInt64(Int64.max) {
            record.l_len = 0
        } else {
            let length = request.end - request.start + 1
            guard length <= UInt64(Int64.max) else { throw HostFSError.invalidName("lock range") }
            record.l_len = off_t(length)
        }
        record.l_pid = pid_t(request.pid)
        record.l_type = Int16(request.type == 0 ? F_RDLCK : request.type == 1 ? F_WRLCK : F_UNLCK)
        record.l_whence = Int16(SEEK_SET)
        return record
    }

    private func releaseAdvisoryLocks(nodeID: UInt64, owner: UInt64) {
        cancelBlockingLocks(nodeID: nodeID, owner: owner)
        var released: [AdvisoryLockDescriptor] = lock.withLock {
            let keys = lockOwners.keys.filter { $0.nodeID == nodeID && $0.owner == owner }
            return keys.compactMap { lockOwners.removeValue(forKey: $0) }
        }
        released.removeAll(keepingCapacity: false)
        wakeAdvisoryLockWaiters()
    }

    private func handleReleaseDirectory(header: FuseInHeader, payload: ArraySlice<UInt8>) -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        releaseDirectory(handle: payload.leUInt64(at: 0))
        return successResponse(unique: header.unique, payload: [])
    }

    /// HostFS already reserved the node lifetime atomically with its identity duplicate. This map
    /// insertion cannot fail, so ownership of both the fd and the open-handle reference transfers
    /// directly to the returned FUSE handle.
    private func storeRetainedFile(
        fd: Int32,
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool,
        resourceToken: FuseResourceToken
    ) -> UInt64 {
        lock.withLock {
            storeFileLocked(
                fd: fd,
                nodeID: nodeID,
                accessMode: accessMode,
                append: append,
                resourceToken: resourceToken
            )
        }
    }

    private func storeFileLocked(
        fd: Int32,
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool,
        resourceToken: FuseResourceToken
    ) -> UInt64 {
        let handle = allocateFileHandleLocked()
        fileHandles[handle] = OpenFileHandle(
            fd: fd,
            nodeID: nodeID,
            accessMode: accessMode,
            append: append,
            hostFS: hostFS,
            resourceToken: resourceToken
        )
        return handle
    }

    private func storeDirectory(nodeID: UInt64) throws -> UInt64 {
        let resourceToken = try resourceQuota.acquire(.directoryHandles)
        try hostFS.retainOpenHandle(nodeID: nodeID)
        let cursor: HostFSDirectoryCursor
        do {
            cursor = try hostFS.openDirectoryCursor(nodeID: nodeID)
        } catch {
            hostFS.releaseOpenHandle(nodeID: nodeID)
            throw error
        }
        return lock.withLock {
            let handle = allocateDirectoryHandleLocked()
            directoryHandles[handle] = OpenDirectoryHandle(
                nodeID: nodeID,
                cursor: cursor,
                hostFS: hostFS,
                resourceQuota: resourceQuota,
                resourceToken: resourceToken
            )
            return handle
        }
    }

    private func loadFile(handle: UInt64) -> OpenFileHandle? {
        lock.withLock { fileHandles[handle] }
    }

    private func describeStaleHandle(_ handle: UInt64, nodeID: UInt64, op: String) -> String {
        if handle & Self.directoryHandleTag != 0 {
            guard let open = loadDirectory(handle: handle) else {
                return "\(op) unknown dir handle=\(handle) node=\(nodeID)"
            }
            return "\(op) dir handle=\(handle) node=\(nodeID) handleNode=\(open.nodeID)"
        }
        guard let open = loadFile(handle: handle) else {
            return "\(op) unknown handle=\(handle) node=\(nodeID)"
        }
        return "\(op) handle=\(handle) node=\(nodeID) handleNode=\(open.nodeID) mode=\(open.accessMode)"
    }

    private func loadDirectory(handle: UInt64) -> OpenDirectoryHandle? {
        lock.withLock { directoryHandles[handle] }
    }

    private func releaseFile(handle: UInt64) {
        // Dropping the table's strong reference closes immediately only when no request queue is
        // still using the handle. Otherwise OpenFileHandle.deinit runs after the last operation.
        _ = lock.withLock { fileHandles.removeValue(forKey: handle) }
    }

    private func releaseDirectory(handle: UInt64) {
        _ = lock.withLock { directoryHandles.removeValue(forKey: handle) }
    }

    private func allocateFileHandleLocked() -> UInt64 {
        while true {
            let handle = nextFileHandle
            nextFileHandle = handle == Self.handleSequenceMask ? 1 : handle + 1
            if fileHandles[handle] == nil { return handle }
        }
    }

    private func allocateDirectoryHandleLocked() -> UInt64 {
        while true {
            let sequence = nextDirectoryHandle
            nextDirectoryHandle = sequence == Self.handleSequenceMask ? 1 : sequence + 1
            let handle = Self.directoryHandleTag | sequence
            if directoryHandles[handle] == nil { return handle }
        }
    }

    private func readCString(_ payload: ArraySlice<UInt8>) throws -> String {
        guard let terminator = payload.firstIndex(of: 0),
              let string = String(bytes: payload[..<terminator], encoding: .utf8) else {
            throw HostFSError.invalidName("")
        }
        return string
    }

    private func readCStrings(_ payload: ArraySlice<UInt8>, count: Int) throws -> [String] {
        var strings = [String]()
        var start = payload.startIndex
        while strings.count < count {
            guard let end = payload[start...].firstIndex(of: 0),
                  let string = String(bytes: payload[start..<end], encoding: .utf8) else {
                throw HostFSError.invalidName("")
            }
            strings.append(string)
            start = payload.index(after: end)
        }
        return strings
    }

    private func successResponse(unique: UInt64, payload: [UInt8]) -> [UInt8] {
        successResponse(unique: unique, payloadByteCount: payload.count) { response in
            response.append(contentsOf: payload)
        }
    }

    private func successResponse(unique: UInt64, payloadByteCount: Int, appendPayload: (inout [UInt8]) -> Void) -> [UInt8] {
        var response = [UInt8]()
        response.reserveCapacity(FuseOutHeader.byteCount + payloadByteCount)
        response.appendLE(UInt32(FuseOutHeader.byteCount + payloadByteCount))
        response.appendLE(UInt32(0))
        response.appendLE(unique)
        appendPayload(&response)
        return response
    }

    private func errorResponse(unique: UInt64, errno rawErrno: Int32) -> [UInt8] {
        let errno = FuseProtocol.linuxErrno(rawErrno)
        var response = [UInt8]()
        response.reserveCapacity(FuseOutHeader.byteCount)
        response.appendLE(UInt32(FuseOutHeader.byteCount))
        response.appendLE(UInt32(bitPattern: -errno))
        response.appendLE(unique)
        return response
    }

    private func encodeEntryOut(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(128)
        appendEntryOut(attrs, to: &data)
        return data
    }

    private func encodeAttrOut(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(96)
        appendAttrOut(attrs, to: &data)
        return data
    }

    private func encodeOpenOut(handle: UInt64, openFlags: UInt32) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(16)
        appendOpenOut(handle: handle, openFlags: openFlags, to: &data)
        return data
    }

    private func appendEntryOut(_ attrs: HostFSAttributes, to data: inout [UInt8]) {
        let cache = cachePolicy.responsePolicy
        data.appendLE(attrs.nodeID)
        data.appendLE(UInt64(1))
        data.appendLE(cache.entryValiditySeconds)   // entry_valid
        data.appendLE(cache.attrValiditySeconds)    // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        appendAttr(attrs, to: &data)
    }

    private func appendAttrOut(_ attrs: HostFSAttributes, to data: inout [UInt8]) {
        let cache = cachePolicy.responsePolicy
        data.appendLE(cache.attrValiditySeconds)   // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        appendAttr(attrs, to: &data)
    }

    private func appendOpenOut(handle: UInt64, openFlags: UInt32, to data: inout [UInt8]) {
        data.appendLE(handle)
        data.appendLE(openFlags)
        data.appendLE(UInt32(0))
    }

    private func encodeDirentPlus(_ entry: HostFSEntry, offset: UInt64) -> [UInt8] {
        let name = Array(entry.name.utf8)
        var data = encodeEntryOut(entry.attributes)
        data.appendLE(entry.nodeID)
        data.appendLE(offset)
        data.appendLE(UInt32(name.count))
        data.appendLE(direntType(for: entry.attributes))
        data.append(contentsOf: name)
        while data.count % 8 != 0 { data.append(0) }
        return data
    }

    private static func direntPlusEncodedLength(nameByteCount: Int) -> Int {
        (128 + 24 + nameByteCount + 7) & ~7
    }

    private func encodeAttr(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(88)
        appendAttr(attrs, to: &data)
        return data
    }

    private func appendAttr(_ attrs: HostFSAttributes, to data: inout [UInt8]) {
        data.appendLE(attrs.nodeID)
        data.appendLE(attrs.size)
        data.appendLE((attrs.size + 511) / 512)
        data.appendLE(UInt64(bitPattern: attrs.atimeSeconds))
        data.appendLE(UInt64(bitPattern: attrs.mtimeSeconds))
        data.appendLE(UInt64(bitPattern: attrs.ctimeSeconds))
        data.appendLE(attrs.atimeNsec)
        data.appendLE(attrs.mtimeNsec)
        data.appendLE(attrs.ctimeNsec)
        data.appendLE(attrs.mode)
        data.appendLE(attrs.linkCount)
        data.appendLE(attrs.uid)
        data.appendLE(attrs.gid)
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(4096))
        data.appendLE(UInt32(0))
    }

    private func direntType(for attrs: HostFSAttributes) -> UInt32 {
        if attrs.isDirectory { return 4 }
        if attrs.isSymlink { return 10 }
        if attrs.isRegularFile { return 8 }
        return 0
    }

    // FUSE_WRITE_KILL_SUIDGID: the kernel sets this in fuse_write_in.write_flags (offset 20 of the
    // write payload) under HANDLE_KILLPRIV_V2 to ask the server to drop suid/sgid + security.capability.
    static let writeKillSuidgid: UInt32 = 1 << 2

    private func killPrivilegeBitsIfRequested(writeFlags: UInt32, fd: Int32) {
        guard killPrivV2, writeFlags & Self.writeKillSuidgid != 0 else { return }
        try? hostFS.clearPrivilegedBits(handle: fd)
    }

    private var fileOpenFlags: UInt32 {
        // FOPEN_KEEP_CACHE cannot be revoked from handles that were opened before notification
        // health degraded. Metadata validity is bounded and fenceable; page-cache retention is not.
        OpenFlag.noFlush
    }

    private var directoryOpenFlags: UInt32 {
        // FOPEN_CACHE_DIR has the same irrevocable lifetime problem as KEEP_CACHE. Directory entry
        // and attribute TTLs are the only cache acceleration enabled by coherent mode.
        0
    }

    private func mapError(_ error: Error) -> Int32 {
        switch error {
        case HostFSError.invalidRoot, HostFSError.io:
            return EIO
        case HostFSError.invalidName:
            return EINVAL
        case HostFSError.notFound:
            return ENOENT
        case HostFSError.staleIdentity:
            return ESTALE
        case HostFSError.notDirectory:
            return ENOTDIR
        case HostFSError.notRegularFile:
            return EISDIR
        case HostFSError.readOnly:
            return EROFS
        case HostFSError.permissionDenied:
            return EACCES
        case HostFSError.operationNotSupported:
            return EOPNOTSUPP
        case let HostFSError.systemCall(_, code):
            return code
        case FuseProtocolError.shortFrame:
            return EINVAL
        case FuseProtocolError.unsupportedMinor:
            return EPROTO
        case RequestError.badFileDescriptor:
            return EBADF
        case let quota as FuseResourceQuotaError:
            // Node identities and every handle/lock-owner table entry retain a descriptor or a
            // descriptor-backed identity, so EMFILE accurately reports per-share FD exhaustion.
            // Blocking-lock admission consumes request capacity instead and is retryable once a
            // waiter completes or is interrupted, matching Linux EAGAIN semantics.
            switch quota.resource {
            case .pendingBlockingLocks:
                return EAGAIN
            case .directoryCursorEntries, .directoryCursorNameBytes:
                return EOVERFLOW
            default:
                return EMFILE
            }
        default:
            return EIO
        }
    }
}

/// A guest-held handle failing to resolve is a protocol invariant violation, never a workload
/// condition. Log the first occurrences so field failures name their branch instead of surfacing
/// only as an unexplained EBADF inside the container.
private final class FuseAnomalyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var budget = 50

    func log(_ message: @autoclosure () -> String) {
        let allowed: Bool = lock.withLock {
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }
        guard allowed else { return }
        FileHandle.standardError.write(Data("dory-hv: fuse anomaly: \(message())\n".utf8))
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
