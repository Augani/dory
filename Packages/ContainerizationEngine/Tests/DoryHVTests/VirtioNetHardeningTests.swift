import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct VirtioNetHardeningTests {
    private struct SocketPaths {
        let directory: String
        let proxy: String
        let device: String
    }

    private struct QueueLayout {
        let descriptors: UInt64
        let available: UInt64
        let used: UInt64
    }

    @Test func requiredMTUsProduceExactEthernetContracts() throws {
        let paths = try makeSocketPaths("mtu")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }

        do {
            let device = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
            try consumeMagic(from: proxyFD)
            #expect(device.effectiveMTUForTesting == 1_500)
            #expect(device.deviceFeatures & (1 << 3) != 0)
            #expect(device.configSpace.count == 12)
            #expect(Array(device.configSpace[10..<12]) == [0xDC, 0x05])
        }

        let explicitPath = paths.directory + "/explicit.sock"
        let explicit = try VirtioNet(
            socketPath: explicitPath,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_280
        )
        try consumeMagic(from: proxyFD)
        #expect(explicit.effectiveMTUForTesting == 1_280)
        #expect(explicit.deviceFeatures & (1 << 3) != 0)
        #expect(Array(explicit.configSpace[10..<12]) == [0, 5])

        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.directory + "/invalid.sock",
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_279
            )
        }
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.directory + "/too-large.sock",
                remotePath: paths.proxy,
                maximumTransmissionUnit: 9_001
            )
        }
    }

    @Test func transmitAdmissionIsBoundedAndRejectsDirectionOffloadAndMTUViolations() throws {
        let paths = try makeSocketPaths("tx")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_280
        )
        try consumeMagic(from: proxyFD)

        let guestBase: UInt64 = 0xB000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 2 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: guestBase + 0x1_0000,
            available: guestBase + 0x1_2000,
            used: guestBase + 0x1_4000
        )
        try configureQueue(transport.queues[1], layout: queue, size: 16, memory: memory)

        // A half-megabyte readable chain is valid guest memory but exceeds the protocol ceiling.
        // The backend must classify it from readableByteCount without copying it.
        try installDescriptor(
            index: 0,
            address: guestBase + 0x2_0000,
            length: 512 * 1_024,
            flags: 0,
            next: 0,
            layout: queue,
            memory: memory
        )

        let ordinaryFrame = ethernetFrame(marker: 0x41, count: 64)
        let ordinaryPacket = transmitPacket(frame: ordinaryFrame)
        try memory.write(ordinaryPacket, at: guestBase + 0xA_1000)
        try installDescriptor(
            index: 1,
            address: guestBase + 0xA_1000,
            length: ordinaryPacket.count,
            flags: 1, // NEXT
            next: 2,
            layout: queue,
            memory: memory
        )
        try installDescriptor(
            index: 2,
            address: guestBase + 0xA_2000,
            length: 32,
            flags: 2, // WRITE: a mixed TX chain is invalid
            next: 0,
            layout: queue,
            memory: memory
        )

        try memory.write(ordinaryPacket, at: guestBase + 0xA_3000)
        try installDescriptor(
            index: 3,
            address: guestBase + 0xA_3000,
            length: ordinaryPacket.count,
            flags: 2, // wholly device-writable TX chain
            next: 0,
            layout: queue,
            memory: memory
        )

        var needsChecksum = ordinaryPacket
        needsChecksum[0] = 0x01
        try memory.write(needsChecksum, at: guestBase + 0xA_4000)
        try installDescriptor(index: 4, address: guestBase + 0xA_4000, length: needsChecksum.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        var gso = ordinaryPacket
        gso[1] = 1
        try memory.write(gso, at: guestBase + 0xA_5000)
        try installDescriptor(index: 5, address: guestBase + 0xA_5000, length: gso.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        var unusedTransmitBufferCount = ordinaryPacket
        unusedTransmitBufferCount[10] = 0xA5
        unusedTransmitBufferCount[11] = 0x5A
        try memory.write(unusedTransmitBufferCount, at: guestBase + 0xA_6000)
        try installDescriptor(index: 6, address: guestBase + 0xA_6000,
                              length: unusedTransmitBufferCount.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        let oversizedPacket = transmitPacket(frame: ethernetFrame(marker: 0x7A, count: 1_295))
        try memory.write(oversizedPacket, at: guestBase + 0xA_7000)
        try installDescriptor(index: 7, address: guestBase + 0xA_7000, length: oversizedPacket.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        var extensibleHeader = ordinaryPacket
        extensibleHeader[0] = 0x80 // unknown flags are ignored
        extensibleHeader[2] = 0xFF // hdr_len/csum fields are never trusted for non-GSO packets
        extensibleHeader[4] = 0xEE
        try memory.write(extensibleHeader, at: guestBase + 0xA_8000)
        try installDescriptor(index: 8, address: guestBase + 0xA_8000, length: extensibleHeader.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        var dataValid = ordinaryPacket
        dataValid[0] = 0x02
        try memory.write(dataValid, at: guestBase + 0xA_9000)
        try installDescriptor(index: 9, address: guestBase + 0xA_9000, length: dataValid.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        var receiveSegmentCoalescing = ordinaryPacket
        receiveSegmentCoalescing[0] = 0x04
        try memory.write(receiveSegmentCoalescing, at: guestBase + 0xA_A000)
        try installDescriptor(index: 10, address: guestBase + 0xA_A000,
                              length: receiveSegmentCoalescing.count,
                              flags: 0, next: 0, layout: queue, memory: memory)

        try publishAvailableHeads([0, 1, 3, 4, 5, 6, 7, 8, 9, 10],
                                  layout: queue, memory: memory)
        device.handleKick(queue: 1, transport: transport)
        device.synchronizeTransmitQueueForTesting()

        #expect(try memory.read(UInt16.self, at: queue.used + 2) == 10)
        // VirtIO declares num_buffers unused on TX. Linux's VERSION_1 path only initializes these
        // bytes when MRG_RXBUF is negotiated, so arbitrary contents cannot reject an ordinary frame.
        #expect(try receiveDatagram(from: proxyFD, maximum: 2_048) == ordinaryFrame)
        #expect(try receiveDatagram(from: proxyFD, maximum: 2_048) == ordinaryFrame)
        #expect(noDatagramAvailable(from: proxyFD))

        let statistics = device.statistics
        #expect(statistics.transmitPackets == 2)
        #expect(statistics.transmitBytes == UInt64(ordinaryFrame.count * 2))
        #expect(statistics.transmitDrops == 8)
        #expect(statistics.transmitOversized == 2)
        #expect(statistics.transmitInvalidDescriptors == 2)
        #expect(statistics.transmitMalformed == 4)

        // Statistics deliberately use one consistent modulo-2^64 policy.
        device.setTransmitDropCountForTesting(UInt64.max)
        let shortPacket = [UInt8](repeating: 0, count: 12)
        try memory.write(shortPacket, at: guestBase + 0xA_B000)
        try installDescriptor(index: 11, address: guestBase + 0xA_B000, length: shortPacket.count,
                              flags: 0, next: 0, layout: queue, memory: memory)
        try appendAvailableHead(11, newIndex: 11, layout: queue, memory: memory)
        device.handleKick(queue: 1, transport: transport)
        device.synchronizeTransmitQueueForTesting()
        #expect(device.statistics.transmitDrops == 0)

        try installDescriptor(index: 12, address: guestBase + 0xA_C000,
                              length: ordinaryPacket.count,
                              flags: 0x0008, // unknown virtqueue flag: pop() must throw
                              next: 0, layout: queue, memory: memory)
        try memory.write(ordinaryPacket, at: guestBase + 0xA_D000)
        try installDescriptor(index: 13, address: guestBase + 0xA_D000,
                              length: ordinaryPacket.count,
                              flags: 0, next: 0, layout: queue, memory: memory)
        try appendAvailableHead(12, newIndex: 12, layout: queue, memory: memory)
        try appendAvailableHead(13, newIndex: 13, layout: queue, memory: memory)

        device.handleKick(queue: 1, transport: transport)
        device.synchronizeTransmitQueueForTesting()
        #expect(device.statistics.transmitInvalidDescriptors == 3)
        #expect(device.statistics.transmitDrops == 1)
        #expect(noDatagramAvailable(from: proxyFD))

        // The thrown malformed entry stops that drain turn. A later kick may safely resume at the
        // following available entry instead of having the error silently masquerade as emptiness.
        device.handleKick(queue: 1, transport: transport)
        device.synchronizeTransmitQueueForTesting()
        #expect(try receiveDatagram(from: proxyFD, maximum: 2_048) == ordinaryFrame)
    }

    @Test func receiveRejectsWrongDirectionAndSmallBuffersWithoutWritingPartialBytes() throws {
        let paths = try makeSocketPaths("rxdesc")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 8,
                maximumDeferredReceiveBytes: 8 * 1_500,
                maximumSocketReceiveOperationsPerTurn: 1,
                maximumSocketReceiveBytesPerTurn: 1_515
            )
        )
        try consumeMagic(from: proxyFD)

        let guestBase: UInt64 = 0xC000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: guestBase + 0x1_0000,
            available: guestBase + 0x1_1000,
            used: guestBase + 0x1_2000
        )
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)

        let wrongDirection = guestBase + 0x2_0000
        let tooSmall = guestBase + 0x2_1000
        let good = guestBase + 0x2_2000
        try memory.write([UInt8](repeating: 0xCC, count: 256), at: wrongDirection)
        try memory.write([UInt8](repeating: 0xDD, count: 20), at: tooSmall)
        try installDescriptor(index: 0, address: wrongDirection, length: 256, flags: 0, next: 0,
                              layout: queue, memory: memory)
        try installDescriptor(index: 1, address: tooSmall, length: 20, flags: 2, next: 0,
                              layout: queue, memory: memory)
        try publishAvailableHeads([0, 1], layout: queue, memory: memory)
        device.deviceReady(transport: transport)

        let frame = ethernetFrame(marker: 0x52, count: 64)
        try sendDatagram(frame, from: proxyFD, to: paths.device)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 2 })
        #expect(waitUntil { device.deferredReceiveResourceSnapshotForTesting.frames == 1 })
        #expect(try memory.read(UInt32.self, at: queue.used + 8) == 0)
        #expect(try memory.read(UInt32.self, at: queue.used + 16) == 0)
        #expect(try memory.readBytes(at: wrongDirection, count: 256).allSatisfy { $0 == 0xCC })
        #expect(try memory.readBytes(at: tooSmall, count: 20).allSatisfy { $0 == 0xDD })

        try installDescriptor(index: 2, address: good, length: 2_048, flags: 2, next: 0,
                              layout: queue, memory: memory)
        try appendAvailableHead(2, newIndex: 3, layout: queue, memory: memory)
        device.handleKick(queue: 0, transport: transport)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 3 })
        let written = Int(try memory.read(UInt32.self, at: queue.used + 24))
        #expect(written == 12 + frame.count)
        let packet = try memory.readBytes(at: good, count: written)
        #expect(Array(packet.dropFirst(12)) == frame)
        #expect(device.statistics.receiveInvalidDescriptors == 1)
        #expect(device.statistics.receiveInsufficientCapacity == 1)
        #expect(device.statistics.receiveTruncations == 0)

        let recoveryBuffer = guestBase + 0x2_3000
        try installDescriptor(index: 3, address: guestBase + 0x2_4000, length: 256,
                              flags: 0x000A, // WRITE plus unknown virtqueue flag
                              next: 0, layout: queue, memory: memory)
        try installDescriptor(index: 4, address: recoveryBuffer, length: 2_048,
                              flags: 2, next: 0, layout: queue, memory: memory)
        try appendAvailableHead(3, newIndex: 4, layout: queue, memory: memory)
        try appendAvailableHead(4, newIndex: 5, layout: queue, memory: memory)

        try sendDatagram(ethernetFrame(marker: 0x61, count: 64),
                         from: proxyFD, to: paths.device)
        #expect(waitUntil {
            device.statistics.receiveInvalidDescriptors == 2
                && device.statistics.receiveDrops == 1
        })
        #expect(try memory.read(UInt16.self, at: queue.used + 2) == 3)

        let recoveredFrame = ethernetFrame(marker: 0x72, count: 64)
        try sendDatagram(recoveredFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 4 })
        let recoveredLength = Int(try memory.read(UInt32.self, at: queue.used + 32))
        let recoveredPacket = try memory.readBytes(at: recoveryBuffer, count: recoveredLength)
        #expect(Array(recoveredPacket.dropFirst(12)) == recoveredFrame)
    }

    @Test func receiveDatagramCeilingDropsOversizedInputBeforeBacklogAdmission() throws {
        let paths = try makeSocketPaths("rxmax")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_280
        )
        try consumeMagic(from: proxyFD)
        let memory = try GuestMemory(guestBase: 0xD000_0000, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        device.deviceReady(transport: transport)

        try sendDatagram([UInt8](repeating: 0xAB, count: 1_500), from: proxyFD, to: paths.device)
        #expect(waitUntil { device.statistics.receiveTruncations == 1 })
        #expect(device.statistics.receiveDrops == 1)
        #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)
        // The bounded recv buffer is exactly one byte beyond the 1,280 + 14 frame ceiling, so a
        // larger host datagram is detected and discarded without allocating its guest size.
        #expect(device.statistics.receiveBytes == 1_295)
    }

    @Test func receiveBacklogEnforcesFrameAndByteLimitsAndPreservesOrder() throws {
        do {
            let paths = try makeSocketPaths("rxframes")
            defer { try? FileManager.default.removeItem(atPath: paths.directory) }
            let proxyFD = try bindUnixDatagram(path: paths.proxy)
            defer { close(proxyFD) }
            let device = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500,
                limits: VirtioNetLimits(
                    maximumDeferredReceiveFrames: 2,
                    maximumDeferredReceiveBytes: 1_000,
                    maximumSocketReceiveOperationsPerTurn: 1,
                    maximumSocketReceiveBytesPerTurn: 1_515
                )
            )
            try consumeMagic(from: proxyFD)
            let guestBase: UInt64 = 0xE000_0000
            let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase,
                backend: device,
                memory: memory
            ) {}
            let queue = QueueLayout(
                descriptors: guestBase + 0x1_0000,
                available: guestBase + 0x1_1000,
                used: guestBase + 0x1_2000
            )
            try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
            device.deviceReady(transport: transport)

            let frames = (0..<3).map { ethernetFrame(marker: UInt8(0x60 + $0), count: 64) }
            for frame in frames {
                try sendDatagram(frame, from: proxyFD, to: paths.device)
            }
            #expect(waitUntil { device.statistics.receiveBacklogDrops == 1 })
            #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 2)
            #expect(device.deferredReceiveResourceSnapshotForTesting.bytes == 128)

            try installDescriptor(index: 0, address: guestBase + 0x2_0000, length: 2_048,
                                  flags: 2, next: 0, layout: queue, memory: memory)
            try installDescriptor(index: 1, address: guestBase + 0x2_1000, length: 2_048,
                                  flags: 2, next: 0, layout: queue, memory: memory)
            try publishAvailableHeads([0, 1], layout: queue, memory: memory)
            device.handleKick(queue: 0, transport: transport)
            #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 2 })
            for index in 0..<2 {
                let usedLengthAddress = queue.used + 8 + UInt64(index) * 8
                let length = Int(try memory.read(UInt32.self, at: usedLengthAddress))
                let packet = try memory.readBytes(
                    at: guestBase + 0x2_0000 + UInt64(index) * 0x1000,
                    count: length
                )
                #expect(Array(packet.dropFirst(12)) == frames[index])
            }
            #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)
            #expect(device.deferredReceiveResourceSnapshotForTesting.bytes == 0)
        }

        do {
            let paths = try makeSocketPaths("rxbytes")
            defer { try? FileManager.default.removeItem(atPath: paths.directory) }
            let proxyFD = try bindUnixDatagram(path: paths.proxy)
            defer { close(proxyFD) }
            let device = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500,
                limits: VirtioNetLimits(
                    maximumDeferredReceiveFrames: 4,
                    maximumDeferredReceiveBytes: 100,
                    maximumSocketReceiveOperationsPerTurn: 1,
                    maximumSocketReceiveBytesPerTurn: 1_515
                )
            )
            try consumeMagic(from: proxyFD)
            let memory = try GuestMemory(guestBase: 0xE100_0000, size: 1 << 20)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase,
                backend: device,
                memory: memory
            ) {}
            let queue = QueueLayout(
                descriptors: 0xE100_0000 + 0x1_0000,
                available: 0xE100_0000 + 0x1_1000,
                used: 0xE100_0000 + 0x1_2000
            )
            try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
            device.deviceReady(transport: transport)
            try sendDatagram(ethernetFrame(marker: 1, count: 64), from: proxyFD, to: paths.device)
            try sendDatagram(ethernetFrame(marker: 2, count: 64), from: proxyFD, to: paths.device)
            #expect(waitUntil { device.statistics.receiveBacklogDrops == 1 })
            #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 1)
            #expect(device.deferredReceiveResourceSnapshotForTesting.bytes == 64)
        }
    }

    @Test func resetRevokesBacklogAndDropsLateSourceInputBeforeNextGeneration() throws {
        let paths = try makeSocketPaths("reset")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500
        )
        try consumeMagic(from: proxyFD)
        let guestBase: UInt64 = 0xF000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: guestBase + 0x1_0000,
            available: guestBase + 0x1_1000,
            used: guestBase + 0x1_2000
        )
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        device.deviceReady(transport: transport)

        let oldFrame = ethernetFrame(marker: 0x11, count: 64)
        try sendDatagram(oldFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { device.deferredReceiveResourceSnapshotForTesting.frames == 1 })
        transport.write(offset: 0x070, value: 0, width: 4)
        #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)
        #expect(device.statistics.receiveInactiveDrops >= 1)

        let resetFrame = ethernetFrame(marker: 0x22, count: 64)
        try sendDatagram(resetFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { device.statistics.receiveInactiveDrops >= 2 })

        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        try installDescriptor(index: 0, address: guestBase + 0x2_0000, length: 2_048,
                              flags: 2, next: 0, layout: queue, memory: memory)
        try publishAvailableHeads([0], layout: queue, memory: memory)
        device.deviceReady(transport: transport)
        let newFrame = ethernetFrame(marker: 0x33, count: 64)
        try sendDatagram(newFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 1 })
        let length = Int(try memory.read(UInt32.self, at: queue.used + 8))
        let packet = try memory.readBytes(at: guestBase + 0x2_0000, count: length)
        #expect(Array(packet.dropFirst(12)) == newFrame)
    }

    @Test func receiveQueueEpochDropsReconfiguredAndDisabledInputBeforeReenable() throws {
        let paths = try makeSocketPaths("queueepoch")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 8,
                maximumDeferredReceiveBytes: 8 * 1_500,
                maximumSocketReceiveOperationsPerTurn: 1,
                maximumSocketReceiveBytesPerTurn: 1_515
            )
        )
        try consumeMagic(from: proxyFD)

        let guestBase: UInt64 = 0xF100_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: guestBase + 0x1_0000,
            available: guestBase + 0x1_1000,
            used: guestBase + 0x1_2000
        )
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        device.deviceReady(transport: transport)

        let oldFrame = ethernetFrame(marker: 0x41, count: 64)
        try sendDatagram(oldFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { device.deferredReceiveResourceSnapshotForTesting.frames == 1 })

        // QueueReady=1 may reconfigure an already-ready ring. The old frame belongs to the old
        // descriptor epoch and must be dropped, not published through the new ring.
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        device.queueStateChanged(queue: 0, ready: true, transport: transport)
        #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)
        let afterReconfiguration = device.statistics.receiveInactiveDrops

        let receiveBuffer = guestBase + 0x2_0000
        let disabledFrames = [UInt8(0x52), 0x53, 0x54].map {
            ethernetFrame(marker: $0, count: 64)
        }
        try device.withReceiveQueueSerializedForTesting {
            #expect(transport.queues[0].setReady(false))
            device.queueStateChanged(queue: 0, ready: false, transport: transport)
            for frame in disabledFrames {
                try sendDatagram(frame, from: proxyFD, to: paths.device)
            }

            try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
            try installDescriptor(index: 0, address: receiveBuffer, length: 2_048,
                                  flags: 2, next: 0, layout: queue, memory: memory)
            try publishAvailableHeads([0], layout: queue, memory: memory)
            device.queueStateChanged(queue: 0, ready: true, transport: transport)
        }
        #expect(waitUntil {
            device.statistics.receiveInactiveDrops == afterReconfiguration + 3
                && device.isReceiveActiveForTesting
        })
        #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)

        let newFrame = ethernetFrame(marker: 0x63, count: 64)
        try sendDatagram(newFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 1 })
        let length = Int(try memory.read(UInt32.self, at: queue.used + 8))
        let packet = try memory.readBytes(at: receiveBuffer, count: length)
        #expect(Array(packet.dropFirst(12)) == newFrame)
        #expect(Array(packet.dropFirst(12)) != oldFrame)
        #expect(!disabledFrames.contains(Array(packet.dropFirst(12))))
    }

    @Test func activationPurgesPreReadyBurstAcrossBoundedWorkTurns() throws {
        let paths = try makeSocketPaths("activationbudget")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 8,
                maximumDeferredReceiveBytes: 8 * 1_500,
                maximumSocketReceiveOperationsPerTurn: 1,
                maximumSocketReceiveBytesPerTurn: 1_515
            )
        )
        try consumeMagic(from: proxyFD)

        let guestBase: UInt64 = 0xF300_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: guestBase + 0x1_0000,
            available: guestBase + 0x1_1000,
            used: guestBase + 0x1_2000
        )
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        let receiveBuffer = guestBase + 0x2_0000
        try installDescriptor(index: 0, address: receiveBuffer, length: 2_048,
                              flags: 2, next: 0, layout: queue, memory: memory)
        try publishAvailableHeads([0], layout: queue, memory: memory)

        for marker: UInt8 in [0x11, 0x22, 0x33] {
            try sendDatagram(
                ethernetFrame(marker: marker, count: 64),
                from: proxyFD,
                to: paths.device
            )
        }
        device.deviceReady(transport: transport)

        #expect(waitUntil {
            device.statistics.receiveInactiveDrops == 3
                && device.isReceiveActiveForTesting
        })
        #expect(try memory.read(UInt16.self, at: queue.used + 2) == 0)

        let liveFrame = ethernetFrame(marker: 0x7A, count: 64)
        try sendDatagram(liveFrame, from: proxyFD, to: paths.device)
        #expect(waitUntil { (try? memory.read(UInt16.self, at: queue.used + 2)) == 1 })
        let length = Int(try memory.read(UInt32.self, at: queue.used + 8))
        let packet = try memory.readBytes(at: receiveBuffer, count: length)
        #expect(Array(packet.dropFirst(12)) == liveFrame)
    }

    @Test func activationFloodExceedingBoundFailsClosedAndTerminates() throws {
        let paths = try makeSocketPaths("activationflood")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500,
            limits: VirtioNetLimits(
                maximumDeferredReceiveFrames: 8,
                maximumDeferredReceiveBytes: 8 * 1_500,
                maximumSocketReceiveOperationsPerTurn: 1,
                maximumSocketReceiveBytesPerTurn: 1_515,
                maximumActivationPurgeTurns: 2
            )
        )
        try consumeMagic(from: proxyFD)
        let memory = try GuestMemory(guestBase: 0xF400_0000, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queue = QueueLayout(
            descriptors: 0xF400_0000 + 0x1_0000,
            available: 0xF400_0000 + 0x1_1000,
            used: 0xF400_0000 + 0x1_2000
        )
        try configureQueue(transport.queues[0], layout: queue, size: 8, memory: memory)
        for marker: UInt8 in [0x10, 0x20, 0x30] {
            try sendDatagram(
                ethernetFrame(marker: marker, count: 64),
                from: proxyFD,
                to: paths.device
            )
        }

        device.deviceReady(transport: transport)

        #expect(waitUntil { device.isReceiveTerminalForTesting })
        #expect(device.statistics.receiveActivationFailures == 1)
        #expect(!device.isReceiveActiveForTesting)
        #expect(waitUntil { !FileManager.default.fileExists(atPath: paths.device) })
    }

    @Test func fatalReceiveErrorQuiescesSourceOnceAndRefusesReactivation() throws {
        let paths = try makeSocketPaths("rxfatal")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        let device = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500
        )
        try consumeMagic(from: proxyFD)
        let memory = try GuestMemory(guestBase: 0xF200_0000, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        device.deviceReady(transport: transport)

        device.handleSocketReceiveFailure(EIO)
        #expect(device.isReceiveTerminalForTesting)
        #expect(device.statistics.receiveSocketErrors == 1)
        #expect(waitUntil { !FileManager.default.fileExists(atPath: paths.device) })

        // A queued late callback or an attempted second DRIVER_OK cannot spin or double-account.
        device.handleSocketReceiveFailure(EBADF)
        device.deviceReady(transport: transport)
        #expect(device.statistics.receiveSocketErrors == 1)
        #expect(device.deferredReceiveResourceSnapshotForTesting.frames == 0)
    }

    @Test func socketAuthorityRefusesLiveRegularAndSymlinkReplacement() throws {
        let paths = try makeSocketPaths("authority")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }

        let liveFD = try bindUnixDatagram(path: paths.device)
        let liveIdentity = try identity(at: paths.device)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(try identity(at: paths.device) == liveIdentity)
        close(liveFD)
        unlink(paths.device)

        let sentinel = Data("preserve-me".utf8)
        try sentinel.write(to: URL(fileURLWithPath: paths.device))
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.device)) == sentinel)
        unlink(paths.device)

        let target = paths.directory + "/target"
        try sentinel.write(to: URL(fileURLWithPath: target))
        #expect(symlink(target, paths.device) == 0)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        var linkInfo = stat()
        #expect(lstat(paths.device, &linkInfo) == 0)
        #expect(linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }

    @Test func socketAuthorityRejectsRemoteRegularFileAndSymlink() throws {
        let paths = try makeSocketPaths("remoteauthority")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let sentinel = Data("remote-preserve".utf8)
        try sentinel.write(to: URL(fileURLWithPath: paths.proxy))

        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.proxy)) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: paths.device))

        unlink(paths.proxy)
        let targetPath = paths.directory + "/proxy-target.sock"
        let targetFD = try bindUnixDatagram(path: targetPath)
        defer { close(targetFD) }
        let targetIdentity = try identity(at: targetPath)
        #expect(symlink(targetPath, paths.proxy) == 0)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        var linkInfo = stat()
        #expect(lstat(paths.proxy, &linkInfo) == 0)
        #expect(linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        #expect(try identity(at: targetPath) == targetIdentity)
        #expect(!FileManager.default.fileExists(atPath: paths.device))
    }

    @Test func ownedSocketIsPrivateNonblockingCloseOnExecAndCleanupIsIdentityConditional() throws {
        let paths = try makeSocketPaths("ownership")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }

        // A provably stale same-user socket may be retired; live and ambiguous endpoints may not.
        let staleFD = try bindUnixDatagram(path: paths.device)
        close(staleFD)
        var device: VirtioNet? = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500
        )
        #expect(device != nil)
        try consumeMagic(from: proxyFD)
        #expect(device?.isSocketNonblockingForTesting == true)
        #expect(device?.isSocketCloseOnExecForTesting == true)
        // Apple documents getpeereid as SOCK_STREAM-only; pathname SOCK_DGRAM uses the strictly
        // revalidated same-euid socket and trusted-parent identity fallback.
        #expect(device?.usesPathnamePeerAuthenticationForTesting == true)
        var info = stat()
        #expect(lstat(paths.device, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let memory = try GuestMemory(guestBase: 0xA100_0000, size: 1 << 20)
        var transport: VirtioMMIOTransport? = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device!,
            memory: memory
        ) {}
        device?.deviceReady(transport: transport!)

        #expect(unlink(paths.device) == 0)
        let replacementFD = try bindUnixDatagram(path: paths.device)
        defer { close(replacementFD) }
        let replacementIdentity = try identity(at: paths.device)
        weak let weakDevice = device
        transport = nil
        device = nil
        #expect(waitUntil { weakDevice == nil })
        // The asynchronous DispatchSource cancel handler may run after deinit. Its captured identity
        // must prevent it from unlinking the replacement even then.
        #expect(waitUntil { (try? identity(at: paths.device)) == replacementIdentity })
        #expect(try identity(at: paths.device) == replacementIdentity)
    }

    @Test func activeSourceTeardownRetiresOwnedEndpointBeforeDeinitReturns() throws {
        let paths = try makeSocketPaths("teardown")
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        var device: VirtioNet? = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500
        )
        try consumeMagic(from: proxyFD)
        let memory = try GuestMemory(guestBase: 0xA200_0000, size: 1 << 20)
        var transport: VirtioMMIOTransport? = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device!,
            memory: memory
        ) {}
        device?.deviceReady(transport: transport!)
        device?.synchronizeReceiveQueueForTesting()
        weak let weakDevice = device

        transport = nil
        device = nil

        #expect(weakDevice == nil)
        var info = stat()
        #expect(lstat(paths.device, &info) == -1)
        #expect(errno == ENOENT)
    }

    @Test func cleanupRequiresTheCapturedParentDirectoryIdentity() throws {
        let paths = try makeSocketPaths("parentid")
        let movedDirectory = paths.directory + "-moved"
        defer {
            try? FileManager.default.removeItem(atPath: paths.directory)
            try? FileManager.default.removeItem(atPath: movedDirectory)
        }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }
        var device: VirtioNet? = try VirtioNet(
            socketPath: paths.device,
            remotePath: paths.proxy,
            maximumTransmissionUnit: 1_500
        )
        #expect(device != nil)
        try consumeMagic(from: proxyFD)

        #expect(rename(paths.directory, movedDirectory) == 0)
        try FileManager.default.createDirectory(
            atPath: paths.directory,
            withIntermediateDirectories: false
        )
        #expect(chmod(paths.directory, 0o700) == 0)
        let replacementFD = try bindUnixDatagram(path: paths.device)
        defer { close(replacementFD) }
        let replacementIdentity = try identity(at: paths.device)

        device = nil

        #expect(try identity(at: paths.device) == replacementIdentity)
    }

    @Test func socketPathsMustBeCanonicalAndParentDirectoryMustBeTrusted() throws {
        let paths = try makeSocketPaths("paths")
        defer {
            chmod(paths.directory, 0o700)
            try? FileManager.default.removeItem(atPath: paths.directory)
        }
        let proxyFD = try bindUnixDatagram(path: paths.proxy)
        defer { close(proxyFD) }

        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: "relative.sock",
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.directory + "/./device.sock",
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.directory + "/bad\u{0}name",
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }

        #expect(chmod(paths.directory, 0o777) == 0)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: paths.device,
                remotePath: paths.proxy,
                maximumTransmissionUnit: 1_500
            )
        }
        #expect(FileManager.default.fileExists(atPath: paths.proxy))

        // A private immediate parent is still untrusted when a writable, non-sticky ancestor can
        // rename it out from under validation and bind.
        let nested = paths.directory + "/private"
        #expect(chmod(paths.directory, 0o700) == 0)
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: false)
        #expect(chmod(nested, 0o700) == 0)
        let nestedProxy = nested + "/proxy.sock"
        let nestedProxyFD = try bindUnixDatagram(path: nestedProxy)
        defer { close(nestedProxyFD) }
        #expect(chmod(paths.directory, 0o777) == 0)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(
                socketPath: nested + "/device.sock",
                remotePath: nestedProxy,
                maximumTransmissionUnit: 1_500
            )
        }
    }

    private func makeSocketPaths(_ label: String) throws -> SocketPaths {
        let directory = "/tmp/dvn-h-\(label)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        guard chmod(directory, 0o700) == 0 else {
            throw VMError.invalidConfiguration("test chmod failed: errno \(errno)")
        }
        return SocketPaths(
            directory: directory,
            proxy: directory + "/proxy.sock",
            device: directory + "/device.sock"
        )
    }

    private func bindUnixDatagram(path: String) throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("test socket failed: errno \(errno)")
        }
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("test bind failed: errno \(errno)")
        }
        return descriptor
    }

    private func consumeMagic(from descriptor: Int32) throws {
        let bytes = try receiveDatagram(from: descriptor, maximum: 4)
        guard bytes == Array("VFKT".utf8) else {
            throw VMError.invalidConfiguration("test did not receive vfkit magic")
        }
    }

    private func receiveDatagram(from descriptor: Int32, maximum: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: maximum)
        let count = bytes.withUnsafeMutableBytes {
            recv(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count >= 0 else {
            throw VMError.invalidConfiguration("test recv failed: errno \(errno)")
        }
        return Array(bytes.prefix(count))
    }

    private func noDatagramAvailable(from descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(descriptor, &byte, 1, MSG_DONTWAIT)
        return result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)
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

    private func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        return address
    }

    private func identity(at path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw VMError.invalidConfiguration("test lstat failed: errno \(errno)")
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_gen):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private func configureQueue(
        _ queue: Virtqueue,
        layout: QueueLayout,
        size: UInt16,
        memory: GuestMemory
    ) throws {
        #expect(queue.configure(
            size: size,
            descriptorTable: layout.descriptors,
            availRing: layout.available,
            usedRing: layout.used
        ))
        #expect(queue.setReady(true))
        try memory.write(UInt16(0), at: layout.available)
        try memory.write(UInt16(0), at: layout.available + 2)
        try memory.write(UInt16(0), at: layout.used + 2)
    }

    private func installDescriptor(
        index: UInt16,
        address: UInt64,
        length: Int,
        flags: UInt16,
        next: UInt16,
        layout: QueueLayout,
        memory: GuestMemory
    ) throws {
        let descriptor = layout.descriptors + UInt64(index) * 16
        try memory.write(address, at: descriptor)
        try memory.write(UInt32(length), at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private func publishAvailableHeads(
        _ heads: [UInt16],
        layout: QueueLayout,
        memory: GuestMemory
    ) throws {
        for (index, head) in heads.enumerated() {
            try memory.write(head, at: layout.available + 4 + UInt64(index) * 2)
        }
        try memory.write(UInt16(heads.count), at: layout.available + 2)
    }

    private func appendAvailableHead(
        _ head: UInt16,
        newIndex: UInt16,
        layout: QueueLayout,
        memory: GuestMemory
    ) throws {
        let slot = UInt64((newIndex - 1) % 16)
        try memory.write(head, at: layout.available + 4 + slot * 2)
        try memory.write(newIndex, at: layout.available + 2)
    }

    private func transmitPacket(
        frame: [UInt8],
        flags: UInt8 = 0,
        gsoType: UInt8 = 0,
        numBuffers: UInt16 = 0
    ) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 12)
        header[0] = flags
        header[1] = gsoType
        header[10] = UInt8(truncatingIfNeeded: numBuffers)
        header[11] = UInt8(truncatingIfNeeded: numBuffers >> 8)
        return header + frame
    }

    private func ethernetFrame(marker: UInt8, count: Int) -> [UInt8] {
        precondition(count >= 14)
        var frame = [UInt8](repeating: marker, count: count)
        frame[0] = marker
        frame[12] = 0x08
        frame[13] = 0x00
        return frame
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            usleep(5_000)
        }
        return predicate()
    }
}
