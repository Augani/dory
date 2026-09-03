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
  case missingPhysicalEntry
  case guestMemoryRejected(DoryX86MemoryError)
}

/// Strict parser and loader for an x86_64 ELF kernel carrying Xen's
/// `XEN_ELFNOTE_PHYS32_ENTRY` PVH note. It owns no host mappings and writes only through the
/// DoryDBT physical-memory boundary.
public struct DoryPCPVHKernelImage: Sendable, Hashable {
  public let data: Data
  public let physicalEntryPoint: UInt64
  public let segments: [DoryPCPVHKernelSegment]

  public init(data: Data) throws {
    guard data.count >= 64 else { throw DoryPCPVHKernelError.truncatedELF }
    guard Array(data[0..<4]) == [0x7F, 0x45, 0x4C, 0x46],
      data[4] == 2,
      data[5] == 1,
      data[6] == 1,
      Self.read(UInt16.self, from: data, at: 18) == 0x3E
    else {
      throw DoryPCPVHKernelError.unsupportedELF
    }

    let headerOffset = Self.read(UInt64.self, from: data, at: 32)
    let headerSize = Int(Self.read(UInt16.self, from: data, at: 54))
    let headerCount = Int(Self.read(UInt16.self, from: data, at: 56))
    guard headerSize >= 56,
      let headers = Self.range(
        offset: headerOffset,
        count: UInt64(headerSize).multipliedReportingOverflow(by: UInt64(headerCount)),
        limit: data.count
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
      case 1:
        // Linux kernel ELF segments carry canonical virtual addresses in p_paddr
        // (e.g. 0xffffffff81000000). For PVH boot the physical load address is
        // obtained by stripping the canonical sign-extension and the kernel
        // virtual base offset. The x86_64 kernel maps virtual
        // 0xffffffff80000000 to physical 0x00000000, so masking with
        // 0x7FFFFFFF recovers the physical address (0xffffffff81000000 ->
        // 0x1000000). Userspace ELF addresses pass through unchanged.
        let rawAddress = Self.read(UInt64.self, from: data, at: offset + 24)
        let physicalAddress =
          (rawAddress & (1 << 47)) != 0
          ? rawAddress & 0x7FFF_FFFF
          : rawAddress
        let memorySize = Self.read(UInt64.self, from: data, at: offset + 40)
        guard fileSize <= memorySize,
          Self.range(offset: fileOffset, count: (fileSize, false), limit: data.count) != nil,
          !physicalAddress.addingReportingOverflow(memorySize).overflow
        else {
          throw DoryPCPVHKernelError.invalidLoadSegment
        }
        parsedSegments.append(
          .init(
            physicalAddress: physicalAddress,
            fileOffset: fileOffset,
            fileSize: fileSize,
            memorySize: memorySize
          ))
      case 4:
        guard
          let noteRange = Self.range(
            offset: fileOffset,
            count: (fileSize, false),
            limit: data.count
          )
        else {
          throw DoryPCPVHKernelError.invalidProgramHeaders
        }
        entryPoint = entryPoint ?? Self.findPhysicalEntry(in: data, range: noteRange)
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
    self.data = data
    physicalEntryPoint = entryPoint
    segments = parsedSegments
  }

  public func load(into memory: any DoryX86Memory) throws {
    do {
      for segment in segments {
        try memory.validateWrite(
          at: segment.physicalAddress,
          byteCount: try Self.integerCount(segment.memorySize)
        )
      }
      for segment in segments {
        let source = Self.range(
          offset: segment.fileOffset,
          count: (segment.fileSize, false),
          limit: data.count
        )!
        try memory.write(at: segment.physicalAddress, bytes: Array(data[source]))
        var remaining = segment.memorySize - segment.fileSize
        var address = segment.physicalAddress + segment.fileSize
        let zeroChunk = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
          let count = Int(min(remaining, UInt64(zeroChunk.count)))
          try memory.write(at: address, bytes: Array(zeroChunk.prefix(count)))
          address += UInt64(count)
          remaining -= UInt64(count)
        }
      }
      // Also load SHF_ALLOC sections not covered by any PT_LOAD segment.
      // Some kernel builds (e.g. Linux PVH) place critical boot data like
      // the PVH load-address constant in the .notes section, which has
      // SHF_ALLOC but may fall in a gap between PT_LOAD segments.
      for section in try uncoveredAllocSections() {
        let source = Self.range(
          offset: section.fileOffset,
          count: (section.fileSize, false),
          limit: data.count
        )!
        try memory.write(at: section.physicalAddress, bytes: Array(data[source]))
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHKernelError.guestMemoryRejected(error)
    }
  }

  private struct UncoveredSection {
    let physicalAddress: UInt64
    let fileOffset: UInt64
    let fileSize: UInt64
  }

  private func uncoveredAllocSections() throws -> [UncoveredSection] {
    guard data.count >= 64 else { return [] }
    let sectionHeaderOffset = Self.read(UInt64.self, from: data, at: 40)
    let sectionHeaderSize = Int(Self.read(UInt16.self, from: data, at: 58))
    let sectionHeaderCount = Int(Self.read(UInt16.self, from: data, at: 60))
    guard sectionHeaderSize >= 40, sectionHeaderCount > 0,
      let headers = Self.range(
        offset: sectionHeaderOffset,
        count: UInt64(sectionHeaderSize).multipliedReportingOverflow(by: UInt64(sectionHeaderCount)),
        limit: data.count
      )
    else { return [] }

    let SHF_ALLOC: UInt64 = 0x2
    var result: [UncoveredSection] = []
    for index in 0..<sectionHeaderCount {
      let offset = headers.lowerBound + index * sectionHeaderSize
      let flags = Self.read(UInt64.self, from: data, at: offset + 8)
      guard flags & SHF_ALLOC != 0 else { continue }
      let virtualAddress = Self.read(UInt64.self, from: data, at: offset + 16)
      guard virtualAddress != 0 else { continue }
      let fileOffset = Self.read(UInt64.self, from: data, at: offset + 24)
      let fileSize = Self.read(UInt64.self, from: data, at: offset + 32)
      guard fileSize > 0 else { continue }
      let physicalAddress =
        (virtualAddress & (1 << 47)) != 0
        ? virtualAddress & 0x7FFF_FFFF
        : virtualAddress
      let sectionEnd = physicalAddress.addingReportingOverflow(fileSize)
      guard !sectionEnd.overflow else { continue }
      let covered = segments.contains { segment in
        segment.physicalAddress <= physicalAddress
          && sectionEnd.partialValue <= segment.physicalAddress + segment.memorySize
      }
      guard !covered else { continue }
      guard Self.range(
        offset: fileOffset,
        count: (fileSize, false),
        limit: data.count
      ) != nil else { continue }
      result.append(
        .init(physicalAddress: physicalAddress, fileOffset: fileOffset, fileSize: fileSize))
    }
    return result
  }

  private static func findPhysicalEntry(in data: Data, range: Range<Int>) -> UInt64? {
    var cursor = range.lowerBound
    while cursor <= range.upperBound - 12 {
      let nameSize = Int(read(UInt32.self, from: data, at: cursor))
      let descriptorSize = Int(read(UInt32.self, from: data, at: cursor + 4))
      let type = read(UInt32.self, from: data, at: cursor + 8)
      let nameStart = cursor + 12
      let nameEnd = nameStart.addingReportingOverflow(nameSize)
      guard !nameEnd.overflow else { return nil }
      let descriptorStart = Self.align4(nameEnd.partialValue)
      let descriptorEnd = descriptorStart.addingReportingOverflow(descriptorSize)
      guard !descriptorEnd.overflow,
        nameEnd.partialValue <= range.upperBound,
        descriptorEnd.partialValue <= range.upperBound
      else { return nil }
      let name = data[nameStart..<nameEnd.partialValue].prefix { $0 != 0 }
      if type == 0x12, name.elementsEqual("Xen".utf8), descriptorSize >= 4 {
        return UInt64(read(UInt32.self, from: data, at: descriptorStart))
      }
      cursor = Self.align4(descriptorEnd.partialValue)
    }
    return nil
  }

  private static func align4(_ value: Int) -> Int { (value + 3) & ~3 }

  private static func integerCount(_ value: UInt64) throws -> Int {
    guard value <= UInt64(Int.max) else { throw DoryPCPVHKernelError.invalidLoadSegment }
    return Int(value)
  }

  private static func range(
    offset: UInt64,
    count: (partialValue: UInt64, overflow: Bool),
    limit: Int
  ) -> Range<Int>? {
    guard !count.overflow else { return nil }
    return range(offset: offset, count: count.partialValue, limit: limit)
  }

  private static func range(offset: UInt64, count: UInt64, limit: Int) -> Range<Int>? {
    let end = offset.addingReportingOverflow(count)
    guard !end.overflow, end.partialValue <= UInt64(limit), end.partialValue <= UInt64(Int.max)
    else { return nil }
    return Int(offset)..<Int(end.partialValue)
  }

  private static func read<T: FixedWidthInteger>(
    _ type: T.Type,
    from data: Data,
    at offset: Int
  ) -> T {
    (0..<MemoryLayout<T>.size).reduce(0) {
      $0 | T(data[offset + $1]) << T($1 * 8)
    }
  }
}
