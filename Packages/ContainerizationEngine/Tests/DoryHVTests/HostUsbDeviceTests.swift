import Darwin
import Foundation
import Testing
@testable import DoryHV

struct HostUsbDeviceTests {
    @Test func discoveryMapsIORegistryPropertiesToUsbipDescriptor() throws {
        let candidate = try #require(HostUsbDiscovery.candidate(from: [
            "idVendor": 0x2e8a,
            "idProduct": NSNumber(value: 0x0003),
            "bcdDevice": "0x0100",
            "bDeviceClass": 0xff,
            "bDeviceSubClass": 0,
            "bDeviceProtocol": 1,
            "bConfigurationValue": 1,
            "bNumConfigurations": 1,
            "bNumInterfaces": 2,
            "USB Address": 4,
            "locationID": 0x1430_0000,
            "Device Speed": 3,
            "USB Vendor Name": "Raspberry Pi",
            "USB Product Name": "RP2 Boot",
            "USB Serial Number": "E0C9125B0D9B",
        ]))

        #expect(candidate.descriptor.busID == "20-4")
        #expect(candidate.descriptor.busNumber == 20)
        #expect(candidate.descriptor.deviceNumber == 4)
        #expect(candidate.descriptor.vendorID == 0x2e8a)
        #expect(candidate.descriptor.productID == 0x0003)
        #expect(candidate.descriptor.bcdDevice == 0x0100)
        #expect(candidate.descriptor.interfaceCount == 2)
        #expect(candidate.vendorName == "Raspberry Pi")
        #expect(candidate.productName == "RP2 Boot")
        #expect(candidate.serialNumber == "E0C9125B0D9B")
    }

    @Test func discoveryRejectsEntriesWithoutVendorAndProductIDs() {
        #expect(HostUsbDiscovery.candidate(from: ["USB Product Name": "Hub"]) == nil)
    }

    @Test func discoveryAcceptsExplicitBusIDForStableTests() throws {
        let candidate = try #require(HostUsbDiscovery.candidate(from: [
            "DoryBusID": "3-2",
            "idVendor": "4660",
            "idProduct": "0xabcd",
        ]))

        #expect(candidate.descriptor.busID == "3-2")
        #expect(candidate.descriptor.vendorID == 0x1234)
        #expect(candidate.descriptor.productID == 0xabcd)
    }

    @Test func openPlansDescribeAuthorizationAndCaptureRequirements() {
        #expect(HostUsbDeviceFactory.plan(mode: .userAuthorized) == HostUsbOpenPlan(
            mode: .userAuthorized,
            authorize: true,
            requiresPrivilegedHelperForClaimedDevice: false,
            optionNames: []
        ))
        #expect(HostUsbDeviceFactory.plan(mode: .seize) == HostUsbOpenPlan(
            mode: .seize,
            authorize: true,
            requiresPrivilegedHelperForClaimedDevice: false,
            optionNames: ["deviceSeize"]
        ))
        #expect(HostUsbDeviceFactory.plan(mode: .capture) == HostUsbOpenPlan(
            mode: .capture,
            authorize: true,
            requiresPrivilegedHelperForClaimedDevice: true,
            optionNames: ["deviceCapture"]
        ))
    }

    @Test func controlSubmitParsesSetupPacketAndReturnsInPayload() throws {
        let backend = RecordingHostUsbBackend(controlResult: HostUsbTransferResult(status: 0, actualLength: 3, data: [1, 2, 3]))
        let device = HostUsbDevice(descriptor: fixtureHostUsbDescriptor(), backend: backend)
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 10, deviceID: 1, direction: .in, endpoint: 0),
            transferFlags: 0,
            transferBufferLength: 3,
            startFrame: 0xffff_ffff,
            numberOfPackets: 0,
            interval: 0,
            setup: [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00],
            transferBuffer: []
        )

        let reply = try device.submit(command)

        #expect(backend.controlSetups == [HostUsbControlSetup(requestType: 0x80, request: 0x06, value: 0x0100, index: 0, length: 3)])
        #expect(reply.status == 0)
        #expect(reply.actualLength == 3)
        #expect(reply.transferBuffer == [1, 2, 3])
    }

    @Test func controlSetupBuildsNativeIOUSBDeviceRequest() throws {
        let setup = try HostUsbControlSetup(usbipSetup: [0x21, 0x09, 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a])

        let request = setup.ioUSBDeviceRequest()

        #expect(request.bmRequestType == 0x21)
        #expect(request.bRequest == 0x09)
        #expect(request.wValue == 0x1234)
        #expect(request.wIndex == 0x5678)
        #expect(request.wLength == 0x9abc)
    }

    @Test func bulkOutSubmitUsesEndpointAddressAndPayload() throws {
        let backend = RecordingHostUsbBackend(transferResult: HostUsbTransferResult(status: 0, actualLength: 4))
        let device = HostUsbDevice(descriptor: fixtureHostUsbDescriptor(), backend: backend)
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 11, deviceID: 1, direction: .out, endpoint: 2),
            transferFlags: 0,
            transferBufferLength: 4,
            startFrame: 0xffff_ffff,
            numberOfPackets: 0,
            interval: 0,
            setup: [],
            transferBuffer: [9, 8, 7, 6]
        )

        let reply = try device.submit(command)

        #expect(backend.transfers.map(\.endpointAddress) == [0x02])
        #expect(backend.transfers.map(\.payload) == [[9, 8, 7, 6]])
        #expect(reply.status == 0)
        #expect(reply.actualLength == 4)
    }

    @Test func interruptInSubmitUsesDirectionalEndpointAddress() throws {
        let backend = RecordingHostUsbBackend(transferResult: HostUsbTransferResult(status: 0, actualLength: 2, data: [0xaa, 0xbb]))
        let device = HostUsbDevice(descriptor: fixtureHostUsbDescriptor(), backend: backend)
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 12, deviceID: 1, direction: .in, endpoint: 3),
            transferFlags: 0,
            transferBufferLength: 8,
            startFrame: 0xffff_ffff,
            numberOfPackets: 0,
            interval: 8,
            setup: [],
            transferBuffer: []
        )

        let reply = try device.submit(command)

        #expect(backend.transfers.map(\.endpointAddress) == [0x83])
        #expect(backend.transfers.map(\.expectedLength) == [8])
        #expect(reply.transferBuffer == [0xaa, 0xbb])
    }

    @Test func transferErrorsMapToNegativeUsbipStatus() throws {
        let backend = RecordingHostUsbBackend(transferError: .endpointNotFound(0x84))
        let device = HostUsbDevice(descriptor: fixtureHostUsbDescriptor(), backend: backend)
        let command = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 13, deviceID: 1, direction: .in, endpoint: 4),
            transferFlags: 0,
            transferBufferLength: 8,
            startFrame: 0xffff_ffff,
            numberOfPackets: 0,
            interval: 1,
            setup: [],
            transferBuffer: []
        )

        let reply = try device.submit(command)

        #expect(reply.status == -ENOENT)
        #expect(reply.actualLength == 0)
    }

    @Test func unlinkAbortsBackend() throws {
        let backend = RecordingHostUsbBackend()
        let device = HostUsbDevice(descriptor: fixtureHostUsbDescriptor(), backend: backend)
        let command = UsbipUnlinkCommand(
            header: UsbipHeaderBasic(command: .cmdUnlink, sequenceNumber: 14, deviceID: 1, direction: .out, endpoint: 0),
            unlinkSequenceNumber: 12
        )

        let reply = try device.unlink(command)

        #expect(backend.abortEndpoints == [nil])
        #expect(reply.status == 0)
    }
}

