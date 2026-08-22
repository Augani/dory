import Darwin
import CryptoKit
import Foundation
import zlib

public enum DoryInstallerISOArchitecture: String, Sendable, Equatable {
    case arm64
    case x86_64
    case multiArchitecture = "multi-architecture"
    case unknown
}

public enum DoryInstallerISOCompatibility: Sendable, Equatable {
    case compatible
    case unknown
    case incompatible(String)
}

public struct DoryInstallerISOMediaIdentity: Sendable, Equatable {
    public let architecture: DoryInstallerISOArchitecture
    public let sha256: String
    public let byteCount: UInt64

    public init(
        architecture: DoryInstallerISOArchitecture,
        sha256: String,
        byteCount: UInt64
    ) {
        self.architecture = architecture
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
    }
}

public enum DoryInstallerISORuntimeQualification: Sendable, Equatable {
    case qualified(String)
    case unqualified
    case knownUnstable(String)
}

/// A qualification key for the parts of Dory's EFI device model that materially affect a guest.
/// Changing this value deliberately invalidates evidence gathered with an older virtual storage
/// controller instead of carrying a failure (or a pass) across different virtual hardware.
public enum DoryInstallerRuntimeProfile: String, Sendable, Equatable {
    case legacyVirtioBlockV1 = "vz-efi-virtio-blk-v1"
    case nativeNVMeFsyncV1 = "vz-efi-nvme-fsync-v1"

    public static let current = DoryInstallerRuntimeProfile.nativeNVMeFsyncV1
}

public struct DoryInstallerHostRuntime: Sendable {
    public let architecture: String
    public let hardwareModel: String
    public let operatingSystemVersion: OperatingSystemVersion
    public let operatingSystemBuild: String
    public let runtimeProfile: String

    public init(
        architecture: String,
        hardwareModel: String,
        operatingSystemVersion: OperatingSystemVersion,
        operatingSystemBuild: String,
        runtimeProfile: String = DoryInstallerRuntimeProfile.current.rawValue
    ) {
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.operatingSystemVersion = operatingSystemVersion
        self.operatingSystemBuild = operatingSystemBuild
        self.runtimeProfile = runtimeProfile
    }

    public static var current: DoryInstallerHostRuntime {
        DoryInstallerHostRuntime(
            architecture: DoryInstallerISOInspector.currentHostArchitecture,
            hardwareModel: systemString("hw.model"),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            operatingSystemBuild: systemString("kern.osversion"),
            runtimeProfile: DoryInstallerRuntimeProfile.current.rawValue
        )
    }

    private static func systemString(_ name: String) -> String {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else {
            return "unknown"
        }
        return String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

/// Runtime evidence is deliberately separate from EFI architecture compatibility.
///
/// A matching loader proves that the host can enter the installer; it does not prove that the
/// distribution kernel is stable on a particular Virtualization.framework and Mac combination.
public enum DoryInstallerISORuntimeCatalog {
    public static let ubuntu24044DesktopARM64SHA256 =
        "c2610520bf582976839a1724c669e1cfed0547427be5a0ad12d457b92b46ffbe"
    public static let ubuntu24043DesktopARM64SHA256 =
        "cdbf0f83ab4f7d46be767e73c59b5cbca9743dd5fb887142c96f4b2df38fa5ad"

    public static func qualification(
        of identity: DoryInstallerISOMediaIdentity,
        on host: DoryInstallerHostRuntime = .current
    ) -> DoryInstallerISORuntimeQualification {
        if [ubuntu24044DesktopARM64SHA256, ubuntu24043DesktopARM64SHA256]
            .contains(identity.sha256),
           host.architecture.lowercased() == "arm64",
           host.hardwareModel == "Mac14,10",
           host.operatingSystemBuild == "26A5406e",
           host.runtimeProfile == DoryInstallerRuntimeProfile.legacyVirtioBlockV1.rawValue {
            return .knownUnstable(
                "This Ubuntu 24.04 Desktop ARM64 media is known to panic or freeze with Dory's retired VirtIO-block EFI profile on this Mac and macOS build. Recreate the machine with Dory's current native-NVMe EFI profile."
            )
        }
        return .unqualified
    }
}

/// Balanced defaults for distribution-owned EFI installers. These are resource choices, not a
/// compatibility workaround; runtime qualification is based on the exact media and host evidence.
public enum DoryInstallerMachinePolicy {
    public static let defaultCPUCount = 4
    public static let defaultMemoryMB: UInt64 = 4_096
}

/// Fast, mount-free architecture preflight for user-selected Linux installer media.
///
/// Dory reads ISO9660 directory records plus bounded EFI boot regions. It never mounts the image,
/// does not execute anything from it, and does not copy a multi-gigabyte image before deciding
/// whether its EFI loader can run on this Mac.
public enum DoryInstallerISOInspector {
    private static let logicalBlockSize: Int64 = 2_048
    private static let scanChunkSize = 1024 * 1024
    private static let maximumDirectoryBytes = 64 * 1024 * 1024
    private static let maximumSingleDirectoryBytes = 16 * 1024 * 1024
    private static let maximumBootRegionBytes: Int64 = 128 * 1024 * 1024
    private static let edgeScanBytes: Int64 = 8 * 1024 * 1024
    private static let trailingScanBytes: Int64 = 64 * 1024 * 1024

    private static let arm64Markers = markerVariants(["BOOTAA64.EFI", "GRUBAA64.EFI"])
    private static let x86Markers = markerVariants(["BOOTX64.EFI", "GRUBX64.EFI"])
    private static let maximumMarkerBytes =
        (arm64Markers + x86Markers).map(\.count).max() ?? 1

    public static func architecture(atPath path: String) throws -> DoryInstallerISOArchitecture {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryInstallerISOInspectionError.open(path, errno)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw DoryInstallerISOInspectionError.notRegularFile(path)
        }

        return try architecture(descriptor: descriptor, size: Int64(info.st_size), path: path)
    }

    public static func mediaIdentity(atPath path: String) throws -> DoryInstallerISOMediaIdentity {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryInstallerISOInspectionError.open(path, errno)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw DoryInstallerISOInspectionError.notRegularFile(path)
        }

        return try mediaIdentity(
            descriptor: descriptor,
            size: Int64(info.st_size),
            path: path
        )
    }

