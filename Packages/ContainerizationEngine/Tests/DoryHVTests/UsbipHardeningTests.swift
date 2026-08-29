import Darwin
import Foundation
import IOKit
import Testing
@testable import DoryHV

struct UsbipAdversarialProtocolTests {
    @Test func bothLinuxNonIsoPacketCountEncodingsRemainNonIso() throws {
        for sentinel in [UInt32(0), UInt32.max] {
            var bytes = validSubmit().encoded()
            setBE(sentinel, in: &bytes, at: 32)

            let metadata = try UsbipSubmitCommand.inspectHeader(bytes)
            #expect(!metadata.isIsochronous)
            #expect(metadata.numberOfPackets == sentinel)
            #expect(try UsbipSubmitCommand(decoding: bytes).numberOfPackets == sentinel)
        }
    }

    @Test func transferFlagsHaveExactDirectionAndSupportedSemantics() throws {
        var unknown = validSubmit().encoded()
        setBE(UsbipTransferFlag.directionIn | 0x8000_0000, in: &unknown, at: 20)
        #expect(throws: UsbipProtocolError.unknownTransferFlags(0x8000_0000)) {
            _ = try UsbipSubmitCommand(decoding: unknown)
        }

        var missingIn = validSubmit().encoded()
        setBE(UInt32(0), in: &missingIn, at: 20)
        #expect(throws: UsbipProtocolError.transferDirectionFlagMismatch(
            flags: 0,
            direction: .in
        )) {
            _ = try UsbipSubmitCommand(decoding: missingIn)
        }

        var falseIn = validSubmit(direction: .out).encoded()
        setBE(UsbipTransferFlag.directionIn, in: &falseIn, at: 20)
        #expect(throws: UsbipProtocolError.transferDirectionFlagMismatch(
            flags: UsbipTransferFlag.directionIn,
            direction: .out
        )) {
            _ = try UsbipSubmitCommand(decoding: falseIn)
        }

        for unsupported in [
            UsbipTransferFlag.isoAsSoonAsPossible,
            UsbipTransferFlag.zeroPacket,
        ] {
            var bytes = validSubmit().encoded()
            setBE(UsbipTransferFlag.directionIn | unsupported, in: &bytes, at: 20)
            #expect(throws: UsbipProtocolError.unsupportedTransferFlags(unsupported)) {
                _ = try UsbipSubmitCommand(decoding: bytes)
            }
        }

        var shortOut = validSubmit(direction: .out).encoded()
        setBE(UsbipTransferFlag.shortNotOK, in: &shortOut, at: 20)
        #expect(throws: UsbipProtocolError.unsupportedTransferFlags(
            UsbipTransferFlag.shortNotOK
        )) {
            _ = try UsbipSubmitCommand(decoding: shortOut)
        }

        let implementationLocal = UsbipTransferFlag.senderMemoryManagement
            | UsbipTransferFlag.senderSchedulingHints
            | UsbipTransferFlag.directionIn
        var accepted = validSubmit().encoded()
        setBE(implementationLocal, in: &accepted, at: 20)
        #expect(try UsbipSubmitCommand(decoding: accepted).transferFlags == implementationLocal)
    }

    @Test func unknownOperationAndDirectionNeverDefault() throws {
        var unknownOperation = validSubmit().encoded()
        setBE(UInt32(0x7fff_ffff), in: &unknownOperation, at: 0)
        #expect(throws: UsbipProtocolError.unknownOperation(0x7fff_ffff)) {
            _ = try UsbipSubmitCommand(decoding: unknownOperation)
        }

        var unknownDirection = validSubmit().encoded()
        setBE(UInt32(2), in: &unknownDirection, at: 12)
        #expect(throws: UsbipProtocolError.unknownDirection(2)) {
            _ = try UsbipSubmitCommand(decoding: unknownDirection)
        }
    }

    @Test func importRequiresExactCanonicalRequest() throws {
        var wrongVersion = UsbipImportRequest(busID: "3-2").encoded()
        setBE(UInt16(0x0110), in: &wrongVersion, at: 0)
        #expect(throws: UsbipProtocolError.invalidVersion(0x0110)) {
            _ = try UsbipImportRequest(decoding: wrongVersion)
        }

        var wrongOpcode = UsbipImportRequest(busID: "3-2").encoded()
        setBE(UInt16(0x8004), in: &wrongOpcode, at: 2)
        #expect(throws: UsbipProtocolError.unexpectedOpCode(0x8004)) {
            _ = try UsbipImportRequest(decoding: wrongOpcode)
        }

        var noncanonicalPadding = UsbipImportRequest(busID: "3-2").encoded()
        noncanonicalPadding[20] = 1
        #expect(throws: UsbipProtocolError.invalidString) {
            _ = try UsbipImportRequest(decoding: noncanonicalPadding)
        }

        var trailing = UsbipImportRequest(busID: "3-2").encoded()
        trailing.append(0)
        #expect(throws: UsbipProtocolError.invalidFrameLength(expected: 40, actual: 41)) {
            _ = try UsbipImportRequest(decoding: trailing)
        }
    }

    @Test func submitRejectsBadIdentityEndpointSetupAndLength() throws {
        var zeroSequence = validSubmit().encoded()
        setBE(UInt32(0), in: &zeroSequence, at: 4)
        #expect(throws: UsbipProtocolError.invalidSequenceNumber(0)) {
            _ = try UsbipSubmitCommand(decoding: zeroSequence)
        }

        var zeroDevice = validSubmit().encoded()
        setBE(UInt32(0), in: &zeroDevice, at: 8)
        #expect(throws: UsbipProtocolError.invalidDeviceID(0)) {
            _ = try UsbipSubmitCommand(decoding: zeroDevice)
        }

        var endpoint = validSubmit().encoded()
        setBE(UInt32(16), in: &endpoint, at: 16)
        #expect(throws: UsbipProtocolError.invalidEndpoint(16)) {
            _ = try UsbipSubmitCommand(decoding: endpoint)
        }

        var controlSetup = validControlSubmit().encoded()
        controlSetup[40] = 0x80 // setup says IN while the usbip header says OUT
        #expect(throws: UsbipProtocolError.invalidSetup) {
            _ = try UsbipSubmitCommand(decoding: controlSetup)
        }

        var oversized = validSubmit().encoded()
        setBE(UsbipSubmitCommand.maxTransferBytes + 1, in: &oversized, at: 24)
        #expect(throws: UsbipProtocolError.transferBufferTooLarge(UsbipSubmitCommand.maxTransferBytes + 1)) {
            _ = try UsbipSubmitCommand(decoding: oversized)
        }

        var trailing = validSubmit().encoded()
        trailing.append(0)
        #expect(throws: UsbipProtocolError.invalidFrameLength(expected: 48, actual: 49)) {
            _ = try UsbipSubmitCommand(decoding: trailing)
        }
    }

    @Test func unlinkRequiresExactCommandShapeAndReservedZeros() throws {
        let command = UsbipUnlinkCommand(
            header: UsbipHeaderBasic(command: .cmdUnlink, sequenceNumber: 22, deviceID: 0x0003_0002, direction: .out, endpoint: 0),
            unlinkSequenceNumber: 21
        )
        var wrongEndpoint = command.encoded()
        setBE(UInt32(1), in: &wrongEndpoint, at: 16)
        #expect(throws: UsbipProtocolError.invalidEndpoint(1)) {
            _ = try UsbipUnlinkCommand(decoding: wrongEndpoint)
        }

        var sameSequence = command.encoded()
        setBE(UInt32(22), in: &sameSequence, at: 20)
        #expect(throws: UsbipProtocolError.invalidSequenceNumber(22)) {
            _ = try UsbipUnlinkCommand(decoding: sameSequence)
        }

        var reserved = command.encoded()
        reserved[47] = 1
        #expect(throws: UsbipProtocolError.nonzeroReservedField) {
            _ = try UsbipUnlinkCommand(decoding: reserved)
        }
    }

    @Test func serverRejectsCommandForDifferentImportedDevice() throws {
        let device = HardeningExportedDevice(descriptor: hardeningDescriptor())
        let server = UsbipServer(devices: [device])
        let context = UsbipRequestContext()
        defer { server.closeSession(context, busID: "3-2") }
        var bytes = validSubmit().encoded()
        setBE(UInt32(0x0004_0001), in: &bytes, at: 8)

        #expect(throws: UsbipProtocolError.unexpectedDeviceID(expected: 0x0003_0002, actual: 0x0004_0001)) {
            _ = try server.handleURB(bytes, busID: "3-2", context: context)
        }
        #expect(device.submitCount == 0)
    }

    @Test func isochronousOutIsRejectedBeforePayloadReadOrHostIO() throws {
        let device = HardeningExportedDevice(descriptor: hardeningDescriptor())
        let connection = HardeningVsockConnection()
        connection.feed(UsbipImportRequest(busID: "3-2").encoded())
        var header = validSubmit(direction: .out).encoded()
        setBE(UsbipSubmitCommand.maxTransferBytes, in: &header, at: 24)
        setBE(UInt32(4), in: &header, at: 32)
        connection.feed(header)
        connection.finishAfterDrain()

        UsbipBridge(connection: connection, device: device).serve()

        #expect(device.submitCount == 0)
        #expect(connection.largestReadRequest == UsbipSubmitCommand.headerByteCount)
        let replies = connection.writes
        let submitReplyOffset = UsbipOperationHeader.byteCount + UsbipDeviceDescriptor.byteCount
        #expect(replies.count == submitReplyOffset + UsbipSubmitReply.headerByteCount)
        #expect(Array(replies[(submitReplyOffset + 20)..<(submitReplyOffset + 24)]) == [0xff, 0xff, 0xff, 0xe0]) // -EPIPE
    }

    @Test func oversizedOutDeclarationClosesBeforePayloadRead() {
        let device = HardeningExportedDevice(descriptor: hardeningDescriptor())
        let connection = HardeningVsockConnection()
        connection.feed(UsbipImportRequest(busID: "3-2").encoded())
        var header = validSubmit().encoded()
        setBE(UsbipSubmitCommand.maxTransferBytes + 1, in: &header, at: 24)
        connection.feed(header)
        connection.finishAfterDrain()

        UsbipBridge(connection: connection, device: device).serve()

        #expect(device.submitCount == 0)
        #expect(connection.largestReadRequest == UsbipSubmitCommand.headerByteCount)
        #expect(connection.writes.count == UsbipOperationHeader.byteCount + UsbipDeviceDescriptor.byteCount)
    }
}