private final class RecordingHostUsbBackend: HostUsbBackend, @unchecked Sendable {
    struct Transfer: Equatable {
        var endpointAddress: UInt8
        var payload: [UInt8]
        var expectedLength: UInt32
        var direction: UsbipDirection
    }

    var controlSetups: [HostUsbControlSetup] = []
    var controlPayloads: [[UInt8]] = []
    var transfers: [Transfer] = []
    var abortEndpoints: [UInt8?] = []
    var controlResult: HostUsbTransferResult
    var transferResult: HostUsbTransferResult
    var transferError: HostUsbTransferError?

    init(
        controlResult: HostUsbTransferResult = HostUsbTransferResult(status: 0, actualLength: 0),
        transferResult: HostUsbTransferResult = HostUsbTransferResult(status: 0, actualLength: 0),
        transferError: HostUsbTransferError? = nil
    ) {
        self.controlResult = controlResult
        self.transferResult = transferResult
        self.transferError = transferError
    }

    func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        controlSetups.append(setup)
        controlPayloads.append(payload)
        return controlResult
    }

    func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        if let transferError { throw transferError }
        transfers.append(Transfer(endpointAddress: endpointAddress, payload: payload, expectedLength: expectedLength, direction: direction))
        return transferResult
    }

    func abort(endpointAddress: UInt8?) throws {
        abortEndpoints.append(endpointAddress)
    }
}

private func fixtureHostUsbDescriptor() -> UsbipDeviceDescriptor {
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
