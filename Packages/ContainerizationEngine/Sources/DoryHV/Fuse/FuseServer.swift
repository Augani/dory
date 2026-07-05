import Darwin
import Foundation

public final class FuseServer: @unchecked Sendable {
    private let hostFS: HostFS
    private let daxWindow: DaxWindow?
    private let lock = NSLock()
    private var nextHandle: UInt64 = 1
    private var fileHandles: [UInt64: Int32] = [:]

    public init(hostFS: HostFS, daxWindow: DaxWindow? = nil) {
        self.hostFS = hostFS
        self.daxWindow = daxWindow
    }

    public func handle(request: [UInt8]) -> [UInt8] {
        guard let header = try? FuseProtocol.decodeInHeader(request),
              Int(header.length) <= request.count,
              header.length >= UInt32(FuseInHeader.byteCount) else {
            return errorResponse(unique: 0, errno: EINVAL)
        }

        let payload = Array(request[Int(FuseInHeader.byteCount)..<Int(header.length)])
        guard let opcode = FuseOpcode(rawValue: header.opcode) else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }

        do {
            switch opcode {
            case .initOp:
                let initIn = try FuseProtocol.decodeInitIn(payload)
                return FuseProtocol.negotiateInit(
                    header: header,
                    request: initIn,
                    daxMapAlignmentLog2: daxWindow == nil ? nil : UInt16(log2(Double(DaxWindow.pageSize)))
                )
            case .lookup:
                return try handleLookup(header: header, payload: payload)
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

    private func handleLookup(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        let name = try readCString(payload)
        let entry = try hostFS.lookup(parent: header.nodeID, name: name)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleGetattr(header: FuseInHeader) throws -> [UInt8] {
        let attrs = try hostFS.getattr(nodeID: header.nodeID)
        return successResponse(unique: header.unique, payload: encodeAttrOut(attrs))
    }

    private func handleSetattr(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 88 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let valid = FuseSetattrValid(rawValue: payload.leUInt32(at: 0))
        let attrs = try hostFS.getattr(nodeID: header.nodeID)
        if valid.contains(.mode) {
            let requestedMode = payload.leUInt32(at: 68) & 0o7777
            let currentMode = attrs.mode & 0o7777
            guard requestedMode == currentMode else {
                return errorResponse(unique: header.unique, errno: EOPNOTSUPP)
            }
        }
        if valid.contains(.size) {
            let size = payload.leUInt64(at: 16)
            if valid.contains(.fileHandle), let fd = load(handle: payload.leUInt64(at: 8)) {
                try hostFS.truncate(handle: fd, size: size)
            } else {
                try hostFS.truncate(nodeID: header.nodeID, size: size)
            }
            return try successResponse(unique: header.unique, payload: encodeAttrOut(hostFS.getattr(nodeID: header.nodeID)))
        }
        return successResponse(unique: header.unique, payload: encodeAttrOut(attrs))
    }

    private func handleOpen(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let flags = Int32(bitPattern: payload.leUInt32(at: 0))
        let fd = flags & O_ACCMODE == O_RDONLY
            ? try hostFS.openRead(nodeID: header.nodeID)
            : try hostFS.openReadWrite(nodeID: header.nodeID)
        let handle = store(fd: fd)
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: handle, openFlags: 1 << 1))
    }

    private func handleOpenDir(header: FuseInHeader) throws -> [UInt8] {
        _ = try hostFS.getattr(nodeID: header.nodeID)
        return successResponse(unique: header.unique, payload: encodeOpenOut(handle: header.nodeID, openFlags: 1 << 3))
    }

    private func handleRead(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
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

    private func handleWrite(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 40 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        let offset = payload.leUInt64(at: 8)
        let size = Int(payload.leUInt32(at: 16))
        guard payload.count >= 40 + size else { return errorResponse(unique: header.unique, errno: EINVAL) }
        guard let fd = load(handle: handle) else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        let data = Array(payload[40..<(40 + size)])
        let written = try hostFS.write(handle: fd, offset: offset, data: data)
        var response = [UInt8]()
        response.appendLE(UInt32(written))
        response.appendLE(UInt32(0))
        return successResponse(unique: header.unique, payload: response)
    }

    private func handleReadDirPlus(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
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

    private func handleFsync(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        guard let fd = load(handle: handle) else {
            return errorResponse(unique: header.unique, errno: EBADF)
        }
        try hostFS.fsync(handle: fd)
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleCreate(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 16 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 4))
        let name = try readCString(Array(payload.dropFirst(16)))
        let entry = try hostFS.createFile(parent: header.nodeID, name: name, mode: mode)
        let fd = try hostFS.openReadWrite(nodeID: entry.nodeID)
        let handle = store(fd: fd)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes) + encodeOpenOut(handle: handle, openFlags: 1 << 1))
    }