    /// Reads one bounded regular file from the ISO9660 namespace without mounting or executing
    /// the image. Paths are matched case-insensitively and ISO9660 version suffixes (`;1`) are
    /// ignored, which covers the layout used by mainstream Linux installer media.
    public static func fileData(
        atISOPath isoPath: String,
        fromPath path: String,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw DoryInstallerISOInspectionError.fileTooLarge(path, 0)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw DoryInstallerISOInspectionError.invalidISOPath(path)
        }

        let descriptor = open(isoPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryInstallerISOInspectionError.open(isoPath, errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw DoryInstallerISOInspectionError.notRegularFile(isoPath)
        }

        let imageSize = Int64(info.st_size)
        let metadata = try inspectISO9660(descriptor: descriptor, size: imageSize, path: isoPath)
        guard var current = metadata.rootDirectory else {
            throw DoryInstallerISOInspectionError.fileNotFound(path)
        }
        for (index, component) in components.enumerated() {
            let entry = try directoryEntry(
                named: component,
                in: current,
                descriptor: descriptor,
                imageSize: imageSize,
                path: isoPath
            )
            guard let entry else {
                throw DoryInstallerISOInspectionError.fileNotFound(path)
            }
            let isLast = index == components.count - 1
            if isLast {
                guard !entry.isDirectory else {
                    throw DoryInstallerISOInspectionError.fileNotFound(path)
                }
                guard entry.range.length <= Int64(maximumBytes) else {
                    throw DoryInstallerISOInspectionError.fileTooLarge(path, entry.range.length)
                }
                return try read(
                    descriptor: descriptor,
                    offset: entry.range.offset,
                    count: Int(entry.range.length),
                    path: isoPath
                )
            }
            guard entry.isDirectory else {
                throw DoryInstallerISOInspectionError.fileNotFound(path)
            }
            current = entry.range
        }
        throw DoryInstallerISOInspectionError.fileNotFound(path)
    }

    fileprivate static func mediaIdentity(
        descriptor: Int32,
        size: Int64,
        path: String
    ) throws -> DoryInstallerISOMediaIdentity {
        let architecture = try architecture(descriptor: descriptor, size: size, path: path)
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let byteCount = Int(min(Int64(scanChunkSize), size - offset))
            let data = try read(
                descriptor: descriptor,
                offset: offset,
                count: byteCount,
                path: path
            )
            guard !data.isEmpty else {
                throw DoryInstallerISOInspectionError.read(path, EIO)
            }
            hasher.update(data: data)
            offset += Int64(data.count)
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return DoryInstallerISOMediaIdentity(
            architecture: architecture,
            sha256: sha256,
            byteCount: UInt64(size)
        )
    }

    fileprivate static func architecture(
        descriptor: Int32,
        size: Int64,
        path: String
    ) throws -> DoryInstallerISOArchitecture {
        var markers = MarkerState()
        let metadata = try inspectISO9660(descriptor: descriptor, size: size, path: path)
        markers.merge(metadata.markers)

        var scannedRanges = Set<ByteRange>()
        let partitionRanges = try mbrEFIPartitionRanges(
            descriptor: descriptor,
            size: size,
            path: path
        )
        for range in metadata.bootImageRanges + partitionRanges {
            try scan(
                descriptor: descriptor,
                size: size,
                range: range,
                path: path,
                markers: &markers,
                scannedRanges: &scannedRanges
            )
            if markers.architecture == .multiArchitecture { return .multiArchitecture }
        }

        try scan(
            descriptor: descriptor,
            size: size,
            range: ByteRange(offset: 0, length: min(size, edgeScanBytes)),
            path: path,
            markers: &markers,
            scannedRanges: &scannedRanges
        )
        if markers.architecture == .multiArchitecture { return .multiArchitecture }

        let trailingLength = min(size, trailingScanBytes)
        try scan(
            descriptor: descriptor,
            size: size,
            range: ByteRange(offset: size - trailingLength, length: trailingLength),
            path: path,
            markers: &markers,
            scannedRanges: &scannedRanges
        )
        return markers.architecture
    }

    public static func compatibility(
        of architecture: DoryInstallerISOArchitecture,
        hostArchitecture: String
    ) -> DoryInstallerISOCompatibility {
        switch (normalizedHostArchitecture(hostArchitecture), architecture) {
        case ("arm64", .x86_64):
            .incompatible("This ISO is Intel x86_64-only. Apple Silicon requires an arm64 EFI ISO.")
        case ("x86_64", .arm64):
            .incompatible("This ISO is arm64-only. This Intel Mac requires an x86_64 EFI ISO.")
        case (_, .unknown):
            .unknown
        default:
            .compatible
        }
    }

