import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryFSWorkerServiceCore
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

    @Test func networkDiagnosticsPreserveEveryBoundedDatapathCounter() {
        let metrics = RawDeviceTelemetryRegistry.networkMetrics(VirtioNetStatistics(
            transmitPackets: 1,
            transmitBytes: 2,
            transmitDrops: 3,
            transmitMalformed: 4,
            transmitOversized: 5,
            transmitInvalidDescriptors: 6,
            transmitBackpressure: 7,
            receivePackets: 8,
            receiveBytes: 9,
            receiveDeferred: 10,
            receiveDrops: 11,
            receiveTruncations: 12,
            receiveMalformed: 13,
            receiveInvalidDescriptors: 14,
            receiveInsufficientCapacity: 15,
            receiveBacklogDrops: 16,
            receiveInactiveDrops: 17,
            receiveSocketErrors: 18,
            receiveActivationFailures: 19
        ))

        #expect(metrics.count == 19)
        #expect(Set(metrics.map(\.kind)).count == metrics.count)
        #expect(metrics.allSatisfy { $0.isValid })
        #expect(Dictionary(uniqueKeysWithValues: metrics.compactMap { metric in
            metric.value.map { (metric.kind, $0) }
        }) == [
            .transmittedFrames: 1,
            .transmittedBytes: 2,
            .transmitDrops: 3,
            .transmitMalformed: 4,
            .transmitOversized: 5,
            .transmitInvalidDescriptors: 6,
            .transmitBackpressure: 7,
            .receivedFrames: 8,
            .receivedBytes: 9,
            .receiveDeferred: 10,
            .receiveDrops: 11,
            .receiveTruncations: 12,
            .receiveMalformed: 13,
            .receiveInvalidDescriptors: 14,
            .receiveInsufficientCapacity: 15,
            .receiveBacklogDrops: 16,
            .receiveInactiveDrops: 17,
            .receiveSocketErrors: 18,
            .receiveActivationFailures: 19,
        ])
    }

    @Test func inputDiagnosticsPreserveEveryDeviceOwnedCounterAndGauge() {
        let metrics = RawDeviceTelemetryRegistry.inputMetrics(VirtioInputStatistics(
            submittedFrames: 1,
            publishedFrames: 2,
            publishedEvents: 3,
            coalescedMotionFrames: 4,
            droppedFrames: 5,
            rejectedFrames: 6,
            stateReconciliationEvents: 7,
            invalidEventBuffers: 8,
            invalidStatusBuffers: 9,
            statusEvents: 10,
            queueFaults: 11,
            boundedDrainStops: 12,
            workerTurns: 13,
            workerYields: 14,
            coalescedWorkerRequests: 15,
            revokedWorkerTurns: 16,
            pendingFrameSaturationEvents: 17,
            pendingFrameDepth: 18,
            pendingFrameHighWatermark: 19,
            availableEventBufferDepth: 20,
            availableEventBufferHighWatermark: 21,
            eventQueueDepth: 22,
            eventQueueHighWatermark: 23,
            statusQueueDepth: 24,
            statusQueueHighWatermark: 25,
            publicationLatencyNanoseconds: 26,
            maximumPublicationLatencyNanoseconds: 27
        ))

        #expect(metrics.count == 27)
        #expect(Set(metrics.map(\.kind)).count == metrics.count)
        #expect(metrics.allSatisfy { $0.isValid })
        #expect(metrics.map(\.kind) == [
            .inputSubmittedFrames,
            .inputPublishedFrames,
            .inputPublishedEvents,
            .inputCoalescedMotionFrames,
            .inputDroppedFrames,
            .inputRejectedFrames,
            .inputStateReconciliationEvents,
            .inputInvalidEventBuffers,
            .inputInvalidStatusBuffers,
            .inputStatusEvents,
            .inputQueueFaults,
            .inputBoundedDrainStops,
            .inputWorkerTurns,
            .inputWorkerYields,
            .inputCoalescedWorkerRequests,
            .inputRevokedWorkerTurns,
            .inputPendingFrameSaturationEvents,
            .inputPendingFrameDepth,
            .inputPendingFrameHighWatermark,
            .inputAvailableEventBufferDepth,
            .inputAvailableEventBufferHighWatermark,
            .inputEventQueueDepth,
            .inputEventQueueHighWatermark,
            .inputStatusQueueDepth,
            .inputStatusQueueHighWatermark,
            .inputPublicationLatencyNanoseconds,
            .inputMaximumPublicationLatencyNanoseconds,
        ])
        #expect(metrics.compactMap(\.value) == (1...27).map { UInt64($0) })
        #expect(metrics.dropLast(2).allSatisfy { $0.unit == .count })
        #expect(metrics.suffix(2).allSatisfy { $0.unit == .nanoseconds })
    }

    @Test func inputSnapshotSamplingDoesNotAcquireTheGuestQueueLock() throws {
        let backend = VirtioInput(profile: .keyboard)
        backend.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-input", operationID: UUID())
        registry.register(slot: 8, backend: backend, transport: transport)

        let baseline = registry.snapshot()
        let device = try #require(baseline.devices.first)
        #expect(baseline.isValid)
        #expect(device.id == "virtio-input-8")
        #expect(device.kind == .input)
        #expect(device.metrics.first { $0.kind == .inputSubmittedFrames }?.value == 1)
        #expect(device.metrics.first { $0.kind == .inputPendingFrameDepth }?.value == 1)
        #expect(device.metrics.first {
            $0.kind == .inputPendingFrameHighWatermark
        }?.value == 1)

        let queueLockHeld = DispatchSemaphore(value: 0)
        let releaseQueueLock = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.withQueueLock {
                queueLockHeld.signal()
                _ = releaseQueueLock.wait(timeout: .now() + 2)
            }
        }
        #expect(queueLockHeld.wait(timeout: .now() + 1) == .success)

        let samplingFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = registry.snapshot()
            samplingFinished.signal()
        }
        let result = samplingFinished.wait(timeout: .now() + 0.1)
        releaseQueueLock.signal()
        #expect(result == .success)
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

    @Test func publishesMeasuredShareInvalidationsAndPermanentFailureHealth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-share-telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = try VirtioFS(
            tag: "telemetry",
            hostFS: HostFS(rootPath: root.path),
            requestQueueCount: 1
        )
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-share", operationID: UUID())
        registry.register(slot: 6, backend: backend, transport: transport)

        do {
            try await backend.invalidate([.inode(nodeID: HostFS.rootNodeID)])
            Issue.record("unnegotiated share unexpectedly completed an invalidation")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .featureNotNegotiated)
        }

        let snapshot = registry.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(device.id == "virtio-shared-directory-6")
        #expect(device.health == .failed)
        #expect(device.metrics.first { $0.kind == .shareInvalidations }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareInvalidationFailures
        }?.value == 1)
        #expect(device.metrics.first {
            $0.kind == .shareRequestPayloadBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareWorkerResponsePayloadBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareGuestPublishedResponseBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareCompletedRequests
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareFailedRequests
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareInFlightRequests
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .sharePeakInFlightRequests
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareTotalRequestLatencyNanoseconds
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .shareMaximumRequestLatencyNanoseconds
        }?.value == 0)
        #expect(snapshot.events.map(\.kind) == [.shareInvalidationFailure])
        #expect(snapshot.events.first?.occurrences == 1)

        let persistent = registry.snapshot()
        #expect(persistent.devices.first?.health == .failed)
        #expect(persistent.events.map(\.kind) == [.shareInvalidationFailure])
    }

    @MainActor
    @Test func publishesMeasuredDisplayFramesAndRealPresentationDrops() throws {
        let mailbox = DesktopFrameMailbox()
        let frame = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 1,
            format: 1,
            width: 1,
            height: 1,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: 1, height: 1),
            bytes: Data(repeating: 0, count: 4)
        )
        mailbox.submit(frame)
        mailbox.submit(frame)
        mailbox.deliver()
        #expect(mailbox.metrics == DesktopFrameMailboxMetrics(
            presentedFrames: 0,
            droppedFrames: 2,
            receivedFrameBytes: 8,
            droppedFrameBytes: 8
        ))

        let backend = VirtioGPU(hostMemoryBase: GuestLayout.daxWindowBase, scanoutCount: 1)
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-display", operationID: UUID())
        registry.register(
            slot: 1,
            backend: backend,
            transport: transport,
            displayMetrics: { [weak mailbox] in mailbox?.metrics }
        )

        let snapshot = registry.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(device.id == "virtio-graphics-1")
        #expect(device.health == .degraded)
        #expect(device.metrics.first { $0.kind == .displayFrames }?.value == 0)
        #expect(device.metrics.first { $0.kind == .displayDrops }?.value == 2)
        #expect(device.metrics.first {
            $0.kind == .displayBudgetRejectedFrames
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .displayReceivedFrameBytes
        }?.value == 8)
        #expect(device.metrics.first {
            $0.kind == .displayStagingCopyBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .displayDrainCopyBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .displayUploadedFrameBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .displayDroppedFrameBytes
        }?.value == 8)
        #expect(device.metrics.first {
            $0.kind == .displayPendingFrameBytes
        }?.value == 0)
        #expect(device.metrics.first {
            $0.kind == .displayPendingFrameDepth
        }?.value == 0)

        let stable = registry.snapshot()
        #expect(stable.devices.first?.health == .healthy)
    }

    @Test func publishesDedicatedProcessPresentationBudgetMetrics() throws {
        let backend = VirtioGPU(hostMemoryBase: GuestLayout.daxWindowBase, scanoutCount: 1)
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(
            machineID: "raw-presentation-budget",
            operationID: UUID()
        )
        registry.register(
            slot: 1,
            backend: backend,
            transport: transport,
            displayMetrics: {
                DesktopFrameMailboxMetrics(
                    presentedFrames: 12,
                    droppedFrames: 9,
                    budgetRejectedFrames: 4
                )
            },
            presentationBudgetMetrics: {
                DesktopCPUPresentationBudgetMetrics(
                    residentBytes: 48 * 1_024,
                    peakResidentBytes: 96 * 1_024,
                    rejectedReservations: 4
                )
            }
        )

        let snapshot = registry.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(snapshot.isValid)
        // Budget rejection is a dedicated subset; the established display-drop counter is not
        // inflated a second time when the new metric is projected.
        #expect(device.metrics.first { $0.kind == .displayDrops }?.value == 9)
        #expect(device.metrics.first {
            $0.kind == .displayBudgetRejectedFrames
        }?.value == 4)
        #expect(device.metrics.first {
            $0.kind == .graphicsPresentationResidentBytes
        }?.value == 48 * 1_024)
        #expect(device.metrics.first {
            $0.kind == .graphicsPresentationPeakResidentBytes
        }?.value == 96 * 1_024)
        #expect(device.metrics.first {
            $0.kind == .graphicsPresentationRejectedReservations
        }?.value == 4)
    }

    @Test func coalescesMoreThanQueueLimitWithoutLosingAnyDamageRectangles() throws {
        let coalescer = DesktopScanoutFrameCoalescer()
        let width: UInt32 = 300
        let initial = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 41,
            format: 1,
            width: width,
            height: 1,
            stride: width * 4,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: width, height: 1),
            bytes: Data(repeating: 0, count: Int(width) * 4)
        )
        let appendedInitial = coalescer.append(initial)
        #expect(appendedInitial)
        _ = coalescer.drain()

        for x in 0..<width {
            let appended = coalescer.append(VirtioGPUScanoutFrame(
                scanoutID: 0,
                resourceID: 41,
                format: 1,
                width: width,
                height: 1,
                stride: 4,
                dirtyRect: VirtioGPURect(x: x, y: 0, width: 1, height: 1),
                bytes: Data([UInt8(truncatingIfNeeded: x), 17, 34, 255])
            ))
            #expect(appended)
        }

        let drain = coalescer.drain()
        #expect(drain.inputFrameCount == UInt64(width))
        let frame = try #require(drain.frames.first)
        #expect(drain.frames.count == 1)
        #expect(frame.dirtyRect == VirtioGPURect(x: 0, y: 0, width: width, height: 1))
        #expect(frame.stride == width * 4)
        for x in 0..<Int(width) {
            let offset = x * 4
            #expect(Array(frame.bytes[offset..<(offset + 4)]) == [
                UInt8(truncatingIfNeeded: x), 17, 34, 255,
            ])
        }
    }

    @Test func oldResourceReleaseCannotDiscardAReusedResourceGeneration() throws {
        let coalescer = DesktopScanoutFrameCoalescer()
        let rect = VirtioGPURect(x: 0, y: 0, width: 1, height: 1)
        let appendedOld = coalescer.append(VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 9,
            resourceGeneration: 3,
            format: 1,
            width: 1,
            height: 1,
            stride: 4,
            dirtyRect: rect,
            bytes: Data([3, 3, 3, 255])
        ))
        #expect(appendedOld)
        let appendedNew = coalescer.append(VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 9,
            resourceGeneration: 4,
            format: 1,
            width: 1,
            height: 1,
            stride: 4,
            dirtyRect: rect,
            bytes: Data([4, 4, 4, 255])
        ))
        #expect(appendedNew)

        let removed = coalescer.remove(resourceID: 9, throughGeneration: 3)
        #expect(removed == 1)
        let drain = coalescer.drain()
        #expect(drain.inputFrameCount == 1)
        let surviving = try #require(drain.frames.first)
        #expect(drain.frames.count == 1)
        #expect(surviving.resourceGeneration == 4)
        #expect(Array(surviving.bytes) == [4, 4, 4, 255])
    }

    @Test func publishesFenceCountsAndClassifiesPendingTimeouts() throws {
        let backend = VirtioGPU(hostMemoryBase: GuestLayout.daxWindowBase, scanoutCount: 1)
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let registry = RawDeviceTelemetryRegistry(machineID: "raw-gpu", operationID: UUID())
        let statistics = VirtioGPUStatistics(
            fences: 9,
            fenceRegistrationFailures: 1,
            fenceTimeouts: 2,
            hasTimedOutPendingFence: true,
            rendererDeviceLosses: 1,
            hasLostRendererDevice: true
        )
        registry.register(
            slot: 1,
            backend: backend,
            transport: transport,
            graphicsMetrics: { statistics }
        )

        let snapshot = registry.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(device.health == .failed)
        #expect(device.metrics.first { $0.kind == .graphicsFences }?.value == 9)
        #expect(device.metrics.first {
            $0.kind == .graphicsDeviceLosses
        }?.value == 1)
        #expect(snapshot.events.map(\.kind) == [
            .graphicsFenceTimeout,
            .graphicsDeviceLoss,
        ])
        #expect(snapshot.events.first?.occurrences == 2)
        #expect(snapshot.events.last?.occurrences == 1)

        let stable = registry.snapshot()
        #expect(stable.devices.first?.health == .failed)
        #expect(stable.events.map(\.kind) == [
            .graphicsFenceTimeout,
            .graphicsDeviceLoss,
        ])
    }
}
