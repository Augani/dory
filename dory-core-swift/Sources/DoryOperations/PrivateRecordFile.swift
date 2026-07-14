import Darwin
import Foundation

enum PrivateRecordFileError: Error {
    case missing
    case invalid
}

enum PrivateRecordFile {
    static func read(at path: String, maximumBytes: Int) throws -> Data {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw PrivateRecordFileError.missing }
            throw PrivateRecordFileError.invalid
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Int64(maximumBytes) else {
            throw PrivateRecordFileError.invalid
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximumBytes else {
                throw PrivateRecordFileError.invalid
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
