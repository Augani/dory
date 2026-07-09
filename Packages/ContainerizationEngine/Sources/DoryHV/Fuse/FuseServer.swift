import Darwin
import Foundation

public final class FuseServer: @unchecked Sendable {
    private let hostFS: HostFS
    private let daxWindow: DaxWindow?
    private let writebackCache: Bool
    private let killPrivV2: Bool
    private let deferReleaseClose: Bool
    private let fastCreateAttributes: Bool
    private let negativeDentryCaching: Bool
    private let entryValiditySeconds: UInt64
    private let attrValiditySeconds: UInt64
    private let stats: FuseStats?
    private let closeQueue = DispatchQueue(label: "dory-hv.fuse.close")
    private let deferredCloseLock = NSLock()
    private var deferredCloseFDs: [Int32] = []
    private var deferredCloseScheduled = false
    private let lock = NSLock()
    private var nextHandle: UInt64 = 1
    private var fileHandles: [UInt64: Int32] = [:]

    private enum OpenFlag {
        static let keepCache: UInt32 = 1 << 1
        static let cacheDir: UInt32 = 1 << 3
        static let noFlush: UInt32 = 1 << 5
    }

    public init(
        hostFS: HostFS,
        daxWindow: DaxWindow? = nil,
        writebackCache: Bool? = nil,
        killPrivV2: Bool? = nil,
        deferReleaseClose: Bool? = nil,
        fastCreateAttributes: Bool? = nil,
        negativeDentryCaching: Bool? = nil,
        entryValiditySeconds: UInt64? = nil,
        attrValiditySeconds: UInt64? = nil
    ) {
        self.hostFS = hostFS
        self.daxWindow = daxWindow
        self.writebackCache = writebackCache ?? Self.writebackCacheEnabledFromEnvironment()
        self.killPrivV2 = killPrivV2 ?? Self.killPrivV2EnabledFromEnvironment()
        self.deferReleaseClose = deferReleaseClose ?? Self.deferReleaseCloseEnabledFromEnvironment()
        self.fastCreateAttributes = fastCreateAttributes ?? Self.fastCreateAttributesEnabledFromEnvironment()
        self.negativeDentryCaching = negativeDentryCaching ?? Self.negativeDentryCachingEnabledFromEnvironment()
        self.entryValiditySeconds = entryValiditySeconds ?? Self.timeoutFromEnvironment("DORY_FUSE_ENTRY_TIMEOUT")
        self.attrValiditySeconds = attrValiditySeconds ?? Self.timeoutFromEnvironment("DORY_FUSE_ATTR_TIMEOUT")
        self.stats = FuseStats.fromEnvironment()
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
                return FuseProtocol.negotiateInit(
                    header: header,
                    request: initIn,
                    daxMapAlignmentLog2: daxWindow == nil ? nil : UInt16(log2(Double(DaxWindow.pageSize))),
                    writebackCache: writebackCache,
                    killPrivV2: killPrivV2
                )
            case .lookup:
                return try handleLookup(header: header, payload: payload)
            case .readlink:
                return try handleReadlink(header: header)
            case .symlink:
                return try handleSymlink(header: header, payload: payload)
            case .getattr:
                return try handleGetattr(header: header)
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
                return successResponse(unique: header.unique, payload: [])
            case .getxattr:
                return errorResponse(unique: header.unique, errno: ENODATA)
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
            case .release, .releasedir:
                return handleRelease(header: header, payload: payload)
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
            guard negativeDentryCaching else {
                return errorResponse(unique: header.unique, errno: ENOENT)
            }
            return successResponse(unique: header.unique, payload: encodeNegativeEntryOut())
        }
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleReadlink(header: FuseInHeader) throws -> [UInt8] {
        return try successResponse(unique: header.unique, payload: Array(hostFS.readlink(nodeID: header.nodeID).utf8))
    }

