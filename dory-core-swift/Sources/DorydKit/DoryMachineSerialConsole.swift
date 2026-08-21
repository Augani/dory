import CryptoKit
import Darwin
import Foundation

public struct DoryMachineSerialConsoleCursor: Codable, Sendable, Equatable, Hashable {
    public var generation: String?
    public var offset: UInt64

    public init(generation: String? = nil, offset: UInt64 = 0) {
        self.generation = generation
        self.offset = offset
    }

    public var isValid: Bool {
        generation.map(Self.isSHA256) ?? (offset == 0)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// One bounded serial-console read. Console bytes are explicit user-requested guest output and
/// are never copied into status, diagnostics, incidents, flight-recorder events, or support
/// bundles. `generation` changes when the underlying log is replaced; clients must discard their
/// prior cursor when `snapshotRequired` is true.
public struct DoryMachineSerialConsoleBatch: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var generation: String?
    public var startOffset: UInt64
    public var nextOffset: UInt64
    public var totalBytes: UInt64
    public var snapshotRequired: Bool
    public var inputAvailable: Bool
    public var bytes: Data

    public init(
        machineID: String,
        generation: String?,
        startOffset: UInt64,
        nextOffset: UInt64,
        totalBytes: UInt64,
        snapshotRequired: Bool,
        inputAvailable: Bool,
        bytes: Data
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.machineID = machineID
        self.generation = generation
        self.startOffset = startOffset
        self.nextOffset = nextOffset
        self.totalBytes = totalBytes
        self.snapshotRequired = snapshotRequired
        self.inputAvailable = inputAvailable
        self.bytes = bytes
    }

    public var cursor: DoryMachineSerialConsoleCursor {
        DoryMachineSerialConsoleCursor(generation: generation, offset: nextOffset)
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !machineID.hasPrefix("."),
              generation.map(Self.isSHA256) ?? true,
              bytes.count <= DoryMachineSerialConsoleAuthority.maximumReadBytes,
              startOffset <= nextOffset,
              nextOffset <= totalBytes,
              nextOffset - startOffset == UInt64(bytes.count) else {
            return false
        }
        if generation == nil {
            return startOffset == 0 && nextOffset == 0 && totalBytes == 0 && bytes.isEmpty
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum DoryMachineSerialConsoleError: Error, Equatable {
    case invalidMachineID
    case invalidCursor
    case invalidLimit
    case invalidLogAuthority
    case logChangedDuringRead
    case inputUnavailable
    case invalidInput
    case filesystem(String)
}

/// Secure access to the helper-owned serial log and optional private interactive socket.
///
/// Reads use `pread` on an owner-only, regular, non-linked file and return at most 64 KiB. A
/// replacement/truncation changes the generation or forces a fresh snapshot. Writes are capped at
/// 4 KiB, connect only to the manager-derived owner-only Unix socket, and have a bounded deadline.
enum DoryMachineSerialConsoleAuthority {
    static let logFileName = "serial.log"
    static let socketFileName = "console.sock"
    static let maximumReadBytes = 64 * 1_024
    static let maximumWriteBytes = 4 * 1_024
    private static let socketTimeoutMilliseconds: Int32 = 1_000

    static func read(
        machineID: String,
        machineDirectory: String,
        consoleSocketPath: String,
        cursor: DoryMachineSerialConsoleCursor,
        limit: Int
    ) throws -> DoryMachineSerialConsoleBatch {
        guard isMachineID(machineID) else {
            throw DoryMachineSerialConsoleError.invalidMachineID
        }
        guard cursor.isValid else { throw DoryMachineSerialConsoleError.invalidCursor }
        guard (1...maximumReadBytes).contains(limit) else {
            throw DoryMachineSerialConsoleError.invalidLimit
        }
        guard isPrivateDirectory(machineDirectory) else {
            throw DoryMachineSerialConsoleError.invalidLogAuthority
        }

        let inputAvailable = isPrivateConsoleSocket(consoleSocketPath)
        let path = machineDirectory + "/" + logFileName
        var pathInfo = stat()
        if lstat(path, &pathInfo) != 0 {
            guard errno == ENOENT else { throw filesystem("inspect serial console") }
            return DoryMachineSerialConsoleBatch(
                machineID: machineID,
                generation: nil,
                startOffset: 0,
                nextOffset: 0,
                totalBytes: 0,
                snapshotRequired: cursor.generation != nil || cursor.offset != 0,
                inputAvailable: inputAvailable,
                bytes: Data()
            )
        }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw filesystem("open serial console") }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              isPrivateRegularFile(before),
              before.st_size >= 0 else {
            throw DoryMachineSerialConsoleError.invalidLogAuthority
        }
        let identity = FileIdentity(before)
        let generation = identity.generation(machineID: machineID)
        let sizeBefore = UInt64(before.st_size)
        let snapshotRequired = cursor.generation != generation || cursor.offset > sizeBefore
        let startOffset = snapshotRequired
            ? sizeBefore - min(sizeBefore, UInt64(limit))
            : cursor.offset
        let requested = Int(min(UInt64(limit), sizeBefore - startOffset))
        var bytes = [UInt8](repeating: 0, count: requested)
        var received = 0
        while received < requested {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return pread(
                    descriptor,
                    base.advanced(by: received),
                    requested - received,
                    off_t(startOffset + UInt64(received))
                )
            }
            if count > 0 {
                received += count
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw filesystem("read serial console")
            }
        }
        if received < bytes.count { bytes.removeLast(bytes.count - received) }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              isPrivateRegularFile(after),
              FileIdentity(after) == identity,
              after.st_size >= 0,
              UInt64(after.st_size) >= startOffset + UInt64(received) else {
            throw DoryMachineSerialConsoleError.logChangedDuringRead
        }
        let batch = DoryMachineSerialConsoleBatch(
            machineID: machineID,
            generation: generation,
            startOffset: startOffset,
            nextOffset: startOffset + UInt64(received),
            totalBytes: UInt64(after.st_size),
            snapshotRequired: snapshotRequired,
            inputAvailable: inputAvailable,
            bytes: Data(bytes)
        )
        guard batch.isValid else { throw DoryMachineSerialConsoleError.invalidLogAuthority }
        return batch
    }

    static func write(_ data: Data, consoleSocketPath: String) throws {
        guard !data.isEmpty, data.count <= maximumWriteBytes else {
            throw DoryMachineSerialConsoleError.invalidInput
        }
        guard isPrivateConsoleSocket(consoleSocketPath) else {
            throw DoryMachineSerialConsoleError.inputUnavailable
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw filesystem("create serial console client") }
        defer { _ = close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw filesystem("configure serial console client")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw filesystem("configure serial console client")
        }

        var address = try socketAddress(path: consoleSocketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw filesystem("connect serial console") }
            try wait(descriptor: descriptor, events: Int16(POLLOUT))
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &length
            ) == 0, socketError == 0 else {
                if socketError != 0 { errno = socketError }
                throw filesystem("connect serial console")
            }
        }

        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset,
                    MSG_NOSIGNAL
                )
            }
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR {
                continue
            } else if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(descriptor: descriptor, events: Int16(POLLOUT))
            } else {
                throw filesystem("write serial console")
            }
        }
        _ = shutdown(descriptor, SHUT_WR)
    }

    static func isPrivateConsoleSocket(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        guard isPrivateDirectory(directory) else { return false }
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFSOCK
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0
    }

    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var birthSeconds: Int64
        var birthNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }

        func generation(machineID: String) -> String {
            let material = Data(
                "serial-console-v1\0\(machineID)\0\(device)\0\(inode)\0\(birthSeconds)\0\(birthNanoseconds)"
                    .utf8
            )
            return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func isMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func isPrivateRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw DoryMachineSerialConsoleError.inputUnavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        return address
    }

    private static func wait(descriptor: Int32, events: Int16) throws {
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let result = poll(&item, 1, socketTimeoutMilliseconds)
            if result > 0 {
                guard item.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0 else {
                    throw DoryMachineSerialConsoleError.inputUnavailable
                }
                return
            }
            if result == 0 { throw DoryMachineSerialConsoleError.inputUnavailable }
            if errno == EINTR { continue }
            throw filesystem("wait for serial console")
        }
    }

    private static func filesystem(_ operation: String) -> DoryMachineSerialConsoleError {
        .filesystem("\(operation): \(String(cString: strerror(errno)))")
    }
}