    public static var currentHostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func normalizedHostArchitecture(_ architecture: String) -> String {
        switch architecture.lowercased() {
        case "aarch64", "arm64": "arm64"
        case "amd64", "x86_64": "x86_64"
        default: architecture.lowercased()
        }
    }

    private struct ISO9660Inspection {
        var markers = MarkerState()
        var bootImageRanges: [ByteRange] = []
        var rootDirectory: ByteRange?
    }

    private static func inspectISO9660(
        descriptor: Int32,
        size: Int64,
        path: String
    ) throws -> ISO9660Inspection {
        var result = ISO9660Inspection()
        var rootDirectory: ByteRange?
        var bootCatalogLBAs: [UInt32] = []

        for index in 16..<272 {
            let offset = Int64(index) * logicalBlockSize
            guard offset + logicalBlockSize <= size else { break }
            let block = try read(
                descriptor: descriptor,
                offset: offset,
                count: Int(logicalBlockSize),
                path: path
            )
            guard block.count == Int(logicalBlockSize),
                  block[1..<6].elementsEqual(Data("CD001".utf8)) else {
                if index == 16 { return result }
                break
            }

            switch block[0] {
            case 0:
                if block.count >= 75,
                   String(decoding: block[7..<39], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("EL TORITO SPECIFICATION") {
                    bootCatalogLBAs.append(littleEndianUInt32(block, at: 71))
                }
            case 1:
                if let directory = directoryRange(from: block, recordOffset: 156, imageSize: size) {
                    rootDirectory = directory
                    result.rootDirectory = directory
                }
            case 255:
                break
            default:
                continue
            }
            if block[0] == 255 { break }
        }

        if let rootDirectory {
            try inspectDirectories(
                descriptor: descriptor,
                imageSize: size,
                root: rootDirectory,
                path: path,
                markers: &result.markers
            )
        }

        for catalogLBA in bootCatalogLBAs {
            result.bootImageRanges.append(contentsOf: try elToritoBootImageRanges(
                descriptor: descriptor,
                imageSize: size,
                catalogLBA: catalogLBA,
                path: path
            ))
        }
        return result
    }

    private struct ISO9660DirectoryEntry {
        var range: ByteRange
        var isDirectory: Bool
    }

    private static func directoryEntry(
        named requestedName: String,
        in directory: ByteRange,
        descriptor: Int32,
        imageSize: Int64,
        path: String
    ) throws -> ISO9660DirectoryEntry? {
        guard directory.length > 0,
              directory.length <= Int64(maximumSingleDirectoryBytes),
              directory.offset >= 0,
              directory.offset + directory.length <= imageSize else {
            return nil
        }
        let data = try read(
            descriptor: descriptor,
            offset: directory.offset,
            count: Int(directory.length),
            path: path
        )
        var position = 0
        while position < data.count {
            let recordLength = Int(data[position])
            if recordLength == 0 {
                position = ((position / Int(logicalBlockSize)) + 1) * Int(logicalBlockSize)
                continue
            }
            guard recordLength >= 34, position + recordLength <= data.count else { break }
            let identifierLength = Int(data[position + 32])
            guard position + 33 + identifierLength <= position + recordLength else {
                position += recordLength
                continue
            }
            let identifier = data[(position + 33)..<(position + 33 + identifierLength)]
            let isDotEntry = identifierLength == 1 && (identifier.first == 0 || identifier.first == 1)
            if !isDotEntry {
                let rawName = String(decoding: identifier, as: UTF8.self)
                var isoName = rawName.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rawName
                // ISO9660 encodes a filename with an empty extension as `NAME.;1`.
                if isoName.last == "." { isoName.removeLast() }
                if isoName.caseInsensitiveCompare(requestedName) == .orderedSame {
                    guard data[position + 25] & 0x80 == 0,
                          let range = directoryRange(
                              from: data,
                              recordOffset: position,
                              imageSize: imageSize
                          ) else {
                        return nil
                    }
                    return ISO9660DirectoryEntry(
                        range: range,
                        isDirectory: data[position + 25] & 0x02 != 0
                    )
                }
            }
            position += recordLength
        }
        return nil
    }

    private static func inspectDirectories(
        descriptor: Int32,
        imageSize: Int64,
        root: ByteRange,
        path: String,
        markers: inout MarkerState
    ) throws {
        var queue = [root]
        var visited = Set<ByteRange>()
        var totalBytes = 0

        while !queue.isEmpty, visited.count < 4_096, totalBytes < maximumDirectoryBytes {
            let directory = queue.removeFirst()
            guard visited.insert(directory).inserted,
                  directory.length > 0,
                  directory.length <= Int64(maximumSingleDirectoryBytes),
                  directory.offset >= 0,
                  directory.offset + directory.length <= imageSize else {
                continue
            }
            totalBytes += Int(directory.length)
            let data = try read(
                descriptor: descriptor,
                offset: directory.offset,
                count: Int(directory.length),
                path: path
            )
            markers.observe(data)

            var position = 0
            while position < data.count {
                let recordLength = Int(data[position])
                if recordLength == 0 {
                    position = ((position / Int(logicalBlockSize)) + 1) * Int(logicalBlockSize)
                    continue
                }
                guard recordLength >= 34, position + recordLength <= data.count else { break }
                let identifierLength = Int(data[position + 32])
                guard position + 33 + identifierLength <= position + recordLength else {
                    position += recordLength
                    continue
                }
                let identifier = data[(position + 33)..<(position + 33 + identifierLength)]
                let isDotEntry = identifierLength == 1 && (identifier.first == 0 || identifier.first == 1)
                if !isDotEntry {
                    markers.observe(Data(identifier))
                    let flags = data[position + 25]
                    if flags & 0x02 != 0,
                       let child = directoryRange(
                           from: data,
                           recordOffset: position,
                           imageSize: imageSize
                       ) {
                        queue.append(child)
                    }
                }
                position += recordLength
            }
        }
    }

    private static func directoryRange(
        from data: Data,
        recordOffset: Int,
        imageSize: Int64
    ) -> ByteRange? {
        guard recordOffset >= 0, recordOffset + 18 <= data.count else { return nil }
        let extent = Int64(littleEndianUInt32(data, at: recordOffset + 2)) * logicalBlockSize
        let length = Int64(littleEndianUInt32(data, at: recordOffset + 10))
        guard extent >= 0, length > 0, extent <= imageSize, length <= imageSize - extent else {
            return nil
        }
        return ByteRange(offset: extent, length: length)
    }

    private static func elToritoBootImageRanges(
        descriptor: Int32,
        imageSize: Int64,
        catalogLBA: UInt32,
        path: String
    ) throws -> [ByteRange] {
        let catalogOffset = Int64(catalogLBA) * logicalBlockSize
        guard catalogOffset >= 0, catalogOffset < imageSize else { return [] }
        let catalog = try read(
            descriptor: descriptor,
            offset: catalogOffset,
            count: Int(min(Int64(64 * 1024), imageSize - catalogOffset)),
            path: path
        )
        var ranges: [ByteRange] = []
        var platform: UInt8 = catalog.count >= 2 ? catalog[1] : 0
        var offset = 32
        while offset + 32 <= catalog.count {
            let indicator = catalog[offset]
            if indicator == 0x90 || indicator == 0x91 {
                platform = catalog[offset + 1]
            } else if indicator == 0x88, platform == 0xEF {
                let imageLBA = littleEndianUInt32(catalog, at: offset + 8)
                let imageOffset = Int64(imageLBA) * logicalBlockSize
                if imageOffset >= 0, imageOffset < imageSize {
                    ranges.append(ByteRange(
                        offset: imageOffset,
                        length: min(maximumBootRegionBytes, imageSize - imageOffset)
                    ))
                }
            }
            if indicator == 0x91 { break }
            offset += 32
        }
        return ranges
    }

    private static func mbrEFIPartitionRanges(
        descriptor: Int32,
        size: Int64,
        path: String
    ) throws -> [ByteRange] {
        guard size >= 512 else { return [] }
        let mbr = try read(descriptor: descriptor, offset: 0, count: 512, path: path)
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA else { return [] }
        return (0..<4).compactMap { index in
            let entry = 446 + index * 16
            guard mbr[entry + 4] == 0xEF else { return nil }
            let offset = Int64(littleEndianUInt32(mbr, at: entry + 8)) * 512
            let declaredLength = Int64(littleEndianUInt32(mbr, at: entry + 12)) * 512
            guard offset >= 0, offset < size, declaredLength > 0 else { return nil }
            return ByteRange(
                offset: offset,
                length: min(maximumBootRegionBytes, min(declaredLength, size - offset))
            )
        }
    }

    private static func scan(
        descriptor: Int32,
        size: Int64,
        range: ByteRange,
        path: String,
        markers: inout MarkerState,
        scannedRanges: inout Set<ByteRange>
    ) throws {
        guard range.offset >= 0, range.length > 0, range.offset < size else { return }
        let bounded = ByteRange(
            offset: range.offset,
            length: min(range.length, size - range.offset)
        )
        guard scannedRanges.insert(bounded).inserted else { return }

        var offset = bounded.offset
        let end = bounded.offset + bounded.length
        var carry = Data()
        while offset < end {
            let count = Int(min(Int64(scanChunkSize), end - offset))
            let chunk = try read(descriptor: descriptor, offset: offset, count: count, path: path)
            if chunk.isEmpty { break }
            var searchable = carry
            searchable.append(chunk)
            markers.observe(searchable)
            if markers.architecture == .multiArchitecture { return }
            carry = Data(searchable.suffix(maximumMarkerBytes - 1))
            offset += Int64(chunk.count)
        }
    }

    private static func read(
        descriptor: Int32,
        offset: Int64,
        count: Int,
        path: String
    ) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        while true {
            let bytesRead = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw DoryInstallerISOInspectionError.read(path, errno)
            }
            data.count = bytesRead
            return data
        }
    }

    private static func markerVariants(_ values: [String]) -> [Data] {
        values.flatMap { value in
            [Data(value.utf8), Data(value.lowercased().utf8)]
        }
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private struct ByteRange: Hashable {
        let offset: Int64
        let length: Int64
    }

    private struct MarkerState {
        var foundArm64 = false
        var foundX86 = false

        mutating func observe(_ data: Data) {
            if !foundArm64 {
                foundArm64 = arm64Markers.contains { data.range(of: $0) != nil }
            }
            if !foundX86 {
                foundX86 = x86Markers.contains { data.range(of: $0) != nil }
            }
        }

        mutating func merge(_ other: MarkerState) {
            foundArm64 = foundArm64 || other.foundArm64
            foundX86 = foundX86 || other.foundX86
        }

        var architecture: DoryInstallerISOArchitecture {
            switch (foundArm64, foundX86) {
            case (true, true): .multiArchitecture
            case (true, false): .arm64
            case (false, true): .x86_64
            case (false, false): .unknown
            }
        }
    }
}

