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
        var accepted: VsockConnection?
        device.listen(port: 1024) { connection in
            accepted = connection
        }

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
        #expect(accepted != nil)
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
        var accepted: VsockConnection?
        device.listen(port: 1024) { accepted = $0 }
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
        #expect(credit.forwardCount == UInt32(payload.count))

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { raw in
            try accepted?.read(into: raw) ?? 0
        }
        #expect(count == payload.count)
        #expect(Array(buffer.prefix(count)) == payload)
    }

    @Test func hostConnectQueuesRequestToGuestPort() throws {
        let device = VirtioVsock(guestCID: 3)
        _ = device.connect(port: 1024)

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
        let connection = device.connect(port: 1024)
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

    @Test func hostConnectionReadsGuestPayload() throws {
        let device = VirtioVsock(guestCID: 3)
        let connection = device.connect(port: 1024)
        let request = try VirtioVsockHeader(decoding: device.drainPendingGuestPackets()[0])
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
        var accepted: VsockConnection?
        device.listen(port: 1024) { accepted = $0 }
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: 0, operation: .request
        ).encoded())

        let payload = [UInt8]("hi".utf8)
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: UInt32(payload.count), operation: .readWrite
        ).encoded() + payload)

        // SHUT_WR half-close: VIRTIO_VSOCK_SHUTDOWN_SEND (2). The guest is done sending, but the host
        // must still be able to stream a reply, so the connection stays alive.
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000, destinationPort: 1024,
            length: 0, operation: .shutdown, flags: 2
        ).encoded())

        let connection = try #require(accepted)
        #expect(connection.isPeerClosed)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = try buffer.withUnsafeMutableBytes { try connection.read(into: $0) }
        #expect(Array(buffer.prefix(count)) == payload)

        try connection.write([9, 9])
        let reply = try #require(device.drainPendingGuestPackets()
            .compactMap { try? VirtioVsockHeader(decoding: $0) }
            .first { $0.operation == .readWrite })
        #expect(reply.length == 2)
    }

    @Test func guestFullShutdownTearsDownConnection() throws {
        let device = VirtioVsock(guestCID: 3)
        device.listen(port: 1024) { _ in }
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
