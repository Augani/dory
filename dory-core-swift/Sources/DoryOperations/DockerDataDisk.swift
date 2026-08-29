import Darwin
import Foundation

public enum DockerDataDiskPreparation: Sendable, Equatable {
    case alreadyPresent
    case createdBlank
}

public enum DockerDataDiskError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidExistingDisk(String)
    case unsafeExistingDisk(String)
    case truncatedDisk(path: String, actualBytes: Int64, expectedBytes: Int64)
    case invalidCapacityGiB(requested: Int, minimum: Int, maximum: Int)
    case shrinkUnsupported(path: String, currentBytes: Int64, requestedBytes: Int64)
    case syscall(String, Int32)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidExistingDisk(path):
            "existing Docker data disk is neither ext4 nor an unallocated sparse blank: \(path); refusing to format possible user data"
        case let .unsafeExistingDisk(path):
            "Docker data disk must be a private, owner-controlled regular file with one link: \(path)"
        case let .truncatedDisk(path, actualBytes, expectedBytes):
            "Docker data disk appears truncated: \(path) is \(actualBytes) bytes, but its ext4 superblock requires at least \(expectedBytes) bytes; restore or repair the sparse image before retrying"
        case let .invalidCapacityGiB(requested, minimum, maximum):
            "Docker disk capacity must be between \(minimum) and \(maximum) GiB (requested \(requested) GiB)"
        case let .shrinkUnsupported(path, currentBytes, requestedBytes):
            "Docker disk shrinking is not supported: \(path) is \(currentBytes) bytes and cannot be reduced to \(requestedBytes) bytes; back up and restore into a new drive instead"
        case let .syscall(operation, code):
            "\(operation): \(String(cString: strerror(code)))"
        case let .filesystem(message):
            message
        }
    }
}

public struct DockerDataDiskUsage: Codable, Sendable, Equatable {
    public let initialized: Bool
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let capacityGiB: Int
    public let minimumCapacityGiB: Int
    public let maximumCapacityGiB: Int
}

public enum DockerDataDiskAdmittedState: Sendable, Equatable {
    case sparseBlank
    case ext4
}

/// One cross-backend wire contract for the daemon-admitted Docker disk. RawHV, VZ, and doryd all
/// consume these values so a spelling or descriptor-slot change cannot silently drift between
/// independently built components.
public enum DockerDataDiskLaunchContract {
    public static let authorityName = "docker-data-disk"
    public static let childFileDescriptor: Int32 = 19
    public static let fileDescriptorArgument = "--docker-data-disk-fd"
    public static let filesystemUUIDArgument = "--docker-data-disk-uuid"