public struct DoryLinuxInstallerBootAssets: Sendable, Equatable {
    public let kernel: Data
    public let initrd: Data
    public let kernelISOPath: String
    public let initrdISOPath: String

    public init(kernel: Data, initrd: Data, kernelISOPath: String, initrdISOPath: String) {
        self.kernel = kernel
        self.initrd = initrd
        self.kernelISOPath = kernelISOPath
        self.initrdISOPath = initrdISOPath
    }
}

/// Boot-time decompression seam supplied by the daemon's Rust artifact layer. Keeping the parser
/// in DoryOperations avoids making desired-state contracts depend on the generated FFI module.
public typealias DoryZstdBootArtifactDecompressor = @Sendable (Data, Int) throws -> Data

/// Derives the direct-boot payload for an installed Linux disk from its installer media. The EFI
/// VM remains the installation backend; these immutable files let the installed disk move to
/// Dory's accelerated VirtIO GPU runtime without attempting to emulate EFI in raw Hypervisor.
public enum DoryLinuxInstallerBootAssetExtractor {
    private static let maximumCompressedKernelBytes = 128 * 1024 * 1024
    private static let maximumKernelBytes = 256 * 1024 * 1024
    private static let maximumInitrdBytes = 512 * 1024 * 1024
    private static let arm64ImageMagic: UInt32 = 0x644d_5241

