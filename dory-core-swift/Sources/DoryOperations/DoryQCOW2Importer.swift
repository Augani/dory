import Darwin
import Foundation

/// A deliberately small, read-only QCOW2 v2/v3 importer. It accepts only ordinary unencrypted,
/// uncompressed images with no backing chain, and writes a sparse raw image using positional I/O.
/// The parser is descriptor-bound and all table/data offsets are checked against the original file
/// before they are dereferenced.
public enum DoryQCOW2ImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSource(String)
    case unsupported(String)
    case malformed(String)
    case destinationExists(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case .invalidSource(let detail): "invalid QCOW2 source: \(detail)"
        case .unsupported(let detail): "unsupported QCOW2 feature: \(detail)"
        case .malformed(let detail): "malformed QCOW2 image: \(detail)"
        case .destinationExists(let path): "QCOW2 destination already exists: \(path)"
        case .io(let operation, let code): "QCOW2 \(operation) failed with errno \(code)"
        }
    }
}

public struct DoryQCOW2ImportReceipt: Sendable, Equatable {
    public let sourcePath: String
    public let destinationPath: String
    public let virtualDiskBytes: UInt64
    public let copiedDataBytes: UInt64
}

public enum DoryQCOW2Importer {
    public static let defaultMaximumVirtualDiskBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024 * 1_024
    private static let maximumSourceBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024 * 1_024
    private static let maximumL1TableBytes: UInt64 = 32 * 1_024 * 1_024
    private static let maximumL1Entries: UInt64 = maximumL1TableBytes / 8
    private static let minimumClusterBits: UInt32 = 9
    private static let maximumClusterBits: UInt32 = 21
    private static let qcowMagic: UInt32 = 0x5146_49fb
    private static let compressedClusterFlag: UInt64 = 1 << 62
    private static let offsetMask: UInt64 = 0x00ff_ffff_ffff_fe00
    private static let copyChunkBytes = 1_024 * 1_024

