import Darwin
import Foundation

/// Discovers the installed Linux root candidate from a whole-disk GPT image. Apple
/// Virtualization presents this image as NVMe during installation; Dory's accelerated runtime
/// presents the same bytes as VirtIO block, so partition 2 becomes `/dev/vda2` without rewriting
/// the guest disk.
public enum DoryLinuxInstalledDiskInspector {
    private static let sectorSize: UInt64 = 512
    private static let maximumPartitionTableBytes = 8 * 1024 * 1024
    // Linux filesystem data partition GUID 0FC63DAF-8483-4772-8E79-3D69D8477DE4 in GPT byte order.
    private static let linuxFilesystemType = Data([
        0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47,
        0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4,
    ])
    // EFI system partition GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B in GPT byte order.
    private static let efiSystemPartitionType = Data([
        0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
        0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
    ])

    private struct GPTPartitionTable {
        let diskByteCount: UInt64
        let firstUsableLBA: UInt64
        let lastUsableLBA: UInt64
        let entryCount: Int
        let entrySize: Int
        let entries: Data
    }

    public static func rootDevice(
        atPath diskPath: String,
        devicePrefix: String = "/dev/vda"
    ) throws -> String {
        guard devicePrefix.hasPrefix("/dev/"),
              !devicePrefix.contains("\0"),
              devicePrefix.last?.isLetter == true else {
            throw DoryLinuxInstalledDiskInspectionError.invalidDevicePrefix(devicePrefix)
        }
        let table = try partitionTable(atPath: diskPath)
        var candidates = [(index: Int, sectors: UInt64)]()
        for index in 0..<table.entryCount {
            let offset = index * table.entrySize
            guard table.entries[offset..<(offset + 16)] == linuxFilesystemType else { continue }
            let firstLBA = littleEndianUInt64(table.entries, at: offset + 32)
            let lastLBA = littleEndianUInt64(table.entries, at: offset + 40)
            guard partitionRangeIsValid(
                firstLBA: firstLBA,
                lastLBA: lastLBA,
                table: table
            ) else { continue }
            candidates.append((index + 1, lastLBA - firstLBA + 1))
        }
        guard let root = candidates.max(by: { $0.sectors < $1.sectors }) else {
            throw DoryLinuxInstalledDiskInspectionError.rootPartitionNotFound(diskPath)
        }
        return "\(devicePrefix)\(root.index)"
    }

    /// Returns the one-based GPT index of a structurally valid EFI system partition. This is a
    /// bounded pre-eject check: the subsequent disk-first boot remains the authoritative proof
    /// that the installed loader and operating system can execute.
    public static func efiSystemPartition(atPath diskPath: String) throws -> Int {
        let table = try partitionTable(atPath: diskPath)
        for index in 0..<table.entryCount {
            let offset = index * table.entrySize
            guard table.entries[offset..<(offset + 16)] == efiSystemPartitionType else { continue }
            let firstLBA = littleEndianUInt64(table.entries, at: offset + 32)
            let lastLBA = littleEndianUInt64(table.entries, at: offset + 40)
            guard partitionRangeIsValid(
                firstLBA: firstLBA,
                lastLBA: lastLBA,
                table: table
            ) else { continue }
            return index + 1
        }
        throw DoryLinuxInstalledDiskInspectionError.efiSystemPartitionNotFound(diskPath)
    }

