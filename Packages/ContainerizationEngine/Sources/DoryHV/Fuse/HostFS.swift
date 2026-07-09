import Darwin
import Foundation

public enum HostFSError: Error, Equatable {
    case invalidRoot(String)
    case invalidName(String)
    case notFound(String)
    case notDirectory(UInt64)
    case notRegularFile(UInt64)
    case readOnly
    case permissionDenied(String)
    case io(String)
}

public struct HostFSAttributes: Equatable, Sendable {
    public var nodeID: UInt64
    public var mode: UInt32
    public var size: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var atimeSeconds: Int64
    public var mtimeSeconds: Int64
    public var ctimeSeconds: Int64
    public var atimeNsec: UInt32 = 0
    public var mtimeNsec: UInt32 = 0
    public var ctimeNsec: UInt32 = 0

    public var isDirectory: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) }
    public var isRegularFile: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFREG) }
    public var isSymlink: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK) }
}

public struct HostFSEntry: Equatable, Sendable {
    public var name: String
    public var nodeID: UInt64
    public var attributes: HostFSAttributes
}

public struct HostFSStat: Equatable, Sendable {
    public var blockSize: UInt64
    public var blocks: UInt64
    public var blocksFree: UInt64
    public var blocksAvailable: UInt64
    public var files: UInt64
    public var filesFree: UInt64
    public var nameMax: UInt32
}

public final class HostFS: @unchecked Sendable {
    public static let rootNodeID: UInt64 = 1
    public static let maxReadCount: Int = 1 << 20

    private struct Node: Sendable {
        var id: UInt64
        var relativePath: String
        var attributes: HostFSAttributes
        var fileKey: FileKey
        var directoryFD: Int32? = nil
    }

    private let rootPath: String
    private let rootFD: Int32
    private let guestUID: UInt32
    private let guestGID: UInt32
    private let readOnly: Bool
    /// Entry names hidden from the guest at any depth. A lookup of a hidden name fails as if the
    /// path does not exist, hidden entries are omitted from directory listings, and entry-creating
    /// or entry-removing operations reject hidden names before touching the host.
    private let hiddenNames: Set<String>
    private var nextNodeID: UInt64 = 2
    private var nodes: [UInt64: Node] = [:]
    private var idsByFileKey: [FileKey: UInt64] = [:]
    private var idsByRelativePath: [String: [UInt64]] = [:]
    private let lock = NSLock()

    public init(rootPath: String, guestUID: UInt32 = 1000, guestGID: UInt32 = 1000, readOnly: Bool = false, hiddenNames: Set<String> = []) throws {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(rootPath, &resolved) != nil else {
            throw HostFSError.invalidRoot(rootPath)
        }
        let rootBytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let root = String(decoding: rootBytes, as: UTF8.self)
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw HostFSError.invalidRoot(rootPath)
        }

