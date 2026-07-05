import Foundation

public struct MPTableImage: Equatable, Sendable {
    public let floatingPointer: Data
    public let configurationTable: Data
}

/// Builds Intel MultiProcessor Specification tables for the x86 guest. Linux can discover CPUs,
/// the ISA bus, the IOAPIC, and virtio interrupt pins from these records before ACPI exists.
public enum MPTableBuilder {
    public static let localAPICAddress: UInt32 = 0xFEE0_0000
    public static let ioAPICAddress: UInt32 = 0xFEC0_0000
    public static let ioAPICID: UInt8 = 0x01

    public static func build(
        tablePhysicalAddress: UInt32,
        cpuCount: Int,
        virtioInterruptPins: [UInt8]
    ) -> MPTableImage {
        let configuration = configurationTable(cpuCount: cpuCount, virtioInterruptPins: virtioInterruptPins)
        return MPTableImage(
            floatingPointer: floatingPointer(tablePhysicalAddress: tablePhysicalAddress),
            configurationTable: configuration
        )
    }

    private static func floatingPointer(tablePhysicalAddress: UInt32) -> Data {
        var data = Data()
        data.appendASCII("_MP_")
        data.appendLE32(tablePhysicalAddress)
        data.append(UInt8(1))
        data.append(UInt8(4))
        data.append(UInt8(0))
        data.append(contentsOf: repeatElement(UInt8(0), count: 5))
        data[10] = checksumByte(for: data)
        return data
    }

    private static func configurationTable(cpuCount: Int, virtioInterruptPins: [UInt8]) -> Data {
        var entries = Data()
        for cpu in 0..<max(1, cpuCount) {
            entries.append(processorEntry(apicID: UInt8(cpu), bootstrap: cpu == 0))
        }
        entries.append(busEntry(busID: 0, type: "ISA"))
        entries.append(ioAPICEntry(id: ioAPICID, address: ioAPICAddress))
        for pin in virtioInterruptPins {
            entries.append(ioInterruptEntry(sourceBusID: 0, sourceIRQ: pin, ioAPICID: ioAPICID, ioAPICPin: pin))
        }

        var table = Data()
        table.appendASCII("PCMP")
        table.appendLE16(UInt16(44 + entries.count))
        table.append(UInt8(4))
        table.append(UInt8(0))
        table.appendPaddedASCII("DORY", count: 8)
        table.appendPaddedASCII("DORY-HV-X86", count: 12)
        table.appendLE32(0)
        table.appendLE16(0)
        table.appendLE16(UInt16(max(1, cpuCount) + 2 + virtioInterruptPins.count))
        table.appendLE32(localAPICAddress)
        table.appendLE16(0)
        table.append(UInt8(0))
        table.append(UInt8(0))
        table.append(entries)
        table[7] = checksumByte(for: table)
        return table
    }

    private static func processorEntry(apicID: UInt8, bootstrap: Bool) -> Data {
        var data = Data()
        data.append(UInt8(0))
        data.append(apicID)
        data.append(UInt8(0x14))
        data.append(UInt8(bootstrap ? 0x03 : 0x01))
        data.appendLE32(0x0000_06A0)
        data.appendLE32(0)
        data.appendLE32(0)
        data.appendLE32(0)
        return data
    }

    private static func busEntry(busID: UInt8, type: String) -> Data {
        var data = Data()
        data.append(UInt8(1))
        data.append(busID)
        data.appendPaddedASCII(type, count: 6)
        return data
    }

    private static func ioAPICEntry(id: UInt8, address: UInt32) -> Data {
        var data = Data()
        data.append(UInt8(2))
        data.append(id)
        data.append(UInt8(0x11))
        data.append(UInt8(0x01))
        data.appendLE32(address)
        return data
    }

    private static func ioInterruptEntry(sourceBusID: UInt8, sourceIRQ: UInt8, ioAPICID: UInt8, ioAPICPin: UInt8) -> Data {
        var data = Data()
        data.append(UInt8(3))
        data.append(UInt8(0))
        data.appendLE16(0)
        data.append(sourceBusID)
        data.append(sourceIRQ)
        data.append(ioAPICID)
        data.append(ioAPICPin)
        return data
    }

    private static func checksumByte(for data: Data) -> UInt8 {
        let sum = data.reduce(UInt8(0)) { partial, byte in partial &+ byte }
        return 0 &- sum
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendPaddedASCII(_ string: String, count: Int) {
        let bytes = Array(string.utf8.prefix(count))
        append(contentsOf: bytes)
        if bytes.count < count {
            append(contentsOf: repeatElement(UInt8(ascii: " "), count: count - bytes.count))
        }
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
