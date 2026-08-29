import Darwin
import Foundation
import Synchronization
import Testing
@testable import DoryHV

@Suite struct VirtioNetTests {
    @Test func disconnectedDeviceBindsResolvedMACAndMTU() {
        let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
        let device = VirtioDisconnectedNet(
            macAddress: mac,
            maximumTransmissionUnit: 1_280
        )

        #expect(device.deviceFeatures & (1 << 3) != 0)
        #expect(Array(device.configSpace.prefix(6)) == mac)
        #expect(Array(device.configSpace[6..<10]) == [0, 0, 0, 0])
        #expect(Array(device.configSpace[10..<12]) == [0, 5])
    }

    @Test func disconnectedDeviceAdvertisesStableMACWithCarrierDown() {
        let device = VirtioDisconnectedNet(maximumTransmissionUnit: 1_500)

        #expect(device.queueCount == 2)
        #expect(device.deviceFeatures & (1 << 5) != 0)
        #expect(device.deviceFeatures & (1 << 16) != 0)
        #expect(device.deviceFeatures & (1 << 3) != 0)
        #expect(Array(device.configSpace.prefix(6)) == VirtioNet.guestMAC)
        #expect(Array(device.configSpace[6..<10]) == [0, 0, 0, 0])
        #expect(Array(device.configSpace.suffix(2)) == [0xDC, 0x05])
    }

    @Test func disconnectedDeviceConsumesTransmitDescriptorsWithoutAHostBackend() throws {
        let device = VirtioDisconnectedNet(maximumTransmissionUnit: 1_500)
        let guestBase: UInt64 = 0xA000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_1000
        let usedRing = guestBase + 0x1_2000
        let frameAddress = guestBase + 0x1_3000
        let frame = [UInt8](repeating: 0xA5, count: 64)

        transport.queues[1].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[1].setReady(true)
        try memory.write(frame, at: frameAddress)
        try memory.write(frameAddress, at: descriptorTable)
        try memory.write(UInt32(frame.count), at: descriptorTable + 8)
        try memory.write(UInt16(0), at: descriptorTable + 12)
        try memory.write(UInt16(0), at: descriptorTable + 14)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(1), at: availableRing + 2)
        try memory.write(UInt16(0), at: availableRing + 4)
        try memory.write(UInt16(0), at: usedRing + 2)