        self.rootPath = root
        self.rootFD = fd
        self.guestUID = guestUID
        self.guestGID = guestGID
        self.readOnly = readOnly
        self.hiddenNames = hiddenNames

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw HostFSError.invalidRoot(rootPath)
        }
        let attrs = Self.attributes(from: st, nodeID: Self.rootNodeID, uid: guestUID, gid: guestGID)
        self.nodes[Self.rootNodeID] = Node(id: Self.rootNodeID, relativePath: "", attributes: attrs, fileKey: FileKey(st))
        self.idsByFileKey[FileKey(st)] = Self.rootNodeID
        self.idsByRelativePath["", default: []].append(Self.rootNodeID)
    }

    deinit {
        for fd in nodes.values.compactMap(\.directoryFD) {
            Darwin.close(fd)
        }
        Darwin.close(rootFD)
    }

    public func getattr(nodeID: UInt64) throws -> HostFSAttributes {
        let node = try node(for: nodeID)
        if node.fileKey.isSynthetic {
            return node.attributes
        }
        var st = stat()
        let result = node.relativePath.isEmpty
            ? fstat(rootFD, &st)
            : fstatat(rootFD, cPath(node.relativePath), &st, AT_SYMLINK_NOFOLLOW)
        guard result == 0 else {
            throw HostFSError.notFound(node.relativePath)
        }
        let attrs = Self.attributes(from: st, nodeID: nodeID, uid: guestUID, gid: guestGID)
        let key = FileKey(st)
        if attrs != node.attributes || key != node.fileKey {
            lock.withLock {
                guard var current = nodes[nodeID] else { return }
                if current.fileKey != key {
                    idsByFileKey.removeValue(forKey: current.fileKey)
                    idsByFileKey[key] = nodeID
                    current.fileKey = key
                }
                current.attributes = attrs
                nodes[nodeID] = current
            }
        }
        return attrs
    }

    public func cachedAttributes(nodeID: UInt64) throws -> HostFSAttributes {
        try node(for: nodeID).attributes
    }

    public func recordWrite(nodeID: UInt64, offset: UInt64, count: Int) {
        guard count > 0 else { return }
        let endOffset = offset &+ UInt64(count)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        lock.withLock {
            guard var node = nodes[nodeID] else { return }
            node.attributes.size = max(node.attributes.size, endOffset)
            node.attributes.mtimeSeconds = Int64(ts.tv_sec)
            node.attributes.ctimeSeconds = Int64(ts.tv_sec)
            node.attributes.mtimeNsec = UInt32(truncatingIfNeeded: ts.tv_nsec)
            node.attributes.ctimeNsec = UInt32(truncatingIfNeeded: ts.tv_nsec)
            nodes[nodeID] = node
        }
    }

    public func lookup(parent: UInt64, name: String) throws -> HostFSEntry {
        guard let entry = try lookupIfExists(parent: parent, name: name) else {
            throw HostFSError.notFound(name)
        }
        return entry
    }

    public func lookupIfExists(parent: UInt64, name: String) throws -> HostFSEntry? {
        try validateComponent(name)
        try requireVisible(name)
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else {
            throw HostFSError.notDirectory(parent)
        }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        var st = stat()
        let result = name.withCString { pointer in
            fstatat(parentFD, pointer, &st, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            throw HostFSError.io("lookup \(relative): errno \(errno)")
        }

        return register(name: name, relativePath: relative, stat: st)
    }

    public func openRead(nodeID: UInt64) throws -> Int32 {
        try openFile(nodeID: nodeID, flags: O_RDONLY)
    }

    public func openReadWrite(nodeID: UInt64) throws -> Int32 {
        guard !readOnly else { throw HostFSError.readOnly }
        return try openFile(nodeID: nodeID, flags: O_RDWR)
    }

    private func openFile(nodeID: UInt64, flags: Int32) throws -> Int32 {
        let node = try node(for: nodeID)
        guard node.attributes.isRegularFile else {
            throw HostFSError.notRegularFile(nodeID)
        }
        let fd = openat(rootFD, cPath(node.relativePath), flags | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw HostFSError.permissionDenied(node.relativePath) }
            throw HostFSError.io("openat \(node.relativePath): errno \(errno)")
        }
        return fd
    }

    public func readlink(nodeID: UInt64) throws -> String {
        let node = try node(for: nodeID)
        guard node.attributes.isSymlink else {
            throw HostFSError.notRegularFile(nodeID)
        }
        var capacity = Int(PATH_MAX)
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count = readlinkat(rootFD, cPath(node.relativePath), &buffer, capacity)
            guard count >= 0 else {
                throw HostFSError.io("readlink \(node.relativePath): errno \(errno)")
            }
            if count < capacity {
                return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity *= 2
        }
    }

    public func read(handle fd: Int32, offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw HostFSError.invalidName("read count") }
        guard let signedOffset = off_t(exactly: offset) else {
            throw HostFSError.invalidName("read offset")
        }
        let clampedCount = min(count, Self.maxReadCount)
        var buffer = [UInt8](repeating: 0, count: clampedCount)
        let readCount = pread(fd, &buffer, clampedCount, signedOffset)
        guard readCount >= 0 else {
            throw HostFSError.io("pread: errno \(errno)")
        }
        if readCount < clampedCount {
            buffer.removeSubrange(readCount..<buffer.count)
        }
        return buffer
    }

    @discardableResult
    public func write(handle fd: Int32, offset: UInt64, data: [UInt8]) throws -> Int {
        try data.withUnsafeBytes { raw in
            try write(handle: fd, offset: offset, bytes: raw)
        }
    }

    @discardableResult
    public func write(handle fd: Int32, offset: UInt64, bytes: UnsafeRawBufferPointer) throws -> Int {
        guard !readOnly else { throw HostFSError.readOnly }
        guard let signedOffset = off_t(exactly: offset) else {
            throw HostFSError.invalidName("write offset")
        }
        let written = pwrite(fd, bytes.baseAddress, bytes.count, signedOffset)
        guard written >= 0 else {
            throw HostFSError.io("pwrite: errno \(errno)")
        }
        return written
    }

    public func fsync(handle fd: Int32) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        guard Darwin.fsync(fd) == 0 else {
            throw HostFSError.io("fsync: errno \(errno)")
        }
    }

    public func truncate(handle fd: Int32, size: UInt64) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        guard let signedSize = off_t(exactly: size) else {
            throw HostFSError.invalidName("truncate size")
        }
        guard ftruncate(fd, signedSize) == 0 else {
            throw HostFSError.io("ftruncate: errno \(errno)")
        }
    }

    public func truncate(nodeID: UInt64, size: UInt64) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        let node = try node(for: nodeID)
        guard node.attributes.isRegularFile else {
            throw HostFSError.notRegularFile(nodeID)
        }
        guard let signedSize = off_t(exactly: size) else {
            throw HostFSError.invalidName("truncate size")
        }
        let fd = openat(rootFD, cPath(node.relativePath), O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw HostFSError.permissionDenied(node.relativePath) }
            throw HostFSError.io("openat truncate \(node.relativePath): errno \(errno)")
        }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, signedSize) == 0 else {
            throw HostFSError.io("ftruncate: errno \(errno)")
        }
    }

    public func close(handle fd: Int32) {
        Darwin.close(fd)
    }

    public func createFile(parent: UInt64, name: String, mode: UInt16 = 0o644) throws -> HostFSEntry {
        let created = try createFileAndOpen(parent: parent, name: name, mode: mode)
        Darwin.close(created.fd)
        return created.entry
    }

    public func createFileAndOpen(
        parent: UInt64,
        name: String,
        mode: UInt16 = 0o644,
        flags: Int32 = O_RDWR,
        syntheticAttributes: Bool = false
    ) throws -> (entry: HostFSEntry, fd: Int32) {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name)
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let accessMode = flags & O_ACCMODE
        let writeAccess = accessMode == O_RDWR ? O_RDWR : O_WRONLY
        let createOptions = flags & (O_EXCL | O_TRUNC | O_APPEND)
        let fd = name.withCString { pointer in
            openat(parentFD, pointer, O_CREAT | createOptions | writeAccess | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        }
        guard fd >= 0 else {
            throw HostFSError.io("create \(relative): errno \(errno)")
        }
        do {
            if syntheticAttributes {
                return (registerCreatedFile(name: name, relativePath: relative, mode: mode), fd)
            }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                throw HostFSError.io("fstat \(relative): errno \(errno)")
            }
            return (register(name: name, relativePath: relative, stat: st), fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func mkdir(parent: UInt64, name: String, mode: UInt16 = 0o755) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name)
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let result = name.withCString { pointer in
            mkdirat(parentFD, pointer, mode_t(mode))
        }
        guard result == 0 else {
            throw HostFSError.io("mkdir \(relative): errno \(errno)")
        }
        return try lookup(parent: parent, name: name)
    }

    public func symlink(parent: UInt64, name: String, target: String) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name)
        guard !target.isEmpty, !target.utf8.contains(0) else {
            throw HostFSError.invalidName(target)
        }
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let result = target.withCString { targetPointer in
            name.withCString { namePointer in
                symlinkat(targetPointer, parentFD, namePointer)
            }
        }
        guard result == 0 else {
            throw HostFSError.io("symlink \(relative): errno \(errno)")
        }
        return try lookup(parent: parent, name: name)
    }

    public func unlink(parent: UInt64, name: String) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name)
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let result = name.withCString { pointer in
            unlinkat(parentFD, pointer, 0)
        }
        guard result == 0 else {
            throw HostFSError.io("unlink \(relative): errno \(errno)")
        }
        forgetExact(relativePath: relative)
    }

    public func rmdir(parent: UInt64, name: String) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name)
        let parentNode = try node(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let result = name.withCString { pointer in
            unlinkat(parentFD, pointer, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw HostFSError.io("rmdir \(relative): errno \(errno)")
        }
        forget(relativePath: relative)
    }

    public func rename(parent: UInt64, name: String, newParent: UInt64, newName: String) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try validateComponent(newName)
        try requireVisible(name)
        try requireVisible(newName)
        let parentNode = try node(for: parent)
        let newParentNode = try node(for: newParent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        guard newParentNode.attributes.isDirectory else { throw HostFSError.notDirectory(newParent) }
        let oldRelative = join(parentNode.relativePath, name)
        let parentFD = try directoryFD(for: parentNode)
        let newParentFD = try directoryFD(for: newParentNode)
        let result = name.withCString { oldPointer in
            newName.withCString { newPointer in
                renameat(parentFD, oldPointer, newParentFD, newPointer)
            }
        }
        guard result == 0 else {
            throw HostFSError.io("rename \(oldRelative): errno \(errno)")
        }
        forget(relativePath: oldRelative)
        return try lookup(parent: newParent, name: newName)
    }

    public func readdirplus(nodeID: UInt64) throws -> [HostFSEntry] {
        let node = try node(for: nodeID)
        guard node.attributes.isDirectory else {
            throw HostFSError.notDirectory(nodeID)
        }
        let absolute = node.relativePath.isEmpty ? rootPath : rootPath + "/" + node.relativePath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: absolute) else {
            throw HostFSError.notFound(node.relativePath)
        }
        return try names.sorted()
            .filter { !hiddenNames.contains($0) }
            .map { try lookup(parent: nodeID, name: $0) }
    }

    public func statfs() throws -> HostFSStat {
        var st = Darwin.statfs()
        guard Darwin.fstatfs(rootFD, &st) == 0 else {
            throw HostFSError.io("fstatfs: errno \(errno)")
        }
        let blockSize = UInt64(st.f_bsize)
        let blocks = UInt64(st.f_blocks)
        let blocksFree = UInt64(st.f_bfree)
        let blocksAvailable = UInt64(st.f_bavail)
        let files = UInt64(st.f_files)
        let filesFree = UInt64(st.f_ffree)
        let nameMax = UInt32(NAME_MAX)
        return HostFSStat(
            blockSize: blockSize,
            blocks: blocks,
            blocksFree: blocksFree,
            blocksAvailable: blocksAvailable,
            files: files,
            filesFree: filesFree,
            nameMax: nameMax
        )
    }

    public func setXattr(handle fd: Int32, name: String, value: [UInt8]) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        let result = value.withUnsafeBytes { raw in
            fsetxattr(fd, name, raw.baseAddress, value.count, 0, 0)
        }
        guard result == 0 else {
            throw HostFSError.io("fsetxattr \(name): errno \(errno)")
        }
    }

    public func getXattr(handle fd: Int32, name: String) throws -> [UInt8] {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size >= 0 else {
            throw HostFSError.io("fgetxattr \(name): errno \(errno)")
        }
        var data = [UInt8](repeating: 0, count: size)
        let read = data.withUnsafeMutableBytes { raw in
            fgetxattr(fd, name, raw.baseAddress, size, 0, 0)
        }
        guard read >= 0 else {
            throw HostFSError.io("fgetxattr \(name): errno \(errno)")
        }
        return data
    }

    public func listXattrs(handle fd: Int32) throws -> [String] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else {
            throw HostFSError.io("flistxattr: errno \(errno)")
        }
        guard size > 0 else { return [] }
        var data = [CChar](repeating: 0, count: size)
        let read = flistxattr(fd, &data, size, 0)
        guard read >= 0 else {
            throw HostFSError.io("flistxattr: errno \(errno)")
        }
        return data.split(separator: 0).map { String(cString: Array($0) + [0]) }.sorted()
    }

    private func node(for id: UInt64) throws -> Node {
        guard let node = lock.withLock({ nodes[id] }) else {
            throw HostFSError.notFound("node \(id)")
        }
        return node
    }

    private func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw HostFSError.invalidName(name)
        }
    }

    private func requireVisible(_ name: String) throws {
        guard !hiddenNames.contains(name) else {
            throw HostFSError.notFound(name)
        }
    }

    private func forgetExact(relativePath: String) {
        forget(relativePath: relativePath, recursive: false)
    }

    private func forget(relativePath: String, recursive: Bool = true) {
        lock.withLock {
            var affectedPaths = [relativePath]
            if recursive {
                let prefix = relativePath + "/"
                for path in idsByRelativePath.keys where path.hasPrefix(prefix) {
                    affectedPaths.append(path)
                }
            }
            for path in affectedPaths {
                guard let ids = idsByRelativePath.removeValue(forKey: path) else { continue }
                for id in ids {
                    guard let node = nodes.removeValue(forKey: id) else { continue }
                    if let fd = node.directoryFD {
                        Darwin.close(fd)
                    }
                    idsByFileKey.removeValue(forKey: node.fileKey)
                }
            }
        }
    }

    private func register(name: String, relativePath: String, stat st: stat) -> HostFSEntry {
        let key = FileKey(st)
        return lock.withLock {
            let id: UInt64
            if let existing = idsByFileKey[key] {
                id = existing
            } else if let existing = idsByRelativePath[relativePath]?.first {
                id = existing
                if let previousKey = nodes[existing]?.fileKey {
                    idsByFileKey.removeValue(forKey: previousKey)
                }
                idsByFileKey[key] = id
            } else {
                id = nextNodeID
                nextNodeID += 1
                idsByFileKey[key] = id
            }

            let attrs = Self.attributes(from: st, nodeID: id, uid: guestUID, gid: guestGID)
            if let previous = nodes[id], previous.relativePath != relativePath {
                idsByRelativePath[previous.relativePath]?.removeAll { $0 == id }
                if idsByRelativePath[previous.relativePath]?.isEmpty == true {
                    idsByRelativePath.removeValue(forKey: previous.relativePath)
                }
            }
            let directoryFD = nodes[id]?.directoryFD
            nodes[id] = Node(id: id, relativePath: relativePath, attributes: attrs, fileKey: key, directoryFD: directoryFD)
            if idsByRelativePath[relativePath]?.contains(id) != true {
                idsByRelativePath[relativePath, default: []].append(id)
            }
            return HostFSEntry(name: name, nodeID: id, attributes: attrs)
        }
    }

    private func registerCreatedFile(name: String, relativePath: String, mode: UInt16) -> HostFSEntry {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return lock.withLock {
            let id = nextNodeID
            nextNodeID += 1
            let key = FileKey(syntheticNodeID: id)
            let attrs = HostFSAttributes(
                nodeID: id,
                mode: UInt32(S_IFREG) | UInt32(mode),
                size: 0,
                uid: guestUID,
                gid: guestGID,
                atimeSeconds: Int64(ts.tv_sec),
                mtimeSeconds: Int64(ts.tv_sec),
                ctimeSeconds: Int64(ts.tv_sec),
                atimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec),
                mtimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec),
                ctimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec)
            )
            nodes[id] = Node(id: id, relativePath: relativePath, attributes: attrs, fileKey: key)
            idsByFileKey[key] = id
            idsByRelativePath[relativePath, default: []].append(id)
            return HostFSEntry(name: name, nodeID: id, attributes: attrs)
        }
    }

    private func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private func directoryFD(for node: Node) throws -> Int32 {
        guard node.attributes.isDirectory else { throw HostFSError.notDirectory(node.id) }
        if node.relativePath.isEmpty { return rootFD }
        if let fd = node.directoryFD { return fd }
        let fd = openat(rootFD, cPath(node.relativePath), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw HostFSError.permissionDenied(node.relativePath) }
            throw HostFSError.io("openat directory \(node.relativePath): errno \(errno)")
        }
        return try lock.withLock {
            guard var current = nodes[node.id] else {
                Darwin.close(fd)
                throw HostFSError.notFound(node.relativePath)
            }
            if let existing = current.directoryFD {
                Darwin.close(fd)
                return existing
            }
            current.directoryFD = fd
            nodes[node.id] = current
            return fd
        }
    }

    private func cPath(_ relative: String) -> [CChar] {
        relative.isEmpty ? [0] : Array(relative.utf8CString)
    }

    private static func attributes(from st: stat, nodeID: UInt64, uid: UInt32, gid: UInt32) -> HostFSAttributes {
        HostFSAttributes(
            nodeID: nodeID,
            mode: UInt32(st.st_mode),
            size: UInt64(max(0, st.st_size)),
            uid: uid,
            gid: gid,
            atimeSeconds: Int64(st.st_atimespec.tv_sec),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            ctimeSeconds: Int64(st.st_ctimespec.tv_sec),
            atimeNsec: UInt32(truncatingIfNeeded: st.st_atimespec.tv_nsec),
            mtimeNsec: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_nsec),
            ctimeNsec: UInt32(truncatingIfNeeded: st.st_ctimespec.tv_nsec)
        )
    }
}

private struct FileKey: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
    var isSynthetic: Bool { device == UInt64.max }

    init(_ st: stat) {
        self.device = UInt64(st.st_dev)
        self.inode = UInt64(st.st_ino)
    }

    init(syntheticNodeID: UInt64) {
        self.device = UInt64.max
        self.inode = syntheticNodeID
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
