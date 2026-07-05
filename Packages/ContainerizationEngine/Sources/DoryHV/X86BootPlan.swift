import Foundation

public struct X86VirtioMMIODevice: Equatable, Sendable {
    public let slot: Int
    public let baseAddress: UInt64
    public let size: UInt64
    public let irq: UInt8

    public init(slot: Int, baseAddress: UInt64, size: UInt64, irq: UInt8) {
        self.slot = slot
        self.baseAddress = baseAddress
        self.size = size
        self.irq = irq
    }

    public var kernelArgument: String {
        "virtio_mmio.device=\(size)@0x\(String(baseAddress, radix: 16)):\(irq)"
    }
}

public struct X86BootPlan: Equatable, Sendable {
    public let commandLine: String
    public let memoryMap: [PVHMemoryMapEntry]
    public let virtioDevices: [X86VirtioMMIODevice]
}

public enum X86GuestLayout {
    public static let uartBase: UInt64 = 0x3F8
    public static let uartIRQ: UInt8 = 4
    public static let rtcBase: UInt64 = 0x70
    public static let virtioBase: UInt64 = 0xD000_0000
    public static let virtioSlotSize: UInt64 = 0x1000
    public static let virtioFirstIRQ: UInt8 = 16
    public static let ramBase: UInt64 = 0x0010_0000
    public static let mmioHoleBase: UInt64 = virtioBase
    public static let pvhStartInfo: UInt64 = 0x0009_0000
    public static let pvhCommandLine: UInt64 = 0x0009_1000
    public static let pvhModules: UInt64 = 0x0009_2000
    public static let pvhMemoryMap: UInt64 = 0x0009_3000
    public static let mpFloatingPointer: UInt64 = 0x000F_0000
    public static let mpConfigurationTable: UInt64 = 0x000F_1000
    public static let daxWindowBase: UInt64 = 0xC_0000_0000
}

/// Produces the x86 Linux boot contract shared by PVH metadata, MPTABLE IRQ entries, and the
/// kernel command line. Keeping all three derived from one slot list prevents the easy-to-miss
/// class of bugs where a virtio IRQ is advertised differently in different boot surfaces.
public enum X86BootPlanBuilder {
    public static let lowMemoryEnd: UInt64 = X86GuestLayout.pvhStartInfo
    public static let lowReservedStart: UInt64 = X86GuestLayout.pvhStartInfo
    public static let lowReservedSize: UInt64 = 0x000A_0000 - X86GuestLayout.pvhStartInfo

    public static func build(
        baseCommandLine: String = "root=/dev/vda rw panic=0",
        memoryBytes: UInt64,
        virtioDeviceCount: Int
    ) -> X86BootPlan {
        let virtioDevices = (0..<max(0, virtioDeviceCount)).map { slot in
            X86VirtioMMIODevice(
                slot: slot,
                baseAddress: X86GuestLayout.virtioBase + UInt64(slot) * X86GuestLayout.virtioSlotSize,
                size: X86GuestLayout.virtioSlotSize,
                irq: UInt8(truncatingIfNeeded: UInt32(X86GuestLayout.virtioFirstIRQ) + UInt32(slot))
            )
        }
        let commandLine = commandLine(baseCommandLine: baseCommandLine, virtioDevices: virtioDevices)
        return X86BootPlan(
            commandLine: commandLine,
            memoryMap: memoryMap(memoryBytes: memoryBytes),
            virtioDevices: virtioDevices
        )
    }

    public static func commandLine(baseCommandLine: String, virtioDevices: [X86VirtioMMIODevice]) -> String {
        ([
            "console=ttyS0",
            "earlyprintk=serial,ttyS0,115200",
            "clocksource=tsc",
            "tsc=reliable",
            baseCommandLine,
        ] + virtioDevices.map(\.kernelArgument))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func memoryMap(memoryBytes: UInt64) -> [PVHMemoryMapEntry] {
        let ramTop = min(memoryBytes, X86GuestLayout.mmioHoleBase)
        let highMemorySize = ramTop > X86GuestLayout.ramBase ? ramTop - X86GuestLayout.ramBase : 0
        return [
            PVHMemoryMapEntry(address: 0, size: lowMemoryEnd, type: .ram),
            PVHMemoryMapEntry(address: lowReservedStart, size: lowReservedSize, type: .reserved),
            PVHMemoryMapEntry(address: X86GuestLayout.ramBase, size: highMemorySize, type: .ram),
        ].filter { $0.size > 0 }
    }
}
