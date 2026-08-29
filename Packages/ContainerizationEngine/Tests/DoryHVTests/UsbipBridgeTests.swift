import Darwin
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
            header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 7, deviceID: 0x0003_0002, direction: .in, endpoint: 1),
            transferFlags: UsbipTransferFlag.directionIn, transferBufferLength: 2, startFrame: 0, numberOfPackets: 0, interval: 0,
            setup: [UInt8](repeating: 0, count: 8), transferBuffer: []
        )
        connection.feed(submit.encoded())
        connection.finishAfterDrain()

        let closed = UsbipLockedFlag()
        let bridge = UsbipBridge(
            connection: connection,
            device: device,
            onClose: { closed.set() }
        )
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
        #expect(closed.value)
    }

    @Test func bridgeRejectsUnknownBusIDWithStatusOne() throws {
        let device = StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2"))
        let connection = LoopbackVsockConnection()
        connection.feed(UsbipImportRequest(busID: "9-9").encoded())
        connection.finishAfterDrain()

        let closed = UsbipLockedFlag()
        let bridge = UsbipBridge(
            connection: connection,
            device: device,
            onClose: { closed.set() }
        )
        bridge.serve()

        // Unknown device → OP_REP_IMPORT with status 1 and no descriptor (8 bytes total).
        let written = connection.writes
        #expect(written.count == 8)
        let status = (UInt32(written[4]) << 24) | (UInt32(written[5]) << 16) | (UInt32(written[6]) << 8) | UInt32(written[7])
        #expect(status == 1)
        #expect(device.submitted.isEmpty)
        #expect(closed.value)
    }

    @Test func bridgeStopsImmediatelyIfPeerClosesBeforeImport() throws {
        let device = StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2"))
        let connection = LoopbackVsockConnection()
        connection.finishAfterDrain()

        let closed = UsbipLockedFlag()
        let bridge = UsbipBridge(
            connection: connection,
            device: device,
            onClose: { closed.set() }
        )
        bridge.serve()

        #expect(connection.writes.isEmpty)
        #expect(closed.value)
    }
}

struct UsbipManagerTests {
    @Test func registerUnregisterTracksClaimedDevicesByBusID() throws {
        let manager = UsbipManager()
        #expect(manager.claimedBusIDs.isEmpty)

        try registerCommittedUSBClaim(
            StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2")),
            with: manager
        )
        try registerCommittedUSBClaim(
            StubExportedDevice(descriptor: fixtureDescriptor(busID: "1-4")),
            with: manager
        )
        #expect(manager.claimedBusIDs == ["1-4", "3-2"])
        #expect(manager.exportedDevice(busID: "3-2")?.descriptor.busID == "3-2")
        #expect(manager.exportedDevices().count == 2)

        let removed = try unregisterUSBClaim(busID: "3-2", with: manager)
        #expect(removed.descriptor.busID == "3-2")
        #expect(manager.claimedBusIDs == ["1-4"])
        #expect(manager.exportedDevice(busID: "3-2") == nil)
    }

    @Test func portDefaultsToUsbipVsockPort() {
        #expect(UsbipManager().port == VsockPorts.usbip)
    }

    @Test func usbipListenerUsesSharedServiceLeaseAcrossResetAndReconnect() throws {
        let admissionLimits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 2,
            defaultMaximumSessionsPerService: 2,
            serviceOverrides: [.usbip: 1]
        )
        let vsock = VirtioVsock(
            guestCID: 3,
            serviceAdmissionLimits: admissionLimits
        )
        let manager = UsbipManager(maxActiveConnections: 2)
        try registerCommittedUSBClaim(
            StubExportedDevice(descriptor: fixtureDescriptor(busID: "3-2")),
            with: manager
        )
        try manager.attachListener(to: vsock)
        defer { _ = manager.stop(timeout: 2) }

