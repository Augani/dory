import CryptoKit
import Darwin
import Foundation

public struct DoryInstalledLinuxBootDescriptor: Sendable, Equatable {
    public let rootDevice: String
    public let kernelLength: UInt64
    public let initrdLength: UInt64
    public let kernelSHA256: String
    public let initrdSHA256: String

    public init(
        rootDevice: String,
        kernelLength: UInt64,
        initrdLength: UInt64,
        kernelSHA256: String,
        initrdSHA256: String
    ) {
        self.rootDevice = rootDevice
        self.kernelLength = kernelLength
        self.initrdLength = initrdLength
        self.kernelSHA256 = kernelSHA256
        self.initrdSHA256 = initrdSHA256
    }
}

/// A single portable artifact containing the direct-boot kernel, initrd, and root-device contract
/// for an EFI-installed Linux disk. EFI snapshots already preserve the machine's opaque `kernel`
/// artifact, so using one verified bundle also makes the accelerated runtime survive clone,
/// snapshot, export, import, and restore without inventing a parallel set of lifecycle rules.
public enum DoryInstalledLinuxBootBundle {
    private static let magic = Data("DORYLINUXBOOT1\n".utf8)
    private static let fixedHeaderBytes = 4 + 8 + 8 + 32 + 32
    private static let maximumRootDeviceBytes = 128
    public static let maximumKernelBytes: UInt64 = 256 * 1024 * 1024
    public static let maximumInitrdBytes: UInt64 = 512 * 1024 * 1024
    private static let copyChunkBytes = 4 * 1024 * 1024

    public static func isBundle(atPath path: String) -> Bool {
        guard let handle = try? openForReading(path),
              let prefix = try? handle.read(upToCount: magic.count) else {
            return false
        }
        try? handle.close()
        return prefix == magic
    }

