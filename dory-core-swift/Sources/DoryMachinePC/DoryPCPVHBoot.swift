import DoryDBTX86
import Foundation

public enum DoryPCV1Layout {
  public static let pvhStartInfo = DoryPCV1ABI.pvhStartInfo
  public static let pvhCommandLine = DoryPCV1ABI.pvhCommandLine
  public static let pvhModules = DoryPCV1ABI.pvhModules
  public static let pvhMemoryMap = DoryPCV1ABI.pvhMemoryMap
  public static let lowRAMEnd = DoryPCV1ABI.lowRAMEnd
  public static let lowReservedEnd = DoryPCV1ABI.lowReservedEnd
  public static let highRAMStart = DoryPCV1ABI.highRAMStart
  public static let initrd = DoryPCV1ABI.directKernelInitrd
  public static let mmioHoleStart = DoryPCV1ABI.mmioHoleStart
}

public struct DoryPCPVHBootLayout: Codable, Sendable, Hashable {
  public let startInfo: UInt64
  public let commandLine: UInt64
  public let modules: UInt64
  public let memoryMap: UInt64
  public let initrd: UInt64

  public init(
    startInfo: UInt64 = DoryPCV1Layout.pvhStartInfo,
    commandLine: UInt64 = DoryPCV1Layout.pvhCommandLine,
    modules: UInt64 = DoryPCV1Layout.pvhModules,
    memoryMap: UInt64 = DoryPCV1Layout.pvhMemoryMap,
    initrd: UInt64 = DoryPCV1Layout.initrd
  ) {
    self.startInfo = startInfo
    self.commandLine = commandLine
    self.modules = modules
    self.memoryMap = memoryMap
    self.initrd = initrd
  }
}

public struct DoryPCMemoryMapEntry: Codable, Sendable, Hashable {
  public enum Kind: UInt32, Codable, Sendable, Hashable {
    case ram = 1
    case reserved = 2
    case acpi = 3
    case nvs = 4
    case unusable = 5
  }

  public let address: UInt64
  public let size: UInt64
  public let kind: Kind

  public init(address: UInt64, size: UInt64, kind: Kind) {
    self.address = address
    self.size = size
    self.kind = kind
  }
}

public enum DoryPCPVHBootError: Error, Sendable, Equatable {
  case emptyCommandLine
  case embeddedCommandLineNUL
  case commandLineTooLong(Int)
  case missingRAMMemoryMap
  case tooManyMemoryMapEntries(Int)
  case invalidMemoryMapEntry(Int)
  case overlappingMemoryMapEntries
  case invalidMemorySize(UInt64)
  case invalidArtifactAddress(UInt64)
  case artifactOutsideUsableMemory(UInt64)
  case invalidEntryPoint(UInt64)
  case overlappingArtifacts
  case guestMemoryRejected(DoryX86MemoryError)
}

public struct DoryPCPVHBootImage: Sendable, Hashable {
  public let layout: DoryPCPVHBootLayout
  public let startInfo: [UInt8]
  public let commandLine: [UInt8]
  public let modules: [UInt8]
  public let memoryMap: [UInt8]
  public let initrd: [UInt8]
  public let physicalRanges: [Range<UInt64>]

  private var artifacts: [(UInt64, [UInt8])] {
    [
      (layout.startInfo, startInfo),
      (layout.commandLine, commandLine),
      (layout.modules, modules),
      (layout.memoryMap, memoryMap),
      (layout.initrd, initrd),
    ].filter { !$0.1.isEmpty }
  }