        device.handleKick(queue: 1, transport: transport)

        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 0)
    }

    @Test func receiveFrameWaitsForGuestBufferAndDrainsOnReceiveKick() throws {
        // sockaddr_un paths are capped at 103 bytes on Darwin; /var/folders/.../T is often already
        // long enough that a descriptive UUID path overflows it.
        let directory = "/tmp/dvn-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath)
        defer { close(proxyFD) }

        let device = try VirtioNet(
            socketPath: devicePath,
            remotePath: proxyPath,
            maximumTransmissionUnit: 1_500
        )
        var magic = [UInt8](repeating: 0, count: 4)
        #expect(recv(proxyFD, &magic, magic.count, 0) == 4)
        #expect(magic == Array("VFKT".utf8))

        let guestBase: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_1000
        let usedRing = guestBase + 0x1_2000
        let receiveBuffer = guestBase + 0x1_3000
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 2) // no RX buffers yet
        try memory.write(UInt16(0), at: usedRing + 2)
        device.deviceReady(transport: transport)

        let ethernetFrame = Array(0..<64).map(UInt8.init)
        try sendDatagram(ethernetFrame, from: proxyFD, to: devicePath)
        #expect(waitUntil { device.statistics.receiveDeferred == 1 })
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        #expect(device.statistics.receiveDrops == 0)

        // Linux replenishes receive buffers and notifies queue 0. The saved datagram must now be
        // delivered intact instead of having been lost during the temporary empty-ring window.
        try memory.write(receiveBuffer, at: descriptorTable)
        try memory.write(UInt32(2048), at: descriptorTable + 8)
        try memory.write(UInt16(2), at: descriptorTable + 12) // VIRTQ_DESC_F_WRITE
        try memory.write(UInt16(0), at: descriptorTable + 14)
        try memory.write(UInt16(0), at: availableRing + 4)
        try memory.write(UInt16(1), at: availableRing + 2)
        device.handleKick(queue: 0, transport: transport)

        #expect(waitUntil { (try? memory.read(UInt16.self, at: usedRing + 2)) == 1 })
        let written = Int(try memory.read(UInt32.self, at: usedRing + 8))
        #expect(written == 12 + ethernetFrame.count)
        let packet = try memory.readBytes(at: receiveBuffer, count: written)
        #expect(packet[0..<10].allSatisfy { $0 == 0 })
        #expect(Array(packet[10..<12]) == [1, 0])
        #expect(Array(packet.dropFirst(12)) == ethernetFrame)
        #expect(device.statistics.receivePackets == 1)
        #expect(device.statistics.receiveBytes == UInt64(ethernetFrame.count))
        #expect(device.statistics.receiveTruncations == 0)
    }

    @Test func connectedDeviceBindsResolvedMACAndMTU() throws {
        let directory = "/tmp/dvn-contract-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath)
        defer { close(proxyFD) }
        let mac: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]

        let device = try VirtioNet(
            socketPath: devicePath,
            remotePath: proxyPath,
            macAddress: mac,
            maximumTransmissionUnit: 9_000
        )
        var magic = [UInt8](repeating: 0, count: 4)
        #expect(recv(proxyFD, &magic, magic.count, 0) == 4)
        #expect(device.deviceFeatures & (1 << 3) != 0)
        #expect(Array(device.configSpace.prefix(6)) == mac)
        #expect(Array(device.configSpace[10..<12]) == [0x28, 0x23])
    }

    @Test func rejectsUnixDatagramPathsThatWouldBeSilentlyTruncated() throws {
        let tooLong = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: tooLong,
                remotePath: "/tmp/unused.sock",
                maximumTransmissionUnit: 1_500
            )
        }
    }

    @Test func transientTransmitBackpressureRetainsDescriptorWithoutPinningTransport() throws {
        let directory = "/tmp/dvn-tx-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath, receiveBufferBytes: 1_024)
        defer { close(proxyFD) }
        let attempts = Mutex(0)

        let device = try VirtioNet(
            socketPath: devicePath,
            remotePath: proxyPath,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 256,
                maximumDeferredReceiveBytes: 4 * 1_024 * 1_024,
                maximumTransmitOperationsPerTurn: 64,
                maximumTransmitBytesPerTurn: 256 * 1_024,
                minimumTransmitRetryDelayNanoseconds: 1_000_000_000,
                maximumTransmitRetryDelayNanoseconds: 1_000_000_000
            ),
            transmitOperationForTesting: { frame in
                attempts.withLock { count in
                    count += 1
                    switch count {
                    case 1: return (-1, EAGAIN)
                    case 2: return (-1, ENOBUFS)
                    default: return (frame.count, 0)
                    }
                }
            }
        )
        #expect(device.isSocketNonblockingForTesting)

        let guestBase: UInt64 = 0x9000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_1000
        let usedRing = guestBase + 0x1_2000
        let frameBase = guestBase + 0x2_0000
        let frameCount: UInt16 = 64
        let frameStride: UInt64 = 1_024
        let frame = [UInt8](repeating: 0, count: 12) + [UInt8](repeating: 0xA5, count: 512)

        transport.queues[1].configure(
            size: frameCount,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[1].setReady(true)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(frameCount, at: availableRing + 2)
        try memory.write(UInt16(0), at: usedRing + 2)
        for index in 0..<frameCount {
            let descriptor = descriptorTable + UInt64(index) * 16
            let frameAddress = frameBase + UInt64(index) * frameStride
            try memory.write(frame, at: frameAddress)
            try memory.write(frameAddress, at: descriptor)
            try memory.write(UInt32(frame.count), at: descriptor + 8)
            try memory.write(UInt16(0), at: descriptor + 12)
            try memory.write(UInt16(0), at: descriptor + 14)
            try memory.write(index, at: availableRing + 4 + UInt64(index) * 2)
        }

        // The backend-managed kick must return before any whole-ring work and release registerLock
        // for unrelated MMIO. The injected first send deterministically models host backpressure.
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.write(offset: 0x050, value: 1, width: 4)
            completed.signal()
        }
        let completionResult = completed.wait(timeout: .now() + 2)
        #expect(completionResult == .success)
        guard completionResult == .success else { return }
        #expect(transport.read(offset: 0x008, width: 4) == UInt64(device.deviceID))
        #expect(waitUntil {
            device.statistics.transmitBackpressure == 1
                && device.isTransmitRetryPendingForTesting
        })

        // EAGAIN publishes nothing: no available-index advance, used entry, drop, or reordering.
        #expect(try transport.queues[1].pendingCount() == frameCount)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        #expect(device.statistics.transmitDrops == 0)
        #expect(device.statistics.transmitQueueDepth == UInt64(frameCount))
        #expect(device.statistics.transmitQueueHighWatermark == UInt64(frameCount))
        #expect(device.isTransmitRetryPendingForTesting)

        #expect(device.triggerTransmitRetryForTesting())
        #expect(waitUntil {
            device.statistics.transmitBackpressure == 2
                && device.isTransmitRetryPendingForTesting
        })
        #expect(try transport.queues[1].pendingCount() == frameCount)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        #expect(device.statistics.transmitDrops == 0)

        #expect(device.triggerTransmitRetryForTesting())
        #expect(waitUntil { (try? memory.read(UInt16.self, at: usedRing + 2)) == frameCount })
        #expect(try transport.queues[1].pendingCount() == 0)
        let statistics = device.statistics
        #expect(statistics.transmitPackets == UInt64(frameCount))
        #expect(statistics.transmitBytes == UInt64(frameCount) * 512)
        #expect(statistics.transmitDrops == 0)
        #expect(statistics.transmitRetryWakeups == 2)
        #expect(statistics.transmitCompletions == UInt64(frameCount))
        #expect(statistics.transmitQueueDepth == 0)
        #expect(statistics.transmitCompletionLatencyNanoseconds > 0)
        #expect(statistics.transmitMaximumCompletionLatencyNanoseconds > 0)
    }

    @Test func blockedHostSendLeavesMMIOResponsiveAndBoundedTurnsYield() throws {
        let directory = "/tmp/dvn-tx-yield-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath)
        defer { close(proxyFD) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attempts = Mutex(0)

        let device = try VirtioNet(
            socketPath: devicePath,
            remotePath: proxyPath,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 256,
                maximumDeferredReceiveBytes: 4 * 1_024 * 1_024,
                maximumTransmitOperationsPerTurn: 2,
                maximumTransmitBytesPerTurn: 256 * 1_024
            ),
            transmitOperationForTesting: { frame in
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    started.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return (frame.count, 0)
            }
        )
        let guestBase: UInt64 = 0xA100_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let frame = [UInt8](repeating: 0, count: 12)
            + [UInt8](repeating: 0x6A, count: 64)
        let layout = try configureTransmitQueue(
            frames: Array(repeating: frame, count: 5),
            guestBase: guestBase,
            memory: memory,
            transport: transport
        )

        // This returns after publishing one async work item; the injected host operation remains
        // blocked on the TX executor and cannot pin the vCPU/register lock.
        transport.write(offset: 0x050, value: 1, width: 4)
        #expect(started.wait(timeout: .now() + 1) == .success)

        let readResult = Mutex<UInt64?>(nil)
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            readResult.withLock { $0 = transport.read(offset: 0x008, width: 4) }
            readFinished.signal()
        }
        let mmioWasResponsive = readFinished.wait(timeout: .now() + 1) == .success
        var hostSendReleased = false
        defer {
            if !hostSendReleased {
                release.signal()
            }
        }
        #expect(mmioWasResponsive)
        #expect(readResult.withLock { $0 } == UInt64(device.deviceID))
        // Prove the queue is untouched while the injected host call is still blocked. Releasing
        // it before these observations makes the assertion scheduler-dependent: the TX executor
        // may legitimately complete a descriptor before the test thread samples the ring.
        #expect(try transport.queues[1].pendingCount() == 5)
        #expect(try memory.read(UInt16.self, at: layout.used + 2) == 0)

        hostSendReleased = true
        release.signal()
        #expect(waitUntil { (try? memory.read(UInt16.self, at: layout.used + 2)) == 5 })
        let statistics = device.statistics
        #expect(statistics.transmitPackets == 5)
        #expect(statistics.transmitCompletions == 5)
        #expect(statistics.transmitBoundedDrainStops == 2)
        #expect(statistics.transmitQueueHighWatermark == 5)
        #expect(statistics.transmitQueueDepth == 0)
    }

    @Test func deviceResetCancelsBackpressureRetryWithoutLateSendOrCompletion() throws {
        let directory = "/tmp/dvn-tx-reset-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath)
        defer { close(proxyFD) }
        let attempts = Mutex(0)

        let device = try VirtioNet(
            socketPath: devicePath,
            remotePath: proxyPath,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 256,
                maximumDeferredReceiveBytes: 4 * 1_024 * 1_024,
                minimumTransmitRetryDelayNanoseconds: 1_000_000_000,
                maximumTransmitRetryDelayNanoseconds: 1_000_000_000
            ),
            transmitOperationForTesting: { _ in
                attempts.withLock { $0 += 1 }
                return (-1, EAGAIN)
            }
        )
        let guestBase: UInt64 = 0xA200_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let frame = [UInt8](repeating: 0, count: 12)
            + [UInt8](repeating: 0x7B, count: 64)
        let layout = try configureTransmitQueue(
            frames: [frame],
            guestBase: guestBase,
            memory: memory,
            transport: transport
        )

        transport.write(offset: 0x050, value: 1, width: 4)
        #expect(waitUntil { device.isTransmitRetryPendingForTesting })
        #expect(try transport.queues[1].pendingCount() == 1)
        #expect(try memory.read(UInt16.self, at: layout.used + 2) == 0)

        transport.write(offset: 0x070, value: 0, width: 4)
        #expect(!device.isTransmitRetryPendingForTesting)
        #expect(!device.triggerTransmitRetryForTesting())
        device.synchronizeTransmitQueueForTesting()
        #expect(attempts.withLock { $0 } == 1)
        #expect(device.statistics.transmitDrops == 0)
        #expect(device.statistics.transmitCompletions == 0)
        #expect(device.statistics.transmitQueueDepth == 0)
    }

    private func bindUnixDatagram(path: String, receiveBufferBytes: Int32? = nil) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("test socket failed: errno \(errno)")
        }
        if var receiveBufferBytes {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                close(descriptor)
                throw VMError.invalidConfiguration("test receive buffer failed: errno \(errno)")
            }
        }
        unlink(path)
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("test bind failed: errno \(errno)")
        }
        return descriptor
    }

    private func sendDatagram(_ bytes: [UInt8], from descriptor: Int32, to path: String) throws {
        var address = unixAddress(path)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        guard sent == bytes.count else {
            throw VMError.invalidConfiguration("test send failed: errno \(errno)")
        }
    }

    private func configureTransmitQueue(
        frames: [[UInt8]],
        guestBase: UInt64,
        memory: GuestMemory,
        transport: VirtioMMIOTransport
    ) throws -> (available: UInt64, used: UInt64) {
        precondition(!frames.isEmpty && frames.count <= Int(Virtqueue.maximumSize))
        var queueSize: UInt16 = 1
        while queueSize < UInt16(frames.count) { queueSize *= 2 }
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_2000
        let usedRing = guestBase + 0x1_4000
        #expect(transport.queues[1].configure(
            size: queueSize,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        ))
        #expect(transport.queues[1].setReady(true))
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(frames.count), at: availableRing + 2)
        try memory.write(UInt16(0), at: usedRing + 2)
        for (offset, frame) in frames.enumerated() {
            let index = UInt16(offset)
            let descriptor = descriptorTable + UInt64(index) * 16
            let frameAddress = guestBase + 0x2_0000 + UInt64(index) * 0x1_000
            try memory.write(frame, at: frameAddress)
            try memory.write(frameAddress, at: descriptor)
            try memory.write(UInt32(frame.count), at: descriptor + 8)
            try memory.write(UInt16(0), at: descriptor + 12)
            try memory.write(UInt16(0), at: descriptor + 14)
            try memory.write(index, at: availableRing + 4 + UInt64(index) * 2)
        }
        return (availableRing, usedRing)
    }

    private func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            precondition(path.utf8.count < destination.count)
            destination.copyBytes(from: path.utf8)
        }
        return address
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            usleep(5_000)
        }
        return predicate()
    }
}
