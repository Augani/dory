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
  case commandLineTooLong(Int)
  case tooManyMemoryMapEntries(Int)
  case invalidMemoryMapEntry(Int)
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

  public func install(into memory: any DoryX86Memory) throws {
    let artifacts: [(UInt64, [UInt8])] = [
      (layout.startInfo, startInfo),
      (layout.commandLine, commandLine),
      (layout.modules, modules),
      (layout.memoryMap, memoryMap),
      (layout.initrd, initrd),
    ].filter { !$0.1.isEmpty }
    do {
      for artifact in artifacts {
        try memory.validateWrite(at: artifact.0, byteCount: artifact.1.count)
      }
      for artifact in artifacts {
        try memory.write(at: artifact.0, bytes: artifact.1)
      }
    } catch let error as DoryX86MemoryError {
      throw DoryPCPVHBootError.guestMemoryRejected(error)
    }
  }

  public func initialState(entryPoint: UInt64) throws -> DoryX86ArchitecturalState {
    try DoryX86ArchitecturalState(
      registers: .init(rbx: layout.startInfo, rsp: 0x8000),
      rip: entryPoint,
      rflags: .reset,
      cs: .init(selector: 0x08, attributes: 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      es: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      fs: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      gs: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      control: .init(cr0: 0x21, xcr0: 1)
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
    let commandLineBytes = Array(commandLine.utf8) + [0]
    guard commandLineBytes.count <= maximumCommandLineBytes else {
      throw DoryPCPVHBootError.commandLineTooLong(commandLineBytes.count)
    }
    guard memoryMap.count <= maximumMemoryMapEntries else {
      throw DoryPCPVHBootError.tooManyMemoryMapEntries(memoryMap.count)
    }
    for (index, entry) in memoryMap.enumerated() {
      guard entry.size > 0, !entry.address.addingReportingOverflow(entry.size).overflow else {
        throw DoryPCPVHBootError.invalidMemoryMapEntry(index)
      }
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
    return .init(
      layout: layout,
      startInfo: startInfo,
      commandLine: commandLineBytes,
      modules: moduleBytes,
      memoryMap: memoryMapBytes,
      initrd: initrd
    )
  }

  public static func memoryMap(memoryBytes: UInt64) -> [DoryPCMemoryMapEntry] {
    let ramTop = min(memoryBytes, DoryPCV1Layout.mmioHoleStart)
    let highSize =
      ramTop > DoryPCV1Layout.highRAMStart ? ramTop - DoryPCV1Layout.highRAMStart : 0
    return [
      .init(address: 0, size: DoryPCV1Layout.lowRAMEnd, kind: .ram),
      .init(
        address: DoryPCV1Layout.pvhStartInfo,
        size: DoryPCV1Layout.lowReservedEnd - DoryPCV1Layout.pvhStartInfo,
        kind: .reserved
      ),
      .init(address: DoryPCV1Layout.highRAMStart, size: highSize, kind: .ram),
    ].filter { $0.size > 0 }
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
