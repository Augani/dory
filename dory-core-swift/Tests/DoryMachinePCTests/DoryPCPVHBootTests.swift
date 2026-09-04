import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPVHBootTests {
  @Test func serializesInstallsAndEntersThePVHHandoff() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x1000,
      commandLine: 0x1100,
      modules: 0x1200,
      memoryMap: 0x1300,
      initrd: 0x2000
    )
    let image = try DoryPCPVHBootBuilder.build(
      commandLine: "console=ttyS0",
      initrd: [0xAA, 0xBB, 0xCC],
      memoryMap: [.init(address: 0, size: 0x10_0000, kind: .ram)],
      layout: layout
    )
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x30_000)

    try image.install(into: memory)
    let state = try image.initialState(entryPoint: 0x10_0020)

    #expect(read32(image.startInfo, at: 0) == DoryPCPVHBootBuilder.magic)
    #expect(read32(image.startInfo, at: 12) == 1)
    #expect(read64(image.startInfo, at: 16) == layout.modules)
    #expect(read64(image.startInfo, at: 24) == layout.commandLine)
    #expect(read64(image.startInfo, at: 40) == layout.memoryMap)
    #expect(try memory.read(at: layout.initrd, byteCount: 3) == [0xAA, 0xBB, 0xCC])
    #expect(state.rip == 0x10_0020)
    #expect(state.registers.rbx == layout.startInfo)
    #expect(state.control.cr0 == 0x11)
    #expect(state.control.cr4 == 0)
    #expect(state.control.efer == 0)
    #expect(state.cs.selector == 0x08)
    #expect(state.cs.attributes == 0xC09B)
    #expect(state.cs.base == 0)
    #expect(state.cs.limit == .max)
    #expect(state.tr == .init(selector: 0x18, attributes: 0x008B, limit: 0x67))
    #expect(state.rflags.rawValue & ((1 << 17) | (1 << 9) | (1 << 8)) == 0)
  }

  @Test func freezesTheDoryPCV1LowMemoryMap() throws {
    let map = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: 512 * 1024 * 1024)

    #expect(map[0] == .init(address: 0, size: 0x90000, kind: .ram))
    #expect(map[1] == .init(address: 0x90000, size: 0x70000, kind: .reserved))
    #expect(map.count == 3)
    #expect(map[2].address == 0x10_0000)
    #expect(map[2].size == 511 * 1024 * 1024)
  }

  @Test func remapsRAMHiddenByTheDoryPCV1MMIOHoleAboveFourGiB() throws {
    let memoryBytes: UInt64 = 4 << 30
    let map = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: memoryBytes)

    #expect(map[2].address == DoryPCV1ABI.highRAMStart)
    #expect(
      map[2].size
        == DoryPCV1ABI.mmioHoleStart - DoryPCV1ABI.highRAMStart
    )
    #expect(
      map[3]
        == .init(
          address: DoryPCV1ABI.mmioHoleStart,
          size: DoryPCV1ABI.above4GRAMStart - DoryPCV1ABI.mmioHoleStart,
          kind: .reserved
        )
    )
    #expect(map.count == 5)
    #expect(
      map[4]
        == .init(
          address: DoryPCV1ABI.above4GRAMStart,
          size: memoryBytes - DoryPCV1ABI.mmioHoleStart,
          kind: .ram
        )
    )
  }

  @Test func rejectsOverlappingArtifactsAndPreflightsBeforeInstallation() throws {
    let overlapping = DoryPCPVHBootLayout(
      startInfo: 0x1000,
      commandLine: 0x1010,
      modules: 0x1200,
      memoryMap: 0x1300,
      initrd: 0x2000
    )
    #expect(throws: DoryPCPVHBootError.overlappingArtifacts) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "console=ttyS0",
        memoryMap: [.init(address: 0, size: 0x1000, kind: .ram)],
        layout: overlapping
      )
    }

    let image = try DoryPCPVHBootBuilder.build(
      commandLine: "console=ttyS0",
      initrd: [1, 2, 3],
      memoryMap: [.init(address: 0, size: 0x3000, kind: .ram)],
      layout: .init(
        startInfo: 0x100,
        commandLine: 0x200,
        modules: 0x300,
        memoryMap: 0x400,
        initrd: 0x2000
      )
    )
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    #expect(throws: DoryPCPVHBootError.self) { try image.install(into: memory) }
    #expect(try memory.read(at: 0x100, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func clampsLowMemoryAndRejectsRemapOverflow() throws {
    #expect(try DoryPCPVHBootBuilder.memoryMap(memoryBytes: 0).isEmpty)
    for bytes: UInt64 in [1, 0x80000, 0x90000] {
      #expect(
        try DoryPCPVHBootBuilder.memoryMap(memoryBytes: bytes)
          == [.init(address: 0, size: bytes, kind: .ram)])
    }
    #expect(
      try DoryPCPVHBootBuilder.memoryMap(memoryBytes: 0x91000) == [
        .init(address: 0, size: 0x90000, kind: .ram),
        .init(address: 0x90000, size: 0x1000, kind: .reserved),
      ])
    #expect(throws: DoryPCPVHBootError.invalidMemorySize(.max)) {
      _ = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: .max)
    }
    #expect(throws: DoryPCPVHBootError.artifactOutsideUsableMemory(0x91000)) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x", memoryMap: DoryPCPVHBootBuilder.memoryMap(memoryBytes: 0x91000))
    }
  }

  @Test func rejectsMissingOverlappingAndOverflowingMemoryMaps() {
    for map: [DoryPCMemoryMapEntry] in [[], [.init(address: 0, size: 0x200000, kind: .reserved)]] {
      #expect(throws: DoryPCPVHBootError.missingRAMMemoryMap) {
        _ = try DoryPCPVHBootBuilder.build(commandLine: "x", memoryMap: map)
      }
    }
    for entry: DoryPCMemoryMapEntry in [
      .init(address: 0, size: 0, kind: .ram),
      .init(address: .max, size: 1, kind: .ram),
    ] {
      #expect(throws: DoryPCPVHBootError.invalidMemoryMapEntry(0)) {
        _ = try DoryPCPVHBootBuilder.build(commandLine: "x", memoryMap: [entry])
      }
    }
    #expect(throws: DoryPCPVHBootError.overlappingMemoryMapEntries) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x",
        memoryMap: [
          .init(address: 0x90000, size: 0x1000, kind: .reserved),
          .init(address: 0, size: 0x200000, kind: .ram),
        ])
    }
  }

  @Test func rejectsEmbeddedNULAndCountsUTF8CommandLineBytes() throws {
    let map = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: 0x200000)
    #expect(throws: DoryPCPVHBootError.embeddedCommandLineNUL) {
      _ = try DoryPCPVHBootBuilder.build(commandLine: "console=ttyS0\0init=/wrong", memoryMap: map)
    }
    #expect(throws: DoryPCPVHBootError.commandLineTooLong(4097)) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: String(repeating: "é", count: 2048), memoryMap: map)
    }
    let image = try DoryPCPVHBootBuilder.build(
      commandLine: String(repeating: "é", count: 2047) + "x", memoryMap: map)
    #expect(image.commandLine.count == 4096)
    #expect(image.commandLine.last == 0)
  }

  @Test func rejectsNullAndTruncatedPointersAndOverflowingArtifacts() throws {
    let map = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: 0x200000)
    for address: UInt64 in [0, 0x1_0000_0000] {
      #expect(throws: DoryPCPVHBootError.invalidArtifactAddress(address)) {
        _ = try DoryPCPVHBootBuilder.build(
          commandLine: "x", memoryMap: map, layout: .init(startInfo: address))
      }
    }
    #expect(throws: DoryPCPVHBootError.overlappingArtifacts) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x", memoryMap: map, layout: .init(commandLine: .max))
    }
    let image = try DoryPCPVHBootBuilder.build(commandLine: "x", memoryMap: map)
    for entry: UInt64 in [0, 0x1_0000_0000] {
      #expect(throws: DoryPCPVHBootError.invalidEntryPoint(entry)) {
        _ = try image.initialState(entryPoint: entry)
      }
    }
  }

  @Test func rejectsFirmwareAndInitrdReservedMemoryEvenWhenMislabelledRAM() {
    let claimedRAM: [DoryPCMemoryMapEntry] = [.init(address: 0, size: 1 << 32, kind: .ram)]
    for address in [DoryPCV1ABI.acpiBase, DoryPCV1ABI.smbiosBase, DoryPCV1ABI.pcieMMIOBase] {
      #expect(throws: DoryPCPVHBootError.artifactOutsideUsableMemory(address)) {
        _ = try DoryPCPVHBootBuilder.build(
          commandLine: "x", memoryMap: claimedRAM, layout: .init(commandLine: address))
      }
    }
    #expect(throws: DoryPCPVHBootError.artifactOutsideUsableMemory(0x94000)) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x", initrd: [1], memoryMap: claimedRAM, layout: .init(initrd: 0x94000))
    }
  }

  @Test func rejectsInitrdCrossingRAMBoundaryAndAcceptsAdjacentRAMEntries() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x1000, commandLine: 0x1100, modules: 0x1200, memoryMap: 0x1300, initrd: 0x1FFF)
    let low: DoryPCMemoryMapEntry = .init(address: 0, size: 0x2000, kind: .ram)
    #expect(throws: DoryPCPVHBootError.artifactOutsideUsableMemory(0x1FFF)) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x", initrd: [1, 2], memoryMap: [low], layout: layout)
    }
    let image = try DoryPCPVHBootBuilder.build(
      commandLine: "x", initrd: [1, 2],
      memoryMap: [.init(address: 0x2000, size: 0x1000, kind: .ram), low], layout: layout)
    #expect(image.physicalRanges.contains(0x1FFF..<0x2001))
    #expect(throws: DoryPCPVHBootError.artifactOutsideUsableMemory(0x1FFF)) {
      _ = try DoryPCPVHBootBuilder.build(
        commandLine: "x", initrd: [1, 2],
        memoryMap: [low, .init(address: 0x2000, size: 0x1000, kind: .reserved)], layout: layout)
    }
  }

  private func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
  }

  private func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
  }
}
