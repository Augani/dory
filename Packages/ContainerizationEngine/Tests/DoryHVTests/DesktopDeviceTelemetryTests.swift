import Foundation
import Testing
@testable import DoryHV
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

    @Test func publishesMeasuredStorageFlushesAndSlowFlushEvents() throws {
        let path = NSTemporaryDirectory() + "/dory-storage-telemetry-\(UUID().uuidString).img"
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [UInt64] = [100, 500]

            func next() -> UInt64 {
                lock.withLock { values.removeFirst() }
            }
        }
        let clock = Clock()
        let backend = try VirtioBlk(
            path: path,
            identity: "storage",
            queueCount: 1,
            flushTelemetry: VirtioBlkFlushTelemetryConfiguration(
                slowThresholdNanoseconds: 400,
                synchronize: { _ in 0 },
                monotonicNanoseconds: { clock.next() }
            )
        )
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-storage", operationID: UUID())
        registry.register(slot: 2, backend: backend, transport: transport)

        #expect(backend.flush() == .ok)
        let snapshot = registry.snapshot()
        let storage = try #require(snapshot.devices.first)
        #expect(storage.id == "virtio-storage-2")
        #expect(storage.health == .degraded)
        #expect(storage.metrics.first { $0.kind == .storageFlushes }?.value == 1)
        #expect(storage.metrics.first {
            $0.kind == .maximumStorageFlushLatencyNanoseconds
        }?.value == 400)
        #expect(snapshot.events.map(\.kind) == [.storageFlushSlow])
        #expect(snapshot.events.first?.occurrences == 1)

        let stable = registry.snapshot()
        #expect(stable.devices.first?.health == .healthy)
        #expect(stable.events.map(\.kind) == [.storageFlushSlow])
    }

    @Test func publishesMeasuredAudioDropsAndClassifiedEvents() throws {
        let audio = DoryMacAudioBackend(log: { _ in })
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: 8,
            periodBytes: 4,
            sampleRate: 48_000,
            channels: 2
        )
        #expect(audio.configure(streamID: 0, direction: .output, parameters: parameters))
        #expect(audio.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })
        #expect(audio.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })
        #expect(!audio.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })

        let backend = VirtioSound(host: audio)
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-audio", operationID: UUID())
        registry.register(
            slot: 4,
            backend: backend,
            transport: transport,
            audioMetrics: { [weak audio] in audio?.runtimeMetrics }
        )

        let snapshot = registry.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(device.id == "virtio-audio-4")
        #expect(device.health == .degraded)
        #expect(device.metrics.first { $0.kind == .audioDrops }?.value == 1)
        #expect(snapshot.events.map(\.kind) == [.audioDrop])
        #expect(snapshot.events.first?.occurrences == 1)

        let stable = registry.snapshot()
        #expect(stable.devices.first?.health == .healthy)
        #expect(stable.events.map(\.kind) == [.audioDrop])
    }
}
