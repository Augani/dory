import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCBootPreflightTests {
  @Test func planAcceptsValidELFAndReportsKernelAndBootRanges() throws {
    let plan = try DoryPCBootPreflight.plan(
      kernel: makeELF(),
      commandLine: "console=ttyS0",
      memoryBytes: 2 << 20
    )
    #expect(plan.entryPoint == 0x10_0000)
    #expect(plan.kernelSegments == [
      .init(physicalAddress: 0x10_0000, fileOffset: 0x200, fileSize: 4, memorySize: 16)
    ])
    #expect(plan.kernelRanges == [0x10_0000..<0x10_0010])
    // The default PVH layout places start info, command line, modules, and the memory map in the
    // reserved handoff region; with no initrd, only those four artifacts appear.
    #expect(plan.bootArtifactRanges.count == 4)
    #expect(plan.bootArtifactRanges.contains(DoryPCV1ABI.pvhStartInfo..<DoryPCV1ABI.pvhStartInfo + 56))
    #expect(plan.bootArtifactRanges.allSatisfy { $0.lowerBound >= DoryPCV1ABI.pvhStartInfo })
  }

  @Test func planAcceptsInitrdWithinRAMAndReportsItsRange() throws {
    let plan = try DoryPCBootPreflight.plan(
      kernel: makeELF(),
      initrd: [0xAA, 0xBB, 0xCC],
      commandLine: "console=ttyS0",
      memoryBytes: 512 << 20
    )
    #expect(plan.bootArtifactRanges.contains(0x1000_0000..<0x1000_0003))
  }

  @Test func planRejectsInvalidMemorySizeBeforeParsingELF() {
    for count in [0, 1_048_577, Int.max] {
      #expect(throws: DoryPCMachineError.invalidMemorySize(count)) {
        _ = try DoryPCBootPreflight.plan(kernel: makeELF(), memoryBytes: count)
      }
    }
  }

  @Test func planRejectsTruncatedELFHeader() {
    #expect(throws: DoryPCPVHKernelError.truncatedELF) {
      _ = try DoryPCBootPreflight.plan(
        kernel: Data(repeating: 0, count: 63), memoryBytes: 2 << 20
      )
    }
  }

  @Test func planRejectsWrongELFClassEndiannessAndISA() {
    for offset in [4, 5, 6, 18] {
      var data = makeELF()
      data[offset] = 0
      #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
        _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
      }
    }
    var bigEndian = makeELF()
    bigEndian[5] = 2  // ELFDATA2MSB
    #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
      _ = try DoryPCBootPreflight.plan(kernel: bigEndian, memoryBytes: 2 << 20)
    }
    var wrongISA = makeELF()
    write(UInt16(0x28), to: &wrongISA, at: 18)  // EM_ARM
    #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
      _ = try DoryPCBootPreflight.plan(kernel: wrongISA, memoryBytes: 2 << 20)
    }
    var wrongClass = makeELF()
    wrongClass[4] = 1  // ELFCLASS32
    #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
      _ = try DoryPCBootPreflight.plan(kernel: wrongClass, memoryBytes: 2 << 20)
    }
  }

  @Test func planRejectsOversizedAndUnboundedProgramHeaderTable() {
    for count: UInt16 in [0, 0xFFFF] {
      var data = makeELF()
      write(count, to: &data, at: 56)
      #expect(throws: DoryPCPVHKernelError.invalidProgramHeaders) {
        _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
      }
    }
    var overflowing = makeELF()
    write(UInt64.max, to: &overflowing, at: 32)  // e_phoff past file end
    #expect(throws: DoryPCPVHKernelError.invalidProgramHeaders) {
      _ = try DoryPCBootPreflight.plan(kernel: overflowing, memoryBytes: 2 << 20)
    }
  }

  @Test func planRejectsOverflowingFileAndVirtualSegmentRanges() {
    for field in [0x48, 0x50, 0x58, 0x68] {
      var data = makeELF()
      write(UInt64.max, to: &data, at: field)
      #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
        _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
      }
    }
  }

  @Test func planRejectsBadSegmentAlignment() {
    for alignment: UInt64 in [3, 0x1000] {
      var data = makeELF()
      write(alignment, to: &data, at: 0x70)
      #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
        _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
      }
    }
  }

  @Test func planRejectsEntryOutsideExecutableLoadRegion() {
    for entry: UInt64 in [0, 0xF_FFFF, 0x10_0004, 0x10_0008, 0x1_0010_0000] {
      #expect(throws: DoryPCPVHKernelError.invalidPhysicalEntry) {
        _ = try DoryPCBootPreflight.plan(
          kernel: makeELF(entry: entry, descriptorSize: 8), memoryBytes: 2 << 20
        )
      }
    }
    #expect(throws: DoryPCPVHKernelError.missingPhysicalEntry) {
      _ = try DoryPCBootPreflight.plan(kernel: makeELF(entry: nil), memoryBytes: 2 << 20)
    }
  }

  @Test func planRejectsKernelSegmentOutsideRAM() {
    // Place a load segment at 0x9E000, inside the reserved handoff hole, not in any RAM entry.
    var data = makeELF()
    write(UInt16(3), to: &data, at: 56)
    writeProgramHeader(
      to: &data, at: 0xB0, type: 1, fileOffset: 0x300,
      physicalAddress: 0x9E000, fileSize: 4, memorySize: 16
    )
    data.replaceSubrange(0x300..<0x304, with: [0xD0, 0x12, 0x34, 0x56])
    #expect(throws: DoryPCMachineError.bootArtifactOutsideRAM) {
      _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
    }
  }

  @Test func planRejectsBSSExtendingPastRAMBoundary() {
    // memorySize extends beyond the 2 MiB RAM top while the file-backed portion stays in RAM.
    let data = makeELF(memorySize: (2 << 20) - 0x10_0000 + 1)
    #expect(throws: DoryPCMachineError.bootArtifactOutsideRAM) {
      _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
    }
  }

  @Test func planRejectsKernelOverlapWithReservedLowMemory() {
    // Place each PT_LOAD segment (and its PVH entry) inside low RAM at an address that overlaps
    // one of the direct-loader's reserved low-memory ranges (first page, initial stack). The
    // segment is genuinely RAM-contained, so it passes the RAM-containment check and reaches the
    // overlap check, which rejects the kernel/reserved overlap.
    for loadAddress: UInt64 in [0x100, 0x7800] {
      #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
        _ = try DoryPCBootPreflight.plan(
          kernel: makeELF(entry: loadAddress, loadAddress: loadAddress), memoryBytes: 2 << 20
        )
      }
    }
  }

  @Test func planRejectsInitrdOverlapWithKernel() {
    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      _ = try DoryPCBootPreflight.plan(
        kernel: makeELF(),
        initrd: [1, 2, 3],
        commandLine: "x",
        memoryBytes: 2 << 20,
        bootLayout: .init(initrd: 0x10_0000)
      )
    }
  }

  @Test func planRejectsKernelOverlapWithPVHHandoff() {
    // The default PVH handoff sits in a reserved memory region that no RAM-contained kernel can
    // overlap; a kernel placed there fails RAM containment before the overlap check. Place a
    // handoff artifact (command line) in high RAM at the kernel's load address using a custom
    // layout so the kernel range genuinely overlaps a boot artifact and reaches the overlap check.
    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      _ = try DoryPCBootPreflight.plan(
        kernel: makeELF(),
        commandLine: "x",
        memoryBytes: 2 << 20,
        bootLayout: .init(commandLine: 0x10_0000)
      )
    }
  }

  @Test func planRejectsCommandLineLimitExceeded() {
    #expect(throws: DoryPCPVHBootError.commandLineTooLong(4097)) {
      _ = try DoryPCBootPreflight.plan(
        kernel: makeELF(),
        commandLine: String(repeating: "é", count: 2048),
        memoryBytes: 2 << 20
      )
    }
  }

  @Test func planRejectsEmptyAndEmbeddedNULCommandLine() {
    #expect(throws: DoryPCPVHBootError.emptyCommandLine) {
      _ = try DoryPCBootPreflight.plan(kernel: makeELF(), commandLine: "", memoryBytes: 2 << 20)
    }
    #expect(throws: DoryPCPVHBootError.embeddedCommandLineNUL) {
      _ = try DoryPCBootPreflight.plan(
        kernel: makeELF(), commandLine: "console=ttyS0\0init=/wrong", memoryBytes: 2 << 20
      )
    }
  }

  @Test func planNeverMasksHighPhysicalAddressesThatExceedRAM() throws {
    var data = makeELF()
    write(UInt16(3), to: &data, at: 56)
    let highAddress: UInt64 = 0xFFFF_FFFF_8110_0000
    writeProgramHeader(
      to: &data, at: 0xB0, type: 1, fileOffset: 0x300,
      physicalAddress: highAddress, fileSize: 4, memorySize: 4
    )
    data.replaceSubrange(0x300..<0x304, with: [0xD0, 0x12, 0x34, 0x56])
    // The ELF parser accepts the high address, but preflight rejects it because the segment is
    // not contained within any RAM entry of the 2 MiB memory map.
    #expect(throws: DoryPCMachineError.bootArtifactOutsideRAM) {
      _ = try DoryPCBootPreflight.plan(kernel: data, memoryBytes: 2 << 20)
    }
  }

  @Test func directKernelLoadStillAcceptsValidFixtureThroughPreflightIntegration() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 << 20)
    try machine.load(kernel: makeELF(), commandLine: "x")
    #expect(machine.state?.rip == 0x10_0000)
  }

  // MARK: - ELF fixture builder

  private func makeELF(
    entry: UInt64? = 0x10_0000,
    loadAddress: UInt64 = 0x10_0000,
    fileSize: UInt64 = 4,
    memorySize: UInt64 = 16,
    descriptorSize: UInt64 = 4
  ) -> Data {
    var data = Data(repeating: 0, count: 0x400)
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    write(UInt16(2), to: &data, at: 16)  // ET_EXEC
    write(UInt16(0x3E), to: &data, at: 18)  // EM_X86_64
    write(UInt32(1), to: &data, at: 20)  // EV_CURRENT
    write(UInt64(0x40), to: &data, at: 32)  // e_phoff
    write(UInt16(64), to: &data, at: 52)  // e_ehsize
    write(UInt16(56), to: &data, at: 54)  // e_phentsize
    write(UInt16(2), to: &data, at: 56)  // e_phnum
    writeProgramHeader(
      to: &data, at: 0x40, type: 1, fileOffset: 0x200,
      physicalAddress: loadAddress, fileSize: fileSize, memorySize: memorySize
    )
    let noteSize = entry == nil ? 0 : 16 + descriptorSize
    writeProgramHeader(
      to: &data, at: 0x78, type: 4, fileOffset: 0x180,
      physicalAddress: 0, fileSize: noteSize, memorySize: noteSize
    )
    if let entry {
      write(UInt32(4), to: &data, at: 0x180)
      write(UInt32(descriptorSize), to: &data, at: 0x184)
      write(UInt32(0x12), to: &data, at: 0x188)  // XEN_ELFNOTE_PHYS32_ENTRY
      data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])  // "xen\0"
      write(entry, to: &data, at: 0x190)
    }
    data.replaceSubrange(0x200..<0x204, with: [1, 2, 3, 4])
    return data
  }

  private func writeProgramHeader(
    to data: inout Data, at offset: Int, type: UInt32,
    fileOffset: UInt64, physicalAddress: UInt64, fileSize: UInt64, memorySize: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(UInt32(type == 1 ? 5 : 0), to: &data, at: offset + 4)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 16)
    write(physicalAddress, to: &data, at: offset + 24)
    write(fileSize, to: &data, at: offset + 32)
    write(memorySize, to: &data, at: offset + 40)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
