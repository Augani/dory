import Foundation
import Testing
@testable import DoryHV

@Suite struct X86BootPlanTests {
    @Test func commandLineUsesSerialConsoleReliableTscAndVirtioMmioDevices() {
        let plan = X86BootPlanBuilder.build(
            baseCommandLine: "root=/dev/vda rw panic=0 init=/init",
            memoryBytes: 1024 * 1024 * 1024,
            virtioDeviceCount: 3
        )

        #expect(plan.commandLine.hasPrefix("console=ttyS0 earlyprintk=serial,ttyS0,115200 clocksource=tsc tsc=reliable "))
        #expect(plan.commandLine.contains("root=/dev/vda rw panic=0 init=/init"))
        #expect(plan.commandLine.contains("virtio_mmio.device=4096@0xd0000000:16"))
        #expect(plan.commandLine.contains("virtio_mmio.device=4096@0xd0001000:17"))
        #expect(plan.commandLine.contains("virtio_mmio.device=4096@0xd0002000:18"))
    }

    @Test func virtioDevicesFollowGuestLayoutSlotStrideAndIrqPins() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 512 * 1024 * 1024, virtioDeviceCount: 4)

        #expect(plan.virtioDevices.map(\.slot) == [0, 1, 2, 3])
        #expect(plan.virtioDevices.map(\.baseAddress) == [
            X86GuestLayout.virtioBase,
            X86GuestLayout.virtioBase + X86GuestLayout.virtioSlotSize,
            X86GuestLayout.virtioBase + 2 * X86GuestLayout.virtioSlotSize,
            X86GuestLayout.virtioBase + 3 * X86GuestLayout.virtioSlotSize,
        ])
        #expect(plan.virtioDevices.map(\.size) == Array(repeating: X86GuestLayout.virtioSlotSize, count: 4))
        #expect(plan.virtioDevices.map(\.irq) == [16, 17, 18, 19])
    }

    @Test func virtioIrqsCanFeedMPTableWithoutRemapping() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 512 * 1024 * 1024, virtioDeviceCount: 2)
        let mp = MPTableBuilder.build(
            tablePhysicalAddress: 0x000F_1000,
            cpuCount: 1,
            virtioInterruptPins: plan.virtioDevices.map(\.irq)
        )

        let firstInterrupt = 44 + 20 + 8 + 8
        #expect(mp.configurationTable[firstInterrupt + 5] == 16)
        #expect(mp.configurationTable[firstInterrupt + 7] == 16)
        #expect(mp.configurationTable[firstInterrupt + 8 + 5] == 17)
        #expect(mp.configurationTable[firstInterrupt + 8 + 7] == 17)
    }

    @Test func memoryMapSplitsLowMemoryHoleAndHighRam() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 1024 * 1024 * 1024, virtioDeviceCount: 0)

        #expect(plan.memoryMap == [
            PVHMemoryMapEntry(address: 0, size: 0x0009_0000, type: .ram),
            PVHMemoryMapEntry(address: 0x0009_0000, size: 0x0001_0000, type: .reserved),
            PVHMemoryMapEntry(address: X86GuestLayout.ramBase, size: 1024 * 1024 * 1024 - X86GuestLayout.ramBase, type: .ram),
        ])
    }

    @Test func smallMemoryConfigurationsOmitEmptyHighRamEntry() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 512 * 1024, virtioDeviceCount: 0)

        #expect(plan.memoryMap == [
            PVHMemoryMapEntry(address: 0, size: 0x0009_0000, type: .ram),
            PVHMemoryMapEntry(address: 0x0009_0000, size: 0x0001_0000, type: .reserved),
        ])
    }

    @Test func highMemoryNeverCrossesTheVirtioMmioHole() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 8 * 1024 * 1024 * 1024, virtioDeviceCount: 0)
        let highRam = plan.memoryMap.last

        #expect(highRam?.type == .ram)
        #expect((highRam?.address ?? 0) + (highRam?.size ?? 0) <= X86GuestLayout.mmioHoleBase)
    }

    @Test func negativeVirtioCountIsTreatedAsNoDevices() {
        let plan = X86BootPlanBuilder.build(memoryBytes: 512 * 1024 * 1024, virtioDeviceCount: -1)

        #expect(plan.virtioDevices.isEmpty)
        #expect(!plan.commandLine.contains("virtio_mmio.device="))
    }
}