    private static func partitionTable(atPath diskPath: String) throws -> GPTPartitionTable {
        let descriptor = open(diskPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryLinuxInstalledDiskInspectionError.open(diskPath, errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= off_t(sectorSize * 34) else {
            throw DoryLinuxInstalledDiskInspectionError.invalidDisk(diskPath)
        }

        let header = try readExactly(
            descriptor: descriptor,
            offset: Int64(sectorSize),
            count: Int(sectorSize),
            path: diskPath
        )
        guard header.prefix(8) == Data("EFI PART".utf8) else {
            throw DoryLinuxInstalledDiskInspectionError.missingGPT(diskPath)
        }
        let headerSize = UInt64(littleEndianUInt32(header, at: 12))
        let currentLBA = littleEndianUInt64(header, at: 24)
        let firstUsableLBA = littleEndianUInt64(header, at: 40)
        let lastUsableLBA = littleEndianUInt64(header, at: 48)
        let entryLBA = littleEndianUInt64(header, at: 72)
        let entryCount = UInt64(littleEndianUInt32(header, at: 80))
        let entrySize = UInt64(littleEndianUInt32(header, at: 84))
        let (tableByteCount, tableOverflow) = entryCount.multipliedReportingOverflow(by: entrySize)
        let (tableOffset, offsetOverflow) = entryLBA.multipliedReportingOverflow(by: sectorSize)
        let diskByteCount = UInt64(info.st_size)
        let diskSectors = diskByteCount / sectorSize
        guard !tableOverflow,
              !offsetOverflow,
              headerSize >= 92,
              headerSize <= sectorSize,
              currentLBA == 1,
              firstUsableLBA > 1,
              lastUsableLBA >= firstUsableLBA,
              lastUsableLBA < diskSectors,
              entryCount > 0,
              entryCount <= UInt64(Int.max),
              entrySize >= 128,
              entrySize <= 4_096,
              entrySize <= UInt64(Int.max),
              tableByteCount > 0,
              tableByteCount <= UInt64(maximumPartitionTableBytes),
              tableOffset < diskByteCount,
              tableByteCount <= diskByteCount - tableOffset else {
            throw DoryLinuxInstalledDiskInspectionError.invalidGPT(diskPath)
        }
        let entries = try readExactly(
            descriptor: descriptor,
            offset: Int64(tableOffset),
            count: Int(tableByteCount),
            path: diskPath
        )
        return GPTPartitionTable(
            diskByteCount: diskByteCount,
            firstUsableLBA: firstUsableLBA,
            lastUsableLBA: lastUsableLBA,
            entryCount: Int(entryCount),
            entrySize: Int(entrySize),
            entries: entries
        )
    }

    private static func partitionRangeIsValid(
        firstLBA: UInt64,
        lastLBA: UInt64,
        table: GPTPartitionTable
    ) -> Bool {
        guard firstLBA >= table.firstUsableLBA,
              lastLBA >= firstLBA,
              lastLBA <= table.lastUsableLBA else { return false }
        let (endLBA, additionOverflow) = lastLBA.addingReportingOverflow(1)
        let (lastByte, multiplicationOverflow) = endLBA.multipliedReportingOverflow(
            by: sectorSize
        )
        return !additionOverflow && !multiplicationOverflow && lastByte <= table.diskByteCount
    }

    private static func readExactly(
        descriptor: Int32,
        offset: Int64,
        count: Int,
        path: String
    ) throws -> Data {
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            let bytesRead = data.withUnsafeMutableBytes { bytes in
                pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    count - completed,
                    off_t(offset + Int64(completed))
                )
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw DoryLinuxInstalledDiskInspectionError.read(path, errno)
            }
            guard bytesRead > 0 else {
                throw DoryLinuxInstalledDiskInspectionError.read(path, EIO)
            }
            completed += bytesRead
        }
        return data
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(littleEndianUInt32(data, at: offset))
            | UInt64(littleEndianUInt32(data, at: offset + 4)) << 32
    }
}

public enum DoryLinuxInstalledDiskInspectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidDevicePrefix(String)
    case open(String, Int32)
    case read(String, Int32)
    case invalidDisk(String)
    case missingGPT(String)
    case invalidGPT(String)
    case efiSystemPartitionNotFound(String)
    case rootPartitionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDevicePrefix(prefix):
            "Invalid Linux block-device prefix: \(prefix)"
        case let .open(path, code):
            "Could not open installed Linux disk \(path): \(String(cString: strerror(code)))"
        case let .read(path, code):
            "Could not read installed Linux disk \(path): \(String(cString: strerror(code)))"
        case let .invalidDisk(path):
            "Installed Linux disk is not a valid nonempty regular image: \(path)"
        case let .missingGPT(path):
            "Installed Linux disk has no GPT partition table: \(path)"
        case let .invalidGPT(path):
            "Installed Linux disk has an invalid GPT partition table: \(path)"
        case let .efiSystemPartitionNotFound(path):
            "Installed Linux disk has no valid EFI system partition: \(path)"
        case let .rootPartitionNotFound(path):
            "Installed Linux disk has no Linux filesystem partition to direct-boot: \(path)"
        }
    }
}
