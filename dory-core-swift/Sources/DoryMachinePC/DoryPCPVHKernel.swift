import DoryDBTX86
import Foundation

public struct DoryPCPVHKernelSegment: Codable, Sendable, Hashable {
  public let physicalAddress: UInt64
  public let fileOffset: UInt64
  public let fileSize: UInt64
  public let memorySize: UInt64

  public init(
    physicalAddress: UInt64,
    fileOffset: UInt64,
    fileSize: UInt64,
    memorySize: UInt64
  ) {
    self.physicalAddress = physicalAddress
    self.fileOffset = fileOffset
    self.fileSize = fileSize
    self.memorySize = memorySize
  }
}

public enum DoryPCPVHKernelError: Error, Sendable, Equatable {
  case truncatedELF
  case unsupportedELF
  case invalidProgramHeaders
  case invalidLoadSegment
  case overlappingLoadSegments
  case missingLoadSegment
  case invalidNotes
  case duplicatePhysicalEntry
  case missingPhysicalEntry
  case invalidPhysicalEntry
  case guestMemoryRejected(DoryX86MemoryError)
}

/// Loads fixed-address ELF64/x86-64 executables using PT_LOAD physical addresses and the
/// PHYS32_ENTRY note. Section headers and e_entry do not define this PVH handoff.
/// No relocation, Xen platform identity, or hypercall service is implied by this loader.
public struct DoryPCPVHKernelImage: Sendable, Hashable {
  public let data: Data
  public let physicalEntryPoint: UInt64
  public let segments: [DoryPCPVHKernelSegment]

  public var physicalRanges: [Range<UInt64>] {
    segments.map { $0.physicalAddress..<($0.physicalAddress + $0.memorySize) }
  }

  public init(data: Data) throws {
    // A Data slice can have a nonzero startIndex; ELF offsets are always file-relative.
    let data = Data(data)
    guard data.count >= 64 else { throw DoryPCPVHKernelError.truncatedELF }
    guard Array(data[0..<4]) == [0x7F, 0x45, 0x4C, 0x46],
      data[4] == 2, data[5] == 1, data[6] == 1,
      Self.read(UInt16.self, from: data, at: 16) == 2,  // ET_EXEC; no dynamic relocation.
      Self.read(UInt16.self, from: data, at: 18) == 0x3E,
      Self.read(UInt32.self, from: data, at: 20) == 1,
      Self.read(UInt16.self, from: data, at: 52) == 64
    else {
      throw DoryPCPVHKernelError.unsupportedELF
    }

    let headerOffset = Self.read(UInt64.self, from: data, at: 32)
    let headerSize = Int(Self.read(UInt16.self, from: data, at: 54))
    let headerCount = Int(Self.read(UInt16.self, from: data, at: 56))
    guard headerOffset >= 64, headerSize == 56, headerCount > 0, headerCount != 0xFFFF,
      let headers = Self.range(
        offset: headerOffset, count: UInt64(headerSize) * UInt64(headerCount), limit: data.count
      )
    else {
      throw DoryPCPVHKernelError.invalidProgramHeaders
    }

    var parsedSegments: [DoryPCPVHKernelSegment] = []
    var entryPoint: UInt64?
    for index in 0..<headerCount {
      let offset = headers.lowerBound + index * headerSize
      let type = Self.read(UInt32.self, from: data, at: offset)
      let fileOffset = Self.read(UInt64.self, from: data, at: offset + 8)
      let fileSize = Self.read(UInt64.self, from: data, at: offset + 32)
      switch type {
      case 1:  // PT_LOAD
        let virtualAddress = Self.read(UInt64.self, from: data, at: offset + 16)
        let physicalAddress = Self.read(UInt64.self, from: data, at: offset + 24)
        let memorySize = Self.read(UInt64.self, from: data, at: offset + 40)
        let alignment = Self.read(UInt64.self, from: data, at: offset + 48)
        guard fileSize <= memorySize,
          fileSize == 0 || Self.range(offset: fileOffset, count: fileSize, limit: data.count) != nil,
          !physicalAddress.addingReportingOverflow(memorySize).overflow,
          !virtualAddress.addingReportingOverflow(memorySize).overflow,
          alignment <= 1
            || (alignment.nonzeroBitCount == 1 && virtualAddress % alignment == fileOffset % alignment)
        else {
          throw DoryPCPVHKernelError.invalidLoadSegment
        }
        // Zero-sized PT_LOAD entries have no image or overlap semantics.
        if memorySize > 0 {
          parsedSegments.append(
            .init(
              physicalAddress: physicalAddress, fileOffset: fileOffset,
              fileSize: fileSize, memorySize: memorySize
            ))
        }
      case 2, 3:  // PT_DYNAMIC/PT_INTERP require a runtime linker, not this boot contract.
        throw DoryPCPVHKernelError.unsupportedELF
      case 4:  // PT_NOTE; examine every record even after finding the entry point.
        guard fileOffset % 4 == 0,
          let noteRange = Self.range(offset: fileOffset, count: fileSize, limit: data.count)
        else {
          throw DoryPCPVHKernelError.invalidNotes
        }
        for value in try Self.physicalEntries(in: data, range: noteRange) {
          guard entryPoint == nil else { throw DoryPCPVHKernelError.duplicatePhysicalEntry }
          entryPoint = value
        }
      default:
        continue
      }
    }

    parsedSegments.sort { $0.physicalAddress < $1.physicalAddress }
    guard !parsedSegments.isEmpty else { throw DoryPCPVHKernelError.missingLoadSegment }
    for pair in zip(parsedSegments, parsedSegments.dropFirst()) {
      guard pair.0.physicalAddress + pair.0.memorySize <= pair.1.physicalAddress else {
        throw DoryPCPVHKernelError.overlappingLoadSegments
      }
    }
    guard let entryPoint else { throw DoryPCPVHKernelError.missingPhysicalEntry }
    // PVH starts with paging disabled. Linux's linker places .init.text in its RW data
    // PT_LOAD, so PF_X is not an entry requirement. The entry must name actual file bytes,
    // not a gap or zero-filled BSS. See Linux arch/x86/kernel/vmlinux.lds.S and PVH head.S.
    guard entryPoint > 0, entryPoint <= UInt64(UInt32.max),
      parsedSegments.contains(where: {
        entryPoint >= $0.physicalAddress && entryPoint - $0.physicalAddress < $0.fileSize
      })
    else {
      throw DoryPCPVHKernelError.invalidPhysicalEntry
    }
    self.data = data
    physicalEntryPoint = entryPoint
    segments = parsedSegments
  }

