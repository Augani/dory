import DoryHV
import Foundation
import Testing
@testable import dory_hv

@Suite struct DesktopDeviceTelemetryTests {
    private final class SilentDevice: VirtioDeviceBackend {
        let deviceID: UInt32 = 0x7fff
        let deviceFeatures: UInt64 = 0
        let queueCount = 1
        let configSpace = [UInt8]()

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {}
    }

    @Test func derivesBoundedResetAndSustainedQueueStallEvents() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let backend = SilentDevice()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let operationID = UUID()
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-dev", operationID: operationID)
        registry.register(slot: 7, backend: backend, transport: transport)

        let baseline = registry.snapshot()
        #expect(baseline.isValid)
        #expect(baseline.events.isEmpty)
        #expect(baseline.devices.first?.health == .healthy)

        transport.write(offset: 0x050, value: 0, width: 4)
        _ = registry.snapshot()
        _ = registry.snapshot()
        let stalled = registry.snapshot()
        #expect(stalled.isValid)
        #expect(stalled.devices.first?.health == .degraded)
        #expect(stalled.events.map(\.kind) == [.queueStall])
        #expect(stalled.events.first?.deviceID == "virtio-platform-7")

        transport.notifyUsed()
        let recovered = registry.snapshot()
        #expect(recovered.devices.first?.health == .healthy)
        #expect(recovered.events.map(\.kind) == [.queueStall])

        transport.write(offset: 0x070, value: 0, width: 4)
        let reset = registry.snapshot()
        #expect(reset.isValid)
        #expect(reset.devices.first?.health == .degraded)
        #expect(reset.events.map(\.kind) == [.queueStall, .reset])
        #expect(reset.events.last?.occurrences == 1)

        var bounded = reset
        for _ in 0..<300 {
            transport.write(offset: 0x070, value: 0, width: 4)
            bounded = registry.snapshot()
        }
        #expect(bounded.isValid)
        #expect(bounded.events.count == 256)
        #expect(bounded.events.first?.sequence == 47)
        #expect(bounded.events.last?.sequence == 302)
    }
}