    private static let candidates: [(kernel: String, initrd: String)] = [
        ("casper/vmlinuz", "casper/initrd"),
        ("live/vmlinuz", "live/initrd.img"),
        ("install.a64/vmlinuz", "install.a64/initrd.gz"),
        ("install.arm64/vmlinuz", "install.arm64/initrd.gz"),
        ("arch/boot/aarch64/vmlinuz-linux", "arch/boot/aarch64/initramfs-linux.img"),
    ]

    public static func extract(
        atPath isoPath: String,
        zstdDecompressor: DoryZstdBootArtifactDecompressor? = nil
    ) throws -> DoryLinuxInstallerBootAssets {
        var attempted = [String]()
        for candidate in candidates {
            attempted.append("\(candidate.kernel) + \(candidate.initrd)")
            guard let compressedKernel = try? DoryInstallerISOInspector.fileData(
                atISOPath: isoPath,
                fromPath: candidate.kernel,
                maximumBytes: maximumCompressedKernelBytes
            ), let initrd = try? DoryInstallerISOInspector.fileData(
                atISOPath: isoPath,
                fromPath: candidate.initrd,
                maximumBytes: maximumInitrdBytes
            ) else {
                continue
            }
            let kernel = try materializeARM64Kernel(
                compressedKernel,
                source: candidate.kernel,
                zstdDecompressor: zstdDecompressor
            )
            return DoryLinuxInstallerBootAssets(
                kernel: kernel,
                initrd: initrd,
                kernelISOPath: candidate.kernel,
                initrdISOPath: candidate.initrd
            )
        }
        throw DoryLinuxInstallerBootAssetError.notFound(attempted)
    }

    static func materializeARM64Kernel(
        _ data: Data,
        source: String,
        zstdDecompressor: DoryZstdBootArtifactDecompressor?,
        depth: Int = 0
    ) throws -> Data {
        guard depth <= 2 else {
            throw DoryLinuxInstallerBootAssetError.unsupportedKernel(source)
        }
        if data.count >= 2, data[0] == 0x1f, data[1] == 0x8b {
            return try materializeARM64Kernel(
                gunzip(data, source: source),
                source: source,
                zstdDecompressor: zstdDecompressor,
                depth: depth + 1
            )
        }
        if isRawARM64Image(data) {
            return data
        }
        if isLinuxZboot(data) {
            return try materializeZbootKernel(
                data,
                source: source,
                zstdDecompressor: zstdDecompressor
            )
        }
        if let linuxSection = try linuxSection(in: data, source: source) {
            return try materializeARM64Kernel(
                linuxSection,
                source: source,
                zstdDecompressor: zstdDecompressor,
                depth: depth + 1
            )
        }
        throw DoryLinuxInstallerBootAssetError.unsupportedKernel(source)
    }