  /// Checks every segment without writing, so the machine can preflight all boot artifacts.
  public func validate(into memory: any DoryX86Memory) throws {
    do {
      for segment in segments {
        try memory.validateWrite(
          at: segment.physicalAddress, byteCount: try Self.integerCount(segment.memorySize)
        )
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHKernelError.guestMemoryRejected(error)
    }
  }

  public func load(into memory: any DoryX86Memory) throws {
    try validate(into: memory)
    do {
      let zeroChunk = [UInt8](repeating: 0, count: 64 * 1024)
      for segment in segments {
        var copied: UInt64 = 0
        while copied < segment.fileSize {
          let count = min(segment.fileSize - copied, UInt64(zeroChunk.count))
          let source = Self.range(offset: segment.fileOffset + copied, count: count, limit: data.count)!
          try memory.write(at: segment.physicalAddress + copied, bytes: Array(data[source]))
          copied += count
        }
        while copied < segment.memorySize {
          let count = Int(min(segment.memorySize - copied, UInt64(zeroChunk.count)))
          try memory.write(at: segment.physicalAddress + copied, bytes: Array(zeroChunk.prefix(count)))
          copied += UInt64(count)
        }
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHKernelError.guestMemoryRejected(error)
    }
  }

  private static func physicalEntries(in data: Data, range: Range<Int>) throws -> [UInt64] {
    var cursor = range.lowerBound
    var entries: [UInt64] = []
    while cursor < range.upperBound {
      guard range.upperBound - cursor >= 12 else { throw DoryPCPVHKernelError.invalidNotes }
      let nameSize = UInt64(read(UInt32.self, from: data, at: cursor))
      let descriptorSize = UInt64(read(UInt32.self, from: data, at: cursor + 4))
      let type = read(UInt32.self, from: data, at: cursor + 8)
      // x86 Xen/Linux ELF notes use 4-byte note alignment even in ELF64.
      let nameStart = UInt64(cursor) + 12
      let descriptorStart = (nameStart + nameSize + 3) & ~UInt64(3)
      let next = (descriptorStart + descriptorSize + 3) & ~UInt64(3)
      guard next <= UInt64(range.upperBound),
        let nameRange = Self.range(offset: nameStart, count: nameSize, limit: range.upperBound),
        nameSize == 0 || data[nameRange.upperBound - 1] == 0
      else { throw DoryPCPVHKernelError.invalidNotes }
      if type == 0x12, data[nameRange].elementsEqual([0x58, 0x65, 0x6E, 0]) {
        // Xen elfnote.h specifies 4/8-byte numeric notes; Linux ELF64 emits _ASM_PTR.
        guard descriptorSize == 4 || descriptorSize == 8 else {
          throw DoryPCPVHKernelError.invalidNotes
        }
        let value = descriptorSize == 4
          ? UInt64(read(UInt32.self, from: data, at: Int(descriptorStart)))
          : read(UInt64.self, from: data, at: Int(descriptorStart))
        guard value <= UInt64(UInt32.max) else { throw DoryPCPVHKernelError.invalidPhysicalEntry }
        entries.append(value)
      }
      cursor = Int(next)
    }
    return entries
  }

  private static func integerCount(_ value: UInt64) throws -> Int {
    guard value <= UInt64(Int.max) else { throw DoryPCPVHKernelError.invalidLoadSegment }
    return Int(value)
  }

  private static func range(offset: UInt64, count: UInt64, limit: Int) -> Range<Int>? {
    let end = offset.addingReportingOverflow(count)
    guard !end.overflow, end.partialValue <= UInt64(limit) else { return nil }
    return Int(offset)..<Int(end.partialValue)
  }

  private static func read<T: FixedWidthInteger>(
    _ type: T.Type, from data: Data, at offset: Int
  ) -> T {
    (0..<MemoryLayout<T>.size).reduce(0) {
      $0 | T(data[offset + $1]) << T($1 * 8)
    }
  }
}
