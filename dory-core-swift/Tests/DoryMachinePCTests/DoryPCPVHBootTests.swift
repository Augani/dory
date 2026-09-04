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
    let memory = DoryX86ByteArrayMemory(byteCount: 0x30_000)

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
    #expect(state.control.cr0 == 0x21)
    #expect(state.cs.selector == 0x08)
  }

  @Test func freezesTheDoryPCV1LowMemoryMap() {
    let map = DoryPCPVHBootBuilder.memoryMap(memoryBytes: 512 * 1024 * 1024)

    #expect(map[0] == .init(address: 0, size: 0x90000, kind: .ram))
    #expect(map[1] == .init(address: 0x90000, size: 0x70000, kind: .reserved))
    #expect(map.count == 3)
    #expect(map[2].address == 0x10_0000)
    #expect(map[2].size == 511 * 1024 * 1024)
  }

  @Test func remapsRAMHiddenByTheDoryPCV1MMIOHoleAboveFourGiB() {
    let memoryBytes: UInt64 = 4 << 30
    let map = DoryPCPVHBootBuilder.memoryMap(memoryBytes: memoryBytes)

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
      memoryMap: [.init(address: 0, size: 0x1000, kind: .ram)],
      layout: .init(
        startInfo: 0x100,
        commandLine: 0x200,
        modules: 0x300,
        memoryMap: 0x400,
        initrd: 0x2000
      )
    )
    let memory = DoryX86ByteArrayMemory(byteCount: 0x1000)
    #expect(throws: DoryPCPVHBootError.self) { try image.install(into: memory) }
    #expect(try memory.read(at: 0x100, byteCount: 4) == [0, 0, 0, 0])
  }

  private func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
  }

  private func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
  }
}
