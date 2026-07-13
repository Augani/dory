import Darwin
import Foundation

public enum DockerDataDiskPreparation: Sendable, Equatable {
    case alreadyPresent
    case createdBlank
}

public enum DockerDataDiskError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidExistingDisk(String)
    case truncatedDisk(path: String, actualBytes: Int64, expectedBytes: Int64)
    case syscall(String, Int32)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidExistingDisk(path):
            "existing Docker data disk is neither ext4 nor an unallocated sparse blank: \(path); refusing to format possible user data"
        case let .truncatedDisk(path, actualBytes, expectedBytes):
            "Docker data disk appears truncated: \(path) is \(actualBytes) bytes, but its ext4 superblock requires at least \(expectedBytes) bytes; restore or repair the sparse image before retrying"
        case let .syscall(operation, code):
            "\(operation): \(String(cString: strerror(code)))"
        case let .filesystem(message):
            message
        }
    }
}

/// Creates and validates the one public-v1 Docker data disk. Existing bytes are never formatted or
/// replaced unless the file is a host-proven, entirely unallocated sparse blank from an interrupted
/// first launch.
public enum DockerDataDisk {
    /// Logical capacity only: APFS keeps the backing file sparse and allocates physical blocks as
    /// Docker writes them. 128 GiB avoids a hidden 16 GiB ceiling during competitor import without
    /// reserving 128 GiB on the Mac.
    public static let blankDiskBytes: Int64 = 128 * 1024 * 1024 * 1024

    @discardableResult
    public static func prepare(
        destination: String,
        blankSize: Int64 = blankDiskBytes,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskPreparation {
        if fileManager.fileExists(atPath: destination) {
            if try isExt4Image(at: destination) {
                guard try expectedExt4ImageBytes(at: destination) != nil else {
                    throw DockerDataDiskError.invalidExistingDisk(destination)
                }
                try rejectTruncatedExt4Image(at: destination)
            } else if try !isUnallocatedSparseBlank(at: destination) {
                throw DockerDataDiskError.invalidExistingDisk(destination)
            }
            try growSparseFileIfNeeded(destination, minimumBytes: blankSize)
            return .alreadyPresent
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = destination + ".partial"
        try? fileManager.removeItem(atPath: partial)

        let descriptor = open(partial, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("create Docker data disk", errno) }
        var failure: DockerDataDiskError?
        if ftruncate(descriptor, blankSize) != 0 {
            failure = .syscall("size Docker data disk", errno)
        } else if fsync(descriptor) != 0 {
            failure = .syscall("sync Docker data disk", errno)
        }
        close(descriptor)
        if let failure {
            try? fileManager.removeItem(atPath: partial)
            throw failure
        }
        do {
            try fileManager.moveItem(atPath: partial, toPath: destination)
            return .createdBlank
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw DockerDataDiskError.filesystem("publish Docker data disk: \(error)")
        }
    }

    public static func isExt4Image(at path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open Docker data disk", errno) }
        defer { close(descriptor) }
        // EXT4_SUPER_MAGIC is the little-endian 16-bit value at offset 0x38 in the superblock,
        // whose base is byte 1024.
        var magic = [UInt8](repeating: 0, count: 2)
        let count = magic.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, off_t(1024 + 0x38))
        }
        guard count == magic.count else { return false }
        return magic[0] == 0x53 && magic[1] == 0xEF
    }

    /// Returns the byte length declared by an ext4 superblock. Sparse-file migration tools can
    /// preserve the leading metadata while dropping the logical tail, so checking the magic alone
    /// is insufficient before attaching a persistent Docker store to a VM.
    public static func expectedExt4ImageBytes(at path: String) throws -> Int64? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open Docker data disk", errno) }
        defer { close(descriptor) }

        var superblock = [UInt8](repeating: 0, count: 1024)
        let count = superblock.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, off_t(1024))
        }
        guard count == superblock.count,
              superblock[0x38] == 0x53,
              superblock[0x39] == 0xEF else { return nil }

        func littleEndianUInt32(at offset: Int) -> UInt32 {
            UInt32(superblock[offset])
                | (UInt32(superblock[offset + 1]) << 8)
                | (UInt32(superblock[offset + 2]) << 16)
                | (UInt32(superblock[offset + 3]) << 24)
        }

        let logBlockSize = littleEndianUInt32(at: 0x18)
        guard logBlockSize <= 6 else { return nil }
        let blockSize = UInt64(1024) << UInt64(logBlockSize)
        let featureIncompat = littleEndianUInt32(at: 0x60)
        let blocksLow = UInt64(littleEndianUInt32(at: 0x04))
        let blocksHigh = featureIncompat & 0x80 != 0
            ? UInt64(littleEndianUInt32(at: 0x150))
            : 0
        let blocks = blocksLow | (blocksHigh << 32)
        guard blocks > 0,
              blocks <= UInt64(Int64.max) / blockSize else { return nil }
        return Int64(blocks * blockSize)
    }

    private static func rejectTruncatedExt4Image(at path: String) throws {
        guard let expectedBytes = try expectedExt4ImageBytes(at: path) else { return }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw DockerDataDiskError.filesystem("inspect Docker data disk: \(error)")
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw DockerDataDiskError.filesystem("inspect Docker data disk size: \(path)")
        }
        let actualBytes = size.int64Value
        guard actualBytes >= expectedBytes else {
            throw DockerDataDiskError.truncatedDisk(
                path: path,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
        }
    }

    private static func isUnallocatedSparseBlank(at path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DockerDataDiskError.syscall("open existing Docker data disk", errno)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect existing Docker data disk allocation", errno)
        }
        // `ftruncate` creates a logical disk with no physical blocks. Once formatting or any other
        // writer allocates a block, a missing ext4 superblock is treated as corruption—not as
        // permission to wipe the file and start over.
        return status.st_blocks == 0
    }

    private static func growSparseFileIfNeeded(_ path: String, minimumBytes: Int64) throws {
        guard minimumBytes > 0 else {
            throw DockerDataDiskError.filesystem("Docker data disk size must be positive")
        }
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open Docker data disk for growth", errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect Docker data disk before growth", errno)
        }
        guard status.st_size < minimumBytes else { return }
        guard ftruncate(descriptor, off_t(minimumBytes)) == 0 else {
            throw DockerDataDiskError.syscall("grow Docker data disk", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw DockerDataDiskError.syscall("sync grown Docker data disk", errno)
        }
    }
}