    public static func write(
        assets: DoryLinuxInstallerBootAssets,
        rootDevice: String,
        toPath path: String
    ) throws {
        let rootBytes = Data(rootDevice.utf8)
        guard isValidRootDevice(rootDevice),
              !rootBytes.isEmpty,
              rootBytes.count <= maximumRootDeviceBytes else {
            throw DoryInstalledLinuxBootBundleError.invalidRootDevice(rootDevice)
        }
        guard !assets.kernel.isEmpty,
              UInt64(assets.kernel.count) <= maximumKernelBytes else {
            throw DoryInstalledLinuxBootBundleError.invalidKernelSize(UInt64(assets.kernel.count))
        }
        guard !assets.initrd.isEmpty,
              UInt64(assets.initrd.count) <= maximumInitrdBytes else {
            throw DoryInstalledLinuxBootBundleError.invalidInitrdSize(UInt64(assets.initrd.count))
        }

        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).boot-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DoryInstalledLinuxBootBundleError.write(path, errno)
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            try output.write(contentsOf: magic)
            try output.write(contentsOf: bigEndian(UInt32(rootBytes.count)))
            try output.write(contentsOf: bigEndian(UInt64(assets.kernel.count)))
            try output.write(contentsOf: bigEndian(UInt64(assets.initrd.count)))
            try output.write(contentsOf: Data(SHA256.hash(data: assets.kernel)))
            try output.write(contentsOf: Data(SHA256.hash(data: assets.initrd)))
            try output.write(contentsOf: rootBytes)
            try output.write(contentsOf: assets.kernel)
            try output.write(contentsOf: assets.initrd)
            try output.synchronize()
            try output.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw DoryInstalledLinuxBootBundleError.write(path, errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func descriptor(atPath path: String) throws -> DoryInstalledLinuxBootDescriptor {
        let input = try openForReading(path)
        defer { try? input.close() }
        return try readHeader(from: input).descriptor
    }

    /// Verifies the complete immutable bundle without materializing guest boot files. Reading the
    /// header alone is insufficient at a daemon trust boundary because the embedded kernel or
    /// initrd may have changed independently of their declared lengths.
    @discardableResult
    public static func verifyContents(
        atPath path: String
    ) throws -> DoryInstalledLinuxBootDescriptor {
        let input = try openForReading(path)
        defer { try? input.close() }
        let header = try readHeader(from: input)
        try input.seek(toOffset: header.kernelOffset)
        let kernelDigest = try hashExactly(
            from: input,
            byteCount: header.descriptor.kernelLength
        )
        let initrdDigest = try hashExactly(
            from: input,
            byteCount: header.descriptor.initrdLength
        )
        guard kernelDigest == header.kernelDigest,
              initrdDigest == header.initrdDigest else {
            throw DoryInstalledLinuxBootBundleError.digestMismatch
        }
        return header.descriptor
    }

    @discardableResult
    public static func materialize(
        fromPath path: String,
        kernelPath: String,
        initrdPath: String
    ) throws -> DoryInstalledLinuxBootDescriptor {
        let input = try openForReading(path)
        defer { try? input.close() }
        let header = try readHeader(from: input)
        let destinations = [URL(fileURLWithPath: kernelPath), URL(fileURLWithPath: initrdPath)]
        let parent = destinations[0].deletingLastPathComponent()
        guard destinations[1].deletingLastPathComponent() == parent else {
            throw DoryInstalledLinuxBootBundleError.invalidDestination
        }
        let token = UUID().uuidString
        let temporaries = destinations.map {
            parent.appendingPathComponent(".\($0.lastPathComponent).boot-\(token)")
        }
        for temporary in temporaries {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                temporaries.forEach { try? FileManager.default.removeItem(at: $0) }
                throw DoryInstalledLinuxBootBundleError.write(temporary.path, errno)
            }
        }
        do {
            let kernelOutput = try FileHandle(forWritingTo: temporaries[0])
            let initrdOutput = try FileHandle(forWritingTo: temporaries[1])
            defer {
                try? kernelOutput.close()
                try? initrdOutput.close()
            }
            try input.seek(toOffset: header.kernelOffset)
            let kernelDigest = try copyExactly(
                from: input,
                to: kernelOutput,
                byteCount: header.descriptor.kernelLength
            )
            let initrdDigest = try copyExactly(
                from: input,
                to: initrdOutput,
                byteCount: header.descriptor.initrdLength
            )
            guard kernelDigest == header.kernelDigest,
                  initrdDigest == header.initrdDigest else {
                throw DoryInstalledLinuxBootBundleError.digestMismatch
            }
            try kernelOutput.synchronize()
            try initrdOutput.synchronize()
            try kernelOutput.close()
            try initrdOutput.close()
            for temporary in temporaries {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            }
            for (temporary, destination) in zip(temporaries, destinations) {
                guard rename(temporary.path, destination.path) == 0 else {
                    throw DoryInstalledLinuxBootBundleError.write(destination.path, errno)
                }
            }
            return header.descriptor
        } catch {
            temporaries.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    /// Copies a verified installed-Linux bundle from one already-open object into caller-owned
    /// staging files. The source and destination descriptors are borrowed and their file offsets
    /// are never changed. The complete pinned source must match the immutable resolved-plan digest
    /// before any staged bytes can be accepted.
    @discardableResult
    public static func materializeVerifiedContents(
        fromFileDescriptor inputDescriptor: Int32,
        expectedBundleSHA256: String,
        kernelFileDescriptor: Int32,
        initrdFileDescriptor: Int32
    ) throws -> DoryInstalledLinuxBootDescriptor {
        guard isLowercaseSHA256(expectedBundleSHA256),
              inputDescriptor >= 0,
              kernelFileDescriptor >= 0,
              initrdFileDescriptor >= 0,
              inputDescriptor != kernelFileDescriptor,
              inputDescriptor != initrdFileDescriptor,
              kernelFileDescriptor != initrdFileDescriptor else {
            throw DoryInstalledLinuxBootBundleError.invalidDescriptor
        }
        let header = try readHeader(fileDescriptor: inputDescriptor)
        let inputDigest = try hashStableFile(
            fileDescriptor: inputDescriptor,
            byteCount: header.expectedLength
        )
        guard hex(inputDigest) == expectedBundleSHA256 else {
            throw DoryInstalledLinuxBootBundleError.artifactDigestMismatch
        }
        try prepareEmptyOutput(kernelFileDescriptor)
        try prepareEmptyOutput(initrdFileDescriptor)

        // Hash the exact header bytes that produced the descriptor together with the exact
        // component bytes copied into staging. This second whole-artifact verification is bound
        // to the materialized outputs themselves; an owner-writable source cannot race a
        // different root-device/header between an earlier plan-digest pass and payload copy.
        var materializedArtifactHasher = SHA256()
        materializedArtifactHasher.update(data: header.encodedHeader)
        let kernelDigest = try copyExactly(
            fromFileDescriptor: inputDescriptor,
            sourceOffset: header.kernelOffset,
            toFileDescriptor: kernelFileDescriptor,
            byteCount: header.descriptor.kernelLength,
            wholeArtifactHasher: &materializedArtifactHasher
        )
        let initrdDigest = try copyExactly(
            fromFileDescriptor: inputDescriptor,
            sourceOffset: header.initrdOffset,
            toFileDescriptor: initrdFileDescriptor,
            byteCount: header.descriptor.initrdLength,
            wholeArtifactHasher: &materializedArtifactHasher
        )
        guard kernelDigest == header.kernelDigest,
              initrdDigest == header.initrdDigest else {
            throw DoryInstalledLinuxBootBundleError.digestMismatch
        }
        guard hex(Data(materializedArtifactHasher.finalize())) == expectedBundleSHA256 else {
            throw DoryInstalledLinuxBootBundleError.artifactChanged
        }
        guard fsync(kernelFileDescriptor) == 0,
              fsync(initrdFileDescriptor) == 0 else {
            throw DoryInstalledLinuxBootBundleError.write("inherited boot staging file", errno)
        }
        return header.descriptor
    }

    private struct Header {
        var descriptor: DoryInstalledLinuxBootDescriptor
        var kernelOffset: UInt64
        var initrdOffset: UInt64
        var expectedLength: UInt64
        var kernelDigest: Data
        var initrdDigest: Data
        var encodedHeader: Data
    }

    private static func readHeader(from input: FileHandle) throws -> Header {
        try input.seek(toOffset: 0)
        guard try readExactly(from: input, count: magic.count) == magic else {
            throw DoryInstalledLinuxBootBundleError.invalidMagic
        }
        let rootLength = Int(decodeUInt32(try readExactly(from: input, count: 4)))
        let kernelLength = decodeUInt64(try readExactly(from: input, count: 8))
        let initrdLength = decodeUInt64(try readExactly(from: input, count: 8))
        let kernelDigest = try readExactly(from: input, count: 32)
        let initrdDigest = try readExactly(from: input, count: 32)
        guard rootLength > 0, rootLength <= maximumRootDeviceBytes,
              kernelLength > 0, kernelLength <= maximumKernelBytes,
              initrdLength > 0, initrdLength <= maximumInitrdBytes else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        let rootData = try readExactly(from: input, count: rootLength)
        guard let rootDevice = String(data: rootData, encoding: .utf8),
              isValidRootDevice(rootDevice) else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        let kernelOffset = UInt64(magic.count + fixedHeaderBytes + rootLength)
        let (afterKernel, kernelOverflow) = kernelOffset.addingReportingOverflow(kernelLength)
        let (expectedLength, initrdOverflow) = afterKernel.addingReportingOverflow(initrdLength)
        guard !kernelOverflow, !initrdOverflow,
              try input.seekToEnd() == expectedLength else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        return Header(
            descriptor: DoryInstalledLinuxBootDescriptor(
                rootDevice: rootDevice,
                kernelLength: kernelLength,
                initrdLength: initrdLength,
                kernelSHA256: hex(kernelDigest),
                initrdSHA256: hex(initrdDigest)
            ),
            kernelOffset: kernelOffset,
            initrdOffset: afterKernel,
            expectedLength: expectedLength,
            kernelDigest: kernelDigest,
            initrdDigest: initrdDigest,
            encodedHeader: magic
                + bigEndian(UInt32(rootLength))
                + bigEndian(kernelLength)
                + bigEndian(initrdLength)
                + kernelDigest
                + initrdDigest
                + rootData
        )
    }

    private static func readHeader(fileDescriptor: Int32) throws -> Header {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0 else {
            throw DoryInstalledLinuxBootBundleError.invalidDescriptor
        }
        var offset: UInt64 = 0
        func read(_ count: Int) throws -> Data {
            let data = try preadExactly(
                fileDescriptor: fileDescriptor,
                offset: offset,
                count: count
            )
            offset += UInt64(count)
            return data
        }
        guard try read(magic.count) == magic else {
            throw DoryInstalledLinuxBootBundleError.invalidMagic
        }
        let rootLength = Int(decodeUInt32(try read(4)))
        let kernelLength = decodeUInt64(try read(8))
        let initrdLength = decodeUInt64(try read(8))
        let kernelDigest = try read(32)
        let initrdDigest = try read(32)
        guard rootLength > 0, rootLength <= maximumRootDeviceBytes,
              kernelLength > 0, kernelLength <= maximumKernelBytes,
              initrdLength > 0, initrdLength <= maximumInitrdBytes else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        let rootData = try read(rootLength)
        guard let rootDevice = String(data: rootData, encoding: .utf8),
              isValidRootDevice(rootDevice) else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        let kernelOffset = offset
        let (initrdOffset, kernelOverflow) = kernelOffset.addingReportingOverflow(kernelLength)
        let (expectedLength, initrdOverflow) = initrdOffset.addingReportingOverflow(initrdLength)
        guard !kernelOverflow, !initrdOverflow,
              info.st_size >= 0,
              UInt64(info.st_size) == expectedLength else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        return Header(
            descriptor: DoryInstalledLinuxBootDescriptor(
                rootDevice: rootDevice,
                kernelLength: kernelLength,
                initrdLength: initrdLength,
                kernelSHA256: hex(kernelDigest),
                initrdSHA256: hex(initrdDigest)
            ),
            kernelOffset: kernelOffset,
            initrdOffset: initrdOffset,
            expectedLength: expectedLength,
            kernelDigest: kernelDigest,
            initrdDigest: initrdDigest,
            encodedHeader: magic
                + bigEndian(UInt32(rootLength))
                + bigEndian(kernelLength)
                + bigEndian(initrdLength)
                + kernelDigest
                + initrdDigest
                + rootData
        )
    }

    private static func isValidRootDevice(_ value: String) -> Bool {
        value.wholeMatch(of: /\/dev\/vd[a-z][1-9][0-9]*/) != nil
    }

    private static func openForReading(_ path: String) throws -> FileHandle {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryInstalledLinuxBootBundleError.open(path, errno)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0 else {
            close(descriptor)
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func copyExactly(
        from input: FileHandle,
        to output: FileHandle,
        byteCount: UInt64
    ) throws -> Data {
        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            let count = Int(min(UInt64(copyChunkBytes), remaining))
            let data = try readExactly(from: input, count: count)
            try output.write(contentsOf: data)
            hasher.update(data: data)
            remaining -= UInt64(data.count)
        }
        return Data(hasher.finalize())
    }

    private static func hashExactly(
        from input: FileHandle,
        byteCount: UInt64
    ) throws -> Data {
        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            let count = Int(min(UInt64(copyChunkBytes), remaining))
            let data = try readExactly(from: input, count: count)
            hasher.update(data: data)
            remaining -= UInt64(data.count)
        }
        return Data(hasher.finalize())
    }

    private static func readExactly(from input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk = try input.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else {
                throw DoryInstalledLinuxBootBundleError.invalidHeader
            }
            result.append(chunk)
        }
        return result
    }

    private static func prepareEmptyOutput(_ fileDescriptor: Int32) throws {
        var info = stat()
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard fstat(fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 0,
              flags >= 0,
              flags & O_ACCMODE != O_RDONLY else {
            throw DoryInstalledLinuxBootBundleError.invalidDescriptor
        }
    }

    private static func hashStableFile(
        fileDescriptor: Int32,
        byteCount: UInt64
    ) throws -> Data {
        var before = stat()
        guard fstat(fileDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) == byteCount else {
            throw DoryInstalledLinuxBootBundleError.invalidDescriptor
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < byteCount {
            let count = Int(min(UInt64(copyChunkBytes), byteCount - offset))
            let data = try preadExactly(
                fileDescriptor: fileDescriptor,
                offset: offset,
                count: count
            )
            hasher.update(data: data)
            offset += UInt64(data.count)
        }
        var after = stat()
        guard fstat(fileDescriptor, &after) == 0,
              sameSnapshot(before, after) else {
            throw DoryInstalledLinuxBootBundleError.artifactChanged
        }
        return Data(hasher.finalize())
    }

    private static func copyExactly(
        fromFileDescriptor inputDescriptor: Int32,
        sourceOffset: UInt64,
        toFileDescriptor outputDescriptor: Int32,
        byteCount: UInt64,
        wholeArtifactHasher: inout SHA256
    ) throws -> Data {
        var remaining = byteCount
        var inputOffset = sourceOffset
        var outputOffset: UInt64 = 0
        var hasher = SHA256()
        while remaining > 0 {
            let count = Int(min(UInt64(copyChunkBytes), remaining))
            let data = try preadExactly(
                fileDescriptor: inputDescriptor,
                offset: inputOffset,
                count: count
            )
            try pwriteExactly(
                data,
                fileDescriptor: outputDescriptor,
                offset: outputOffset
            )
            hasher.update(data: data)
            wholeArtifactHasher.update(data: data)
            inputOffset += UInt64(data.count)
            outputOffset += UInt64(data.count)
            remaining -= UInt64(data.count)
        }
        return Data(hasher.finalize())
    }

    private static func preadExactly(
        fileDescriptor: Int32,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard offset <= UInt64(Int64.max) else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        var result = Data(count: count)
        var completed = 0
        try result.withUnsafeMutableBytes { bytes in
            while completed < count {
                let readCount = pread(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    count - completed,
                    off_t(offset + UInt64(completed))
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    throw DoryInstalledLinuxBootBundleError.invalidHeader
                }
                completed += readCount
            }
        }
        return result
    }

    private static func pwriteExactly(
        _ data: Data,
        fileDescriptor: Int32,
        offset: UInt64
    ) throws {
        guard offset <= UInt64(Int64.max) else {
            throw DoryInstalledLinuxBootBundleError.invalidHeader
        }
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let written = pwrite(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed,
                    off_t(offset + UInt64(completed))
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw DoryInstalledLinuxBootBundleError.write(
                        "inherited boot staging file",
                        errno
                    )
                }
                completed += written
            }
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func decodeUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decodeUInt64(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

public enum DoryInstalledLinuxBootBundleError: Error, LocalizedError, Sendable, Equatable {
    case invalidRootDevice(String)
    case invalidKernelSize(UInt64)
    case invalidInitrdSize(UInt64)
    case invalidMagic
    case invalidHeader
    case invalidDescriptor
    case artifactChanged
    case artifactDigestMismatch
    case digestMismatch
    case invalidDestination
    case open(String, Int32)
    case write(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidRootDevice(device): "Invalid installed Linux root device: \(device)"
        case let .invalidKernelSize(size): "Invalid installed Linux kernel size: \(size) bytes"
        case let .invalidInitrdSize(size): "Invalid installed Linux initrd size: \(size) bytes"
        case .invalidMagic: "Not a Dory installed-Linux boot bundle"
        case .invalidHeader: "Installed-Linux boot bundle has an invalid or truncated header"
        case .invalidDescriptor: "Installed-Linux boot descriptors are invalid"
        case .artifactChanged: "Installed-Linux boot bundle changed during verification"
        case .artifactDigestMismatch: "Installed-Linux boot bundle does not match the resolved artifact digest"
        case .digestMismatch: "Installed-Linux boot bundle failed kernel/initrd verification"
        case .invalidDestination: "Installed-Linux boot destinations must share one directory"
        case let .open(path, code): "Could not open installed-Linux boot bundle \(path): \(String(cString: strerror(code)))"
        case let .write(path, code): "Could not write installed-Linux boot artifact \(path): \(String(cString: strerror(code)))"
        }
    }
}
