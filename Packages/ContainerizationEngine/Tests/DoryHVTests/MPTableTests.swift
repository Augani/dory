import Foundation
import Testing
@testable import DoryHV

@Suite struct MPTableTests {
    @Test func floatingPointerReferencesConfigTableAndChecksumsToZero() {
        let image = MPTableBuilder.build(tablePhysicalAddress: 0x000F_1000, cpuCount: 2, virtioInterruptPins: [16, 17])

        #expect(Array(image.floatingPointer[0..<4]) == Array("_MP_".utf8))
        #expect(le32(image.floatingPointer, 4) == 0x000F_1000)
        #expect(image.floatingPointer[8] == 1)
        #expect(image.floatingPointer[9] == 4)
        #expect(checksum(image.floatingPointer) == 0)
    }

    @Test func configurationHeaderCarriesExpectedIdentityAndChecksum() {
        let image = MPTableBuilder.build(tablePhysicalAddress: 0x000F_1000, cpuCount: 2, virtioInterruptPins: [16, 17, 18])

        #expect(Array(image.configurationTable[0..<4]) == Array("PCMP".utf8))
        #expect(le16(image.configurationTable, 4) == image.configurationTable.count)
        #expect(image.configurationTable[6] == 4)
        #expect(String(decoding: image.configurationTable[8..<16], as: UTF8.self) == "DORY    ")
        #expect(String(decoding: image.configurationTable[16..<28], as: UTF8.self) == "DORY-HV-X86 ")
        #expect(le16(image.configurationTable, 34) == 7)  // 2 CPUs + ISA bus + IOAPIC + 3 INT entries
        #expect(le32(image.configurationTable, 36) == MPTableBuilder.localAPICAddress)
        #expect(checksum(image.configurationTable) == 0)
    }

    @Test func processorBusAndIoApicEntriesAreSerializedInOrder() {
        let image = MPTableBuilder.build(tablePhysicalAddress: 0x000F_1000, cpuCount: 2, virtioInterruptPins: [16])
        let table = image.configurationTable

        var offset = 44
        #expect(table[offset] == 0)
        #expect(table[offset + 1] == 0)
        #expect(table[offset + 3] == 0x03)
        offset += 20

        #expect(table[offset] == 0)
        #expect(table[offset + 1] == 1)
        #expect(table[offset + 3] == 0x01)
        offset += 20

        #expect(table[offset] == 1)
        #expect(table[offset + 1] == 0)
        #expect(String(decoding: table[(offset + 2)..<(offset + 8)], as: UTF8.self) == "ISA   ")
        offset += 8

        #expect(table[offset] == 2)
        #expect(table[offset + 1] == MPTableBuilder.ioAPICID)
        #expect(table[offset + 3] == 0x01)
        #expect(le32(table, offset + 4) == MPTableBuilder.ioAPICAddress)
    }

    @Test func virtioInterruptEntriesMapSourceIrqToMatchingIoApicPin() {
        let image = MPTableBuilder.build(tablePhysicalAddress: 0x000F_1000, cpuCount: 1, virtioInterruptPins: [16, 17, 23])
        let table = image.configurationTable
        var offset = 44 + 20 + 8 + 8

        for pin in [UInt8(16), UInt8(17), UInt8(23)] {
            #expect(table[offset] == 3)
            #expect(table[offset + 1] == 0)
            #expect(le16(table, offset + 2) == 0)
            #expect(table[offset + 4] == 0)
            #expect(table[offset + 5] == pin)
            #expect(table[offset + 6] == MPTableBuilder.ioAPICID)
            #expect(table[offset + 7] == pin)
            offset += 8
        }
    }

    @Test func atLeastOneProcessorIsAlwaysAdvertised() {
        let image = MPTableBuilder.build(tablePhysicalAddress: 0x000F_1000, cpuCount: 0, virtioInterruptPins: [])

        #expect(le16(image.configurationTable, 34) == 3)
        #expect(image.configurationTable[44] == 0)
        #expect(image.configurationTable[45] == 0)
    }

    private func checksum(_ data: Data) -> UInt8 {
        data.reduce(UInt8(0)) { partial, byte in partial &+ byte }
    }

    private func le16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
