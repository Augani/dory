import CryptoKit
import Darwin
import Foundation

public struct DoryInstalledLinuxBootDescriptor: Sendable, Equatable {
    public let rootDevice: String
    public let kernelLength: UInt64
    public let initrdLength: UInt64

    public init(rootDevice: String, kernelLength: UInt64, initrdLength: UInt64) {
        self.rootDevice = rootDevice
        self.kernelLength = kernelLength
        self.initrdLength = initrdLength
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
    private static let maximumKernelBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumInitrdBytes: UInt64 = 512 * 1024 * 1024
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

    private struct Header {
        var descriptor: DoryInstalledLinuxBootDescriptor
        var kernelOffset: UInt64
        var kernelDigest: Data
        var initrdDigest: Data
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
                initrdLength: initrdLength
            ),
            kernelOffset: kernelOffset,
            kernelDigest: kernelDigest,
            initrdDigest: initrdDigest
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
        case .digestMismatch: "Installed-Linux boot bundle failed kernel/initrd verification"
        case .invalidDestination: "Installed-Linux boot destinations must share one directory"
        case let .open(path, code): "Could not open installed-Linux boot bundle \(path): \(String(cString: strerror(code)))"
        case let .write(path, code): "Could not write installed-Linux boot artifact \(path): \(String(cString: strerror(code)))"
        }
    }
}
