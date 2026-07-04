import Foundation
import Testing
@testable import DoryHV

struct UsbipProtocolTests {
    @Test func importRequestEncodesVersionOpcodeAndBusID() throws {
        let request = UsbipImportRequest(busID: "3-2")
        let encoded = request.encoded()
        let decoded = try UsbipImportRequest(decoding: encoded)

        #expect(encoded.count == UsbipImportRequest.byteCount)
        #expect(encoded.prefix(8).elementsEqual([0x01, 0x11, 0x80, 0x03, 0, 0, 0, 0]))
        #expect(Array(encoded[8..<12]) == Array("3-2\0".utf8))
        #expect(decoded == request)
    }

    @Test func importReplyIncludesPackedDeviceDescriptorOnSuccess() throws {
        let device = fixtureDevice()
        let reply = UsbipImportReply(status: 0, device: device)
        let encoded = reply.encoded()
        let header = try UsbipOperationHeader(decoding: Array(encoded.prefix(8)))
        let decodedDevice = try UsbipDeviceDescriptor(decoding: Array(encoded.dropFirst(8)))

        #expect(header.version == UsbipOperationHeader.version)
        #expect(header.code == UsbipOpCode.repImport.rawValue)
        #expect(header.status == 0)
        #expect(encoded.count == 8 + UsbipDeviceDescriptor.byteCount)
        #expect(decodedDevice == device)
        #expect(encoded[8 + 300] == 0x12)
        #expect(encoded[8 + 301] == 0x34)
        #expect(encoded[8 + 302] == 0xab)
        #expect(encoded[8 + 303] == 0xcd)
    }

    @Test func submitInFixtureFromKernelDocsDecodesAndRoundTrips() throws {
        let bytes = hex("00000001 00000d05 0001000f 00000001 00000001 00000200 00000040 ffffffff 00000000 00000004 00000000 00000000")

        let command = try UsbipSubmitCommand(decoding: bytes)

        #expect(command.header.command == .cmdSubmit)
        #expect(command.header.sequenceNumber == 0x0d05)
        #expect(command.header.deviceID == 0x0001_000f)
        #expect(command.header.direction == .in)
        #expect(command.header.endpoint == 1)
        #expect(command.transferBufferLength == 0x40)
        #expect(command.startFrame == 0xffff_ffff)
        #expect(command.numberOfPackets == 0)
        #expect(command.interval == 4)
        #expect(command.transferBuffer.isEmpty)
        #expect(command.encoded() == bytes)
    }

    @Test func submitOutFixtureCarriesTransferBuffer() throws {
        let bytes = hex("""
        00000001 00000d06 0001000f 00000000 00000001 00000000 00000040 ffffffff 00000000 00000004 00000000 00000000
        ffffffff860008a784ce5ae212376300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
        """)

        let command = try UsbipSubmitCommand(decoding: bytes)

        #expect(command.header.direction == .out)
        #expect(command.transferBufferLength == 0x40)
        #expect(command.transferBuffer.count == 0x40)
        #expect(command.transferBuffer.prefix(4).elementsEqual([0xff, 0xff, 0xff, 0xff]))
        #expect(command.encoded() == bytes)
    }

    @Test func submitReplyEncodesInPayloadOnlyForInDirection() throws {
        let header = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: 0x0d05, deviceID: 0, direction: .in, endpoint: 0)
        let reply = UsbipSubmitReply(header: header, status: 0, actualLength: 4, transferBuffer: [1, 2, 3, 4, 5])
        let encoded = reply.encoded()

        #expect(encoded.count == UsbipSubmitReply.headerByteCount + 4)
        #expect(encoded.prefix(4).elementsEqual([0, 0, 0, 3]))
        #expect(Array(encoded.suffix(4)) == [1, 2, 3, 4])
    }

    @Test func unlinkCommandAndReplyRoundTripHeaders() throws {
        let command = UsbipUnlinkCommand(
            header: UsbipHeaderBasic(command: .cmdUnlink, sequenceNumber: 22, deviceID: 0x0001_000f, direction: .out, endpoint: 0),
            unlinkSequenceNumber: 21
        )
        let encoded = command.encoded()
        let decoded = try UsbipUnlinkCommand(decoding: encoded)

        #expect(encoded.count == UsbipUnlinkCommand.byteCount)
        #expect(decoded == command)

        let reply = UsbipUnlinkReply(
            header: UsbipHeaderBasic(command: .retUnlink, sequenceNumber: 22, deviceID: 0, direction: .out, endpoint: 0),
            status: -54
        )
        let replyBytes = reply.encoded()

        #expect(replyBytes.count == UsbipUnlinkReply.byteCount)
        #expect(replyBytes[0..<4].elementsEqual([0, 0, 0, 4]))
        #expect(replyBytes[20..<24].elementsEqual([0xff, 0xff, 0xff, 0xca]))
    }

    @Test func shortFramesAreRejected() {
        #expect(throws: UsbipProtocolError.shortFrame) {
            _ = try UsbipSubmitCommand(decoding: [0, 1, 2])
        }
        #expect(throws: UsbipProtocolError.shortFrame) {
            _ = try UsbipImportRequest(decoding: [0, 1, 2])
        }
    }
}

private func fixtureDevice() -> UsbipDeviceDescriptor {
    UsbipDeviceDescriptor(
        path: "/sys/devices/pci0000:00/usb3/3-2",
        busID: "3-2",
        busNumber: 3,
        deviceNumber: 2,
        speed: 2,
        vendorID: 0x1234,
        productID: 0xabcd,
        bcdDevice: 0x0100,
        deviceClass: 0xff,
        deviceSubClass: 0,
        deviceProtocol: 1,
        configurationValue: 1,
        configurationCount: 1,
        interfaceCount: 2
    )
}

private func hex(_ string: String) -> [UInt8] {
    let compact = string.filter { $0.isHexDigit }
    var bytes = [UInt8]()
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        bytes.append(UInt8(compact[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
