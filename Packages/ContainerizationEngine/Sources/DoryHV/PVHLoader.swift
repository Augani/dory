import Foundation
import Darwin

public struct PVHKernelSegment: Equatable, Sendable {
    public let physicalAddress: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
    public let memorySize: UInt64

    public init(physicalAddress: UInt64, fileOffset: UInt64, fileSize: UInt64, memorySize: UInt64) {
        self.physicalAddress = physicalAddress
        self.fileOffset = fileOffset
        self.fileSize = fileSize
        self.memorySize = memorySize
    }
}

/// Loader for Linux x86_64 `vmlinux` images built with `CONFIG_PVH=y`.
///
/// Linux publishes its 32-bit PVH entry through the Xen `XEN_ELFNOTE_PHYS32_ENTRY`
/// note. The x86 VMM loads PT_LOAD segments at their physical addresses, enters at
/// this note's address with paging off, and passes the PVH start-info pointer in EBX.
public struct PVHKernelImage {
    public let data: Data
    public let entryPoint: UInt64
    public let segments: [PVHKernelSegment]

    private static let elfMagic = [UInt8](arrayLiteral: 0x7F, 0x45, 0x4C, 0x46)
    private static let elfClass64: UInt8 = 2
    private static let elfLittleEndian: UInt8 = 1
    private static let elfVersionCurrent: UInt8 = 1
    private static let elfMachineX8664: UInt16 = 0x3E
    private static let programHeaderLoad: UInt32 = 1
    private static let programHeaderNote: UInt32 = 4
    private static let xenNoteName = [UInt8]("Xen".utf8)
    private static let xenPhys32EntryNoteType: UInt32 = 0x12