        #expect(try request(vsock, guestPort: 40_000) == .response)
        #expect(waitUntil {
            vsock.serviceAdmissionSnapshot.activeSessionsByService[.usbip] == 1
        })
        #expect(try request(vsock, guestPort: 40_001) == .response)
        #expect(waitUntil {
            vsock.serviceAdmissionSnapshot.serviceCapacityRejections[.usbip] == 1
        })

        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: vsock,
            memory: memory
        ) {}
        vsock.deviceReset(transport: transport)
        #expect(waitUntil { vsock.serviceAdmissionSnapshot.activeSessionsTotal == 0 })
        #expect(vsock.serviceAdmissionSnapshot.resetRevocations == 1)

        // Listener registration is VM configuration and survives the transport generation reset.
        #expect(try request(vsock, guestPort: 40_002) == .response)
        #expect(waitUntil {
            vsock.serviceAdmissionSnapshot.activeSessionsByService[.usbip] == 1
        })
    }

    private func request(
        _ device: VirtioVsock,
        guestPort: UInt32
    ) throws -> VirtioVsockHeader.Operation {
        let packet = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: VsockPorts.usbip,
            length: 0,
            operation: .request
        )
        let response = try #require(device.receive(packet: packet.encoded()).first)
        return try VirtioVsockHeader(decoding: response).operation
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            usleep(1_000)
        }
        return predicate()
    }
}

struct UsbControlHandlerTests {
    private func makeHandler(
        manager: UsbipManager = UsbipManager(),
        openFails: Bool = false,
        attachFails: Bool = false
    ) -> (UsbControlHandler, Box) {
        let box = Box()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, mode in
                box.opened.append((busID, mode))
                if openFails { throw UsbControlError.notAttached(busID) }
                return StubExportedDevice(descriptor: fixtureDescriptor(busID: busID))
            },
            notifyAttach: { req in
                box.attachCalls.append(req)
                if attachFails { throw UsbControlError.notAttached(req.busid) }
            },
            notifyDetach: { req in box.detachCalls.append(req) }
        )
        return (handler, box)
    }

    @Test func attachClaimsRegistersAndNotifiesGuest() async throws {
        let manager = UsbipManager()
        let (handler, box) = makeHandler(manager: manager)

        let outcome = try await handler.attach(busID: "3-2")

        #expect(box.opened.map(\.0) == ["3-2"])
        #expect(manager.claimedBusIDs == ["3-2"])
        #expect(box.attachCalls.count == 1)
        #expect(box.attachCalls.first?.busid == "3-2")
        #expect(box.attachCalls.first?.vsock_port == VsockPorts.usbip)
        #expect(box.attachCalls.first?.device_id == (UInt32(3) << 16) | 2) // busNumber 3, deviceNumber 2
        #expect(outcome.port == 0)
    }

    @Test func attachAllocatesDistinctPortsAndRejectsDuplicate() async throws {
        let (handler, _) = makeHandler()
        let a = try await handler.attach(busID: "3-2")
        let b = try await handler.attach(busID: "1-4")
        #expect(Set([a.port, b.port]) == [0, 1])
        await #expect(throws: UsbControlError.self) { _ = try await handler.attach(busID: "3-2") }
    }

    @Test func concurrentDuplicateAttachClaimsHostDeviceExactlyOnce() async {
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in
                StubExportedDevice(descriptor: fixtureDescriptor(busID: busID))
            },
            notifyAttach: { _ in await Task.yield() },
            notifyDetach: { _ in }
        )

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<2 {
                group.addTask { (try? await handler.attach(busID: "3-2")) != nil }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        #expect(successes == 1)
        #expect(handler.attachedBusIDs == ["3-2"])
        #expect(manager.claimedBusIDs == ["3-2"])
    }

    @Test func attachRollsBackWhenGuestNotifyFails() async throws {
        let manager = UsbipManager()
        let (handler, _) = makeHandler(manager: manager, attachFails: true)

        await #expect(throws: (any Error).self) { _ = try await handler.attach(busID: "3-2") }
        // The claim must be undone so the device returns to macOS.
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
    }

    @Test func unavailableGuestRPCFailsBeforeOpeningOrClaimingHostDevice() async throws {
        let manager = UsbipManager()
        let box = Box()
        let handler = UsbControlHandler(
            manager: manager,
            ensureSupported: { throw UsbControlError.guestAgentRPCUnavailable },
            openDevice: { busID, mode in
                box.opened.append((busID, mode))
                return StubExportedDevice(descriptor: fixtureDescriptor(busID: busID))
            },
            notifyAttach: { box.attachCalls.append($0) },
            notifyDetach: { box.detachCalls.append($0) }
        )

        await #expect(throws: UsbControlError.guestAgentRPCUnavailable) {
            _ = try await handler.attach(busID: "3-2")
        }
        await #expect(throws: UsbControlError.guestAgentRPCUnavailable) {
            try await handler.detach(busID: "3-2")
        }
        #expect(box.opened.isEmpty)
        #expect(box.attachCalls.isEmpty)
        #expect(box.detachCalls.isEmpty)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
    }

    @Test func detachNotifiesGuestUnregistersAndFreesPort() async throws {
        let manager = UsbipManager()
        let (handler, box) = makeHandler(manager: manager)
        _ = try await handler.attach(busID: "3-2")

        try await handler.detach(busID: "3-2")

        #expect(box.detachCalls.map(\.busid) == ["3-2"])
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
        // Port is freed for reuse.
        let again = try await handler.attach(busID: "3-2")
        #expect(again.port == 0)
    }

    @Test func detachOfUnknownBusIDThrows() async throws {
        let (handler, _) = makeHandler()
        await #expect(throws: UsbControlError.self) { try await handler.detach(busID: "9-9") }
    }

    final class Box: @unchecked Sendable {
        var opened: [(String, HostUsbOpenMode)] = []
        var attachCalls: [UsbAgentAttachRequest] = []
        var detachCalls: [UsbAgentDetachRequest] = []
    }
}

