import Darwin
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

public final class FuseServer: @unchecked Sendable {
    static let maximumCoherentCacheValiditySeconds = FuseCachePolicy.maximumValiditySeconds
    static let negativeCoherentCacheValiditySeconds = FuseCachePolicy.negativeValiditySeconds

    private let hostFS: HostFS
    private let daxWindow: DaxWindow?
    private let writebackCache: Bool
    private let killPrivV2: Bool
    private let fastCreateAttributes: Bool
    private let cachePolicy = FuseCachePolicy()
    private let stats: FuseStats?
    private let anomalyLog = FuseAnomalyLog()
    private let lock = NSLock()
    private var nextFileHandle: UInt64 = 1
    private var nextDirectoryHandle: UInt64 = 1
    private var fileHandles: [UInt64: OpenFileHandle] = [:]
    private var directoryHandles: [UInt64: OpenDirectoryHandle] = [:]
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

        init(fd: Int32, nodeID: UInt64, accessMode: HostFSAccessMode, append: Bool, hostFS: HostFS) {
            self.fd = fd
            self.nodeID = nodeID
            self.accessMode = accessMode
            self.append = append
            self.hostFS = hostFS
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
        /// Linux treats `fuse_read_in.offset` as a cookie into one open directory stream. Rebuilding
        /// the sorted listing for every page makes that cookie unstable when a consumer such as
        /// `rm -rf` deletes page one before requesting page two: the remaining entries shift left
        /// and are skipped. Keep one enumeration snapshot for the lifetime of the open handle.
        /// Slots are never renumbered during this open-directory lifetime. A removed name becomes
        /// nil instead of shifting later cookies left; newly discovered names append new slots.
        var entries: [HostFSEntry?]?
        private let hostFS: HostFS

        init(nodeID: UInt64, entries: [HostFSEntry?]? = nil, hostFS: HostFS) {
            self.nodeID = nodeID
            self.entries = entries
            self.hostFS = hostFS
        }

        deinit {
            hostFS.releaseOpenHandle(nodeID: nodeID)
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
        daxWindow: DaxWindow? = nil,
        writebackCache: Bool? = nil,
        killPrivV2: Bool? = nil,
        deferReleaseClose _: Bool? = nil,
        fastCreateAttributes: Bool? = nil
    ) {
        self.hostFS = hostFS
        self.daxWindow = daxWindow
        self.writebackCache = writebackCache ?? Self.writebackCacheEnabledFromEnvironment()
        self.killPrivV2 = killPrivV2 ?? Self.killPrivV2EnabledFromEnvironment()
        // A synthetic create identity cannot distinguish the original inode from a host atomic
        // replacement that lands before the first getattr/open. Production always records the real
        // file key; tests may still opt in explicitly to exercise legacy reconciliation behavior.
        self.fastCreateAttributes = fastCreateAttributes ?? false
        self.stats = FuseStats.fromEnvironment()
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
        stats?.record(opcode)

        do {
            switch opcode {
            case .initOp:
                let initIn = try FuseProtocol.decodeInitIn(Array(payload))
                let response = FuseProtocol.negotiateInit(
                    header: header,
                    request: initIn,
                    daxMapAlignmentLog2: daxWindow == nil ? nil : UInt16(log2(Double(DaxWindow.pageSize))),
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
            case .flush:
                return handleFlush(header: header, payload: payload)
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
            case .setupmapping:
                return try handleSetupMapping(header: header, payload: payload)
            case .removemapping:
                return try handleRemoveMapping(header: header, payload: payload)
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
        let entry = try hostFS.symlink(parent: header.nodeID, name: values[0], target: values[1])
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
        let fd = try hostFS.openFileForFuseHandle(
            nodeID: header.nodeID,
            accessMode: hostAccess,
            append: intent.append && !writebackCache
        )
        let handle = storeRetainedFile(
            fd: fd,
            nodeID: header.nodeID,
            accessMode: intent.accessMode,
            append: intent.append
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

    /// Zero-copy READ: `preadv` the payload straight into the guest's device-writable descriptor
    /// segments (scatter-gather, so any header+data split works) and write the fuse_out_header in
    /// place, returning total bytes produced. Avoids the intermediate read buffer, the response
    /// array, and the copy back into guest memory that the array path incurs. Returns 0 to signal
    /// the caller to fall back (e.g. the first segment is too small to hold the out header).
    public func writeReadResponse(header: FuseInHeader, payload: [UInt8], writable: [VirtqueueSegment]) -> Int {
        writeReadResponse(header: header, payload: payload[...], writable: writable)
    }

    public func writeReadResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        guard let first = writable.first, first.length >= FuseOutHeader.byteCount else { return 0 }
        let totalCapacity = writable.reduce(0) { $0 + $1.length }
        func finish(errno: Int32, payloadBytes: Int) -> Int {
            let total = FuseOutHeader.byteCount + payloadBytes
            first.pointer.storeBytes(of: UInt32(total).littleEndian, toByteOffset: 0, as: UInt32.self)
            first.pointer.storeBytes(of: Int32(-FuseProtocol.linuxErrno(errno)).littleEndian, toByteOffset: 4, as: Int32.self)
            first.pointer.storeBytes(of: header.unique.littleEndian, toByteOffset: 8, as: UInt64.self)
            return total
        }
        guard payload.count >= 40 else { return finish(errno: EINVAL, payloadBytes: 0) }
        let size = min(Int(payload.leUInt32(at: 16)), HostFS.maxReadCount)
        guard let signedOffset = off_t(exactly: payload.leUInt64(at: 8)) else {
            return finish(errno: EINVAL, payloadBytes: 0)
        }
        guard let openHandle = loadFile(handle: payload.leUInt64(at: 0)),
              openHandle.nodeID == header.nodeID,
              openHandle.permitsRead(writebackCache: writebackCache) else {
            anomalyLog.log(describeStaleHandle(payload.leUInt64(at: 0), nodeID: header.nodeID, op: "READ(direct)"))
            return finish(errno: EBADF, payloadBytes: 0)
        }
        let dataCapacity = min(size, totalCapacity - FuseOutHeader.byteCount)
        guard dataCapacity > 0 else { return finish(errno: 0, payloadBytes: 0) }

        // Build iovecs over the writable bytes AFTER the 16-byte out header.
        var iovecs = [iovec]()
        var remaining = dataCapacity
        var skip = FuseOutHeader.byteCount
        for segment in writable where remaining > 0 {
            var base = segment.pointer
            var length = segment.length
            if skip > 0 {
                let drop = min(skip, length)
                base = base.advanced(by: drop)
                length -= drop
                skip -= drop
            }
            guard length > 0 else { continue }
            let take = min(length, remaining)
            iovecs.append(iovec(iov_base: base, iov_len: take))
            remaining -= take
        }
        let readCount = preadv(openHandle.fd, iovecs, Int32(iovecs.count), signedOffset)
        guard readCount >= 0 else { return finish(errno: errno, payloadBytes: 0) }
        return finish(errno: 0, payloadBytes: Int(readCount))
    }

    /// Complete direct LOOKUP response. Handling hits as well as misses here is important: probing for
    /// a miss and then falling back on a hit performs the same descriptor-relative stat twice. Require
    /// enough output space for either result before touching HostFS so an undersized chain can fall
    /// back without registering an entry or acquiring a lookup reference.
    public func writeLookupResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        let payloadBytes = 128
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else {
            return 0
        }
        stats?.record(.lookup)
        do {
            let name = try readCString(payload)
            guard let entry = try hostFS.lookupIfExists(parent: header.nodeID, name: name) else {
                let validity = cachePolicy.negativeEntryValiditySeconds
                guard validity > 0 else {
                    return writeErrorResponse(unique: header.unique, errno: ENOENT, writable: writable)
                }
                var writer = FuseDirectResponseWriter(writable: writable)
                writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
                writer.append(encodeNegativeEntryOut(validity: validity))
                return writer.written
            }
            hostFS.retainLookup(nodeID: entry.nodeID)
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendEntryOut(entry.attributes, to: &writer)
            return writer.written
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct GETXATTR response for the default policy: Dory does not expose host extended attributes
    /// through broad home shares, so the stable answer is ENODATA. This is on the hot path for Alpine's
    /// shell-created files.
    public func writeGetXattrNoDataResponse(header: FuseInHeader, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.getxattr)
        // ENOSYS latches fc->no_getxattr guest-side; see the array-path getxattr case.
        return writeErrorResponse(unique: header.unique, errno: ENOSYS, writable: writable)
    }

    /// Direct GETATTR response. Metadata-heavy create loops ask for attrs after create; emitting the
    /// fixed attr payload in place avoids another response allocation on that path.
    public func writeGetattrResponse(
        header: FuseInHeader,
        payload: ArraySlice<UInt8>,
        writable: [VirtqueueSegment]
    ) -> Int {
        stats?.record(.getattr)
        let payloadBytes = 104
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
        do {
            let attrs = try getattrAttributes(header: header, payload: payload)
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendAttrOut(attrs, to: &writer)
            return writer.written
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct CREATE response. The common shell redirection path creates and opens a file, then writes
    /// and releases it immediately. This keeps the create response on the same direct path as write and
    /// release while preserving the normal fallback for undersized writable chains.
    public func writeCreateResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.create)
        let payloadBytes = 144
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
        do {
            guard payload.count >= 16 else {
                return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
            }
            guard let intent = FileOpenIntent(wireFlags: payload.leUInt32(at: 0)) else {
                return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
            }
            let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
            let name = try readCString(payload.dropFirst(16))
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
                retainOpenHandle: true
            )
            let handle = storeRetainedFile(
                fd: created.fd,
                nodeID: created.entry.nodeID,
                accessMode: intent.accessMode,
                append: intent.append
            )
            hostFS.retainLookup(nodeID: created.entry.nodeID)
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendEntryOut(created.entry.attributes, to: &writer)
            appendOpenOut(handle: handle, openFlags: fileOpenFlags, to: &writer)
            return writer.written
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct MKDIR response. It is cold compared with CREATE, but keeping directory setup on the
    /// direct path avoids a stray allocation in create/delete benchmark loops.
    public func writeMkdirResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.mkdir)
        let payloadBytes = 128
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
        do {
            guard payload.count >= 8 else {
                return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
            }
            let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 0))
            let name = try readCString(payload.dropFirst(8))
            let entry = try hostFS.mkdir(
                parent: header.nodeID,
                name: name,
                mode: mode,
                syntheticAttributes: fastCreateAttributes
            )
            hostFS.retainLookup(nodeID: entry.nodeID)
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendEntryOut(entry.attributes, to: &writer)
            return writer.written
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct UNLINK/RMDIR response for cleanup-heavy bind mount loops. The host mutation still goes
    /// through HostFS; this only avoids allocating and copying the empty success frame.
    public func writeRemoveResponse(header: FuseInHeader, opcode: FuseOpcode, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        stats?.record(opcode)
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        do {
            let name = try readCString(payload)
            switch opcode {
            case .unlink:
                try hostFS.unlink(parent: header.nodeID, name: name)
            case .rmdir:
                try hostFS.rmdir(parent: header.nodeID, name: name)
            default:
                return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
            }
            return writeEmptySuccessResponse(unique: header.unique, writable: writable)
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct WRITE response path for the virtio-fs device. The response is a fixed
    /// `fuse_out_header + fuse_write_out`, so writing it straight into the guest avoids a tiny
    /// allocation and scatter-copy on every small write in metadata-heavy bind workloads.
    public func writeWriteResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.write)
        let payloadBytes = 8
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
        do {
            guard payload.count >= 40 else { return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable) }
            let handle = payload.leUInt64(at: 0)
            let offset = payload.leUInt64(at: 8)
            let size = Int(payload.leUInt32(at: 16))
            guard payload.count >= 40 + size else {
                return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
            }
            guard let openHandle = loadFile(handle: handle),
                  openHandle.nodeID == header.nodeID,
                  openHandle.permitsWrite else {
                anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "WRITE(direct)"))
                return writeErrorResponse(unique: header.unique, errno: EBADF, writable: writable)
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
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            writer.appendLE(UInt32(written))
            writer.appendLE(UInt32(0))
            return writer.written
        } catch {
            return writeErrorResponse(unique: header.unique, errno: mapError(error), writable: writable)
        }
    }

    /// Direct RELEASE/RELEASEDIR response path. RELEASE is close-heavy in shell-file-create loops;
    /// keeping it allocation-free makes the common success path cheaper without changing close
    /// ordering or deferred-close semantics.
    public func writeReleaseResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        guard let opcode = FuseOpcode(rawValue: header.opcode), opcode == .release || opcode == .releasedir else {
            return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
        }
        stats?.record(opcode)
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        guard payload.count >= 8 else {
            return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
        }
        let handle = payload.leUInt64(at: 0)
        if opcode == .release {
            releaseFile(handle: handle)
        } else {
            releaseDirectory(handle: handle)
        }
        return writeEmptySuccessResponse(unique: header.unique, writable: writable)
    }

    public func writeEmptySuccessResponse(unique: UInt64, writable: [VirtqueueSegment]) -> Int {
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        var writer = FuseDirectResponseWriter(writable: writable)
        writer.appendOutHeader(unique: unique, error: 0, payloadByteCount: 0)
        return writer.written
    }

    /// Reverses only server-side lifetime grants from a successful response that never reached the
    /// used ring. Host namespace/data mutations remain committed; the guest never received the
    /// node or handle references that would otherwise authorize keeping these resources alive.
    func rollbackUnpublishedResponse(
        opcode: FuseOpcode,
        writable: [VirtqueueSegment],
        written: Int
    ) {
        guard let response = copyEncodedResponse(writable: writable, written: written) else { return }
        rollbackUnpublishedResponse(opcode: opcode, response: response)
    }

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
        let openHandles: ([OpenFileHandle], [OpenDirectoryHandle]) = lock.withLock {
            let files = Array(fileHandles.values)
            let directories = Array(directoryHandles.values)
            fileHandles.removeAll(keepingCapacity: false)
            directoryHandles.removeAll(keepingCapacity: false)
            return (files, directories)
        }
        // Keep the removed handles alive until after the table lock is released. Their deinits
        // close descriptors and release HostFS open references after any in-flight request-owned
        // references have also drained.
        var openFiles = openHandles.0
        var openDirectories = openHandles.1
        openFiles.removeAll(keepingCapacity: false)
        openDirectories.removeAll(keepingCapacity: false)
        hostFS.resetFuseReferences()
        cachePolicy.deactivate(resetFuseInit: true)
    }

