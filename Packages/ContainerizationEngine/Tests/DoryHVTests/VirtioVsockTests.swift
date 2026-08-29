import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioVsockTests {
    @Test func headerEncodeDecodeRoundTrip() throws {
        let header = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 49_152,
            destinationPort: 1024,
            length: 5,
            operation: .readWrite,
            flags: 7,
            bufferAllocation: 8192,
            forwardCount: 33
        )

        let encoded = header.encoded()
        #expect(encoded.count == VirtioVsockHeader.byteCount)
        #expect(encoded[0] == 3)
        #expect(encoded[8] == 2)
        #expect(try VirtioVsockHeader(decoding: encoded) == header)
    }

    @Test func requestToListeningPortProducesResponseAndConnection() throws {
        let device = VirtioVsock(guestCID: 3)
        let accepted = TestLockedValue<VsockConnection?>(nil)
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }

        let request = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 1024,
            length: 0,
            operation: .request
        )
        let responses = try device.receive(packet: request.encoded())

        #expect(responses.count == 1)
        let response = try VirtioVsockHeader(decoding: responses[0])
        #expect(response.operation == .response)
        #expect(response.sourceCID == 2)
        #expect(response.destinationCID == 3)
        #expect(accepted.value != nil)
    }

    @Test func unknownPortResetsConnection() throws {
        let device = VirtioVsock(guestCID: 3)
        let request = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 65000,
            length: 0,
            operation: .request
        )

        let responses = try device.receive(packet: request.encoded())
        let response = try VirtioVsockHeader(decoding: responses[0])
        #expect(response.operation == .reset)
    }

    @Test func readWritePayloadIsDeliveredAndCreditsAdvance() throws {
        let device = VirtioVsock(guestCID: 3)
        let accepted = TestLockedValue<VsockConnection?>(nil)
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }
        let request = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 1024,
            length: 0,
            operation: .request
        )
        _ = try device.receive(packet: request.encoded())

        let payload = [UInt8]("hello".utf8)
        let rw = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 1024,
            length: UInt32(payload.count),
            operation: .readWrite
        )
        let responses = try device.receive(packet: rw.encoded() + payload)
        let credit = try VirtioVsockHeader(decoding: responses[0])
        #expect(credit.operation == .creditUpdate)
        #expect(credit.forwardCount == 0)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { raw in
            try accepted.value?.read(into: raw) ?? 0
        }
        #expect(count == payload.count)
        #expect(Array(buffer.prefix(count)) == payload)

        let consumedCredit = try #require(device.drainPendingGuestPackets().first)
        let consumedHeader = try VirtioVsockHeader(decoding: consumedCredit)
        #expect(consumedHeader.operation == .creditUpdate)
        #expect(consumedHeader.forwardCount == UInt32(payload.count))
    }

    @Test func hostConnectQueuesRequestToGuestPort() throws {
        let device = VirtioVsock(guestCID: 3)
        _ = try device.connectIfCapacity(port: 1024)

        let packets = device.drainPendingGuestPackets()
        #expect(packets.count == 1)
        let request = try VirtioVsockHeader(decoding: packets[0])
        #expect(request.operation == .request)
        #expect(request.sourceCID == 2)
        #expect(request.destinationCID == 3)
        #expect(request.destinationPort == 1024)
        #expect(request.sourcePort >= 49_152)
    }

    @Test func hostConnectionWritesReadWritePacketsAfterResponse() throws {
        let device = VirtioVsock(guestCID: 3)
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: device.drainPendingGuestPackets()[0])
        let response = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response
        )
        _ = try device.receive(packet: response.encoded())

        try connection.write([1, 2, 3, 4])
        let packets = device.drainPendingGuestPackets()
        #expect(packets.count == 1)
        let rw = try VirtioVsockHeader(decoding: packets[0])
        #expect(rw.operation == .readWrite)
        #expect(rw.sourcePort == request.sourcePort)
        #expect(rw.destinationPort == 1024)
        #expect(rw.length == 4)
        #expect(Array(packets[0].dropFirst(VirtioVsockHeader.byteCount)) == [1, 2, 3, 4])
    }

    @Test func hostConnectionSplitsLargeWritesIntoRxSafePackets() throws {
        let device = VirtioVsock(guestCID: 3)
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: device.drainPendingGuestPackets()[0])
        let response = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response
        )
        _ = try device.receive(packet: response.encoded())

        let payload = Array(repeating: UInt8(7), count: 12_515)
        try connection.write(payload)

        let packets = device.drainPendingGuestPackets()
        #expect(packets.count == 4)
        let reconstructed = try packets.flatMap { packet -> [UInt8] in
            let header = try VirtioVsockHeader(decoding: packet)
            #expect(header.operation == .readWrite)
            #expect(packet.count <= VirtioVsockHeader.byteCount + 4 * 1024)
            let chunk = Array(packet.dropFirst(VirtioVsockHeader.byteCount))
            #expect(header.length == UInt32(chunk.count))
            return chunk
        }
        #expect(reconstructed == payload)
    }

    @Test func boundedHostWriteTimesOutWhenGuestStopsReturningCredit() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response,
            bufferAllocation: 4
        ).encoded())

        #expect(throws: VsockConnectionWriteError.timedOut) {
            try connection.write(
                [1, 2, 3, 4, 5],
                timeoutNanoseconds: 5_000_000
            )
        }
        let emitted = try #require(device.drainPendingGuestPackets().first)
        let emittedHeader = try VirtioVsockHeader(decoding: emitted)
        #expect(emittedHeader.operation == .readWrite)
        #expect(emittedHeader.length == 4)
        #expect(Array(emitted.dropFirst(VirtioVsockHeader.byteCount)) == [1, 2, 3, 4])
    }

    @Test func hostWriteUsesPartialPeerCreditWithoutWaitingForFullChunk() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response,
            bufferAllocation: 2
        ).encoded())

        let finished = DispatchSemaphore(value: 0)
        let outcome = TestLockedValue<VsockConnectionWriteError?>(nil)
        DispatchQueue.global().async {
            do {
                try connection.write([1, 2, 3], timeoutNanoseconds: 1_000_000_000)
            } catch let error as VsockConnectionWriteError {
                outcome.withValue { $0 = error }
            } catch {
                outcome.withValue { $0 = .connectionClosed }
            }
            finished.signal()
        }
        for _ in 0..<200 where device.resourceSnapshot.pendingGuestPackets == 0 {
            usleep(1_000)
        }
        let first = try #require(device.drainPendingGuestPackets().first)
        let firstHeader = try VirtioVsockHeader(decoding: first)
        #expect(firstHeader.length == 2)
        #expect(Array(first.dropFirst(VirtioVsockHeader.byteCount)) == [1, 2])

        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .creditUpdate,
            bufferAllocation: 2,
            forwardCount: 2
        ).encoded())
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(outcome.value == nil)
        let second = try #require(device.drainPendingGuestPackets().first)
        let secondHeader = try VirtioVsockHeader(decoding: second)
        #expect(secondHeader.length == 1)
        #expect(Array(second.dropFirst(VirtioVsockHeader.byteCount)) == [3])
    }

    @Test func closeWakesWriterBlockedIndefinitelyForPeerCredit() throws {
        let device = VirtioVsock(guestCID: 3)
        defer { device.quiesce() }
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: #require(
            device.drainPendingGuestPackets().first
        ))
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response,
            bufferAllocation: 0
        ).encoded())

        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let writerOutcome = TestLockedValue<VsockConnectionWriteError?>(nil)
        DispatchQueue.global().async {
            writerStarted.signal()
            do {
                try connection.write([1])
            } catch let error as VsockConnectionWriteError {
                writerOutcome.withValue { $0 = error }
            } catch {
                writerOutcome.withValue { $0 = .connectionClosed }
            }
            writerFinished.signal()
        }
        #expect(writerStarted.wait(timeout: .now() + 1) == .success)

        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            connection.close()
            closeFinished.signal()
        }
        #expect(closeFinished.wait(timeout: .now() + 1) == .success)
        #expect(writerFinished.wait(timeout: .now() + 1) == .success)
        #expect(writerOutcome.value == .connectionClosed)
    }

    @Test func hostConnectionReadsGuestPayload() throws {
        let device = VirtioVsock(guestCID: 3)
        let connection = try device.connectIfCapacity(port: 1024)
        let request = try VirtioVsockHeader(decoding: device.drainPendingGuestPackets()[0])
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: 0,
            operation: .response
        ).encoded())
        let payload = [UInt8]("pong".utf8)
        let rw = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 1024,
            destinationPort: request.sourcePort,
            length: UInt32(payload.count),
            operation: .readWrite
        )
        _ = try device.receive(packet: rw.encoded() + payload)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { try connection.read(into: $0) }
        #expect(count == payload.count)
        #expect(Array(buffer.prefix(count)) == payload)
    }

    @Test func guestSendShutdownHalfClosesButKeepsConnectionWritable() throws {
        let device = VirtioVsock(guestCID: 3)
        let accepted = TestLockedValue<VsockConnection?>(nil)
        let listener = try device.registerListener(port: 1024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: 0, operation: .request
        ).encoded())

        let payload = [UInt8]("hi".utf8)
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: UInt32(payload.count), operation: .readWrite
        ).encoded() + payload)

        let connection = try #require(accepted.value)
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { try connection.read(into: $0) }
        #expect(Array(buffer.prefix(count)) == payload)

        // SHUT_WR half-close: VIRTIO_VSOCK_SHUTDOWN_SEND (2). The guest is done sending, but the host
        // must still be able to stream a reply, so the connection stays alive.
        let shutdownResponses = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: 0, operation: .shutdown, flags: 2
        ).encoded())
        let shutdown = try VirtioVsockHeader(decoding: #require(shutdownResponses.first))
        #expect(shutdown.operation == .shutdown)
        #expect(shutdown.forwardCount == UInt32(payload.count))

        #expect(connection.isPeerClosed)

        try connection.write([9, 9])
        let reply = try #require(device.drainPendingGuestPackets()
            .compactMap { try? VirtioVsockHeader(decoding: $0) }
            .first { $0.operation == .readWrite })
        #expect(reply.length == 2)
    }

    @Test func guestFullShutdownTearsDownConnection() throws {
        let device = VirtioVsock(guestCID: 3)
        let listener = try device.registerListener(port: 1024) { _ in }
        defer { listener.close() }
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_001, destinationPort: 1024,
            length: 0, operation: .request
        ).encoded())

        // Full shutdown (SEND|RCV = 3) tears the connection down.
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_001, destinationPort: 1024,
            length: 0, operation: .shutdown, flags: 3
        ).encoded())

        let responses = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_001, destinationPort: 1024,
            length: 1, operation: .readWrite
        ).encoded() + [7])
        #expect(try VirtioVsockHeader(decoding: responses[0]).operation == .reset)
    }
}

private final class TestLockedValue<Value>: @unchecked Sendable {
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
