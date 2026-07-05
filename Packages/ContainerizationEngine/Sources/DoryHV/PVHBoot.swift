import Foundation

public struct PVHMemoryMapEntry: Equatable, Sendable {
    public enum EntryType: UInt32, Sendable {
        case ram = 1
        case reserved = 2
        case acpi = 3
        case nvs = 4
        case unusable = 5
    }

    public let address: UInt64
    public let size: UInt64
    public let type: EntryType

    public init(address: UInt64, size: UInt64, type: EntryType) {
        self.address = address
        self.size = size
        self.type = type
    }
}

public struct PVHModule: Equatable, Sendable {
    public let physicalAddress: UInt64
    public let size: UInt64
    public let commandLinePhysicalAddress: UInt64

    public init(physicalAddress: UInt64, size: UInt64, commandLinePhysicalAddress: UInt64 = 0) {
        self.physicalAddress = physicalAddress
        self.size = size
        self.commandLinePhysicalAddress = commandLinePhysicalAddress
    }
}

public struct PVHBootImage: Equatable, Sendable {
    public let startInfo: Data
    public let commandLine: Data
    public let modules: Data
    public let memoryMap: Data
}

/// Serializes the Xen PVH direct-boot handoff used by Linux's `CONFIG_PVH` entry point. The x86
/// vCPU starts with EBX pointing at `hvm_start_info`, and the guest follows the physical pointers
/// in that structure to discover the command line, initrd modules, and E820 memory map.
public enum PVHBootBuilder {
    public static let magic: UInt32 = 0x336E_C578
    public static let version: UInt32 = 1

    public static func build(
        commandLine: String,
        commandLinePhysicalAddress: UInt64,
        modulesPhysicalAddress: UInt64,
        memoryMapPhysicalAddress: UInt64,
        modules: [PVHModule],
        memoryMap: [PVHMemoryMapEntry],
        rsdpPhysicalAddress: UInt64 = 0
    ) -> PVHBootImage {
        let commandLineBytes = Data(commandLine.utf8 + [0])
        let moduleBytes = serializeModules(modules)
        let memoryMapBytes = serializeMemoryMap(memoryMap)

        var start = Data()
        start.appendLE32(magic)
        start.appendLE32(version)
        start.appendLE32(0)
        start.appendLE32(UInt32(modules.count))
        start.appendLE64(modules.isEmpty ? 0 : modulesPhysicalAddress)
        start.appendLE64(commandLinePhysicalAddress)
        start.appendLE64(rsdpPhysicalAddress)
        start.appendLE64(memoryMapPhysicalAddress)
        start.appendLE32(UInt32(memoryMap.count))
        start.appendLE32(0)

        return PVHBootImage(
            startInfo: start,
            commandLine: commandLineBytes,
            modules: moduleBytes,
            memoryMap: memoryMapBytes
        )
    }

    private static func serializeModules(_ modules: [PVHModule]) -> Data {
        var data = Data()
        for module in modules {
            data.appendLE64(module.physicalAddress)
            data.appendLE64(module.size)
            data.appendLE64(module.commandLinePhysicalAddress)
            data.appendLE64(0)
        }
        return data
    }

    private static func serializeMemoryMap(_ entries: [PVHMemoryMapEntry]) -> Data {
        var data = Data()
        for entry in entries {
            data.appendLE64(entry.address)
            data.appendLE64(entry.size)
            data.appendLE32(entry.type.rawValue)
            data.appendLE32(0)
        }
        return data
    }
}

private extension Data {
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLE64(_ value: UInt64) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 56) & 0xFF))
    }
}