@Suite(.serialized)
struct HostUsbRequestSafetyTests {
    @Test func shortNotOKProducesLinuxRemoteIOStatusOnShortInCompletion() throws {
        let backend = HardeningRecordingBackend(
            transferResult: HostUsbTransferResult(
                status: 0,
                actualLength: 2,
                data: [0xaa, 0xbb]
            )
        )
        let device = HostUsbDevice(descriptor: hardeningDescriptor(), backend: backend)
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }
        var command = validSubmit(sequence: 1, transferLength: 4)
        command.transferFlags |= UsbipTransferFlag.shortNotOK

        let reply = try device.submit(command, context: context)

        #expect(reply.status == -121)
        #expect(reply.actualLength == 2)
        #expect(reply.transferBuffer == [0xaa, 0xbb])
    }

    @Test func bulkAndInterruptAlwaysReceiveFiniteDoryDeadline() throws {
        let backend = HardeningRecordingBackend()
        let device = HostUsbDevice(descriptor: hardeningDescriptor(), backend: backend, timeout: 0)
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }

        _ = try device.submit(validSubmit(sequence: 1, endpoint: 2, interval: 0), context: context)
        _ = try device.submit(validSubmit(sequence: 2, endpoint: 3, interval: 8), context: context)

        let calls = backend.transferCalls
        #expect(calls.map(\.kind) == [.bulk, .interrupt])
        #expect(calls.allSatisfy { $0.timeout.isFinite && $0.timeout > 0 })
    }

    @Test func physicalEndpointDescriptorControlsTransferKindAndRejectsIsochronous() throws {
        #expect(try IOUSBHostDeviceBackend.transferKind(endpointAttributes: 0x02) == .bulk)
        #expect(try IOUSBHostDeviceBackend.transferKind(endpointAttributes: 0x83) == .interrupt)
        #expect(throws: HostUsbTransferError.failed(errno: ENOTSUP)) {
            _ = try IOUSBHostDeviceBackend.transferKind(endpointAttributes: 0x01)
        }
        #expect(throws: HostUsbTransferError.failed(errno: EPROTO)) {
            _ = try IOUSBHostDeviceBackend.transferKind(endpointAttributes: 0x00)
        }
    }

    @Test func duplicateAndConcurrentRequestsAreBackpressured() throws {
        let backend = BlockingHostUsbBackend()
        let device = HostUsbDevice(
            descriptor: hardeningDescriptor(),
            backend: backend,
            maxConcurrentRequests: 1,
            maxInFlightBytes: 64
        )
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }
        let result = SubmitResultBox()
        DispatchQueue.global().async {
            result.store(try? device.submit(validSubmit(sequence: 10), context: context))
        }
        #expect(backend.waitForStarted(count: 1))

        let duplicate = try device.submit(validSubmit(sequence: 10), context: context)
        let overloaded = try device.submit(validSubmit(sequence: 11), context: context)
        #expect(duplicate.status == -EALREADY)
        #expect(overloaded.status == -EBUSY)

        device.shutdown()
        #expect(result.wait())
    }

    @Test func aggregateTransferBytesAreBounded() throws {
        let backend = BlockingHostUsbBackend()
        let device = HostUsbDevice(
            descriptor: hardeningDescriptor(),
            backend: backend,
            maxConcurrentRequests: 2,
            maxInFlightBytes: 4
        )
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }
        let result = SubmitResultBox()
        DispatchQueue.global().async {
            result.store(try? device.submit(validSubmit(sequence: 20, transferLength: 4), context: context))
        }
        #expect(backend.waitForStarted(count: 1))

        let reply = try device.submit(validSubmit(sequence: 21, transferLength: 1), context: context)
        #expect(reply.status == -EBUSY)
        device.shutdown()
        #expect(result.wait())
    }

    @Test func unlinkIsSessionScopedAndAbortsOnlyExactEndpoint() throws {
        let backend = BlockingHostUsbBackend()
        let device = HostUsbDevice(descriptor: hardeningDescriptor(), backend: backend)
        let owner = UsbipRequestContext()
        let stranger = UsbipRequestContext()
        defer {
            device.closeSession(owner)
            device.closeSession(stranger)
        }
        let result = SubmitResultBox()
        DispatchQueue.global().async {
            result.store(try? device.submit(validSubmit(sequence: 30, endpoint: 2), context: owner))
        }
        #expect(backend.waitForStarted(count: 1))

        let unlink = unlinkCommand(sequence: 31, target: 30)
        let denied = try device.unlink(unlink, context: stranger)
        #expect(denied.status == -ENOENT)
        #expect(backend.abortEndpoints.isEmpty)

        let accepted = try device.unlink(unlink, context: owner)
        #expect(accepted.status == 0)
        #expect(backend.abortEndpoints.count == 1)
        #expect(backend.abortEndpoints.compactMap { $0 } == [UInt8(0x82)])
        #expect(result.wait())
    }

    @Test func unlinkFailsBusyRatherThanAbortAnotherRequestOnSamePipe() throws {
        let backend = BlockingHostUsbBackend()
        let device = HostUsbDevice(descriptor: hardeningDescriptor(), backend: backend, maxConcurrentRequests: 2)
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }
        let first = SubmitResultBox()
        let second = SubmitResultBox()
        DispatchQueue.global().async {
            first.store(try? device.submit(validSubmit(sequence: 40, endpoint: 2), context: context))
        }
        DispatchQueue.global().async {
            second.store(try? device.submit(validSubmit(sequence: 41, endpoint: 2), context: context))
        }
        #expect(backend.waitForStarted(count: 2))

        let reply = try device.unlink(unlinkCommand(sequence: 42, target: 40), context: context)
        #expect(reply.status == -EBUSY)
        #expect(backend.abortEndpoints.isEmpty)

        device.shutdown()
        #expect(first.wait())
        #expect(second.wait())
    }

    @Test func unregisterSynchronouslyAbortsAndClosesDeviceAuthority() throws {
        let backend = BlockingHostUsbBackend()
        let device = HostUsbDevice(descriptor: hardeningDescriptor(), backend: backend)
        let manager = UsbipManager()
        try registerCommittedUSBClaim(device, with: manager)
        let context = UsbipRequestContext()
        defer { device.closeSession(context) }
        let result = SubmitResultBox()
        DispatchQueue.global().async {
            result.store(try? device.submit(validSubmit(sequence: 50), context: context))
        }
        #expect(backend.waitForStarted(count: 1))

        _ = try unregisterUSBClaim(busID: "3-2", with: manager)

        #expect(backend.abortEndpoints.contains { $0 == nil })
        #expect(result.wait())
        let afterDetach = try device.submit(validSubmit(sequence: 51), context: context)
        #expect(afterDetach.status == -ENODEV)
    }

    @Test func completionWatchdogTimesOutAbortsAndToleratesLateCompletion() throws {
        let holder = CompletionHolder()
        let aborts = LockedCounter()
        let started = ProcessInfo.processInfo.systemUptime

        #expect(throws: HostUsbTransferError.failed(errno: ETIMEDOUT)) {
            _ = try HostUsbDeadlineWaiter.perform(
                timeout: 0.02,
                enqueue: { completion in holder.store(completion); return true },
                abort: { aborts.increment() }
            )
        }

        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        #expect(aborts.value == 1)
        holder.complete(status: kIOReturnSuccess, count: 1)
    }
}