  /// Checks all writes without mutation, for the machine's combined boot preflight.
  public func validate(into memory: any DoryX86Memory) throws {
    do {
      for artifact in artifacts {
        try memory.validateWrite(at: artifact.0, byteCount: artifact.1.count)
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHBootError.guestMemoryRejected(error)
    }
  }

  public func install(into memory: any DoryX86Memory) throws {
    try validate(into: memory)
    do {
      for artifact in artifacts {
        try memory.write(at: artifact.0, bytes: artifact.1)
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHBootError.guestMemoryRejected(error)
    }
  }

  public func initialState(entryPoint: UInt64) throws -> DoryX86ArchitecturalState {
    guard entryPoint > 0, entryPoint <= UInt64(UInt32.max) else {
      throw DoryPCPVHBootError.invalidEntryPoint(entryPoint)
    }
    return try DoryX86ArchitecturalState(
      registers: .init(rbx: layout.startInfo, rsp: 0x8000),
      rip: entryPoint,
      rflags: .reset,
      cs: .init(selector: 0x08, attributes: 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      es: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      fs: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      gs: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      // The PVH ABI requires an active 32-bit TSS cache, even before the guest loads a GDT.
      tr: .init(selector: 0x18, attributes: 0x008B, limit: 0x67),
      // PE plus the architectural read-only ET bit; writable NE/PG/TS/EM bits are clear.
      control: .init(cr0: 0x11, xcr0: 1)
    )
  }
}

public enum DoryPCPVHBootBuilder {
  public static let maximumCommandLineBytes = 4_096
  public static let maximumMemoryMapEntries = 128
  public static let magic: UInt32 = 0x336E_C578
  public static let version: UInt32 = 1

  public static func build(
    commandLine: String,
    initrd: [UInt8] = [],
    memoryMap: [DoryPCMemoryMapEntry],
    layout: DoryPCPVHBootLayout = .init(),
    rsdpPhysicalAddress: UInt64 = 0
  ) throws -> DoryPCPVHBootImage {
    guard !commandLine.isEmpty else { throw DoryPCPVHBootError.emptyCommandLine }
    guard !commandLine.utf8.contains(0) else { throw DoryPCPVHBootError.embeddedCommandLineNUL }
    guard commandLine.utf8.count < maximumCommandLineBytes else {
      throw DoryPCPVHBootError.commandLineTooLong(commandLine.utf8.count + 1)
    }
    let commandLineBytes = Array(commandLine.utf8) + [0]
    guard memoryMap.count <= maximumMemoryMapEntries else {
      throw DoryPCPVHBootError.tooManyMemoryMapEntries(memoryMap.count)
    }
    for (index, entry) in memoryMap.enumerated() {
      guard entry.size > 0, !entry.address.addingReportingOverflow(entry.size).overflow else {
        throw DoryPCPVHBootError.invalidMemoryMapEntry(index)
      }
    }
    let sortedMap = memoryMap.sorted { $0.address < $1.address }
    for pair in zip(sortedMap, sortedMap.dropFirst()) {
      guard pair.0.address + pair.0.size <= pair.1.address else {
        throw DoryPCPVHBootError.overlappingMemoryMapEntries
      }
    }
    guard memoryMap.contains(where: { $0.kind == .ram }) else {
      throw DoryPCPVHBootError.missingRAMMemoryMap
    }

    var moduleBytes: [UInt8] = []
    if !initrd.isEmpty {
      append(layout.initrd, to: &moduleBytes)
      append(UInt64(initrd.count), to: &moduleBytes)
      append(UInt64(0), to: &moduleBytes)
      append(UInt64(0), to: &moduleBytes)
    }
    var memoryMapBytes: [UInt8] = []
    for entry in memoryMap {
      append(entry.address, to: &memoryMapBytes)
      append(entry.size, to: &memoryMapBytes)
      append(entry.kind.rawValue, to: &memoryMapBytes)
      append(UInt32(0), to: &memoryMapBytes)
    }

    var startInfo: [UInt8] = []
    append(magic, to: &startInfo)
    append(version, to: &startInfo)
    append(UInt32(0), to: &startInfo)
    append(UInt32(initrd.isEmpty ? 0 : 1), to: &startInfo)
    append(initrd.isEmpty ? UInt64(0) : layout.modules, to: &startInfo)
    append(layout.commandLine, to: &startInfo)
    append(rsdpPhysicalAddress, to: &startInfo)
    append(layout.memoryMap, to: &startInfo)
    append(UInt32(memoryMap.count), to: &startInfo)
    append(UInt32(0), to: &startInfo)

    let ranges = try artifactRanges(
      layout: layout,
      startInfo: startInfo,
      commandLine: commandLineBytes,
      modules: moduleBytes,
      memoryMap: memoryMapBytes,
      initrd: initrd
    )
    for pair in zip(ranges, ranges.dropFirst()) where pair.0.overlaps(pair.1) {
      throw DoryPCPVHBootError.overlappingArtifacts
    }
    for range in ranges {
      // Linux's 32-bit PVH handoff truncates command-line and initrd addresses into
      // boot_params. Keep every supplied boot artifact addressable before paging.
      guard range.lowerBound > 0, range.upperBound <= DoryPCV1ABI.above4GRAMStart else {
        throw DoryPCPVHBootError.invalidArtifactAddress(range.lowerBound)
      }
      let isInitrd = !initrd.isEmpty && range.lowerBound == layout.initrd
      let handoff = DoryPCV1ABI.pvhStartInfo..<(DoryPCV1ABI.pvhStartInfo + DoryPCV1ABI.pvhHandoffBytes)
      let inHandoff = !isInitrd
        && handoff.lowerBound <= range.lowerBound && range.upperBound <= handoff.upperBound
      let lowReservation = DoryPCV1ABI.lowRAMEnd..<DoryPCV1ABI.highRAMStart
      guard (!range.overlaps(lowReservation) || inHandoff),
        range.upperBound <= DoryPCV1ABI.mmioHoleStart
      else { throw DoryPCPVHBootError.artifactOutsideUsableMemory(range.lowerBound) }
      let allowedEntries = sortedMap.filter { entry in
        entry.kind == .ram
          || (inHandoff && entry.kind == .reserved)
      }
      // Allow contiguous RAM entries, but never bridge an absent or reserved region.
      var coveredEnd = range.lowerBound
      for entry in allowedEntries where entry.address <= coveredEnd {
        let end = entry.address + entry.size
        if end > coveredEnd { coveredEnd = end }
        if coveredEnd >= range.upperBound { break }
      }
      guard coveredEnd >= range.upperBound else {
        throw DoryPCPVHBootError.artifactOutsideUsableMemory(range.lowerBound)
      }
    }
    return .init(
      layout: layout,
      startInfo: startInfo,
      commandLine: commandLineBytes,
      modules: moduleBytes,
      memoryMap: memoryMapBytes,
      initrd: initrd,
      physicalRanges: ranges
    )
  }

  public static func memoryMap(memoryBytes: UInt64) throws -> [DoryPCMemoryMapEntry] {
    let lowRAMTop = min(memoryBytes, DoryPCV1Layout.mmioHoleStart)
    let lowHighSize =
      lowRAMTop > DoryPCV1Layout.highRAMStart
      ? lowRAMTop - DoryPCV1Layout.highRAMStart : 0
    let above4GSize =
      memoryBytes > DoryPCV1Layout.mmioHoleStart
      ? memoryBytes - DoryPCV1Layout.mmioHoleStart : 0
    guard !DoryPCV1ABI.above4GRAMStart.addingReportingOverflow(above4GSize).overflow else {
      throw DoryPCPVHBootError.invalidMemorySize(memoryBytes)
    }
    let lowReservedTop = min(memoryBytes, DoryPCV1Layout.highRAMStart)
    var entries: [DoryPCMemoryMapEntry] = [
      .init(address: 0, size: min(memoryBytes, DoryPCV1Layout.lowRAMEnd), kind: .ram),
      .init(
        address: DoryPCV1Layout.pvhStartInfo,
        size: lowReservedTop > DoryPCV1Layout.pvhStartInfo
          ? lowReservedTop - DoryPCV1Layout.pvhStartInfo : 0,
        kind: .reserved
      ),
      .init(address: DoryPCV1Layout.highRAMStart, size: lowHighSize, kind: .ram),
    ]
    if above4GSize > 0 {
      // Mark the MMIO hole (PCIe ECAM + MMIO base) as reserved.
      entries.append(
        .init(
          address: DoryPCV1Layout.mmioHoleStart,
          size: DoryPCV1ABI.above4GRAMStart - DoryPCV1Layout.mmioHoleStart,
          kind: .reserved
        ))
      entries.append(
        .init(address: DoryPCV1ABI.above4GRAMStart, size: above4GSize, kind: .ram))
    }
    return entries.filter { $0.size > 0 }
  }

  private static func artifactRanges(
    layout: DoryPCPVHBootLayout,
    startInfo: [UInt8],
    commandLine: [UInt8],
    modules: [UInt8],
    memoryMap: [UInt8],
    initrd: [UInt8]
  ) throws -> [Range<UInt64>] {
    try [
      (layout.startInfo, startInfo.count),
      (layout.commandLine, commandLine.count),
      (layout.modules, modules.count),
      (layout.memoryMap, memoryMap.count),
      (layout.initrd, initrd.count),
    ].filter { $0.1 > 0 }.map { address, count in
      let end = address.addingReportingOverflow(UInt64(count))
      guard !end.overflow else { throw DoryPCPVHBootError.overlappingArtifacts }
      return address..<end.partialValue
    }.sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for index in 0..<MemoryLayout<T>.size {
      bytes.append(UInt8(truncatingIfNeeded: value >> T(index * 8)))
    }
  }
}