    private static func materializeZbootKernel(
        _ data: Data,
        source: String,
        zstdDecompressor: DoryZstdBootArtifactDecompressor?
    ) throws -> Data {
        guard data.count >= 0x40,
              data[0] == 0x4d, data[1] == 0x5a,
              data[2] == 0, data[3] == 0,
              data[4] == 0x7a, data[5] == 0x69,
              data[6] == 0x6d, data[7] == 0x67,
              data[16..<24].allSatisfy({ $0 == 0 }) else {
            throw DoryLinuxInstallerBootAssetError.invalidZboot(source)
        }
        let peOffset = Int(littleEndianUInt32(data, at: 0x3c))
        guard validPEHeader(in: data, at: peOffset, expectedMachine: 0xaa64) else {
            throw DoryLinuxInstallerBootAssetError.invalidZboot(source)
        }

        let compressionBytes = data[24..<56]
        guard let terminator = compressionBytes.firstIndex(of: 0),
              terminator > compressionBytes.startIndex,
              let compression = String(
                  bytes: compressionBytes[..<terminator],
                  encoding: .ascii
              ) else {
            throw DoryLinuxInstallerBootAssetError.invalidZboot(source)
        }
        guard compression == "zstd" else {
            throw DoryLinuxInstallerBootAssetError.unsupportedZbootCompression(
                source,
                compression
            )
        }

        let payloadOffset = Int(littleEndianUInt32(data, at: 8))
        let payloadSize = Int(littleEndianUInt32(data, at: 12))
        guard payloadOffset >= 0x40,
              payloadSize > 0,
              payloadSize <= maximumCompressedKernelBytes,
              let payloadRange = checkedRange(
                  offset: payloadOffset,
                  length: payloadSize,
                  total: data.count
              ) else {
            throw DoryLinuxInstallerBootAssetError.invalidZboot(source)
        }
        guard let zstdDecompressor else {
            throw DoryLinuxInstallerBootAssetError.zstdDecoderUnavailable(source)
        }
        let kernel: Data
        do {
            kernel = try zstdDecompressor(Data(data[payloadRange]), maximumKernelBytes)
        } catch {
            throw DoryLinuxInstallerBootAssetError.invalidZstd(
                source,
                error.localizedDescription
            )
        }
        guard kernel.count <= maximumKernelBytes, isRawARM64Image(kernel) else {
            throw DoryLinuxInstallerBootAssetError.invalidZstd(
                source,
                "decoded bytes are not a raw arm64 Linux Image"
            )
        }
        return kernel
    }

    /// Extract the `.linux` payload from an ARM64 PE/COFF wrapper such as Ubuntu's unified EFI
    /// kernel image. Section-table and file ranges are validated before any slice is materialized.
    private static func linuxSection(in data: Data, source: String) throws -> Data? {
        guard data.count >= 0x40, data[0] == 0x4d, data[1] == 0x5a else {
            return nil
        }
        let peOffset = Int(littleEndianUInt32(data, at: 0x3c))
        guard validPEHeader(in: data, at: peOffset, expectedMachine: 0xaa64),
              let fileHeaderRange = checkedRange(
                  offset: peOffset + 4,
                  length: 20,
                  total: data.count
              ) else {
            throw DoryLinuxInstallerBootAssetError.invalidPE(source)
        }
        let numberOfSections = Int(littleEndianUInt16(data, at: fileHeaderRange.lowerBound + 2))
        let optionalHeaderSize = Int(littleEndianUInt16(data, at: fileHeaderRange.lowerBound + 16))
        guard (1...96).contains(numberOfSections),
              let sectionTableOffset = checkedAdd(peOffset + 24, optionalHeaderSize),
              let sectionTableRange = checkedRange(
                  offset: sectionTableOffset,
                  length: numberOfSections * 40,
                  total: data.count
              ) else {
            throw DoryLinuxInstallerBootAssetError.invalidPE(source)
        }

        var match: Range<Int>?
        for sectionIndex in 0..<numberOfSections {
            let offset = sectionTableRange.lowerBound + sectionIndex * 40
            let nameBytes = data[offset..<(offset + 8)]
            let nameEnd = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
            guard let name = String(bytes: nameBytes[..<nameEnd], encoding: .ascii) else {
                throw DoryLinuxInstallerBootAssetError.invalidPE(source)
            }
            guard name == ".linux" else { continue }
            guard match == nil else {
                throw DoryLinuxInstallerBootAssetError.invalidPE(source)
            }
            let rawSize = Int(littleEndianUInt32(data, at: offset + 16))
            let rawOffset = Int(littleEndianUInt32(data, at: offset + 20))
            guard rawSize > 0,
                  rawSize <= maximumCompressedKernelBytes,
                  let range = checkedRange(
                      offset: rawOffset,
                      length: rawSize,
                      total: data.count
                  ) else {
                throw DoryLinuxInstallerBootAssetError.invalidPE(source)
            }
            match = range
        }
        guard let match else {
            throw DoryLinuxInstallerBootAssetError.invalidPE(source)
        }
        return Data(data[match])
    }

    private static func isRawARM64Image(_ data: Data) -> Bool {
        data.count >= 0x3c && littleEndianUInt32(data, at: 0x38) == arm64ImageMagic
    }

    private static func isLinuxZboot(_ data: Data) -> Bool {
        data.count >= 8
            && data[0] == 0x4d && data[1] == 0x5a
            && data[2] == 0 && data[3] == 0
            && data[4] == 0x7a && data[5] == 0x69
            && data[6] == 0x6d && data[7] == 0x67
    }

    private static func validPEHeader(
        in data: Data,
        at offset: Int,
        expectedMachine: UInt16
    ) -> Bool {
        guard let range = checkedRange(offset: offset, length: 24, total: data.count) else {
            return false
        }
        return data[range.lowerBound] == 0x50
            && data[range.lowerBound + 1] == 0x45
            && data[range.lowerBound + 2] == 0
            && data[range.lowerBound + 3] == 0
            && littleEndianUInt16(data, at: range.lowerBound + 4) == expectedMachine
    }

