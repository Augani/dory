import Foundation
import Testing
@testable import DoryHV

struct UsbipBridgeTests {
    @Test func bridgeAnswersImportThenForwardsSubmitAndClosesOnEOF() throws {
        let device = StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2"), submitPayload: [0xAA, 0xBB])
        let connection = LoopbackVsockConnection()

        // Guest side, in order: OP_REQ_IMPORT for the busID, then one CMD_SUBMIT (IN, 2-byte reply).
        connection.feed(UsbipImportRequest(busID: "3-2").encoded())
        let submit = UsbipSubmitCommand(
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 7, deviceID: 0, direction: .in, endpoint: 1),
            transferFlags: 0, transferBufferLength: 2, startFrame: 0, numberOfPackets: 0, interval: 0,
            setup: [UInt8](repeating: 0, count: 8), transferBuffer: []
        )
        connection.feed(submit.encoded())
        connection.finishAfterDrain()

        var closed = false
        let bridge = UsbipBridge(connection: connection, device: device) { closed = true }
        bridge.serve()

        let written = connection.writes
        // 1. OP_REP_IMPORT: 8-byte op header (status 0) then the 312-byte device descriptor.
        #expect(written.count > 8 + UsbipDeviceDescriptor.byteCount)
        let importReply = Array(written.prefix(8 + UsbipDeviceDescriptor.byteCount))
        let descriptor = try UsbipDeviceDescriptor(decoding: Array(importReply.dropFirst(8)))
        #expect(descriptor.busID == "3-2")
        // 2. The submit was forwarded to the device and a reply followed the import reply.
        #expect(device.submitted.count == 1)
        #expect(device.submitted.first?.header.sequenceNumber == 7)
        // 3. EOF (peer closed after draining) ended the loop and released the device.
        #expect(closed)
    }

    @Test func bridgeRejectsUnknownBusIDWithStatusOne() throws {
        let device = StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2"))
        let connection = LoopbackVsockConnection()
        connection.feed(UsbipImportRequest(busID: "9-9").encoded())
        connection.finishAfterDrain()

        var closed = false
        let bridge = UsbipBridge(connection: connection, device: device) { closed = true }
        bridge.serve()

        // Unknown device → OP_REP_IMPORT with status 1 and no descriptor (8 bytes total).
        let written = connection.writes
        #expect(written.count == 8)
        let status = (UInt32(written[4]) << 24) | (UInt32(written[5]) << 16) | (UInt32(written[6]) << 8) | UInt32(written[7])
        #expect(status == 1)
        #expect(device.submitted.isEmpty)
        #expect(closed)
    }

    @Test func bridgeStopsImmediatelyIfPeerClosesBeforeImport() throws {
        let device = StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2"))
        let connection = LoopbackVsockConnection()
        connection.finishAfterDrain()

        var closed = false
        let bridge = UsbipBridge(connection: connection, device: device) { closed = true }
        bridge.serve()

        #expect(connection.writes.isEmpty)
        #expect(closed)
    }
}

struct UsbipManagerTests {
    @Test func registerUnregisterTracksClaimedDevicesByBusID() {
        let manager = UsbipManager()
        #expect(manager.claimedBusIDs.isEmpty)

        manager.register(StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2")))
        manager.register(StubExportedDevice(descriptor: fixtureDescriptor(busID: "1-4")))
        #expect(manager.claimedBusIDs == ["1-4", "3-2"])
        #expect(manager.exportedDevice(busID: "3-2")?.descriptor.busID == "3-2")
        #expect(manager.exportedDevices().count == 2)

        let removed = manager.unregister(busID: "3-2")
        #expect(removed?.descriptor.busID == "3-2")
        #expect(manager.claimedBusIDs == ["1-4"])
        #expect(manager.exportedDevice(busID: "3-2") == nil)
    }

    @Test func portDefaultsToUsbipVsockPort() {
        #expect(UsbipManager().port == VsockPorts.usbip)
    }
}

private final class StubExportedDevice: UsbipExportedDevice, @unchecked Sendable {
    let descriptor: UsbipDeviceDescriptor
    let submitPayload: [UInt8]
    private(set) var submitted: [UsbipSubmitCommand] = []

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
        let header = UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipUnlinkReply(header: header, status: 0)
    }
}

private func fixtureDescriptor(busID: String) -> UsbipDeviceDescriptor {
    UsbipDeviceDescriptor(
        path: "/sys/devices/pci0000:00/usb3/\(busID)",
        busID: busID,
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

private final class LoopbackVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound = [UInt8]()
    private var written = [UInt8]()
    private var finished = false
    private var closed = false

    func feed(_ bytes: [UInt8]) { lock.lock(); inbound.append(contentsOf: bytes); lock.unlock() }
    func finishAfterDrain() { lock.lock(); finished = true; lock.unlock() }
    var writes: [UInt8] { lock.lock(); defer { lock.unlock() }; return written }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = min(buffer.count, inbound.count)
        guard count > 0 else { return 0 }
        inbound.prefix(count).withUnsafeBytes { source in
            buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
        }
        inbound.removeFirst(count)
        return count
    }

    func write(_ bytes: [UInt8]) throws { lock.lock(); written.append(contentsOf: bytes); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var isPeerClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed || (finished && inbound.isEmpty) }
}