    private func copyEncodedResponse(
        writable: [VirtqueueSegment],
        written: Int
    ) -> [UInt8]? {
        guard written >= FuseOutHeader.byteCount else { return nil }
        var response = [UInt8]()
        response.reserveCapacity(written)
        var remaining = written
        for segment in writable where remaining > 0 {
            let take = min(segment.length, remaining)
            response.append(contentsOf: UnsafeRawBufferPointer(start: segment.pointer, count: take))
            remaining -= take
        }
        guard remaining == 0 else { return nil }
        let declaredLength = Int(response.leUInt32(at: 0))
        guard declaredLength >= FuseOutHeader.byteCount, declaredLength <= response.count else {
            return nil
        }
        if declaredLength < response.count {
            response.removeSubrange(declaredLength..<response.count)
        }
        return response
    }

    private func writeErrorResponse(unique: UInt64, errno rawErrno: Int32, writable: [VirtqueueSegment]) -> Int {
        let errno = FuseProtocol.linuxErrno(rawErrno)
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        var writer = FuseDirectResponseWriter(writable: writable)
        writer.appendOutHeader(unique: unique, error: -errno, payloadByteCount: 0)
        return writer.written
    }

    /// Removes every metadata-cache grant from an already encoded successful response. VirtioFS
    /// calls this under its publish fence when a queue-health policy transition overtook a worker.
    /// Copying is intentional: this is a cold race path, and it handles TTL fields split
    /// across arbitrary writable descriptor segments without weakening the direct hot paths.
    @discardableResult
    func neutralizeCacheGrants(
        opcode: FuseOpcode,
        writable: [VirtqueueSegment],
        written: Int
    ) -> Bool {
        guard var response = copyEncodedResponse(writable: writable, written: written) else { return false }
        let declaredLength = response.count
        // Errors and response kinds without entry/attribute validity cannot grant metadata cache.
        guard Int32(bitPattern: response.leUInt32(at: 4)) == 0 else { return true }

        func zeroUInt64(at offset: Int) -> Bool {
            guard offset >= 0, offset + MemoryLayout<UInt64>.size <= declaredLength else {
                return false
            }
            response.replaceSubrange(offset..<(offset + MemoryLayout<UInt64>.size), with: repeatElement(0, count: 8))
            return true
        }

        let payloadStart = FuseOutHeader.byteCount
        switch opcode {
        case .lookup, .symlink, .link, .mkdir, .create:
            // fuse_entry_out: nodeid, generation, entry_valid, attr_valid, ...
            guard zeroUInt64(at: payloadStart + 16), zeroUInt64(at: payloadStart + 24) else {
                return false
            }
        case .getattr, .setattr:
            // fuse_attr_out begins with attr_valid.
            guard zeroUInt64(at: payloadStart) else { return false }
        case .readdirplus:
            // Each packed record is fuse_entry_out (128 bytes) followed by fuse_dirent. Records are
            // independently 8-byte aligned, so neutralize both validity fields in every entry.
            var recordStart = payloadStart
            while recordStart < declaredLength {
                let nameLengthOffset = recordStart + 128 + 16
                guard nameLengthOffset + 4 <= declaredLength,
                      zeroUInt64(at: recordStart + 16),
                      zeroUInt64(at: recordStart + 24) else {
                    return false
                }
                let nameLength = Int(response.leUInt32(at: nameLengthOffset))
                let unalignedLength = 128 + 24 + nameLength
                let recordLength = (unalignedLength + 7) & ~7
                guard recordLength >= 152, recordStart + recordLength <= declaredLength else {
                    return false
                }
                recordStart += recordLength
            }
            guard recordStart == declaredLength else { return false }
        default:
            return true
        }

        var offset = 0
        for segment in writable where offset < declaredLength {
            let take = min(segment.length, declaredLength - offset)
            response[offset..<(offset + take)].withUnsafeBytes { source in
                segment.pointer.copyMemory(from: source.baseAddress!, byteCount: take)
            }
            offset += take
        }
        return offset == declaredLength
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
        guard let entries = try directoryEntries(
            handle: handle,
            nodeID: header.nodeID,
            refresh: offset == 0
        ) else {
            anomalyLog.log(describeStaleHandle(handle, nodeID: header.nodeID, op: "READDIRPLUS"))
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        let maxSize = Int(payload.leUInt32(at: 16))
        var data = [UInt8]()
        var retainedNodeIDs = [UInt64]()
        for (index, optionalEntry) in entries.enumerated().dropFirst(offset) {
            guard let entry = optionalEntry else { continue }
            let encoded = encodeDirentPlus(entry, offset: UInt64(index + 1))
            guard data.count + encoded.count <= maxSize else { break }
            data.append(contentsOf: encoded)
            retainedNodeIDs.append(entry.nodeID)
        }
        hostFS.retainLookups(nodeIDs: retainedNodeIDs)
        return successResponse(unique: header.unique, payload: data)
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
        return successResponse(unique: header.unique, payload: [])
    }

    public func writeFlushResponse(
        header: FuseInHeader,
        payload: ArraySlice<UInt8>,
        writable: [VirtqueueSegment]
    ) -> Int {
        guard payload.count >= 24 else {
            return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
        }
        guard let openHandle = loadFile(handle: payload.leUInt64(at: 0)),
              openHandle.nodeID == header.nodeID else {
            anomalyLog.log(describeStaleHandle(payload.leUInt64(at: 0), nodeID: header.nodeID, op: "FLUSH(direct)"))
            return writeErrorResponse(unique: header.unique, errno: EBADF, writable: writable)
        }
        return writeEmptySuccessResponse(unique: header.unique, writable: writable)
    }

    private func handleCreate(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let intent = FileOpenIntent(wireFlags: payload.leUInt32(at: 0)) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
        let name = try readCString(payload.dropFirst(16))
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
            retainOpenHandle: true
        )
        let handle = storeRetainedFile(
            fd: created.fd,
            nodeID: created.entry.nodeID,
            accessMode: intent.accessMode,
            append: intent.append
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
            syntheticAttributes: fastCreateAttributes
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
        releaseFile(handle: payload.leUInt64(at: 0))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleReleaseDirectory(header: FuseInHeader, payload: ArraySlice<UInt8>) -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        releaseDirectory(handle: payload.leUInt64(at: 0))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleSetupMapping(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard let daxWindow else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        let request = try FuseProtocol.decodeSetupMappingIn(Array(payload))
        let knownMappingFlags = FuseSetupMappingFlag.read.rawValue
            | FuseSetupMappingFlag.write.rawValue
        guard request.flags & ~knownMappingFlags == 0 else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        // virtio-fs sends fh = -1 for inode-based DAX mappings; resolve the file from the node id.
        // The backend mmaps read-write (Apple's hv_vm_map rejects a read-only host region), so the
        // fd must be writable; a read-only file therefore falls back to plain FUSE reads via the
        // thrown error. The backend keeps its own mmap, so a temporary open is closed after setup.
        let fd: Int32
        var temporaryFD: Int32?
        if request.fileHandle == UInt64.max {
            fd = try hostFS.openReadWrite(nodeID: header.nodeID)
            temporaryFD = fd
        } else if let openHandle = loadFile(handle: request.fileHandle),
                  openHandle.nodeID == header.nodeID,
                  request.flags & FuseSetupMappingFlag.write.rawValue == 0
                    || openHandle.permitsWrite,
                  request.flags & FuseSetupMappingFlag.read.rawValue == 0
                    || openHandle.permitsRead(writebackCache: false) {
            fd = openHandle.fd
        } else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        defer { if let temporaryFD { hostFS.close(handle: temporaryFD) } }
        _ = try daxWindow.setup(request, fileDescriptor: fd)
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRemoveMapping(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard let daxWindow else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        let request = try FuseProtocol.decodeRemoveMappingIn(Array(payload))
        try daxWindow.remove(request)
        return successResponse(unique: header.unique, payload: [])
    }

    /// HostFS already reserved the node lifetime atomically with its identity duplicate. This map
    /// insertion cannot fail, so ownership of both the fd and the open-handle reference transfers
    /// directly to the returned FUSE handle.
    private func storeRetainedFile(
        fd: Int32,
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool
    ) -> UInt64 {
        lock.withLock {
            storeFileLocked(
                fd: fd,
                nodeID: nodeID,
                accessMode: accessMode,
                append: append
            )
        }
    }

    private func storeFileLocked(
        fd: Int32,
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool
    ) -> UInt64 {
        let handle = allocateFileHandleLocked()
        fileHandles[handle] = OpenFileHandle(
            fd: fd,
            nodeID: nodeID,
            accessMode: accessMode,
            append: append,
            hostFS: hostFS
        )
        return handle
    }

    private func storeDirectory(nodeID: UInt64) throws -> UInt64 {
        try hostFS.retainOpenHandle(nodeID: nodeID)
        return lock.withLock {
            let handle = allocateDirectoryHandleLocked()
            directoryHandles[handle] = OpenDirectoryHandle(nodeID: nodeID, hostFS: hostFS)
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

    private func directoryEntries(
        handle: UInt64,
        nodeID: UInt64,
        refresh: Bool
    ) throws -> [HostFSEntry?]? {
        guard let directory = loadDirectory(handle: handle), directory.nodeID == nodeID else {
            return nil
        }
        directoryOperationLoadedTestHook?()
        let cached = lock.withLock { directory.entries }
        if !refresh, let entries = cached { return entries }

        // Host enumeration can perform many descriptor-relative stats; never hold the server's
        // handle-table lock across it. If two first-page requests race, the first installed
        // snapshot wins and both callers use that same stable cookie space.
        let discovered = try hostFS.readdirplus(nodeID: nodeID)
        return lock.withLock {
            if !refresh, let entries = directory.entries { return entries }
            if let entries = directory.entries {
                var currentByName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
                var stableSlots = entries.map { previous -> HostFSEntry? in
                    guard let previous else { return nil }
                    return currentByName.removeValue(forKey: previous.name)
                }
                // `discovered` is sorted, so additions are deterministic while existing cookies
                // retain their original slot numbers. Replacements update attributes in place.
                stableSlots.append(contentsOf: discovered.compactMap { currentByName[$0.name] })
                directory.entries = stableSlots
                return stableSlots
            }
            let initial = discovered.map(Optional.some)
            directory.entries = initial
            return initial
        }
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

    private func appendEntryOut(_ attrs: HostFSAttributes, to writer: inout FuseDirectResponseWriter) {
        let cache = cachePolicy.responsePolicy
        writer.appendLE(attrs.nodeID)
        writer.appendLE(UInt64(1))
        writer.appendLE(cache.entryValiditySeconds)   // entry_valid
        writer.appendLE(cache.attrValiditySeconds)    // attr_valid
        writer.appendLE(UInt32(0))
        writer.appendLE(UInt32(0))
        appendAttr(attrs, to: &writer)
    }

    private func appendAttrOut(_ attrs: HostFSAttributes, to data: inout [UInt8]) {
        let cache = cachePolicy.responsePolicy
        data.appendLE(cache.attrValiditySeconds)   // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        appendAttr(attrs, to: &data)
    }

    private func appendAttrOut(_ attrs: HostFSAttributes, to writer: inout FuseDirectResponseWriter) {
        let cache = cachePolicy.responsePolicy
        writer.appendLE(cache.attrValiditySeconds)   // attr_valid
        writer.appendLE(UInt32(0))
        writer.appendLE(UInt32(0))
        appendAttr(attrs, to: &writer)
    }

    private func appendOpenOut(handle: UInt64, openFlags: UInt32, to data: inout [UInt8]) {
        data.appendLE(handle)
        data.appendLE(openFlags)
        data.appendLE(UInt32(0))
    }

    private func appendOpenOut(handle: UInt64, openFlags: UInt32, to writer: inout FuseDirectResponseWriter) {
        writer.appendLE(handle)
        writer.appendLE(openFlags)
        writer.appendLE(UInt32(0))
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

    private func appendAttr(_ attrs: HostFSAttributes, to writer: inout FuseDirectResponseWriter) {
        writer.appendLE(attrs.nodeID)
        writer.appendLE(attrs.size)
        writer.appendLE((attrs.size + 511) / 512)
        writer.appendLE(UInt64(bitPattern: attrs.atimeSeconds))
        writer.appendLE(UInt64(bitPattern: attrs.mtimeSeconds))
        writer.appendLE(UInt64(bitPattern: attrs.ctimeSeconds))
        writer.appendLE(attrs.atimeNsec)
        writer.appendLE(attrs.mtimeNsec)
        writer.appendLE(attrs.ctimeNsec)
        writer.appendLE(attrs.mode)
        writer.appendLE(attrs.linkCount)
        writer.appendLE(attrs.uid)
        writer.appendLE(attrs.gid)
        writer.appendLE(UInt32(0))
        writer.appendLE(UInt32(4096))
        writer.appendLE(UInt32(0))
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

    private static func writebackCacheEnabledFromEnvironment() -> Bool {
        // Default OFF: desktop shares are bidirectional. With FUSE writeback enabled, dirty guest
        // pages can survive a reverse invalidation and later overwrite a host editor's change even
        // after the notification barrier completes. Keep explicit opt-in for isolated experiments;
        // production coherence requires write-through until dirty-page conflict handling exists.
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_WRITEBACK_CACHE"]?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    private static func killPrivV2EnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_KILLPRIV"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
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
        case DaxWindowError.unaligned, DaxWindowError.outOfBounds, DaxWindowError.invalidWindow:
            return EINVAL
        case DaxWindowError.overlap:
            return EBUSY
        case DaxWindowError.missingMapping:
            return ENOENT
        case DaxWindowError.mappingFailed, DaxWindowError.unmappingFailed:
            return EIO
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

private final class FuseStats: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [FuseOpcode: Int] = [:]
    private var total = 0

    static func fromEnvironment() -> FuseStats? {
        let value = ProcessInfo.processInfo.environment["DORY_FUSE_STATS"] ?? ""
        guard ["1", "true", "yes", "on"].contains(value.lowercased()) else { return nil }
        FileHandle.standardError.write(Data("dory-hv: fuse stats enabled\n".utf8))
        return FuseStats()
    }

    func record(_ opcode: FuseOpcode) {
        let snapshot: (Int, [FuseOpcode: Int])? = lock.withLock {
            total += 1
            counts[opcode, default: 0] += 1
            guard total <= 20 || total.isMultiple(of: 100) else { return nil }
            return (total, counts)
        }
        guard let snapshot else { return }
        let line = snapshot.1
            .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        FileHandle.standardError.write(Data("dory-hv: fuse stats total=\(snapshot.0) \(line)\n".utf8))
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct FuseDirectResponseWriter {
    private let writable: [VirtqueueSegment]
    private var segmentIndex = 0
    private var segmentOffset = 0
    private(set) var written = 0

    init(writable: [VirtqueueSegment]) {
        self.writable = writable
    }

    mutating func appendOutHeader(unique: UInt64, error: Int32, payloadByteCount: Int) {
        appendLE(UInt32(FuseOutHeader.byteCount + payloadByteCount))
        appendLE(UInt32(bitPattern: error))
        appendLE(unique)
    }

    mutating func append(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { append($0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { append($0) }
    }

    mutating func appendLE(_ value: UInt64) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { append($0) }
    }

    private mutating func append(_ source: UnsafeRawBufferPointer) {
        var copied = 0
        while copied < source.count, segmentIndex < writable.count {
            let segment = writable[segmentIndex]
            let remainingInSegment = segment.length - segmentOffset
            if remainingInSegment <= 0 {
                segmentIndex += 1
                segmentOffset = 0
                continue
            }
            let take = min(remainingInSegment, source.count - copied)
            segment.pointer
                .advanced(by: segmentOffset)
                .copyMemory(from: source.baseAddress!.advanced(by: copied), byteCount: take)
            copied += take
            segmentOffset += take
            written += take
        }
    }
}