    private static func checkedAdd(_ left: Int, _ right: Int) -> Int? {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? nil : value
    }

    private static func checkedRange(offset: Int, length: Int, total: Int) -> Range<Int>? {
        guard offset >= 0, length >= 0, offset <= total, length <= total - offset else {
            return nil
        }
        return offset..<(offset + length)
    }

    private static func gunzip(_ input: Data, source: String) throws -> Data {
        guard input.count >= 18 else {
            throw DoryLinuxInstallerBootAssetError.invalidGzip(source)
        }
        let expectedSize = Int(littleEndianUInt32(input, at: input.count - 4))
        guard expectedSize > 0, expectedSize <= maximumKernelBytes else {
            throw DoryLinuxInstallerBootAssetError.kernelTooLarge(source, expectedSize)
        }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw DoryLinuxInstallerBootAssetError.invalidGzip(source)
        }
        defer { inflateEnd(&stream) }

        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress!
                )
                stream.avail_in = uInt(inputBytes.count)
                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(outputBytes.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END,
              stream.total_out == uLong(expectedSize),
              stream.avail_out == 0 else {
            throw DoryLinuxInstallerBootAssetError.invalidGzip(source)
        }
        return output
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}

public enum DoryLinuxInstallerBootAssetError: Error, LocalizedError, Sendable, Equatable {
    case notFound([String])
    case unsupportedKernel(String)
    case invalidPE(String)
    case invalidZboot(String)
    case unsupportedZbootCompression(String, String)
    case zstdDecoderUnavailable(String)
    case invalidZstd(String, String)
    case invalidGzip(String)
    case kernelTooLarge(String, Int)

    public var errorDescription: String? {
        switch self {
        case let .notFound(candidates):
            "Installer ISO does not expose a supported arm64 Linux kernel/initrd pair (tried \(candidates.joined(separator: ", ")))."
        case let .unsupportedKernel(path):
            "Installer kernel \(path) is not a raw arm64 Linux Image that Dory can direct-boot."
        case let .invalidPE(path):
            "Installer kernel \(path) has an invalid ARM64 PE/COFF wrapper."
        case let .invalidZboot(path):
            "Installer kernel \(path) has an invalid Linux EFI zboot header."
        case let .unsupportedZbootCompression(path, compression):
            "Installer kernel \(path) uses unsupported zboot compression \(compression)."
        case let .zstdDecoderUnavailable(path):
            "Installer kernel \(path) requires the bounded Rust Zstandard decoder."
        case let .invalidZstd(path, message):
            "Installer kernel \(path) has an invalid Zstandard payload: \(message)"
        case let .invalidGzip(path):
            "Installer kernel \(path) has an invalid or unsupported gzip payload."
        case let .kernelTooLarge(path, size):
            "Installer kernel \(path) expands to an unsupported size (\(size) bytes)."
        }
    }
}

public struct DoryStagedInstallerISO: Sendable, Equatable {
    public let path: String
    public let identity: DoryInstallerISOMediaIdentity
    public let runtimeQualification: DoryInstallerISORuntimeQualification

    public var architecture: DoryInstallerISOArchitecture { identity.architecture }
    public var sha256: String { identity.sha256 }

    public init(
        path: String,
        identity: DoryInstallerISOMediaIdentity,
        runtimeQualification: DoryInstallerISORuntimeQualification
    ) {
        self.path = path
        self.identity = identity
        self.runtimeQualification = runtimeQualification
    }
}

/// Creates a private, daemon-readable handoff for user-selected installer media.
///
/// Sandboxed apps and interactive command-line tools can read files selected from protected macOS
/// locations such as Downloads, while a launch agent intentionally cannot. This staging boundary
/// keeps those permissions in the selecting process and gives doryd only a short-lived private copy.
public enum DoryInstallerISOStager {
    public static func stage(
        atPath sourcePath: String,
        stagingDirectory requestedDirectory: URL? = nil,
        hostArchitecture: String = DoryInstallerISOInspector.currentHostArchitecture,
        hostRuntime requestedHostRuntime: DoryInstallerHostRuntime? = nil
    ) throws -> DoryStagedInstallerISO {
        let sourceDescriptor = open(
            sourcePath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw DoryInstallerISOStagingError.openSource(sourcePath, errno)
        }
        defer { close(sourceDescriptor) }

        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              sourceInfo.st_size > 0 else {
            throw DoryInstallerISOStagingError.invalidSource(sourcePath)
        }

        let identity = try DoryInstallerISOInspector.mediaIdentity(
            descriptor: sourceDescriptor,
            size: Int64(sourceInfo.st_size),
            path: sourcePath
        )
        if case let .incompatible(message) = DoryInstallerISOInspector.compatibility(
            of: identity.architecture,
            hostArchitecture: hostArchitecture
        ) {
            throw DoryInstallerISOStagingError.incompatible(message)
        }
        let currentHost = requestedHostRuntime ?? .current
        let hostRuntime = DoryInstallerHostRuntime(
            architecture: hostArchitecture,
            hardwareModel: currentHost.hardwareModel,
            operatingSystemVersion: currentHost.operatingSystemVersion,
            operatingSystemBuild: currentHost.operatingSystemBuild
        )
        let runtimeQualification = DoryInstallerISORuntimeCatalog.qualification(
            of: identity,
            on: hostRuntime
        )
        if case let .knownUnstable(message) = runtimeQualification {
            throw DoryInstallerISOStagingError.knownUnstable(message)
        }

        let stagingDirectory = requestedDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("dory-installer-imports", isDirectory: true)
        if mkdir(stagingDirectory.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DoryInstallerISOStagingError.createStagingDirectory(
                stagingDirectory.path,
                errno
            )
        }
        let directoryDescriptor = open(
            stagingDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw DoryInstallerISOStagingError.openStagingDirectory(
                stagingDirectory.path,
                errno
            )
        }
        defer { close(directoryDescriptor) }

        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw DoryInstallerISOStagingError.insecureStagingDirectory(stagingDirectory.path)
        }