    private func handleSymlink(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let values = try readCStrings(payload, count: 2)
        let entry = try hostFS.symlink(parent: header.nodeID, name: values[0], target: values[1])
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleGetattr(header: FuseInHeader) throws -> [UInt8] {
        let attrs = try hostFS.getattr(nodeID: header.nodeID)
        return successResponse(unique: header.unique, payload: encodeAttrOut(attrs))
    }

    private func handleSetattr(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 88 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let valid = FuseSetattrValid(rawValue: payload.leUInt32(at: 0))
        let cachedAttrs = try hostFS.cachedAttributes(nodeID: header.nodeID)
        if valid.contains(.mode) {
            let requestedMode = payload.leUInt32(at: 68) & 0o7777
            let currentMode = cachedAttrs.mode & 0o7777
            guard requestedMode == currentMode else {
                return errorResponse(unique: header.unique, errno: EOPNOTSUPP)
            }
        }
        if valid.contains(.size) {
            let size = payload.leUInt64(at: 16)
            if valid.contains(.fileHandle), let fd = load(handle: payload.leUInt64(at: 8)) {
                try hostFS.truncate(handle: fd, size: size)
                // KILLPRIV_V2 delegates the suid/sgid kill on truncate to the server, same as WRITE.
                // Clear unconditionally under V2 (clearPrivilegedBits no-ops when no priv bit is set),
                // matching POSIX truncate semantics and the flag the kernel sets (FATTR_KILL_SUIDGID).
                if killPrivV2 { try? hostFS.clearPrivilegedBits(handle: fd) }
            } else {
                try hostFS.truncate(nodeID: header.nodeID, size: size)
                if killPrivV2 { try? hostFS.clearPrivilegedBits(nodeID: header.nodeID) }
            }
            return try successResponse(unique: header.unique, payload: encodeAttrOut(hostFS.getattr(nodeID: header.nodeID)))
        }
        return successResponse(unique: header.unique, payload: encodeAttrOut(cachedAttrs))
    }

    private func handleOpen(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let flags = Int32(bitPattern: payload.leUInt32(at: 0))
        let fd = flags & O_ACCMODE == O_RDONLY
            ? try hostFS.openRead(nodeID: header.nodeID)
            : try hostFS.openReadWrite(nodeID: header.nodeID)
        let handle = store(fd: fd)
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: handle, openFlags: OpenFlag.keepCache | OpenFlag.noFlush))
    }

    private func handleOpenDir(header: FuseInHeader) throws -> [UInt8] {
        _ = try hostFS.getattr(nodeID: header.nodeID)
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: header.nodeID, openFlags: OpenFlag.cacheDir))
    }

    private func handleRead(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        let offset = payload.leUInt64(at: 8)
        let size = min(Int(payload.leUInt32(at: 16)), HostFS.maxReadCount)
        guard let fd = load(handle: handle) else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        return try successResponse(unique: header.unique, payload: hostFS.read(handle: fd, offset: offset, count: size))
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
            first.pointer.storeBytes(of: Int32(-errno).littleEndian, toByteOffset: 4, as: Int32.self)
            first.pointer.storeBytes(of: header.unique.littleEndian, toByteOffset: 8, as: UInt64.self)
            return total
        }
        guard payload.count >= 40 else { return finish(errno: EINVAL, payloadBytes: 0) }
        let size = min(Int(payload.leUInt32(at: 16)), HostFS.maxReadCount)
        guard let signedOffset = off_t(exactly: payload.leUInt64(at: 8)) else {
            return finish(errno: EINVAL, payloadBytes: 0)
        }
        guard let fd = load(handle: payload.leUInt64(at: 0)) else {
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
        let readCount = preadv(fd, iovecs, Int32(iovecs.count), signedOffset)
        guard readCount >= 0 else { return finish(errno: errno, payloadBytes: 0) }
        return finish(errno: 0, payloadBytes: Int(readCount))
    }

    /// Direct LOOKUP miss response. Fresh file-create loops issue a negative LOOKUP before CREATE for
    /// each path; returning ENOENT in place avoids allocating a tiny error frame thousands of times.
    /// Existing entries fall back to the normal array path so the full entry payload stays centralized.
    public func writeLookupMissResponse(header: FuseInHeader, payload: ArraySlice<UInt8>, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.lookup)
        do {
            let name = try readCString(payload)
            guard try hostFS.lookupIfExists(parent: header.nodeID, name: name) == nil else {
                return 0
            }
            guard negativeDentryCaching else {
                return writeErrorResponse(unique: header.unique, errno: ENOENT, writable: writable)
            }
            let payloadBytes = 128
            guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendNegativeEntryOut(to: &writer)
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
        return writeErrorResponse(unique: header.unique, errno: ENODATA, writable: writable)
    }

    /// Direct GETATTR response. Metadata-heavy create loops ask for attrs after create; emitting the
    /// fixed attr payload in place avoids another response allocation on that path.
    public func writeGetattrResponse(header: FuseInHeader, writable: [VirtqueueSegment]) -> Int {
        stats?.record(.getattr)
        let payloadBytes = 104
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount + payloadBytes else { return 0 }
        do {
            let attrs = try hostFS.getattr(nodeID: header.nodeID)
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
            let flags = Int32(bitPattern: payload.leUInt32(at: 0))
            let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
            let name = try readCString(payload.dropFirst(16))
            let created = try hostFS.createFileAndOpen(
                parent: header.nodeID,
                name: name,
                mode: mode,
                flags: flags,
                syntheticAttributes: fastCreateAttributes
            )
            let handle = store(fd: created.fd)
            var writer = FuseDirectResponseWriter(writable: writable)
            writer.appendOutHeader(unique: header.unique, error: 0, payloadByteCount: payloadBytes)
            appendEntryOut(created.entry.attributes, to: &writer)
            appendOpenOut(handle: handle, openFlags: OpenFlag.keepCache | OpenFlag.noFlush, to: &writer)
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
            let entry = try hostFS.mkdir(parent: header.nodeID, name: name, mode: mode)
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
            guard let fd = load(handle: handle) else {
                return writeErrorResponse(unique: header.unique, errno: EBADF, writable: writable)
            }
            let written = try payload.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress?.advanced(by: 40)
                return try hostFS.write(
                    handle: fd,
                    offset: offset,
                    bytes: UnsafeRawBufferPointer(start: base, count: size)
                )
            }
            hostFS.recordWrite(nodeID: header.nodeID, offset: offset, count: written)
            killPrivilegeBitsIfRequested(writeFlags: payload.leUInt32(at: 20), fd: fd)
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
        stats?.record(.release)
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        guard payload.count >= 8 else {
            return writeErrorResponse(unique: header.unique, errno: EINVAL, writable: writable)
        }
        let handle = payload.leUInt64(at: 0)
        if let fd = remove(handle: handle) {
            if deferReleaseClose {
                enqueueDeferredClose(fd)
            } else {
                hostFS.close(handle: fd)
            }
        }
        return writeEmptySuccessResponse(unique: header.unique, writable: writable)
    }

    public func writeEmptySuccessResponse(unique: UInt64, writable: [VirtqueueSegment]) -> Int {
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        var writer = FuseDirectResponseWriter(writable: writable)
        writer.appendOutHeader(unique: unique, error: 0, payloadByteCount: 0)
        return writer.written
    }

    private func writeErrorResponse(unique: UInt64, errno: Int32, writable: [VirtqueueSegment]) -> Int {
        guard writable.reduce(0, { $0 + $1.length }) >= FuseOutHeader.byteCount else { return 0 }
        var writer = FuseDirectResponseWriter(writable: writable)
        writer.appendOutHeader(unique: unique, error: -errno, payloadByteCount: 0)
        return writer.written
    }

    private func handleWrite(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        let offset = payload.leUInt64(at: 8)
        let size = Int(payload.leUInt32(at: 16))
        guard payload.count >= 40 + size else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let fd = load(handle: handle) else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        let written = try payload.withUnsafeBytes { raw -> Int in
            let base = raw.baseAddress?.advanced(by: 40)
            return try hostFS.write(
                handle: fd,
                offset: offset,
                bytes: UnsafeRawBufferPointer(start: base, count: size)
            )
        }
        hostFS.recordWrite(nodeID: header.nodeID, offset: offset, count: written)
        killPrivilegeBitsIfRequested(writeFlags: payload.leUInt32(at: 20), fd: fd)
        return successResponse(unique: header.unique, payloadByteCount: 8) { response in
            response.appendLE(UInt32(written))
            response.appendLE(UInt32(0))
        }
    }

    private func handleReadDirPlus(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let offset = Int(exactly: payload.leUInt64(at: 8)) else {
            return errorResponse(unique: header.unique, errno: EINVAL)
        }
        let maxSize = Int(payload.leUInt32(at: 16))
        let entries = try hostFS.readdirplus(nodeID: header.nodeID)
        var data = [UInt8]()
        for (index, entry) in entries.enumerated().dropFirst(offset) {
            let encoded = encodeDirentPlus(entry, offset: UInt64(index + 1))
            guard data.count + encoded.count <= maxSize else { break }
            data.append(contentsOf: encoded)
        }
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
        guard let fd = load(handle: handle) else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        try hostFS.fsync(handle: fd)
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleCreate(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let flags = Int32(bitPattern: payload.leUInt32(at: 0))
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
        let name = try readCString(payload.dropFirst(16))
        let created = try hostFS.createFileAndOpen(
            parent: header.nodeID,
            name: name,
            mode: mode,
            flags: flags,
            syntheticAttributes: fastCreateAttributes
        )
        let handle = store(fd: created.fd)
        let entry = created.entry
        return successResponse(unique: header.unique, payloadByteCount: 144) { response in
            appendEntryOut(entry.attributes, to: &response)
            appendOpenOut(handle: handle, openFlags: OpenFlag.keepCache | OpenFlag.noFlush, to: &response)
        }
    }

    private func handleMkdir(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 0))
        let name = try readCString(payload.dropFirst(8))
        let entry = try hostFS.mkdir(parent: header.nodeID, name: name, mode: mode)
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

    private func handleRelease(header: FuseInHeader, payload: ArraySlice<UInt8>) -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        if let fd = remove(handle: handle) {
            if deferReleaseClose {
                enqueueDeferredClose(fd)
            } else {
                hostFS.close(handle: fd)
            }
        }
        return successResponse(unique: header.unique, payload: [])
    }

    private func enqueueDeferredClose(_ fd: Int32) {
        let shouldSchedule = deferredCloseLock.withLock {
            deferredCloseFDs.append(fd)
            guard !deferredCloseScheduled else { return false }
            deferredCloseScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        closeQueue.async { [self] in
            drainDeferredCloses()
        }
    }

    private func drainDeferredCloses() {
        while true {
            let batch: [Int32] = deferredCloseLock.withLock {
                guard !deferredCloseFDs.isEmpty else {
                    deferredCloseScheduled = false
                    return []
                }
                let fds = deferredCloseFDs
                deferredCloseFDs.removeAll(keepingCapacity: true)
                return fds
            }
            guard !batch.isEmpty else { return }
            for fd in batch {
                hostFS.close(handle: fd)
            }
        }
    }

    private func handleSetupMapping(header: FuseInHeader, payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard let daxWindow else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        let request = try FuseProtocol.decodeSetupMappingIn(Array(payload))
        // virtio-fs sends fh = -1 for inode-based DAX mappings; resolve the file from the node id.
        // The backend mmaps read-write (Apple's hv_vm_map rejects a read-only host region), so the
        // fd must be writable; a read-only file therefore falls back to plain FUSE reads via the
        // thrown error. The backend keeps its own mmap, so a temporary open is closed after setup.
        let fd: Int32
        var temporaryFD: Int32?
        if request.fileHandle == UInt64.max {
            fd = try hostFS.openReadWrite(nodeID: header.nodeID)
            temporaryFD = fd
        } else if let open = load(handle: request.fileHandle) {
            fd = open
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

    private func store(fd: Int32) -> UInt64 {
        lock.withLock {
            let handle = nextHandle
            nextHandle += 1
            fileHandles[handle] = fd
            return handle
        }
    }

    private func load(handle: UInt64) -> Int32? {
        lock.withLock { fileHandles[handle] }
    }

    private func remove(handle: UInt64) -> Int32? {
        lock.withLock { fileHandles.removeValue(forKey: handle) }
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

    private func errorResponse(unique: UInt64, errno: Int32) -> [UInt8] {
        var response = [UInt8]()
        response.reserveCapacity(FuseOutHeader.byteCount)
        response.appendLE(UInt32(FuseOutHeader.byteCount))
        response.appendLE(UInt32(bitPattern: -errno))
        response.appendLE(unique)
        return response
    }

    // Default cache-validity window handed to the guest for looked-up entries and attributes. A zero
    // attr_valid forces the guest to revalidate with a GETATTR on essentially every access and
    // prevents the page cache from being trusted, collapsing read throughput to a FUSE round-trip
    // per 4 KiB. One second is the cache=auto default (virtiofsd): the guest trusts cached metadata
    // and data for up to a second, revalidating on open via mtime. `entryValiditySeconds` /
    // `attrValiditySeconds` are the seam for P0.3: once the FSEvents notify path can invalidate the
    // guest kernel cache on host-side changes, these can be raised to 5-30s. They stay at 1s until
    // then, because a longer window without invalidation serves stale dentries/attrs.
    static let defaultCacheValiditySeconds: UInt64 = 1

    private func encodeEntryOut(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(128)
        appendEntryOut(attrs, to: &data)
        return data
    }

    // Cacheable negative dentry: fuse_entry_out with nodeid=0 and a nonzero entry_valid. The guest
    // kernel translates nodeid=0 to ENOENT for the syscall but caches the "does not exist" answer for
    // entry_valid seconds, deleting the LOOKUP-miss that precedes every CREATE in a file-create storm.
    private func encodeNegativeEntryOut() -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(128)
        appendNegativeEntryOut(to: &data)
        return data
    }

    private func appendNegativeEntryOut(to data: inout [UInt8]) {
        data.appendLE(UInt64(0))                  // nodeid = 0 => negative dentry
        data.appendLE(UInt64(0))                  // generation
        data.appendLE(entryValiditySeconds)       // entry_valid
        data.appendLE(UInt64(0))                  // attr_valid (unused for negatives)
        data.appendLE(UInt32(0))                  // entry_valid_nsec
        data.appendLE(UInt32(0))                  // attr_valid_nsec
        for _ in 0..<11 { data.appendLE(UInt64(0)) }  // empty fuse_attr (88 bytes)
    }

    private func appendNegativeEntryOut(to writer: inout FuseDirectResponseWriter) {
        writer.appendLE(UInt64(0))
        writer.appendLE(UInt64(0))
        writer.appendLE(entryValiditySeconds)
        writer.appendLE(UInt64(0))
        writer.appendLE(UInt32(0))
        writer.appendLE(UInt32(0))
        for _ in 0..<11 { writer.appendLE(UInt64(0)) }
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
        data.appendLE(attrs.nodeID)
        data.appendLE(UInt64(1))
        data.appendLE(entryValiditySeconds)   // entry_valid
        data.appendLE(attrValiditySeconds)    // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        appendAttr(attrs, to: &data)
    }

    private func appendEntryOut(_ attrs: HostFSAttributes, to writer: inout FuseDirectResponseWriter) {
        writer.appendLE(attrs.nodeID)
        writer.appendLE(UInt64(1))
        writer.appendLE(entryValiditySeconds)   // entry_valid
        writer.appendLE(attrValiditySeconds)    // attr_valid
        writer.appendLE(UInt32(0))
        writer.appendLE(UInt32(0))
        appendAttr(attrs, to: &writer)
    }

    private func appendAttrOut(_ attrs: HostFSAttributes, to data: inout [UInt8]) {
        data.appendLE(attrValiditySeconds)   // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        appendAttr(attrs, to: &data)
    }

    private func appendAttrOut(_ attrs: HostFSAttributes, to writer: inout FuseDirectResponseWriter) {
        writer.appendLE(attrValiditySeconds)   // attr_valid
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
        data.appendLE(attrs.isDirectory ? UInt32(2) : UInt32(1))
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
        writer.appendLE(attrs.isDirectory ? UInt32(2) : UInt32(1))
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
        // Default ON (P0.2): the guest is the effectively-exclusive writer of shared paths, so
        // coalescing buffered writes is safe and removes the per-write round trip. Opt out with
        // DORY_FUSE_WRITEBACK_CACHE=0 for the durability-strict benchmark arm.
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_WRITEBACK_CACHE"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func killPrivV2EnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_KILLPRIV"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func negativeDentryCachingEnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_NEGATIVE_DENTRY"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func timeoutFromEnvironment(_ key: String) -> UInt64 {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = UInt64(raw) else {
            return defaultCacheValiditySeconds
        }
        return value
    }

    private static func deferReleaseCloseEnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_DEFER_CLOSE"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func fastCreateAttributesEnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_FAST_CREATE"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func mapError(_ error: Error) -> Int32 {
        switch error {
        case HostFSError.invalidRoot, HostFSError.io:
            return EIO
        case HostFSError.invalidName:
            return EINVAL
        case HostFSError.notFound:
            return ENOENT
        case HostFSError.notDirectory:
            return ENOTDIR
        case HostFSError.notRegularFile:
            return EISDIR
        case HostFSError.readOnly:
            return EROFS
        case HostFSError.permissionDenied:
            return EACCES
        case FuseProtocolError.shortFrame:
            return EINVAL
        case FuseProtocolError.unsupportedMinor:
            return EPROTO
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
