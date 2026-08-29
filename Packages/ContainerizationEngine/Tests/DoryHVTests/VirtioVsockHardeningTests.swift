import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioVsockHardeningTests {
    @Test func descriptorLengthBoundsPayloadAndIgnoresTrailingBytes() throws {
        let device = VirtioVsock(guestCID: 3)
        let accepted = LockedValue<VsockConnection?>(nil)
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }
        _ = try device.receive(packet: packet(.request, guestPort: 40_000))

        let response = try device.receive(
            packet: packet(
                .readWrite,
                guestPort: 40_000,
                length: 2,
                payload: [1, 2, 0xAA, 0xBB]
            )
        )
        #expect(try operation(response) == .creditUpdate)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { raw in
            try accepted.value?.read(into: raw) ?? 0
        }
        #expect(count == 2)
        #expect(Array(buffer.prefix(count)) == [1, 2])

        let malformed = try device.receive(
            packet: packet(
                .readWrite,
                guestPort: 40_000,
                length: 3,
                payload: [1, 2]
            )
        )
        #expect(try operation(malformed) == .reset)
        #expect(accepted.value?.isPeerClosed == true)
    }

    @Test func malformedCIDTypeOperationAndControlFieldsReceiveReset() throws {
        let device = VirtioVsock(guestCID: 3)
        let malformedPackets = [
            packet(.request, guestPort: 40_000, sourceCID: 4),
            packet(.request, guestPort: 40_001, destinationCID: 3),
            packet(.request, guestPort: 40_002, type: 2),
            packet(.invalid, guestPort: 40_003),
            packet(.request, guestPort: 40_004, flags: 1),
            packet(.shutdown, guestPort: 40_005, flags: 0),
            packet(.shutdown, guestPort: 40_006, flags: 4),
            packet(.creditRequest, guestPort: 40_007, length: 1, payload: [7]),
        ]

        for malformed in malformedPackets {
            #expect(try operation(device.receive(packet: malformed)) == .reset)
        }

        var unknownOperation = packet(.request, guestPort: 40_008)
        unknownOperation[30] = 0xFE
        unknownOperation[31] = 0x00
        #expect(try operation(device.receive(packet: unknownOperation)) == .reset)
        #expect(throws: (any Error).self) {
            _ = try device.receive(packet: [UInt8](repeating: 0, count: 43))
        }
    }

    @Test func duplicateTupleNeverOverwritesLiveConnection() throws {
        let device = VirtioVsock(guestCID: 3)
        let accepted = LockedValue([VsockConnection]())
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0.append(connection) }
        }
        defer { listener.close() }
        let request = packet(.request, guestPort: 40_000)

        #expect(try operation(device.receive(packet: request)) == .response)
        let original = try #require(accepted.value.first)
        #expect(try operation(device.receive(packet: request)) == .reset)

        #expect(accepted.value.count == 1)
        #expect(original.isPeerClosed)
        #expect(device.resourceSnapshot.connections == 0)
    }

    @Test func globalConnectionCapacityRejectsGuestAndHostAdmission() throws {
        let limits = try limits(maximumConnections: 1)
        let guestDevice = try VirtioVsock(guestCID: 3, limits: limits)
        let listener = try guestDevice.registerListener(port: 1024) { _ in }
        defer { listener.close() }

        #expect(try operation(guestDevice.receive(
            packet: packet(.request, guestPort: 40_000)
        )) == .response)
        #expect(try operation(guestDevice.receive(
            packet: packet(.request, guestPort: 40_001)
        )) == .reset)
        #expect(guestDevice.resourceSnapshot.connections == 1)

        let hostDevice = try VirtioVsock(guestCID: 3, limits: limits)
        _ = try hostDevice.connectIfCapacity(port: 1024)
        #expect(throws: VirtioVsockConnectionAdmissionError.connectionCapacityReached(limit: 1)) {
            _ = try hostDevice.connectIfCapacity(port: 1025)
        }
    }

    @Test func perConnectionInboundLimitResetsAndReleasesBufferedBytes() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumInboundBytesPerConnection: 4,
                maximumInboundBytesTotal: 8
            )
        )
        let accepted = LockedValue<VsockConnection?>(nil)
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }
        _ = try device.receive(packet: packet(.request, guestPort: 40_000))

        #expect(try operation(device.receive(packet: packet(
            .readWrite,
            guestPort: 40_000,
            length: 4,
            payload: [1, 2, 3, 4]
        ))) == .creditUpdate)
        #expect(device.resourceSnapshot.inboundBufferedBytes == 4)

        #expect(try operation(device.receive(packet: packet(
            .readWrite,
            guestPort: 40_000,
            length: 1,
            payload: [5]
        ))) == .reset)
        #expect(device.resourceSnapshot.inboundBufferedBytes == 0)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(accepted.value?.isPeerClosed == true)
    }

    @Test func globalInboundLimitRejectsOnlyTheOverflowingFlow() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumConnections: 2,
                maximumInboundBytesPerConnection: 8,
                maximumInboundBytesTotal: 6
            )
        )
        let accepted = LockedValue([VsockConnection]())
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0.append(connection) }
        }
        defer { listener.close() }
        _ = try device.receive(packet: packet(.request, guestPort: 40_000))
        _ = try device.receive(packet: packet(.request, guestPort: 40_001))

        _ = try device.receive(packet: packet(
            .readWrite,
            guestPort: 40_000,
            length: 4,
            payload: [1, 2, 3, 4]
        ))
        #expect(try operation(device.receive(packet: packet(
            .readWrite,
            guestPort: 40_001,
            length: 3,
            payload: [5, 6, 7]
        ))) == .reset)

        #expect(device.resourceSnapshot.connections == 1)
        #expect(device.resourceSnapshot.inboundBufferedBytes == 4)
        #expect(accepted.value[0].isPeerClosed == false)
        #expect(accepted.value[1].isPeerClosed)
    }

    @Test func rxStarvationStopsAtPendingPacketAndByteCeilings() throws {
        let packetBoundDevice = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumConnections: 2,
                maximumPendingGuestPackets: 1,
                maximumPendingGuestBytes: 1024
            )
        )
        _ = try packetBoundDevice.connectIfCapacity(port: 1024)
        #expect(throws: VirtioVsockConnectionAdmissionError.outboundQueueCapacityReached) {
            _ = try packetBoundDevice.connectIfCapacity(port: 1025)
        }
        #expect(packetBoundDevice.resourceSnapshot.pendingGuestPackets == 1)
        #expect(packetBoundDevice.resourceSnapshot.pendingGuestBytes == VirtioVsockHeader.byteCount)

        let byteBoundDevice = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumPendingGuestPackets: 4,
                maximumPendingGuestBytes: VirtioVsockHeader.byteCount
            )
        )
        let connection = try byteBoundDevice.connectIfCapacity(port: 1024)
        let request = try #require(byteBoundDevice.drainPendingGuestPackets().first)
        let requestHeader = try VirtioVsockHeader(decoding: request)
        _ = try byteBoundDevice.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: requestHeader.sourcePort
        ))

        #expect(throws: VsockConnectionWriteError.outboundQueueFull) {
            try connection.write([9])
        }
        #expect(byteBoundDevice.resourceSnapshot.pendingGuestPackets == 0)
        #expect(byteBoundDevice.resourceSnapshot.pendingGuestBytes == 0)
    }

    @Test func pendingPacketOverflowBackpressuresEstablishedWriter() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumPendingGuestPackets: 1,
                maximumPendingGuestBytes: 1024
            )
        )
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try #require(device.drainPendingGuestPackets().first)
        let requestHeader = try VirtioVsockHeader(decoding: request)
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: requestHeader.sourcePort
        ))

        try connection.write([1])
        #expect(throws: VsockConnectionWriteError.outboundQueueFull) {
            try connection.write([2])
        }
        #expect(device.resourceSnapshot.pendingGuestPackets == 1)
        #expect(device.resourceSnapshot.pendingGuestBytes == VirtioVsockHeader.byteCount + 1)
    }

    @Test func creditArithmeticUsesWrappingU32CountersWithoutUnderflowCredit() {
        #expect(VirtioVsockCreditArithmetic.available(
            bufferAllocation: 10,
            transmittedCount: 2,
            peerForwardCount: UInt32.max - 2
        ) == 5)
        #expect(VirtioVsockCreditArithmetic.available(
            bufferAllocation: 4,
            transmittedCount: 20,
            peerForwardCount: 10
        ) == 0)
    }

    @Test func boundedHostPortAllocatorSkipsCollisionsAndWrapsAfterReset() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumConnections: 3,
                maximumPendingGuestPackets: 8,
                hostPortRange: 500...501
            )
        )
        let first = try device.connectIfCapacity(port: 1024)
        _ = try device.connectIfCapacity(port: 1024)
        let requests = device.drainPendingGuestPackets()
        let ports = try requests.map { try VirtioVsockHeader(decoding: $0).sourcePort }
        #expect(ports == [500, 501])

        #expect(throws: VirtioVsockConnectionAdmissionError.hostPortRangeExhausted) {
            _ = try device.connectIfCapacity(port: 1024)
        }

        #expect(try device.receive(packet: packet(
            .reset,
            guestPort: 1024,
            hostPort: 500
        )).isEmpty)
        #expect(first.isPeerClosed)
        _ = try device.connectIfCapacity(port: 1024)
        let reused = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: reused).sourcePort == 500)
    }

    @Test func terminalResetAuthorityPreventsTupleReuseUntilGuestHandoff() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumConnections: 2,
                maximumPendingGuestPackets: 4,
                hostPortRange: 500...500
            )
        )
        defer { device.quiesce() }
        let original = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort
        ))
        let harness = try QueueHarness(device: device)
        try harness.publish(
            queue: 1,
            bytes: packet(.request, guestPort: 1024, hostPort: 500),
            deviceWritable: false
        )

        device.handleKick(queue: 1, transport: harness.transport)

        #expect(original.isPeerClosed)
        #expect(throws: VirtioVsockConnectionAdmissionError.hostPortRangeExhausted) {
            _ = try device.connectIfCapacity(port: 1024)
        }
        let terminal = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: terminal).operation == .reset)
        _ = try device.connectIfCapacity(port: 1024)
        let replacement = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: replacement).sourcePort == 500)
    }

    @Test func listenerTokenRejectsDuplicatesAndCannotUnregisterNewGeneration() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(maximumListeners: 1)
        )
        let first = try device.registerListener(port: 1024) { _ in }
        #expect(throws: VirtioVsockListenerRegistrationError.duplicatePort(1024)) {
            _ = try device.registerListener(port: 1024) { _ in }
        }
        #expect(throws: VirtioVsockListenerRegistrationError.listenerCapacityReached(limit: 1)) {
            _ = try device.registerListener(port: 1025) { _ in }
        }

        first.close()
        let replacement = try device.registerListener(port: 1024) { _ in }
        first.close()
        #expect(device.resourceSnapshot.listeners == 1)
        replacement.close()
        replacement.close()
        #expect(device.resourceSnapshot.listeners == 0)
    }

    @Test func resetAndQuiesceCloseFlowsReleaseBytesAndClearQueues() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(hostPortRange: 500...501)
        )
        let listener = try device.registerListener(port: 2048) { _ in }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try #require(device.drainPendingGuestPackets().first)
        let requestHeader = try VirtioVsockHeader(decoding: request)
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: requestHeader.sourcePort
        ))
        _ = try device.receive(packet: packet(
            .readWrite,
            guestPort: 1024,
            hostPort: requestHeader.sourcePort,
            length: 3,
            payload: [1, 2, 3]
        ))
        try connection.write([9])
        #expect(device.resourceSnapshot.inboundBufferedBytes == 3)
        #expect(device.resourceSnapshot.pendingGuestPackets == 1)

        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        device.deviceReset(transport: transport)

        #expect(connection.isPeerClosed)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(device.resourceSnapshot.inboundBufferedBytes == 0)
        #expect(device.resourceSnapshot.pendingGuestPackets == 0)
        #expect(device.resourceSnapshot.pendingGuestBytes == 0)
        #expect(device.resourceSnapshot.listeners == 1)
        #expect(device.resourceSnapshot.isQuiesced == false)

        let afterReset = try device.connectIfCapacity(port: 1024)
        let resetRequest = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: resetRequest).sourcePort == 500)

        let receipt = device.quiesce()
        #expect(receipt.connections == 0)
        #expect(receipt.listeners == 0)
        #expect(receipt.inboundBufferedBytes == 0)
        #expect(receipt.pendingGuestPackets == 0)
        #expect(receipt.pendingGuestBytes == 0)
        #expect(receipt.isQuiesced)
        #expect(afterReset.isPeerClosed)
        #expect(throws: VirtioVsockConnectionAdmissionError.deviceQuiesced) {
            _ = try device.connectIfCapacity(port: 1024)
        }
        device.deviceReset(transport: transport)
        #expect(device.resourceSnapshot.isQuiesced)
        #expect(device.resourceSnapshot.listeners == 0)
        #expect(throws: VirtioVsockListenerRegistrationError.deviceQuiesced) {
            _ = try device.registerListener(port: 2048) { _ in }
        }
        listener.close()
    }

    @Test func txResponseReservationCommitsBeforeListenerCanConsumeCapacity() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumPendingGuestPackets: 1,
                maximumPendingGuestBytes: VirtioVsockHeader.byteCount,
                shutdownTimeoutNanoseconds: 2_000_000
            )
        )
        defer { device.quiesce() }
        let callbackCount = LockedValue(0)
        let listener = try device.registerListener(port: 1024) { connection in
            callbackCount.withValue { $0 += 1 }
            // If the required RESPONSE were not already committed, this host-originated control
            // packet could steal its only queue slot and leave an accepted guest flow unacknowledged.
            connection.close()
        }
        defer { listener.close() }
        let harness = try QueueHarness(device: device)
        try harness.publish(
            queue: 1,
            bytes: packet(.request, guestPort: 40_000),
            deviceWritable: false
        )

        device.handleKick(queue: 1, transport: harness.transport)

        #expect(callbackCount.value == 1)
        #expect(try harness.usedLength(queue: 1) == 0)
        usleep(5_000)
        // The required RESPONSE owns the only slot. The reaper must keep the tuple fail-closed
        // instead of dropping that response or silently reusing the tuple.
        #expect(device.resourceSnapshot.connections == 1)
        #expect(device.resourceSnapshot.pendingGuestPackets == 1)
        let response = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: response).operation == .response)
        for _ in 0..<100 where device.resourceSnapshot.connections != 0 {
            usleep(1_000)
        }
        #expect(device.resourceSnapshot.connections == 0)
        let reset = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: reset).operation == .reset)
    }

    @Test func txMustBeReadOnlyAndRxMustBeWriteOnly() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let callbackCount = LockedValue(0)
        let listener = try device.registerListener(port: 1024) { _ in
            callbackCount.withValue { $0 += 1 }
        }
        defer { listener.close() }
        let txHarness = try QueueHarness(device: device)
        try txHarness.publish(
            queue: 1,
            bytes: packet(.request, guestPort: 40_000),
            deviceWritable: true
        )

        device.handleKick(queue: 1, transport: txHarness.transport)

        #expect(callbackCount.value == 0)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(try txHarness.usedLength(queue: 1) == 0)

        let rxDevice = VirtioVsock(guestCID: 3)
        defer { rxDevice.quiesce() }
        _ = try rxDevice.connectIfCapacity(port: 1024)
        let rxHarness = try QueueHarness(device: rxDevice)
        try rxHarness.publish(
            queue: 0,
            bytes: [UInt8](repeating: 0xA5, count: VirtioVsockHeader.byteCount),
            deviceWritable: false
        )

        rxDevice.handleKick(queue: 0, transport: rxHarness.transport)

        #expect(try rxHarness.usedLength(queue: 0) == 0)
        #expect(rxDevice.resourceSnapshot.pendingGuestPackets == 1)
    }

    @Test func tooSmallRxBufferDoesNotConsumePendingPacket() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        _ = try device.connectIfCapacity(port: 1024)
        let harness = try QueueHarness(device: device)
        try harness.publish(
            queue: 0,
            bytes: [UInt8](repeating: 0, count: VirtioVsockHeader.byteCount - 1),
            deviceWritable: true
        )

        device.handleKick(queue: 0, transport: harness.transport)

        #expect(try harness.usedLength(queue: 0) == 0)
        #expect(device.resourceSnapshot.pendingGuestPackets == 1)
        #expect(device.resourceSnapshot.pendingGuestBytes == VirtioVsockHeader.byteCount)
    }

    @Test func rxStarvationCannotBlockFollowingUsableBuffer() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        _ = try device.connectIfCapacity(port: 1024)
        let harness = try QueueHarness(device: device)
        try harness.publish(queue: 0, chains: [
            [QueueSegmentInput(length: VirtioVsockHeader.byteCount - 1, deviceWritable: true)],
            [QueueSegmentInput(length: VirtioVsockHeader.byteCount, deviceWritable: true)],
        ])

        device.handleKick(queue: 0, transport: harness.transport)

        #expect(try harness.usedLengths(queue: 0) == [0, UInt32(VirtioVsockHeader.byteCount)])
        #expect(device.resourceSnapshot.pendingGuestPackets == 0)
        #expect(device.statistics.rxStarvationEvents == 1)
        let delivered = try harness.data(
            queue: 0,
            chain: 1,
            count: VirtioVsockHeader.byteCount
        )
        #expect(try VirtioVsockHeader(decoding: delivered).operation == .request)
    }

    @Test func rxFragmentsStreamPacketAcrossLinuxSizedGuestBuffersExactlyOnce() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort
        ))
        let payload = Array(UInt8(0)..<UInt8(10))
        try connection.write(payload)

        let fragmentBytes = VirtioVsockHeader.byteCount + 5
        let harness = try QueueHarness(device: device)
        try harness.publish(queue: 0, chains: [
            [QueueSegmentInput(length: fragmentBytes, deviceWritable: true)],
            [QueueSegmentInput(length: fragmentBytes, deviceWritable: true)],
        ])

        device.handleKick(queue: 0, transport: harness.transport)

        #expect(try harness.usedLengths(queue: 0) == [UInt32(fragmentBytes), UInt32(fragmentBytes)])
        let fragments = try (0..<2).map { index -> [UInt8] in
            let bytes = try harness.data(queue: 0, chain: index, count: fragmentBytes)
            let header = try VirtioVsockHeader(decoding: bytes)
            #expect(header.operation == .readWrite)
            #expect(header.length == 5)
            return Array(bytes.dropFirst(VirtioVsockHeader.byteCount))
        }
        #expect(fragments.flatMap { $0 } == payload)
        #expect(device.resourceSnapshot.pendingGuestPackets == 0)
        #expect(device.statistics.publishedGuestPackets == 2)
    }

    @Test func txRejectsMixedZeroLengthAndOversizedChainsWithoutExecution() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let callbackCount = LockedValue(0)
        let listener = try device.registerListener(port: 1024) { _ in
            callbackCount.withValue { $0 += 1 }
        }
        defer { listener.close() }
        let harness = try QueueHarness(device: device)
        let request = packet(.request, guestPort: 40_000)

        try harness.publish(queue: 1, chains: [[
            QueueSegmentInput(bytes: request, deviceWritable: false),
            QueueSegmentInput(length: 8, deviceWritable: true),
        ]])
        device.handleKick(queue: 1, transport: harness.transport)

        try harness.publish(queue: 1, chains: [[
            QueueSegmentInput(length: 0, deviceWritable: false),
            QueueSegmentInput(bytes: request, deviceWritable: false),
        ]])
        device.handleKick(queue: 1, transport: harness.transport)

        let oversizedHeaderOnly = packet(
            .readWrite,
            guestPort: 40_001,
            length: UInt32(VirtioVsockLimits.linuxMaximumPacketPayloadBytes + 1)
        )
        try harness.publish(
            queue: 1,
            bytes: oversizedHeaderOnly,
            deviceWritable: false
        )
        device.handleKick(queue: 1, transport: harness.transport)

        #expect(callbackCount.value == 0)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(device.statistics.invalidTXChains == 2)
        #expect(device.statistics.oversizedGuestPackets == 1)
        #expect(try harness.usedLength(queue: 1) == 0)
        let reset = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: reset).operation == .reset)
    }

    @Test func eventQueueRejectsReadableBuffersAndRetainsValidWritableBuffer() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let invalidHarness = try QueueHarness(device: device)
        try invalidHarness.publish(
            queue: 2,
            bytes: [UInt8](repeating: 0, count: 4),
            deviceWritable: false
        )
        device.handleKick(queue: 2, transport: invalidHarness.transport)
        #expect(try invalidHarness.usedLength(queue: 2) == 0)
        #expect(device.statistics.invalidEventChains == 1)

        let validHarness = try QueueHarness(device: device)
        try validHarness.publish(
            queue: 2,
            bytes: [UInt8](repeating: 0, count: 4),
            deviceWritable: true
        )
        device.handleKick(queue: 2, transport: validHarness.transport)
        #expect(try validHarness.transport.queues[2].pendingCount() == 1)
        #expect(try validHarness.usedLengths(queue: 2).isEmpty)
    }

    @Test func drainBudgetIsObservableAndMakesProgressOnNextKick() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(maximumChainsPerKick: 1)
        )
        defer { device.quiesce() }
        let callbackCount = LockedValue(0)
        let listener = try device.registerListener(port: 1024) { _ in
            callbackCount.withValue { $0 += 1 }
        }
        defer { listener.close() }
        let harness = try QueueHarness(device: device)
        try harness.publish(queue: 1, chains: [
            [QueueSegmentInput(bytes: packet(.request, guestPort: 40_000), deviceWritable: false)],
            [QueueSegmentInput(bytes: packet(.request, guestPort: 40_001), deviceWritable: false)],
        ])

        device.handleKick(queue: 1, transport: harness.transport)
        #expect(callbackCount.value == 1)
        #expect(try harness.transport.queues[1].pendingCount() == 1)
        #expect(device.statistics.boundedDrainStops == 1)

        device.handleKick(queue: 1, transport: harness.transport)
        #expect(callbackCount.value == 2)
        #expect(try harness.transport.queues[1].pendingCount() == 0)
        #expect(try harness.usedLengths(queue: 1) == [0, 0])
    }

    @Test func queueFaultIsTerminalUntilNewQueueGeneration() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let callbackCount = LockedValue(0)
        let listener = try device.registerListener(port: 1024) { _ in
            callbackCount.withValue { $0 += 1 }
        }
        defer { listener.close() }
        let harness = try QueueHarness(device: device)
        try harness.publish(
            queue: 1,
            bytes: packet(.request, guestPort: 40_000),
            deviceWritable: false
        )
        try harness.setAvailableIndex(queue: 1, 9)

        device.handleKick(queue: 1, transport: harness.transport)
        device.handleKick(queue: 1, transport: harness.transport)
        #expect(device.statistics.queueFaults == 1)
        #expect(callbackCount.value == 0)

        try harness.publish(
            queue: 1,
            bytes: packet(.request, guestPort: 40_001),
            deviceWritable: false
        )
        device.queueStateChanged(queue: 1, ready: true, transport: harness.transport)
        device.handleKick(queue: 1, transport: harness.transport)
        #expect(callbackCount.value == 1)
        #expect(device.statistics.queueFaults == 1)
    }

    @Test func peerCreditIsClampedToLocalResourceCeilingAcrossWrapSafeAccounting() throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(maximumInboundBytesPerConnection: 64)
        )
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort,
            bufferAllocation: UInt32.max
        ))

        #expect(throws: VsockConnectionWriteError.timedOut) {
            try connection.write(
                [UInt8](repeating: 7, count: 65),
                timeoutNanoseconds: 5_000_000
            )
        }
        let emitted = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: emitted).length == 64)
        #expect(device.statistics.peerCreditClamps == 1)
    }

    @Test func resetRevokesLateHostUseAndClearsTransportResources() throws {
        let device = VirtioVsock(guestCID: 3)
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort
        ))
        let harness = try QueueHarness(device: device)

        device.deviceReady(transport: harness.transport)
        device.deviceReset(transport: harness.transport)

        #expect(throws: VsockConnectionWriteError.connectionClosed) {
            try connection.write([1])
        }
        #expect(connection.isPeerClosed)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(device.resourceSnapshot.pendingGuestPackets == 0)
        #expect(device.resourceSnapshot.pendingGuestBytes == 0)
    }

    @Test func pendingTakeAndConcurrentAbortCannotDeleteTheNextFlowPacket() throws {
        for iteration in 0..<32 {
            let device = try VirtioVsock(
                guestCID: 3,
                limits: limits(maximumConnections: 2, hostPortRange: 500...501)
            )
            let first = try device.connectIfCapacity(port: 1024)
            _ = first
            _ = try device.connectIfCapacity(port: 1025)
            let pending = device.drainPendingGuestPackets()
            let firstHeader = try VirtioVsockHeader(decoding: pending[0])
            let secondHeader = try VirtioVsockHeader(decoding: pending[1])

            // Restore the same ordered pending state through two new flows.
            device.deviceReset(transport: try QueueHarness(device: device).transport)
            _ = try device.connectIfCapacity(port: 1024)
            _ = try device.connectIfCapacity(port: 1025)
            let harness = try QueueHarness(device: device)
            try harness.publish(
                queue: 0,
                bytes: [UInt8](repeating: 0, count: VirtioVsockHeader.byteCount),
                deviceWritable: true
            )
            let resetFirst = packet(
                .reset,
                guestPort: 1024,
                hostPort: firstHeader.sourcePort
            )
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                device.handleKick(queue: 0, transport: harness.transport)
                finished.leave()
            }
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                _ = try? device.receive(packet: resetFirst)
                finished.leave()
            }
            start.signal()
            start.signal()
            #expect(finished.wait(timeout: .now() + 2) == .success)

            let remaining = device.drainPendingGuestPackets()
            let usedLength = try harness.usedLength(queue: 0)
            if usedLength == 0 {
                // The reset removed the exact head after delivery was planned but before guest
                // memory was touched. The generation/id check completes the buffer empty and must
                // preserve the next flow's packet.
                #expect(remaining.count == 1, "iteration \(iteration)")
                #expect(try VirtioVsockHeader(decoding: remaining[0]).destinationPort
                    == secondHeader.destinationPort)
            } else {
                let written = try harness.data(queue: 0, count: VirtioVsockHeader.byteCount)
                let writtenHeader = try VirtioVsockHeader(decoding: written)
                if writtenHeader.destinationPort == firstHeader.destinationPort {
                    #expect(remaining.count == 1, "iteration \(iteration)")
                    #expect(try VirtioVsockHeader(decoding: remaining[0]).destinationPort
                        == secondHeader.destinationPort)
                } else {
                    #expect(writtenHeader.destinationPort == secondHeader.destinationPort)
                    #expect(remaining.isEmpty, "iteration \(iteration)")
                }
            }
            device.quiesce()
        }
    }

    @Test func localCloseReaperQueuesResetBeforeTupleRetirementAndReuse() async throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumConnections: 2,
                maximumPendingGuestPackets: 8,
                hostPortRange: 500...501,
                shutdownTimeoutNanoseconds: 2_000_000
            )
        )
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort
        ))

        connection.close()
        for _ in 0..<100 where device.resourceSnapshot.connections != 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(device.resourceSnapshot.connections == 0)

        // The old tuple remains reserved by the queued RST until that packet is handed off.
        _ = try device.connectIfCapacity(port: 1024)
        let packets = device.drainPendingGuestPackets()
        let headers = try packets.map { try VirtioVsockHeader(decoding: $0) }
        #expect(headers.map(\.operation) == [.shutdown, .reset, .request])
        #expect(headers.last?.sourcePort == 501)

        _ = try device.receive(packet: packet(.reset, guestPort: 1024, hostPort: 501))
        _ = try device.connectIfCapacity(port: 1024)
        let reused = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: reused).sourcePort == 500)
    }

    @Test func localCloseReaperReplacesItsOwnQueuedShutdownAtDeadline() async throws {
        let device = try VirtioVsock(
            guestCID: 3,
            limits: limits(
                maximumPendingGuestPackets: 1,
                maximumPendingGuestBytes: VirtioVsockHeader.byteCount,
                shutdownTimeoutNanoseconds: 2_000_000
            )
        )
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: packet(
            .response,
            guestPort: 1024,
            hostPort: request.sourcePort
        ))

        connection.close()
        #expect(device.resourceSnapshot.pendingGuestPackets == 1)
        #expect(device.resourceSnapshot.pendingGuestBytes == VirtioVsockHeader.byteCount)
        for _ in 0..<100 where device.resourceSnapshot.connections != 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(device.resourceSnapshot.connections == 0)
        let terminal = try #require(device.drainPendingGuestPackets().first)
        #expect(try VirtioVsockHeader(decoding: terminal).operation == .reset)
        #expect(device.resourceSnapshot.pendingGuestPackets == 0)
    }

    private func limits(
        maximumConnections: Int = 8,
        maximumListeners: Int = 4,
        maximumInboundBytesPerConnection: Int = 64,
        maximumInboundBytesTotal: Int = 256,
        maximumPendingGuestPackets: Int = 16,
        maximumPendingGuestBytes: Int = 4096,
        maximumChainsPerKick: Int = Int(Virtqueue.maximumSize),
        hostPortRange: ClosedRange<UInt32> = 500...507,
        shutdownTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws -> VirtioVsockLimits {
        try VirtioVsockLimits(
            maximumConnections: maximumConnections,
            maximumListeners: maximumListeners,
            maximumInboundBytesPerConnection: maximumInboundBytesPerConnection,
            maximumInboundBytesTotal: maximumInboundBytesTotal,
            maximumPendingGuestPackets: maximumPendingGuestPackets,
            maximumPendingGuestBytes: maximumPendingGuestBytes,
            maximumChainsPerKick: maximumChainsPerKick,
            hostPortRange: hostPortRange,
            shutdownTimeoutNanoseconds: shutdownTimeoutNanoseconds
        )
    }

    private func packet(
        _ operation: VirtioVsockHeader.Operation,
        guestPort: UInt32,
        hostPort: UInt32 = 1024,
        sourceCID: UInt64 = 3,
        destinationCID: UInt64 = 2,
        length: UInt32 = 0,
        type: UInt16 = 1,
        flags: UInt32 = 0,
        bufferAllocation: UInt32 = 256 * 1024,
        forwardCount: UInt32 = 0,
        payload: [UInt8] = []
    ) -> [UInt8] {
        VirtioVsockHeader(
            sourceCID: sourceCID,
            destinationCID: destinationCID,
            sourcePort: guestPort,
            destinationPort: hostPort,
            length: length,
            type: type,
            operation: operation,
            flags: flags,
            bufferAllocation: bufferAllocation,
            forwardCount: forwardCount
        ).encoded() + payload
    }

    private func operation(
        _ responses: [[UInt8]]
    ) throws -> VirtioVsockHeader.Operation {
        let response = try #require(responses.first)
        return try VirtioVsockHeader(decoding: response).operation
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

private struct QueueSegmentInput {
    var bytes: [UInt8]
    var length: Int
    var deviceWritable: Bool

    init(
        bytes: [UInt8] = [],
        length: Int? = nil,
        deviceWritable: Bool
    ) {
        self.bytes = bytes
        self.length = length ?? bytes.count
        self.deviceWritable = deviceWritable
    }
}

private final class QueueHarness: @unchecked Sendable {
    private let base: UInt64 = 0x8000_0000
    let memory: GuestMemory
    let transport: VirtioMMIOTransport

    init(device: VirtioVsock) throws {
        memory = try GuestMemory(guestBase: base, size: 0x10_000)
        transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
    }

    func publish(queue: Int, bytes: [UInt8], deviceWritable: Bool) throws {
        try publish(
            queue: queue,
            chains: [[QueueSegmentInput(bytes: bytes, deviceWritable: deviceWritable)]]
        )
    }

    func publish(queue: Int, chains: [[QueueSegmentInput]]) throws {
        precondition(!chains.isEmpty && chains.count <= 8)
        precondition(chains.allSatisfy { !$0.isEmpty })
        precondition(chains.flatMap { $0 }.count <= 8)
        let layout = layout(queue: queue)
        transport.queues[queue].configure(
            size: 8,
            descriptorTable: layout.descriptor,
            availRing: layout.available,
            usedRing: layout.used
        )
        transport.queues[queue].setReady(true)

        var descriptorIndex = 0
        var dataOffset = 0
        for (chainIndex, segments) in chains.enumerated() {
            try memory.write(UInt16(descriptorIndex), at: layout.available + 4 + UInt64(chainIndex * 2))
            for (segmentIndex, segment) in segments.enumerated() {
                precondition(segment.length >= 0 && segment.bytes.count <= segment.length)
                let descriptorAddress = layout.descriptor + UInt64(descriptorIndex * 16)
                let dataAddress = layout.data + UInt64(dataOffset)
                try memory.write(dataAddress, at: descriptorAddress)
                try memory.write(UInt32(segment.length), at: descriptorAddress + 8)
                let hasNext = segmentIndex + 1 < segments.count
                let flags: UInt16 = (segment.deviceWritable ? 2 : 0) | (hasNext ? 1 : 0)
                try memory.write(flags, at: descriptorAddress + 12)
                try memory.write(UInt16(hasNext ? descriptorIndex + 1 : 0), at: descriptorAddress + 14)
                if !segment.bytes.isEmpty { try memory.write(segment.bytes, at: dataAddress) }
                descriptorIndex += 1
                dataOffset += max(0x100, segment.length)
            }
        }
        try memory.write(UInt16(0), at: layout.available)
        try memory.write(UInt16(chains.count), at: layout.available + 2)
    }

    func usedLength(queue: Int) throws -> UInt32 {
        try memory.read(UInt32.self, at: layout(queue: queue).used + 8)
    }

    func usedLengths(queue: Int) throws -> [UInt32] {
        let layout = layout(queue: queue)
        let count = Int(try memory.read(UInt16.self, at: layout.used + 2))
        return try (0..<count).map { index in
            try memory.read(UInt32.self, at: layout.used + 8 + UInt64(index * 8))
        }
    }

    func setAvailableIndex(queue: Int, _ index: UInt16) throws {
        try memory.write(index, at: layout(queue: queue).available + 2)
    }

    func data(queue: Int, count: Int) throws -> [UInt8] {
        try memory.readBytes(at: layout(queue: queue).data, count: count)
    }

    func data(queue: Int, chain: Int, count: Int) throws -> [UInt8] {
        try memory.readBytes(
            at: layout(queue: queue).data + UInt64(chain * 0x100),
            count: count
        )
    }

    private func layout(queue: Int) -> (
        descriptor: UInt64,
        available: UInt64,
        used: UInt64,
        data: UInt64
    ) {
        let offset = UInt64(queue) * 0x4_000
        return (
            base + offset + 0x1_000,
            base + offset + 0x2_000,
            base + offset + 0x3_000,
            base + offset + 0x4_000
        )
    }
}