    /// Reads one filesystem UUID using only the default `blkid` output contract shared by
    /// BusyBox and util-linux. Dory's Alpine engine image exposes BusyBox `blkid`, which rejects
    /// util-linux-only `-s UUID -o value` arguments. Keep this exact function shared by both VM
    /// backends and the post-boot resource probe so admission and reconciliation cannot drift.
    public static let guestFilesystemUUIDShellFunction = #"""
        dory_docker_data_uuid() {
          [ "$#" -eq 1 ] || return 64
          DORY_BLKID_RECORD=$(blkid "$1" 2>/dev/null) || return 1
          printf '%s\n' "$DORY_BLKID_RECORD" | awk '
            BEGIN {
              matches=0
              invalid=0
            }
            {
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^UUID=/) {
                  if ($i !~ /^UUID="[^"]*"$/) {
                    invalid=1
                    continue
                  }
                  value=$i
                  sub(/^UUID="/, "", value)
                  sub(/"$/, "", value)
                  matches++
                }
              }
            }
            END {
              if (invalid || matches != 1) exit 1
              component_count=split(value, components, "-")
              if (component_count != 5 ||
                  length(components[1]) != 8 ||
                  length(components[2]) != 4 ||
                  length(components[3]) != 4 ||
                  length(components[4]) != 4 ||
                  length(components[5]) != 12) exit 1
              compact=components[1] components[2] components[3] components[4] components[5]
              if (compact ~ /[^0-9A-Fa-f]/) exit 1
              print tolower(value)
            }
          '
        }
        """#

    public static let guestFilesystemUUIDShellCommand = "dory_docker_data_uuid /dev/vdb"
}

/// Owns the exact private Docker disk file admitted through a trusted directory descriptor. The
/// pathname is deliberately absent: launchers may borrow or duplicate this descriptor, but cannot
/// silently reopen a replaceable path after admission.
public final class DockerDataDiskFileAuthority: @unchecked Sendable {
    public let state: DockerDataDiskAdmittedState

    private let descriptor: Int32

    fileprivate init(descriptor: Int32, state: DockerDataDiskAdmittedState) {
        self.descriptor = descriptor
        self.state = state
    }

    public func withBorrowedDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) rethrows -> Result {
        try body(descriptor)
    }

    /// Returns a close-on-exec duplicate whose ownership transfers to the caller.
    public func duplicate() throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw DockerDataDiskError.syscall("duplicate admitted Docker data disk", errno)
        }
        return duplicate
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// Creates and validates Dory's public-v1 Docker data disk. Existing bytes are never formatted or
/// replaced unless the file is a host-proven, entirely unallocated sparse blank from an interrupted
/// first launch.
public enum DockerDataDisk {
    public static let bytesPerGiB: Int64 = 1024 * 1024 * 1024
    public static let minimumCapacityGiB = 128
    public static let maximumCapacityGiB = 2_048

    /// Logical capacity only: APFS keeps the backing file sparse and allocates physical blocks as
    /// Docker writes them. 128 GiB avoids a hidden 16 GiB ceiling during competitor import without
    /// reserving 128 GiB on the Mac.
    public static let blankDiskBytes: Int64 = 128 * 1024 * 1024 * 1024

    /// Creates or opens the fixed disk filename relative to a pinned private directory. Every
    /// mutation and publication is descriptor-relative, so an intermediate symlink or pathname
    /// replacement cannot redirect first-launch formatting to another file.
    public static func prepareAdmittedFile(
        in directory: DoryTrustedDirectoryHandle,
        fileName: String = "docker-data.ext4",
        blankSize: Int64 = blankDiskBytes
    ) throws -> DockerDataDiskFileAuthority {
        _ = try DoryTrustedPathComponent(validating: fileName)
        guard blankSize > 0,
              blankSize <= Int64(maximumCapacityGiB) * bytesPerGiB,
              blankSize % 512 == 0 else {
            throw DockerDataDiskError.filesystem(
                "Docker data disk size must be a positive sector-aligned value within the supported capacity"
            )
        }
        return try directory.withBorrowedDescriptor { directoryDescriptor in
            for _ in 0..<3 {
                if let existing = try openAdmittedFileIfPresent(
                    in: directoryDescriptor,
                    fileName: fileName,
                    blankSize: blankSize
                ) {
                    return existing
                }

                let partialName = ".\(fileName).\(UUID().uuidString.lowercased()).partial"
                let descriptor = openat(
                    directoryDescriptor,
                    partialName,
                    O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
                guard descriptor >= 0 else {
                    throw DockerDataDiskError.syscall(
                        "create admitted Docker data disk",
                        errno
                    )
                }
                var published = false
                defer {
                    if !published {
                        Darwin.close(descriptor)
                        _ = unlinkat(directoryDescriptor, partialName, 0)
                    }
                }
                guard ftruncate(descriptor, off_t(blankSize)) == 0 else {
                    throw DockerDataDiskError.syscall("size admitted Docker data disk", errno)
                }
                guard fsync(descriptor) == 0 else {
                    throw DockerDataDiskError.syscall("sync admitted Docker data disk", errno)
                }
                let renameResult = renameatx_np(
                    directoryDescriptor,
                    partialName,
                    directoryDescriptor,
                    fileName,
                    UInt32(RENAME_EXCL)
                )
                if renameResult != 0, errno == EEXIST {
                    continue
                }
                guard renameResult == 0 else {
                    throw DockerDataDiskError.syscall("publish admitted Docker data disk", errno)
                }
                guard fsync(directoryDescriptor) == 0 else {
                    throw DockerDataDiskError.syscall(
                        "sync admitted Docker data disk directory",
                        errno
                    )
                }
                var descriptorStatus = stat()
                var pathnameStatus = stat()
                guard fstat(descriptor, &descriptorStatus) == 0,
                      fstatat(
                          directoryDescriptor,
                          fileName,
                          &pathnameStatus,
                          AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      descriptorStatus.st_dev == pathnameStatus.st_dev,
                      descriptorStatus.st_ino == pathnameStatus.st_ino else {
                    throw DockerDataDiskError.filesystem(
                        "published Docker data disk does not match its admitted descriptor"
                    )
                }
                published = true
                return DockerDataDiskFileAuthority(
                    descriptor: descriptor,
                    state: .sparseBlank
                )
            }
            throw DockerDataDiskError.filesystem(
                "Docker data disk publication did not stabilize after concurrent creation"
            )
        }
    }

    /// Opens an existing disk relative to a pinned private directory without changing its size or
    /// contents. Readiness attestation uses this to prove the selected pathname still names the
    /// exact descriptor passed to the helper.
    public static func openAdmittedFile(
        in directory: DoryTrustedDirectoryHandle,
        fileName: String = "docker-data.ext4",
        minimumBytes: Int64 = 1,
        maximumBytes: Int64 = Int64(maximumCapacityGiB) * bytesPerGiB
    ) throws -> DockerDataDiskFileAuthority {
        _ = try DoryTrustedPathComponent(validating: fileName)
        return try directory.withBorrowedDescriptor { directoryDescriptor in
            let descriptor = openat(
                directoryDescriptor,
                fileName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                if errno == ELOOP {
                    throw DockerDataDiskError.unsafeExistingDisk(fileName)
                }
                throw DockerDataDiskError.syscall("open admitted Docker data disk", errno)
            }
            var transferred = false
            defer {
                if !transferred { Darwin.close(descriptor) }
            }
            let state = try admittedState(
                ofFileDescriptor: descriptor,
                description: fileName,
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes
            )
            transferred = true
            return DockerDataDiskFileAuthority(descriptor: descriptor, state: state)
        }
    }

    /// Validates one already-open disk descriptor without resolving a pathname. Shipping helper
    /// processes use this before attaching an inherited descriptor to the guest.
    public static func admittedState(
        ofFileDescriptor descriptor: Int32,
        description: String = "inherited Docker data disk",
        minimumBytes: Int64 = 1,
        maximumBytes: Int64 = Int64(maximumCapacityGiB) * bytesPerGiB
    ) throws -> DockerDataDiskAdmittedState {
        guard minimumBytes >= 0,
              maximumBytes >= minimumBytes else {
            throw DockerDataDiskError.filesystem("Docker data disk admission bounds are invalid")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDWR else {
            throw DockerDataDiskError.unsafeExistingDisk(description)
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw DockerDataDiskError.syscall("inspect \(description)", errno)
        }
        let forbiddenFlags = UInt32(
            UF_IMMUTABLE | UF_APPEND | UF_COMPRESSED | SF_IMMUTABLE | SF_APPEND
        )
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_nlink == 1,
              before.st_flags & forbiddenFlags == 0,
              before.st_size >= minimumBytes,
              before.st_size <= maximumBytes,
              before.st_size % 512 == 0 else {
            throw DockerDataDiskError.unsafeExistingDisk(description)
        }

        let expectedExt4Bytes = try expectedExt4ImageBytes(on: descriptor)
        let state: DockerDataDiskAdmittedState
        if let expectedExt4Bytes {
            guard before.st_size >= expectedExt4Bytes else {
                throw DockerDataDiskError.truncatedDisk(
                    path: description,
                    actualBytes: before.st_size,
                    expectedBytes: expectedExt4Bytes
                )
            }
            state = .ext4
        } else {
            guard before.st_blocks == 0,
                  hasNoDataExtents(descriptor) else {
                throw DockerDataDiskError.invalidExistingDisk(description)
            }
            state = .sparseBlank
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw DockerDataDiskError.syscall("reinspect \(description)", errno)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_uid == after.st_uid,
              before.st_nlink == after.st_nlink,
              before.st_size == after.st_size,
              before.st_blocks == after.st_blocks,
              before.st_flags == after.st_flags,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DockerDataDiskError.filesystem(
                "Docker data disk changed while \(description) was being admitted"
            )
        }
        switch state {
        case .sparseBlank:
            guard hasNoDataExtents(descriptor) else {
                throw DockerDataDiskError.invalidExistingDisk(description)
            }
        case .ext4:
            guard try expectedExt4ImageBytes(on: descriptor) == expectedExt4Bytes else {
                throw DockerDataDiskError.filesystem(
                    "Docker data disk filesystem geometry changed during admission"
                )
            }
        }
        return state
    }

    private static func hasNoDataExtents(_ descriptor: Int32) -> Bool {
        errno = 0
        let firstDataOffset = lseek(descriptor, 0, SEEK_DATA)
        return firstDataOffset == -1 && errno == ENXIO
    }

    private static func openAdmittedFileIfPresent(
        in directoryDescriptor: Int32,
        fileName: String,
        blankSize: Int64
    ) throws -> DockerDataDiskFileAuthority? {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw DockerDataDiskError.unsafeExistingDisk(fileName)
            }
            throw DockerDataDiskError.syscall("open admitted Docker data disk", errno)
        }
        var transferred = false
        defer {
            if !transferred { Darwin.close(descriptor) }
        }

        let maximumBytes = Int64(maximumCapacityGiB) * bytesPerGiB
        let initialState = try admittedState(
            ofFileDescriptor: descriptor,
            description: fileName,
            minimumBytes: 0,
            maximumBytes: maximumBytes
        )
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect admitted Docker data disk", errno)
        }
        if status.st_size < blankSize {
            guard ftruncate(descriptor, off_t(blankSize)) == 0 else {
                throw DockerDataDiskError.syscall("grow admitted Docker data disk", errno)
            }
            guard fsync(descriptor) == 0 else {
                throw DockerDataDiskError.syscall("sync grown admitted Docker data disk", errno)
            }
        }
        let finalState = try admittedState(
            ofFileDescriptor: descriptor,
            description: fileName,
            minimumBytes: blankSize,
            maximumBytes: maximumBytes
        )
        guard finalState == initialState else {
            throw DockerDataDiskError.filesystem(
                "Docker data disk format state changed during descriptor-relative preparation"
            )
        }
        transferred = true
        return DockerDataDiskFileAuthority(
            descriptor: descriptor,
            state: finalState
        )
    }

    @discardableResult
    public static func prepare(
        destination: String,
        blankSize: Int64 = blankDiskBytes,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskPreparation {
        guard blankSize > 0 else {
            throw DockerDataDiskError.filesystem("Docker data disk size must be positive")
        }
        if try pathEntryExists(destination) {
            let descriptor = try openValidated(destination, flags: O_RDWR)
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw DockerDataDiskError.syscall("inspect Docker data disk before growth", errno)
            }
            try validateContents(of: descriptor, at: destination, status: status)
            guard status.st_size < blankSize else { return .alreadyPresent }
            guard ftruncate(descriptor, off_t(blankSize)) == 0 else {
                throw DockerDataDiskError.syscall("grow Docker data disk", errno)
            }
            guard fsync(descriptor) == 0 else {
                throw DockerDataDiskError.syscall("sync grown Docker data disk", errno)
            }
            return .alreadyPresent
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        let partial = destination + ".partial"
        try? fileManager.removeItem(atPath: partial)

        let descriptor = open(
            partial,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
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
            try syncDirectory(parent)
            return .createdBlank
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw DockerDataDiskError.filesystem("publish Docker data disk: \(error)")
        }
    }

    /// Reports the logical ceiling separately from physical APFS allocation. An uninitialized
    /// selected drive reports the production default without creating its Docker disk.
    public static func usage(at destination: String) throws -> DockerDataDiskUsage {
        guard try pathEntryExists(destination) else {
            return DockerDataDiskUsage(
                initialized: false,
                logicalBytes: blankDiskBytes,
                allocatedBytes: 0,
                capacityGiB: minimumCapacityGiB,
                minimumCapacityGiB: minimumCapacityGiB,
                maximumCapacityGiB: maximumCapacityGiB
            )
        }
        let descriptor = try openValidated(destination, flags: O_RDONLY)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect Docker data disk usage", errno)
        }
        try validateContents(of: descriptor, at: destination, status: status)
        let logicalBytes = Int64(status.st_size)
        let wholeGiB = logicalBytes / bytesPerGiB
        let capacityGiB = Int(wholeGiB + (logicalBytes % bytesPerGiB == 0 ? 0 : 1))
        return DockerDataDiskUsage(
            initialized: true,
            logicalBytes: logicalBytes,
            allocatedBytes: Int64(status.st_blocks) * 512,
            capacityGiB: capacityGiB,
            minimumCapacityGiB: minimumCapacityGiB,
            maximumCapacityGiB: maximumCapacityGiB
        )
    }

    /// Grows the sparse host file. The guest performs the ext4 expansion on its next boot. Shrink
    /// requests fail before mutation because host truncation before an offline ext4 shrink would
    /// destroy data.
    public static func grow(
        destination: String,
        capacityGiB: Int,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskUsage {
        guard (minimumCapacityGiB...maximumCapacityGiB).contains(capacityGiB) else {
            throw DockerDataDiskError.invalidCapacityGiB(
                requested: capacityGiB,
                minimum: minimumCapacityGiB,
                maximum: maximumCapacityGiB
            )
        }
        let requestedBytes = Int64(capacityGiB) * bytesPerGiB
        let current = try usage(at: destination)
        if current.initialized, current.logicalBytes > requestedBytes {
            throw DockerDataDiskError.shrinkUnsupported(
                path: destination,
                currentBytes: current.logicalBytes,
                requestedBytes: requestedBytes
            )
        }
        _ = try prepare(
            destination: destination,
            blankSize: requestedBytes,
            fileManager: fileManager
        )
        return try usage(at: destination)
    }

    public static func isExt4Image(at path: String) throws -> Bool {
        let descriptor = try openValidated(path, flags: O_RDONLY)
        defer { close(descriptor) }
        return try expectedExt4ImageBytes(on: descriptor) != nil
    }

    /// Returns the byte length declared by an ext4 superblock. Sparse-file migration tools can
    /// preserve the leading metadata while dropping the logical tail, so checking the magic alone
    /// is insufficient before attaching a persistent Docker store to a VM.
    public static func expectedExt4ImageBytes(at path: String) throws -> Int64? {
        let descriptor = try openValidated(path, flags: O_RDONLY)
        defer { close(descriptor) }
        return try expectedExt4ImageBytes(on: descriptor)
    }

    private static func expectedExt4ImageBytes(on descriptor: Int32) throws -> Int64? {
        // EXT4_SUPER_MAGIC is the little-endian 16-bit value at offset 0x38 in the superblock,
        // whose base is byte 1024.
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

    private static func validateContents(
        of descriptor: Int32,
        at path: String,
        status: stat
    ) throws {
        if let expectedBytes = try expectedExt4ImageBytes(on: descriptor) {
            let actualBytes = Int64(status.st_size)
            guard actualBytes >= expectedBytes else {
                throw DockerDataDiskError.truncatedDisk(
                    path: path,
                    actualBytes: actualBytes,
                    expectedBytes: expectedBytes
                )
            }
            return
        }
        guard status.st_blocks == 0 else {
            throw DockerDataDiskError.invalidExistingDisk(path)
        }
    }

    private static func pathEntryExists(_ path: String) throws -> Bool {
        var status = stat()
        if path.withCString({ lstat($0, &status) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw DockerDataDiskError.syscall("inspect Docker data disk path", errno)
    }

    private static func openValidated(_ path: String, flags: Int32) throws -> Int32 {
        let descriptor = path.withCString { open($0, flags | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DockerDataDiskError.unsafeExistingDisk(path)
            }
            throw DockerDataDiskError.syscall("open Docker data disk", errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            close(descriptor)
            throw DockerDataDiskError.unsafeExistingDisk(path)
        }
        return descriptor
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DockerDataDiskError.syscall("open Docker data disk directory for sync", errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DockerDataDiskError.syscall("sync Docker data disk directory", errno)
        }
    }
}