    /// Converts `source` into a new, private raw file at `destination`. On any failure the
    /// destination created by this call is removed; an existing destination is never replaced.
    @discardableResult
    public static func convert(
        source: URL,
        destination: URL,
        maximumVirtualDiskBytes: UInt64 = defaultMaximumVirtualDiskBytes
    ) throws -> DoryQCOW2ImportReceipt {
        guard source.isFileURL, destination.isFileURL,
              maximumVirtualDiskBytes > 0 else {
            throw DoryQCOW2ImportError.invalidSource("source, destination, or size limit")
        }
        let sourceDescriptor = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else {
            throw DoryQCOW2ImportError.io("open source", errno)
        }
        defer { close(sourceDescriptor) }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0 else {
            throw DoryQCOW2ImportError.io("inspect source", errno)
        }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              sourceInfo.st_size >= 104,
              sourceInfo.st_nlink == 1 else {
            throw DoryQCOW2ImportError.invalidSource("source is not one direct regular file")
        }
        let sourceBytes = UInt64(sourceInfo.st_size)
        guard sourceBytes <= maximumSourceBytes else {
            throw DoryQCOW2ImportError.invalidSource("source exceeds the bounded import limit")
        }
        let header = try readExactly(sourceDescriptor, offset: 0, count: 104)
        let layout = try Layout(header: header, sourceBytes: sourceBytes,
                                maximumVirtualDiskBytes: maximumVirtualDiskBytes)

        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else {
            throw DoryQCOW2ImportError.io("open destination directory", errno)
        }
        defer { close(parentDescriptor) }
        let destinationDescriptor = openat(
            parentDescriptor,
            destination.lastPathComponent,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard destinationDescriptor >= 0 else {
            if errno == EEXIST { throw DoryQCOW2ImportError.destinationExists(destination.path) }
            throw DoryQCOW2ImportError.io("create destination", errno)
        }
        var published = false
        defer {
            close(destinationDescriptor)
            if !published { _ = unlinkat(parentDescriptor, destination.lastPathComponent, 0) }
        }
        guard layout.virtualDiskBytes <= UInt64(Int64.max),
              ftruncate(destinationDescriptor, off_t(layout.virtualDiskBytes)) == 0 else {
            throw DoryQCOW2ImportError.io("size destination", errno)
        }

        let l1Data = try readExactly(
            sourceDescriptor,
            offset: layout.l1TableOffset,
            count: Int(layout.l1TableBytes)
        )
        var copiedDataBytes: UInt64 = 0
        for l1Index in 0..<layout.requiredL1Entries {
            let l1Entry = bigEndianUInt64(l1Data, at: l1Index * 8)
            if l1Entry == 0 { continue }
            let l2Offset = try layout.validDataClusterOffset(l1Entry, label: "L1 entry \(l1Index)")
            let l2Data = try readExactly(sourceDescriptor, offset: l2Offset, count: layout.clusterBytes)
            for l2Index in 0..<layout.entriesPerL2 {
                let guestOffset = try layout.guestOffset(l1Index: l1Index, l2Index: l2Index)
                guard guestOffset < layout.virtualDiskBytes else { break }
                let l2Entry = bigEndianUInt64(l2Data, at: l2Index * 8)
                if l2Entry == 0 { continue }
                if l2Entry & compressedClusterFlag != 0 {
                    throw DoryQCOW2ImportError.unsupported("compressed clusters")
                }
                let hostOffset = try layout.validDataClusterOffset(
                    l2Entry,
                    label: "L2 entry \(l1Index):\(l2Index)"
                )
                let remaining = layout.virtualDiskBytes - guestOffset
                let byteCount = Int(min(UInt64(layout.clusterBytes), remaining))
                try copyRange(
                    sourceDescriptor: sourceDescriptor,
                    destinationDescriptor: destinationDescriptor,
                    sourceOffset: hostOffset,
                    destinationOffset: guestOffset,
                    byteCount: byteCount
                )
                copiedDataBytes += UInt64(byteCount)
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw DoryQCOW2ImportError.io("sync destination", errno)
        }
        guard fsync(parentDescriptor) == 0 else {
            throw DoryQCOW2ImportError.io("sync destination directory", errno)
        }
        published = true
        return DoryQCOW2ImportReceipt(
            sourcePath: source.path,
            destinationPath: destination.path,
            virtualDiskBytes: layout.virtualDiskBytes,
            copiedDataBytes: copiedDataBytes
        )
    }

    private struct Layout {
        let sourceBytes: UInt64
        let virtualDiskBytes: UInt64
        let clusterBytes: Int
        let clusterBytesUInt64: UInt64
        let entriesPerL2: Int
        let l1TableOffset: UInt64
        let l1TableBytes: UInt64
        let requiredL1Entries: Int

        init(header: Data, sourceBytes: UInt64, maximumVirtualDiskBytes: UInt64) throws {
            guard bigEndianUInt32(header, at: 0) == qcowMagic else {
                throw DoryQCOW2ImportError.invalidSource("missing QFI magic")
            }
            let version = bigEndianUInt32(header, at: 4)
            guard version == 2 || version == 3 else {
                throw DoryQCOW2ImportError.unsupported("QCOW version \(version)")
            }
            let backingOffset = bigEndianUInt64(header, at: 8)
            let backingBytes = bigEndianUInt32(header, at: 16)
            let clusterBits = bigEndianUInt32(header, at: 20)
            let virtualDiskBytes = bigEndianUInt64(header, at: 24)
            let cryptMethod = bigEndianUInt32(header, at: 32)
            let l1Entries = UInt64(bigEndianUInt32(header, at: 36))
            let l1TableOffset = bigEndianUInt64(header, at: 40)
            let snapshots = bigEndianUInt32(header, at: 60)
            let snapshotsOffset = bigEndianUInt64(header, at: 64)
            guard backingOffset == 0, backingBytes == 0 else {
                throw DoryQCOW2ImportError.unsupported("backing files")
            }
            guard cryptMethod == 0 else { throw DoryQCOW2ImportError.unsupported("encryption") }
            guard snapshots == 0, snapshotsOffset == 0 else {
                throw DoryQCOW2ImportError.unsupported("internal snapshots")
            }
            guard clusterBits >= minimumClusterBits, clusterBits <= maximumClusterBits else {
                throw DoryQCOW2ImportError.unsupported("cluster size")
            }
            guard virtualDiskBytes > 0, virtualDiskBytes <= maximumVirtualDiskBytes else {
                throw DoryQCOW2ImportError.invalidSource("virtual disk size")
            }
            if version == 3 {
                let incompatibleFeatures = bigEndianUInt64(header, at: 72)
                let headerLength = bigEndianUInt32(header, at: 100)
                guard incompatibleFeatures == 0 else {
                    throw DoryQCOW2ImportError.unsupported("incompatible feature bits")
                }
                guard headerLength >= 104, headerLength <= (1 << clusterBits) else {
                    throw DoryQCOW2ImportError.malformed("v3 header length")
                }
            }
            let clusterBytesUInt64 = UInt64(1) << UInt64(clusterBits)
            let clusterBytes = Int(clusterBytesUInt64)
            let entriesPerL2 = clusterBytes / 8
            let l2Coverage = clusterBytesUInt64 * UInt64(entriesPerL2)
            let requiredL1Entries64 = (virtualDiskBytes + l2Coverage - 1) / l2Coverage
            let (l1TableBytes, l1Overflow) = l1Entries.multipliedReportingOverflow(by: 8)
            guard l1Entries >= requiredL1Entries64,
                  l1Entries <= maximumL1Entries,
                  !l1Overflow,
                  l1TableBytes > 0,
                  l1TableBytes <= maximumL1TableBytes,
                  l1TableOffset.isMultiple(of: clusterBytesUInt64),
                  l1TableOffset <= sourceBytes,
                  l1TableBytes <= sourceBytes - l1TableOffset,
                  requiredL1Entries64 <= UInt64(Int.max) else {
                throw DoryQCOW2ImportError.malformed("L1 table")
            }
            self.sourceBytes = sourceBytes
            self.virtualDiskBytes = virtualDiskBytes
            self.clusterBytes = clusterBytes
            self.clusterBytesUInt64 = clusterBytesUInt64
            self.entriesPerL2 = entriesPerL2
            self.l1TableOffset = l1TableOffset
            self.l1TableBytes = l1TableBytes
            requiredL1Entries = Int(requiredL1Entries64)
        }

        func validDataClusterOffset(_ entry: UInt64, label: String) throws -> UInt64 {
            let offset = entry & offsetMask
            guard offset > 0,
                  offset.isMultiple(of: clusterBytesUInt64),
                  offset <= sourceBytes,
                  clusterBytesUInt64 <= sourceBytes - offset else {
                throw DoryQCOW2ImportError.malformed("\(label) points outside source")
            }
            return offset
        }

        func guestOffset(l1Index: Int, l2Index: Int) throws -> UInt64 {
            let l2Coverage = clusterBytesUInt64 * UInt64(entriesPerL2)
            let (base, baseOverflow) = UInt64(l1Index).multipliedReportingOverflow(by: l2Coverage)
            let (addition, additionOverflow) = UInt64(l2Index).multipliedReportingOverflow(by: clusterBytesUInt64)
            let (result, resultOverflow) = base.addingReportingOverflow(addition)
            guard !baseOverflow, !additionOverflow, !resultOverflow else {
                throw DoryQCOW2ImportError.malformed("guest cluster offset overflow")
            }
            return result
        }
    }

    private static func readExactly(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else {
            throw DoryQCOW2ImportError.malformed("invalid read range")
        }
        var result = Data(count: count)
        var completed = 0
        while completed < count {
            let readCount = result.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress!.advanced(by: completed), count - completed,
                      off_t(offset + UInt64(completed)))
            }
            guard readCount > 0 else {
                if readCount == 0 { throw DoryQCOW2ImportError.malformed("unexpected end of source") }
                if errno == EINTR { continue }
                throw DoryQCOW2ImportError.io("read source", errno)
            }
            completed += readCount
        }
        return result
    }

    private static func copyRange(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        sourceOffset: UInt64,
        destinationOffset: UInt64,
        byteCount: Int
    ) throws {
        var copied = 0
        while copied < byteCount {
            let count = min(copyChunkBytes, byteCount - copied)
            let data = try readExactly(sourceDescriptor, offset: sourceOffset + UInt64(copied), count: count)
            var written = 0
            while written < data.count {
                let writeCount = data.withUnsafeBytes { buffer in
                    pwrite(destinationDescriptor, buffer.baseAddress!.advanced(by: written), data.count - written,
                           off_t(destinationOffset + UInt64(copied + written)))
                }
                guard writeCount >= 0 else {
                    if errno == EINTR { continue }
                    throw DoryQCOW2ImportError.io("write destination", errno)
                }
                guard writeCount > 0 else { throw DoryQCOW2ImportError.io("write destination", EIO) }
                written += writeCount
            }
            copied += count
        }
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func bigEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
