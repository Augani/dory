import CryptoKit
import Darwin
import Foundation

extension DoryOperationJournalStore {
    static func encoded<T: Encodable>(_ value: T, pretty: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func isTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func isPrivateText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumLength
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 95
        }
    }

    static func pathEntryExists(_ path: String) -> Bool {
        var status = stat()
        return path.withCString { lstat($0, &status) } == 0
    }

    static func createPrivateDirectory(_ path: String) throws {
        guard path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "create private Dory operation directory at \(path): errno \(errno)"
            )
        }
        try validatePrivateDirectory(path)
    }

    static func securePrivateDirectory(_ path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid() else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        guard Darwin.chmod(path, mode_t(0o700)) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "secure Dory operation directory at \(path): errno \(errno)"
            )
        }
        try validatePrivateDirectory(path)
    }

    static func validatePrivateDirectory(_ path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
    }

    static func secureRead(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw DoryOperationJournalError.invalidRecord(path)
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw DoryOperationJournalError.filesystem(
                    "read Dory operation file at \(path): errno \(errno)"
                )
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    static func publish(_ data: Data, to destination: String) throws {
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        try validatePrivateDirectory(parent)
        if pathEntryExists(destination) {
            _ = try secureRead(destination, maximumBytes: 64 * 1_024 * 1_024)
        }
        let temporary = parent + "/." + URL(fileURLWithPath: destination).lastPathComponent + "."
            + UUID().uuidString.lowercased() + ".partial"
        let descriptor = temporary.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw DoryOperationJournalError.filesystem(
                "create Dory operation file at \(temporary): errno \(errno)"
            )
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = Darwin.unlink(temporary) }
        }
        try writeAll(data, descriptor: descriptor, path: temporary)
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "sync Dory operation file at \(temporary): errno \(errno)"
            )
        }
        guard Darwin.rename(temporary, destination) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "publish Dory operation file at \(destination): errno \(errno)"
            )
        }
        published = true
        try syncDirectory(parent)
    }

    static func append(_ data: Data, to path: String) throws {
        let descriptor = path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        defer { Darwin.close(descriptor) }
        try validatePrivateFile(descriptor: descriptor, path: path)
        try writeAll(data, descriptor: descriptor, path: path)
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "sync Dory operation audit log at \(path): errno \(errno)"
            )
        }
    }

    static func truncate(_ path: String, to length: Int) throws {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        defer { Darwin.close(descriptor) }
        try validatePrivateFile(descriptor: descriptor, path: path)
        guard ftruncate(descriptor, off_t(length)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "repair Dory operation audit log at \(path): errno \(errno)"
            )
        }
    }

    private static func validatePrivateFile(descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw DoryOperationJournalError.filesystem(
                        "write Dory operation file at \(path): errno \(errno)"
                    )
                }
                offset += count
            }
        }
    }

    static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              Darwin.fsync(descriptor) == 0 else {
            throw DoryOperationJournalError.filesystem(
                "sync Dory operation directory at \(path): errno \(errno)"
            )
        }
    }
}