private final class HardeningExportedDevice: UsbipExportedDevice, @unchecked Sendable {
    let descriptor: UsbipDeviceDescriptor
    private let lock = NSLock()
    private var storedSubmitCount = 0

    init(descriptor: UsbipDeviceDescriptor) {
        self.descriptor = descriptor
    }

    var submitCount: Int { lock.withLock { storedSubmitCount } }

    func submit(
        _ command: UsbipSubmitCommand,
        context: UsbipRequestContext
    ) throws -> UsbipSubmitReply {
        lock.withLock { storedSubmitCount += 1 }
        return UsbipSubmitReply(
            header: UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0),
            status: 0,
            actualLength: 0
        )
    }

    func unlink(
        _ command: UsbipUnlinkCommand,
        context: UsbipRequestContext
    ) throws -> UsbipUnlinkReply {
        UsbipUnlinkReply(
            header: UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0),
            status: 0
        )
    }

    func closeSession(_ context: UsbipRequestContext) {}
    func shutdown() {}
}

private final class HardeningRecordingBackend: HostUsbBackend, @unchecked Sendable {
    struct TransferCall: Sendable {
        var kind: HostUsbTransferKind
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var storedTransferCalls: [TransferCall] = []
    private let transferResult: HostUsbTransferResult?
    var transferCalls: [TransferCall] { lock.withLock { storedTransferCalls } }