@Suite(.serialized)
struct UsbControlServerTests {
    @Test func createsOwnerPrivateSocketAndRemovesOnlyItsOwnNode() throws {
        let root = "/tmp/dory-usb-server-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        #expect(chmod(root, 0o700) == 0)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/u.sock"
        let server = UsbControlServer(path: path, handler: makeServerHandler())

        try server.start()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
        server.stop()
        #expect(lstat(path, &info) != 0)
    }

    @Test func refusesToReplaceRegularFile() throws {
        let root = "/tmp/dory-usb-server-file-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        #expect(chmod(root, 0o700) == 0)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/u.sock"
        let bytes = Data("keep-me".utf8)
        try bytes.write(to: URL(fileURLWithPath: path))
        let server = UsbControlServer(path: path, handler: makeServerHandler())

        #expect(throws: UsbControlServerError.self) { try server.start() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    }

    private func makeServerHandler() -> UsbControlHandler {
        UsbControlHandler(
            manager: UsbipManager(),
            openDevice: { busID, _ in
                StubExportedDevice(descriptor: fixtureDescriptor(busID: busID))
            },
            notifyAttach: { _ in },
            notifyDetach: { _ in }
        )
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

    func submit(
        _ command: UsbipSubmitCommand,
        context: UsbipRequestContext
    ) throws -> UsbipSubmitReply {
        submitted.append(command)
        let header = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipSubmitReply(header: header, status: 0, actualLength: UInt32(submitPayload.count), transferBuffer: submitPayload)
    }

    func unlink(
        _ command: UsbipUnlinkCommand,
        context: UsbipRequestContext
    ) throws -> UsbipUnlinkReply {
        let header = UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipUnlinkReply(header: header, status: 0)
    }

    func closeSession(_ context: UsbipRequestContext) {}
    func shutdown() {}
}

func registerCommittedUSBClaim(
    _ device: any UsbipExportedDevice,
    with manager: UsbipManager
) throws {
    let lease = try manager.beginControlMutation(
        operation: .attach,
        busID: device.descriptor.busID
    )
    defer { manager.finishControlMutation(lease) }
    try manager.register(device, under: lease)
    guard manager.withCurrentControlMutation(lease, { true }) == true else {
        throw UsbipManagerError.stopped
    }
}

@discardableResult
func unregisterUSBClaim(
    busID: String,
    with manager: UsbipManager
) throws -> (any UsbipExportedDevice) {
    let lease = try manager.beginControlMutation(operation: .detach, busID: busID)
    defer { manager.finishControlMutation(lease) }
    return try manager.unregisterClaim(under: lease)
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
    func shutdownSend() {}
    var isPeerClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed || (finished && inbound.isEmpty) }
}

private final class UsbipLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}