    public init(contentsOf path: String) throws {
        try self.init(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public init(data: Data) throws {
        guard data.count >= 64 else {
            throw VMError.bootFailure("PVH kernel ELF too small: \(data.count) bytes")
        }
        guard Array(data[0..<4]) == Self.elfMagic,
              data[4] == Self.elfClass64,
              data[5] == Self.elfLittleEndian,
              data[6] == Self.elfVersionCurrent else {
            throw VMError.bootFailure("not an ELF64 little-endian kernel image")
        }
        let machine = data.readLittleEndian(UInt16.self, at: 18)
        guard machine == Self.elfMachineX8664 else {
            throw VMError.bootFailure("not an x86_64 ELF kernel image (machine \(machine))")
        }

        let programHeaderOffset = data.readLittleEndian(UInt64.self, at: 32)
        let programHeaderEntrySize = Int(data.readLittleEndian(UInt16.self, at: 54))
        let programHeaderCount = Int(data.readLittleEndian(UInt16.self, at: 56))
        guard programHeaderEntrySize >= 56 else {
            throw VMError.bootFailure("ELF program header entry too small: \(programHeaderEntrySize)")
        }
        guard let programHeaders = Self.programHeaderRange(
            offset: programHeaderOffset,
            entrySize: programHeaderEntrySize,
            count: programHeaderCount,
            dataCount: data.count
        ) else {
            throw VMError.bootFailure("ELF program header table is outside the kernel image")
        }

        var segments: [PVHKernelSegment] = []
        var pvhEntry: UInt64?
        for index in 0..<programHeaderCount {
            let offset = programHeaders.lowerBound + index * programHeaderEntrySize
            let type = data.readLittleEndian(UInt32.self, at: offset)
            switch type {
            case Self.programHeaderLoad:
                let fileOffset = data.readLittleEndian(UInt64.self, at: offset + 8)
                let physicalAddress = data.readLittleEndian(UInt64.self, at: offset + 24)
                let fileSize = data.readLittleEndian(UInt64.self, at: offset + 32)
                let memorySize = data.readLittleEndian(UInt64.self, at: offset + 40)
                guard fileSize <= memorySize else {
                    throw VMError.bootFailure("ELF PT_LOAD file size exceeds memory size")
                }
                guard Self.range(offset: fileOffset, count: fileSize, dataCount: data.count) != nil else {
                    throw VMError.bootFailure("ELF PT_LOAD segment is outside the kernel image")
                }
                segments.append(PVHKernelSegment(
                    physicalAddress: physicalAddress,
                    fileOffset: fileOffset,
                    fileSize: fileSize,
                    memorySize: memorySize
                ))
            case Self.programHeaderNote:
                let noteOffset = data.readLittleEndian(UInt64.self, at: offset + 8)
                let noteSize = data.readLittleEndian(UInt64.self, at: offset + 32)
                guard let range = Self.range(offset: noteOffset, count: noteSize, dataCount: data.count) else {
                    throw VMError.bootFailure("ELF PT_NOTE segment is outside the kernel image")
                }
                pvhEntry = pvhEntry ?? Self.findPVHEntry(in: data, range: range)
            default:
                continue
            }
        }

        guard !segments.isEmpty else {
            throw VMError.bootFailure("PVH kernel ELF has no PT_LOAD segments")
        }
        guard let pvhEntry else {
            throw VMError.bootFailure("PVH kernel ELF is missing XEN_ELFNOTE_PHYS32_ENTRY")
        }
        self.data = data
        self.entryPoint = pvhEntry
        self.segments = segments
    }

    @discardableResult
    public func load(into memory: GuestMemory) throws -> UInt64 {
        for segment in segments {
            guard memory.contains(segment.physicalAddress, count: segment.memorySize) else {
                throw VMError.bootFailure("PVH kernel segment does not fit in guest RAM")
            }
            guard segment.memorySize <= UInt64(Int.max) else {
                throw VMError.bootFailure("PVH kernel segment is too large to map")
            }
            let destination = try memory.hostPointer(at: segment.physicalAddress, count: segment.memorySize)
            if segment.memorySize > 0 {
                memset(destination, 0, Int(segment.memorySize))
            }
            guard let sourceRange = Self.range(offset: segment.fileOffset, count: segment.fileSize, dataCount: data.count) else {
                throw VMError.bootFailure("PVH kernel segment source is outside the image")
            }
            data.withUnsafeBytes { bytes in
                destination.copyMemory(
                    from: bytes.baseAddress!.advanced(by: sourceRange.lowerBound),
                    byteCount: Int(segment.fileSize)
                )
            }
        }
        return entryPoint
    }

    private static func findPVHEntry(in data: Data, range: Range<Int>) -> UInt64? {
        var cursor = range.lowerBound
        while cursor + 12 <= range.upperBound {
            let nameSize = Int(data.readLittleEndian(UInt32.self, at: cursor))
            let descriptorSize = Int(data.readLittleEndian(UInt32.self, at: cursor + 4))
            let type = data.readLittleEndian(UInt32.self, at: cursor + 8)
            cursor += 12

            let nameStart = cursor
            let nameEnd = nameStart + nameSize
            cursor = align4(nameEnd)
            let descriptorStart = cursor
            let descriptorEnd = descriptorStart + descriptorSize
            cursor = align4(descriptorEnd)
            guard nameEnd <= range.upperBound, descriptorEnd <= range.upperBound else {
                return nil
            }

            let name = trimmedNullSuffix(Array(data[nameStart..<nameEnd]))
            if type == xenPhys32EntryNoteType, name == xenNoteName, descriptorSize >= 4 {
                return UInt64(data.readLittleEndian(UInt32.self, at: descriptorStart))
            }
        }
        return nil
    }

    private static func align4(_ value: Int) -> Int {
        (value + 3) & ~3
    }

    private static func trimmedNullSuffix(_ bytes: [UInt8]) -> [UInt8] {
        var trimmed = bytes
        while trimmed.last == 0 {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func range(offset: UInt64, count: UInt64, dataCount: Int) -> Range<Int>? {
        let sum = offset.addingReportingOverflow(count)
        guard !sum.overflow, offset <= UInt64(Int.max), count <= UInt64(Int.max) else { return nil }
        let start = Int(offset)
        let end = Int(sum.partialValue)
        guard end >= start, end <= dataCount else { return nil }
        return start..<end
    }

    private static func programHeaderRange(
        offset: UInt64,
        entrySize: Int,
        count: Int,
        dataCount: Int
    ) -> Range<Int>? {
        guard entrySize >= 0, count >= 0, offset <= UInt64(Int.max) else { return nil }
        let tableSize = entrySize.multipliedReportingOverflow(by: count)
        guard !tableSize.overflow else { return nil }
        return range(offset: offset, count: UInt64(tableSize.partialValue), dataCount: dataCount)
    }
}