        let destinationName = "\(UUID().uuidString.lowercased()).iso"
        do {
            if fclonefileat(sourceDescriptor, directoryDescriptor, destinationName, 0) != 0 {
                let destinationDescriptor = openat(
                    directoryDescriptor,
                    destinationName,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
                guard destinationDescriptor >= 0 else {
                    throw DoryInstallerISOStagingError.copy(sourcePath, errno)
                }
                defer { close(destinationDescriptor) }
                guard lseek(sourceDescriptor, 0, SEEK_SET) == 0,
                      fcopyfile(
                          sourceDescriptor,
                          destinationDescriptor,
                          nil,
                          copyfile_flags_t(COPYFILE_DATA)
                      ) == 0,
                      fchmod(destinationDescriptor, mode_t(0o600)) == 0,
                      fsync(destinationDescriptor) == 0 else {
                    throw DoryInstallerISOStagingError.copy(sourcePath, errno)
                }
            }

            let stagedDescriptor = openat(
                directoryDescriptor,
                destinationName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard stagedDescriptor >= 0 else {
                throw DoryInstallerISOStagingError.verify(sourcePath, errno)
            }
            defer { close(stagedDescriptor) }
            var stagedInfo = stat()
            guard fchmod(stagedDescriptor, mode_t(0o600)) == 0,
                  fstat(stagedDescriptor, &stagedInfo) == 0,
                  (stagedInfo.st_mode & S_IFMT) == S_IFREG,
                  stagedInfo.st_uid == geteuid(),
                  stagedInfo.st_size == sourceInfo.st_size,
                  stagedInfo.st_mode & 0o077 == 0,
                  fsync(stagedDescriptor) == 0,
                  fsync(directoryDescriptor) == 0 else {
                throw DoryInstallerISOStagingError.verify(sourcePath, errno)
            }
        } catch {
            _ = unlinkat(directoryDescriptor, destinationName, 0)
            throw error
        }

        return DoryStagedInstallerISO(
            path: stagingDirectory.appendingPathComponent(destinationName).path,
            identity: identity,
            runtimeQualification: runtimeQualification
        )
    }
}

public enum DoryInstallerISOStagingError: Error, LocalizedError, CustomStringConvertible {
    case openSource(String, Int32)
    case invalidSource(String)
    case incompatible(String)
    case knownUnstable(String)
    case createStagingDirectory(String, Int32)
    case openStagingDirectory(String, Int32)
    case insecureStagingDirectory(String)
    case copy(String, Int32)
    case verify(String, Int32)

    public var description: String { errorDescription ?? "Installer ISO staging failed." }

    public var errorDescription: String? {
        switch self {
        case let .openSource(path, code):
            "Could not open installer ISO \(path): \(String(cString: strerror(code)))"
        case let .invalidSource(path):
            "Installer ISO is not a nonempty regular file: \(path)"
        case let .incompatible(message):
            message
        case let .knownUnstable(message):
            message
        case let .createStagingDirectory(path, code):
            "Could not create private installer staging directory \(path): \(String(cString: strerror(code)))"
        case let .openStagingDirectory(path, code):
            "Could not open private installer staging directory \(path): \(String(cString: strerror(code)))"
        case let .insecureStagingDirectory(path):
            "Installer staging directory is not private and user-owned: \(path)"
        case let .copy(path, code):
            "Could not stage installer ISO \(path): \(String(cString: strerror(code)))"
        case let .verify(path, code):
            "Could not verify staged installer ISO \(path): \(String(cString: strerror(code)))"
        }
    }
}

public enum DoryInstallerISOInspectionError: Error, LocalizedError {
    case open(String, Int32)
    case read(String, Int32)
    case notRegularFile(String)
    case invalidISOPath(String)
    case fileNotFound(String)
    case fileTooLarge(String, Int64)

    public var errorDescription: String? {
        switch self {
        case let .open(path, code):
            "Could not inspect installer ISO \(path): \(String(cString: strerror(code)))"
        case let .read(path, code):
            "Could not read installer ISO \(path): \(String(cString: strerror(code)))"
        case let .notRegularFile(path):
            "Installer ISO is not a nonempty regular file: \(path)"
        case let .invalidISOPath(path):
            "Invalid ISO9660 file path: \(path)"
        case let .fileNotFound(path):
            "File was not found in the installer ISO: \(path)"
        case let .fileTooLarge(path, size):
            "Installer ISO file exceeds its extraction limit: \(path) (\(size) bytes)"
        }
    }
}