    init(transferResult: HostUsbTransferResult? = nil) {
        self.transferResult = transferResult
    }

    func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        HostUsbTransferResult(status: 0, actualLength: 0)
    }

    func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, kind: HostUsbTransferKind, timeout: TimeInterval) throws -> HostUsbTransferResult {
        lock.withLock { storedTransferCalls.append(TransferCall(kind: kind, timeout: timeout)) }
        if let transferResult { return transferResult }
        return HostUsbTransferResult(status: 0, actualLength: expectedLength, data: direction == .in ? [UInt8](repeating: 0, count: Int(expectedLength)) : [])
    }

    func abort(endpointAddress: UInt8?) throws {}
}

private final class BlockingHostUsbBackend: HostUsbBackend, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = 0
    private var released = false
    private var storedAbortEndpoints: [UInt8?] = []

    var abortEndpoints: [UInt8?] {
        condition.withLock { storedAbortEndpoints }
    }

    func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        try block(expectedLength: UInt32(direction == .in ? Int(setup.length) : payload.count), direction: direction)
    }

    func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, kind: HostUsbTransferKind, timeout: TimeInterval) throws -> HostUsbTransferResult {
        try block(expectedLength: expectedLength, direction: direction)
    }

    func abort(endpointAddress: UInt8?) throws {
        condition.lock()
        storedAbortEndpoints.append(endpointAddress)
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForStarted(count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        defer { condition.unlock() }
        while started < count {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    private func block(expectedLength: UInt32, direction: UsbipDirection) throws -> HostUsbTransferResult {
        condition.lock()
        started += 1
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        throw HostUsbTransferError.failed(errno: ECANCELED)
    }
}

private final class SubmitResultBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var complete = false
    private var reply: UsbipSubmitReply?

    func store(_ reply: UsbipSubmitReply?) {
        condition.lock()
        self.reply = reply
        complete = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        defer { condition.unlock() }
        while !complete {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

private final class CompletionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: HostUsbDeadlineWaiter.Completion?

    func store(_ completion: @escaping HostUsbDeadlineWaiter.Completion) {
        lock.withLock { self.completion = completion }
    }

    func complete(status: IOReturn, count: Int) {
        let callback = lock.withLock { completion }
        callback?(status, count)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class HardeningVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [UInt8] = []
    private var outbound: [UInt8] = []
    private var finished = false
    private var closed = false
    private var maxRead = 0

    func feed(_ bytes: [UInt8]) { lock.withLock { inbound += bytes } }
    func finishAfterDrain() { lock.withLock { finished = true } }
    var writes: [UInt8] { lock.withLock { outbound } }
    var largestReadRequest: Int { lock.withLock { maxRead } }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        maxRead = max(maxRead, buffer.count)
        let count = min(buffer.count, inbound.count)
        guard count > 0 else { return 0 }
        inbound.prefix(count).withUnsafeBytes { source in
            buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
        }
        inbound.removeFirst(count)
        return count
    }

    func write(_ bytes: [UInt8]) throws { lock.withLock { outbound += bytes } }
    func close() { lock.withLock { closed = true } }
    func shutdownSend() {}
    var isPeerClosed: Bool { lock.withLock { closed || (finished && inbound.isEmpty) } }
}

private func validSubmit(
    sequence: UInt32 = 7,
    endpoint: UInt32 = 1,
    direction: UsbipDirection = .in,
    transferLength: UInt32 = 0,
    interval: UInt32 = 0
) -> UsbipSubmitCommand {
    UsbipSubmitCommand(
        header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: sequence, deviceID: 0x0003_0002, direction: direction, endpoint: endpoint),
        transferFlags: direction == .in ? UsbipTransferFlag.directionIn : 0,
        transferBufferLength: transferLength,
        startFrame: UInt32.max,
        numberOfPackets: 0,
        interval: interval,
        setup: [UInt8](repeating: 0, count: 8),
        transferBuffer: direction == .out ? [UInt8](repeating: 0, count: Int(transferLength)) : []
    )
}

private func validControlSubmit() -> UsbipSubmitCommand {
    UsbipSubmitCommand(
        header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 8, deviceID: 0x0003_0002, direction: .out, endpoint: 0),
        transferFlags: 0,
        transferBufferLength: 0,
        startFrame: UInt32.max,
        numberOfPackets: 0,
        interval: 0,
        setup: [0, 1, 0, 0, 0, 0, 0, 0],
        transferBuffer: []
    )
}

private func unlinkCommand(sequence: UInt32, target: UInt32) -> UsbipUnlinkCommand {
    UsbipUnlinkCommand(
        header: UsbipHeaderBasic(command: .cmdUnlink, sequenceNumber: sequence, deviceID: 0x0003_0002, direction: .out, endpoint: 0),
        unlinkSequenceNumber: target
    )
}

private func hardeningDescriptor() -> UsbipDeviceDescriptor {
    UsbipDeviceDescriptor(
        path: "/io/usb/3-2",
        busID: "3-2",
        busNumber: 3,
        deviceNumber: 2,
        speed: 2,
        vendorID: 0x1234,
        productID: 0xabcd,
        bcdDevice: 0x0100,
        deviceClass: 0,
        deviceSubClass: 0,
        deviceProtocol: 0,
        configurationValue: 1,
        configurationCount: 1,
        interfaceCount: 1
    )
}

private func setBE(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
}

private func setBE(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
