import Foundation
import Testing
@testable import DoryHV

@Suite struct PVHBootTests {
    @Test func startInfoSerializesLinuxPVHFieldsInOrder() {
        let image = PVHBootBuilder.build(
            commandLine: "console=ttyS0 panic=-1",
            commandLinePhysicalAddress: 0x0009_0000,
            modulesPhysicalAddress: 0x0009_1000,
            memoryMapPhysicalAddress: 0x0009_2000,
            modules: [PVHModule(physicalAddress: 0x0400_0000, size: 0x0080_0000)],
            memoryMap: [
                PVHMemoryMapEntry(address: 0, size: 0x0009_FC00, type: .ram),
                PVHMemoryMapEntry(address: 0x0010_0000, size: 0x3FF0_0000, type: .ram),
            ],
            rsdpPhysicalAddress: 0
        )

        #expect(image.startInfo.count == 56)
        #expect(le32(image.startInfo, 0) == PVHBootBuilder.magic)
        #expect(le32(image.startInfo, 4) == PVHBootBuilder.version)
        #expect(le32(image.startInfo, 8) == 0)
        #expect(le32(image.startInfo, 12) == 1)
        #expect(le64(image.startInfo, 16) == 0x0009_1000)
        #expect(le64(image.startInfo, 24) == 0x0009_0000)
        #expect(le64(image.startInfo, 32) == 0)
        #expect(le64(image.startInfo, 40) == 0x0009_2000)
        #expect(le32(image.startInfo, 48) == 2)
        #expect(le32(image.startInfo, 52) == 0)
    }

    @Test func commandLineIsNullTerminatedUtf8() {
        let image = PVHBootBuilder.build(
            commandLine: "console=ttyS0",
            commandLinePhysicalAddress: 0x90000,
            modulesPhysicalAddress: 0,
            memoryMapPhysicalAddress: 0x91000,
            modules: [],
            memoryMap: []
        )

        #expect(Array(image.commandLine) == Array("console=ttyS0".utf8) + [0])
    }

    @Test func emptyModuleListClearsModulePointer() {
        let image = PVHBootBuilder.build(
            commandLine: "",
            commandLinePhysicalAddress: 0x90000,
            modulesPhysicalAddress: 0x91000,
            memoryMapPhysicalAddress: 0x92000,
            modules: [],
            memoryMap: []
        )

        #expect(le32(image.startInfo, 12) == 0)
        #expect(le64(image.startInfo, 16) == 0)
        #expect(image.modules.isEmpty)
    }

    @Test func moduleEntriesAreThirtyTwoByteRecords() {
        let image = PVHBootBuilder.build(
            commandLine: "",
            commandLinePhysicalAddress: 0x90000,
            modulesPhysicalAddress: 0x91000,
            memoryMapPhysicalAddress: 0x92000,
            modules: [
                PVHModule(physicalAddress: 0x0400_0000, size: 0x0010_0000, commandLinePhysicalAddress: 0x93000),
                PVHModule(physicalAddress: 0x0500_0000, size: 0x0020_0000),
            ],
            memoryMap: []
        )

        #expect(image.modules.count == 64)
        #expect(le64(image.modules, 0) == 0x0400_0000)
        #expect(le64(image.modules, 8) == 0x0010_0000)
        #expect(le64(image.modules, 16) == 0x93000)
        #expect(le64(image.modules, 24) == 0)
        #expect(le64(image.modules, 32) == 0x0500_0000)
        #expect(le64(image.modules, 40) == 0x0020_0000)
        #expect(le64(image.modules, 48) == 0)
        #expect(le64(image.modules, 56) == 0)
    }

    @Test func memoryMapEntriesAreTwentyFourByteE820Records() {
        let image = PVHBootBuilder.build(
            commandLine: "",
            commandLinePhysicalAddress: 0x90000,
            modulesPhysicalAddress: 0,
            memoryMapPhysicalAddress: 0x92000,
            modules: [],
            memoryMap: [
                PVHMemoryMapEntry(address: 0x0000_0000, size: 0x0009_FC00, type: .ram),
                PVHMemoryMapEntry(address: 0x0009_FC00, size: 0x0000_0400, type: .reserved),
                PVHMemoryMapEntry(address: 0x0010_0000, size: 0x3FF0_0000, type: .ram),
            ]
        )

        #expect(image.memoryMap.count == 72)
        #expect(le64(image.memoryMap, 0) == 0)
        #expect(le64(image.memoryMap, 8) == 0x0009_FC00)
        #expect(le32(image.memoryMap, 16) == PVHMemoryMapEntry.EntryType.ram.rawValue)
        #expect(le32(image.memoryMap, 20) == 0)
        #expect(le64(image.memoryMap, 24) == 0x0009_FC00)
        #expect(le64(image.memoryMap, 32) == 0x0000_0400)
        #expect(le32(image.memoryMap, 40) == PVHMemoryMapEntry.EntryType.reserved.rawValue)
        #expect(le64(image.memoryMap, 48) == 0x0010_0000)
        #expect(le64(image.memoryMap, 56) == 0x3FF0_0000)
        #expect(le32(image.memoryMap, 64) == PVHMemoryMapEntry.EntryType.ram.rawValue)
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func le64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(data[offset])
            | (UInt64(data[offset + 1]) << 8)
            | (UInt64(data[offset + 2]) << 16)
            | (UInt64(data[offset + 3]) << 24)
            | (UInt64(data[offset + 4]) << 32)
            | (UInt64(data[offset + 5]) << 40)
            | (UInt64(data[offset + 6]) << 48)
            | (UInt64(data[offset + 7]) << 56)
    }
}
