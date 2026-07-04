import Darwin
import Testing
@testable import DoryHV

struct UsbipServerTests {
    @Test func importHandshakeReturnsDeviceDescriptorForKnownBusID() throws {
        let device = StubUsbDevice(descriptor: fixtureUsbDevice())
        let server = UsbipServer(devices: [device])

        let response = try server.handleImport(UsbipImportRequest(busID: "3-2").encoded())
        let header = try UsbipOperationHeader(decoding: Array(response.prefix(8)))
        let descriptor = try UsbipDeviceDescriptor(decoding: Array(response.dropFirst(8)))

        #expect(header.code == UsbipOpCode.repImport.rawValue)
        #expect(header.status == 0)
        #expect(descriptor == device.descriptor)
    }

    @Test func importHandshakeReturnsErrorForUnknownBusID() throws {
        let server = UsbipServer(devices: [StubUsbDevice(descriptor: fixtureUsbDevice())])

        let response = try server.handleImport(UsbipImportRequest(busID: "9-9").encoded())
        let header = try UsbipOperationHeader(decoding: response)

        #expect(header.code == UsbipOpCode.repImport.rawValue)
        #expect(header.status == 1)
        #expect(response.count == UsbipOperationHeader.byteCount)
    }

    @Test func submitIsForwardedToExportedDevice() throws {
        let device = StubUsbDevice(descriptor: fixtureUsbDevice(), submitPayload: [7, 8, 9])
        let server = UsbipServer(devices: [device])
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 44, deviceID: 0x0003_0002, direction: .in, endpoint: 1),
            transferFlags: 0,
            transferBufferLength: 3,
            startFrame: 0xffff_ffff,
            numberOfPackets: 0,
            interval: 1,
            setup: [],
            transferBuffer: []
        )

        let response = try server.handleURB(command.encoded(), busID: "3-2")

        #expect(device.submitted.map(\.header.sequenceNumber) == [44])
        #expect(response.prefix(4).elementsEqual([0, 0, 0, 3]))
        #expect(Array(response.suffix(3)) == [7, 8, 9])
    }

    @Test func unlinkIsForwardedToExportedDevice() throws {
        let device = StubUsbDevice(descriptor: fixtureUsbDevice())
        let server = UsbipServer(devices: [device])
        let command = UsbipUnlinkCommand(
            header: UsbipHeaderBasic(command: .cmdUnlink, sequenceNumber: 45, deviceID: 0x0003_0002, direction: .out, endpoint: 0),
            unlinkSequenceNumber: 44
        )

        let response = try server.handleURB(command.encoded(), busID: "3-2")

        #expect(device.unlinked.map(\.unlinkSequenceNumber) == [44])
        #expect(response.prefix(4).elementsEqual([0, 0, 0, 4]))
        #expect(response[20..<24].elementsEqual([0, 0, 0, 0]))
    }

    @Test func isochronousSubmitReturnsPipeErrorWithoutForwarding() throws {
        let device = StubUsbDevice(descriptor: fixtureUsbDevice())
        let server = UsbipServer(devices: [device])
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 46, deviceID: 0x0003_0002, direction: .out, endpoint: 2),
            transferFlags: 0,
            transferBufferLength: 0,
            startFrame: 0,
            numberOfPackets: 2,
            interval: 1,
            setup: [],
            transferBuffer: []
        )

        let response = try server.handleURB(command.encoded(), busID: "3-2")

        #expect(device.submitted.isEmpty)
        #expect(response.prefix(4).elementsEqual([0, 0, 0, 3]))
        #expect(response[20..<24].elementsEqual([0xff, 0xff, 0xff, UInt8(bitPattern: Int8(Int32(EPIPE) * -1))]))
    }
}

private final class StubUsbDevice: UsbipExportedDevice, @unchecked Sendable {
    let descriptor: UsbipDeviceDescriptor
    var submitPayload: [UInt8]
    private(set) var submitted: [UsbipSubmitCommand] = []
    private(set) var unlinked: [UsbipUnlinkCommand] = []

    init(descriptor: UsbipDeviceDescriptor, submitPayload: [UInt8] = []) {
        self.descriptor = descriptor
        self.submitPayload = submitPayload
    }

    func submit(_ command: UsbipSubmitCommand) throws -> UsbipSubmitReply {
        submitted.append(command)
        let header = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: command.header.direction, endpoint: 0)
        return UsbipSubmitReply(header: header, status: 0, actualLength: UInt32(submitPayload.count), transferBuffer: submitPayload)
    }

    func unlink(_ command: UsbipUnlinkCommand) throws -> UsbipUnlinkReply {
        unlinked.append(command)
        let header = UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipUnlinkReply(header: header, status: 0)
    }
}

private func fixtureUsbDevice() -> UsbipDeviceDescriptor {
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