    private func handleMkdir(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let mode = UInt16(truncatingIfNeeded: payload.leUInt32(at: 0))
        let name = try readCString(Array(payload.dropFirst(8)))
        let entry = try hostFS.mkdir(parent: header.nodeID, name: name, mode: mode)
        return successResponse(unique: header.unique, payload: encodeEntryOut(entry.attributes))
    }

    private func handleUnlink(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        try hostFS.unlink(parent: header.nodeID, name: readCString(payload))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRmdir(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        try hostFS.rmdir(parent: header.nodeID, name: readCString(payload))
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRename(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let newParent = payload.leUInt64(at: 0)
        let names = try readCStrings(Array(payload.dropFirst(8)), count: 2)
        _ = try hostFS.rename(parent: header.nodeID, name: names[0], newParent: newParent, newName: names[1])
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleRelease(header: FuseInHeader, payload: [UInt8]) -> [UInt8] {
        guard payload.count >= 8 else { return errorResponse(unique: header.unique, errno: EINVAL) }
        let handle = payload.leUInt64(at: 0)
        if let fd = remove(handle: handle) {
            hostFS.close(handle: fd)
        }
        return successResponse(unique: header.unique, payload: [])
    }

    private func handleSetupMapping(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard let daxWindow else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        let request = try FuseProtocol.decodeSetupMappingIn(payload)
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

    private func handleRemoveMapping(header: FuseInHeader, payload: [UInt8]) throws -> [UInt8] {
        guard let daxWindow else {
            return errorResponse(unique: header.unique, errno: ENOSYS)
        }
        let request = try FuseProtocol.decodeRemoveMappingIn(payload)
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

    private func readCString(_ payload: [UInt8]) throws -> String {
        guard let terminator = payload.firstIndex(of: 0),
              let string = String(bytes: payload[..<terminator], encoding: .utf8) else {
            throw HostFSError.invalidName("")
        }
        return string
    }

    private func readCStrings(_ payload: [UInt8], count: Int) throws -> [String] {
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
        FuseProtocol.encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount + payload.count),
            error: 0,
            unique: unique
        )) + payload
    }

    private func errorResponse(unique: UInt64, errno: Int32) -> [UInt8] {
        FuseProtocol.encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount),
            error: -errno,
            unique: unique
        ))
    }

    // Cache-validity window handed to the guest for looked-up entries and attributes. A zero
    // attr_valid forces the guest to revalidate with a GETATTR on essentially every access and
    // prevents the page cache from being trusted, collapsing read throughput to a FUSE round-trip
    // per 4 KiB. One second is the cache=auto default (virtiofsd): the guest trusts cached
    // metadata and data for up to a second, revalidating on open via mtime.
    static let cacheValiditySeconds: UInt64 = 1

    private func encodeEntryOut(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(attrs.nodeID)
        data.appendLE(UInt64(1))
        data.appendLE(Self.cacheValiditySeconds)   // entry_valid
        data.appendLE(Self.cacheValiditySeconds)   // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.append(contentsOf: encodeAttr(attrs))
        return data
    }

    private func encodeAttrOut(_ attrs: HostFSAttributes) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(Self.cacheValiditySeconds)   // attr_valid
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.append(contentsOf: encodeAttr(attrs))
        return data
    }

    private func encodeOpenOut(handle: UInt64, openFlags: UInt32) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(handle)
        data.appendLE(openFlags)
        data.appendLE(UInt32(0))
        return data
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
        return data
    }

    private func direntType(for attrs: HostFSAttributes) -> UInt32 {
        if attrs.isDirectory { return 4 }
        if attrs.isSymlink { return 10 }
        if attrs.isRegularFile { return 8 }
        return 0
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

private extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
