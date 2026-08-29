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

        return try read(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    static func read(
        in directoryDescriptor: Int32,
        fileName: String,
        maximumBytes: Int
    ) throws -> Data {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\0") else {
            throw PrivateRecordFileError.invalid
        }
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw PrivateRecordFileError.missing }
            throw PrivateRecordFileError.invalid
        }
        defer { Darwin.close(descriptor) }
        return try read(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    private static func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
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
            if count == 0 {
                var finalStatus = stat()
                guard Darwin.fstat(descriptor, &finalStatus) == 0,
                      status.st_dev == finalStatus.st_dev,
                      status.st_ino == finalStatus.st_ino,
                      status.st_mode == finalStatus.st_mode,
                      status.st_uid == finalStatus.st_uid,
                      status.st_nlink == finalStatus.st_nlink,
                      status.st_size == finalStatus.st_size else {
                    throw PrivateRecordFileError.invalid
                }
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
