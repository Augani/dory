import Darwin
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import DoryHVUSBShim

public struct HostUsbDeviceCandidate: Codable, Equatable, Sendable {
    public var descriptor: UsbipDeviceDescriptor
    public var vendorName: String?
    public var productName: String?
    public var serialNumber: String?
    public var locationID: UInt32?

    public init(
        descriptor: UsbipDeviceDescriptor,
        vendorName: String? = nil,
        productName: String? = nil,
        serialNumber: String? = nil,
        locationID: UInt32? = nil
    ) {
        self.descriptor = descriptor
        self.vendorName = vendorName
        self.productName = productName
        self.serialNumber = serialNumber
        self.locationID = locationID
    }
}

public enum HostUsbDiscoveryError: Error, Equatable, Sendable {
    case matchingFailed(kern_return_t)
}

public enum HostUsbOpenMode: Hashable, Sendable {
    case userAuthorized
    case seize
    case capture
}

public enum HostUsbOpenError: Error, Equatable, Sendable {
    case notFound(String)
    case authorizationFailed(kern_return_t)
    case openDeviceFailed
}

public enum HostUsbDeviceFactory: Sendable {
    public static func open(busID: String, mode: HostUsbOpenMode = .userAuthorized) throws -> HostUsbDevice {
        let (candidate, service) = try findService(busID: busID)
        defer { IOObjectRelease(service) }
        let kr = IOServiceAuthorize(service, UInt32(kIOServiceInteractionAllowed))
        guard kr == KERN_SUCCESS else { throw HostUsbOpenError.authorizationFailed(kr) }
        guard let device = DoryIOUSBHostCreateDevice(service, options(for: mode), nil) else {
            throw HostUsbOpenError.openDeviceFailed
        }
        let opened = collectPipes(deviceService: service)
        let retained: [IOUSBHostObject] = [device] + opened.interfaces
        let backend = IOUSBHostDeviceBackend(controlObject: device, pipes: opened.pipes, retainedObjects: retained)
        return HostUsbDevice(descriptor: candidate.descriptor, backend: backend)
    }

    private static func findService(busID: String) throws -> (HostUsbDeviceCandidate, io_service_t) {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard kr == KERN_SUCCESS else { throw HostUsbDiscoveryError.matchingFailed(kr) }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = props?.takeRetainedValue() as? [String: Any],
                  let candidate = HostUsbDiscovery.candidate(from: dictionary, service: service),
                  candidate.descriptor.busID == busID else { continue }
            IOObjectRetain(service)
            return (candidate, service)
        }
        throw HostUsbOpenError.notFound(busID)
    }

    private static func collectPipes(deviceService: io_service_t) -> (interfaces: [IOUSBHostInterface], pipes: [UInt8: IOUSBHostPipe]) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(deviceService, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return ([], [:])
        }
        defer { IOObjectRelease(iterator) }

        var interfaces: [IOUSBHostInterface] = []
        var pipes: [UInt8: IOUSBHostPipe] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard IOObjectConformsTo(service, "IOUSBHostInterface") != 0,
                  let hostInterface = DoryIOUSBHostCreateInterface(service, [], nil) else {
                continue
            }
            var interfaceHasPipe = false
            for endpoint in UInt8(1)...UInt8(15) {
                for address in [endpoint, endpoint | 0x80] {
                    if pipes[address] == nil, let pipe = DoryIOUSBHostCopyPipe(hostInterface, UInt(address), nil) {
                        pipes[address] = pipe
                        interfaceHasPipe = true
                    }
                }
            }
            if interfaceHasPipe {
                interfaces.append(hostInterface)
            } else {
                DoryIOUSBHostDestroyObject(hostInterface, [])
            }
        }
        return (interfaces, pipes)
    }

    private static func options(for mode: HostUsbOpenMode) -> IOUSBHostObjectInitOptions {
        switch mode {
        case .userAuthorized: []
        case .seize: .deviceSeize
        case .capture: .deviceCapture
        }
    }
}

public enum HostUsbDiscovery: Sendable {
    public static func list() throws -> [HostUsbDeviceCandidate] {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard kr == KERN_SUCCESS else { throw HostUsbDiscoveryError.matchingFailed(kr) }
        defer { IOObjectRelease(iterator) }

        var result: [HostUsbDeviceCandidate] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = props?.takeRetainedValue() as? [String: Any] else { continue }
            if let candidate = candidate(from: dictionary, service: service) {
                result.append(candidate)
            }
        }
        return result.sorted { $0.descriptor.busID < $1.descriptor.busID }
    }

    public static func candidate(from properties: [String: Any], service: io_registry_entry_t = 0) -> HostUsbDeviceCandidate? {
        guard let vendorID = uint16(properties, keys: ["idVendor", "USB Vendor ID"]),
              let productID = uint16(properties, keys: ["idProduct", "USB Product ID"]) else { return nil }
        let locationID = uint32(properties, keys: ["locationID", "LocationID", "USB LocationID"])
        let deviceNumber = uint32(properties, keys: ["USB Address", "bDeviceAddress", "Device Address"]) ?? UInt32(service & 0xffff)
        let busNumber = busNumber(fromLocationID: locationID)
        let busID = properties["DoryBusID"] as? String ?? "\(busNumber)-\(deviceNumber)"
        let path = registryPath(for: service, fallbackBusID: busID)
        let descriptor = UsbipDeviceDescriptor(
            path: path,
            busID: busID,
            busNumber: busNumber,
            deviceNumber: deviceNumber,
            speed: uint32(properties, keys: ["Device Speed", "speed", "USB Speed"]) ?? 0,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: uint16(properties, keys: ["bcdDevice", "USB Product Revision"]) ?? 0,
            deviceClass: uint8(properties, keys: ["bDeviceClass", "USB Device Class"]) ?? 0,
            deviceSubClass: uint8(properties, keys: ["bDeviceSubClass", "USB Device Subclass"]) ?? 0,
            deviceProtocol: uint8(properties, keys: ["bDeviceProtocol", "USB Device Protocol"]) ?? 0,
            configurationValue: uint8(properties, keys: ["bConfigurationValue", "CurrentConfiguration", "USB Current Configuration"]) ?? 1,
            configurationCount: uint8(properties, keys: ["bNumConfigurations", "USB Configurations"]) ?? 1,
            interfaceCount: uint8(properties, keys: ["bNumInterfaces", "USB Interfaces"]) ?? 0
        )
        return HostUsbDeviceCandidate(
            descriptor: descriptor,
            vendorName: string(properties, keys: ["USB Vendor Name", "kUSBVendorString", "iManufacturer"]),
            productName: string(properties, keys: ["USB Product Name", "kUSBProductString", "iProduct"]),
            serialNumber: string(properties, keys: ["USB Serial Number", "kUSBSerialNumberString", "iSerialNumber"]),
            locationID: locationID
        )
    }

    private static func registryPath(for service: io_registry_entry_t, fallbackBusID: String) -> String {
        guard service != 0 else { return "/io/usb/\(fallbackBusID)" }
        var path = [CChar](repeating: 0, count: 512)
        if IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS {
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return "/io/usb/\(fallbackBusID)"
    }

    private static func busNumber(fromLocationID locationID: UInt32?) -> UInt32 {
        guard let locationID else { return 0 }
        return max(1, (locationID >> 24) & 0xff)
    }

    private static func string(_ properties: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = properties[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func uint8(_ properties: [String: Any], keys: [String]) -> UInt8? {
        uint32(properties, keys: keys).flatMap { UInt8(exactly: $0) }
    }

    private static func uint16(_ properties: [String: Any], keys: [String]) -> UInt16? {
        uint32(properties, keys: keys).flatMap { UInt16(exactly: $0) }
    }

    private static func uint32(_ properties: [String: Any], keys: [String]) -> UInt32? {
        for key in keys {
            guard let raw = properties[key] else { continue }
            if let value = raw as? UInt32 { return value }
            if let value = raw as? UInt16 { return UInt32(value) }
            if let value = raw as? UInt8 { return UInt32(value) }
            if let value = raw as? Int, value >= 0 { return UInt32(value) }
            if let value = raw as? NSNumber { return value.uint32Value }
            if let value = raw as? String {
                if value.lowercased().hasPrefix("0x") { return UInt32(value.dropFirst(2), radix: 16) }
                if let decimal = UInt32(value) { return decimal }
            }
        }
        return nil
    }
}

public struct HostUsbControlSetup: Equatable, Sendable {
    public var requestType: UInt8
    public var request: UInt8
    public var value: UInt16
    public var index: UInt16
    public var length: UInt16

    public init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: UInt16) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
        self.length = length
    }

    public init(usbipSetup bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw HostUsbTransferError.malformedSetup }
        self.init(
            requestType: bytes[0],
            request: bytes[1],
            value: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8),
            index: UInt16(bytes[4]) | (UInt16(bytes[5]) << 8),
            length: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        )
    }

    public func ioUSBDeviceRequest() -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(
            bmRequestType: requestType,
            bRequest: request,
            wValue: value,
            wIndex: index,
            wLength: length
        )
    }
}

public struct HostUsbTransferResult: Equatable, Sendable {
    public var status: Int32
    public var actualLength: UInt32
    public var data: [UInt8]

    public init(status: Int32, actualLength: UInt32, data: [UInt8] = []) {
        self.status = status
        self.actualLength = actualLength
        self.data = data
    }
}

public enum HostUsbTransferError: Error, Equatable, Sendable {
    case malformedSetup
    case endpointNotFound(UInt8)
    case failed(errno: Int32)
}

public enum HostUsbTransferKind: Equatable, Sendable {
    case bulk
    case interrupt
}

public protocol HostUsbBackend: Sendable {
    func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult
    func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, kind: HostUsbTransferKind, timeout: TimeInterval) throws -> HostUsbTransferResult
    func abort(endpointAddress: UInt8?) throws
}

public final class HostUsbDevice: UsbipExportedDevice, @unchecked Sendable {
    /// Linux `EREMOTEIO`, used on the USB/IP wire for `URB_SHORT_NOT_OK`.
    private static let linuxRemoteIO: Int32 = 121

    private struct RequestKey: Hashable {
        var contextID: UUID
        var sequenceNumber: UInt32
    }

    private struct ActiveRequest {
        var endpointAddress: UInt8
        var reservedBytes: UInt64
    }

    public let descriptor: UsbipDeviceDescriptor
    private let backend: any HostUsbBackend
    private let timeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private let maxConcurrentRequests: Int
    private let maxInFlightBytes: UInt64
    private let state = NSCondition()
    private var activeRequests: [RequestKey: ActiveRequest] = [:]
    private var inFlightBytes: UInt64 = 0
    private var abortingEndpoints = Set<UInt8>()
    private var shuttingDown = false

    public init(
        descriptor: UsbipDeviceDescriptor,
        backend: any HostUsbBackend,
        timeout: TimeInterval = 5,
        maxConcurrentRequests: Int = 8,
        maxInFlightBytes: UInt64 = 16 * 1024 * 1024,
        shutdownTimeout: TimeInterval = 2
    ) {
        self.descriptor = descriptor
        self.backend = backend
        self.timeout = Self.finiteDeadline(timeout, fallback: 5)
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxInFlightBytes = max(1, maxInFlightBytes)
        self.shutdownTimeout = Self.finiteDeadline(shutdownTimeout, fallback: 2)
    }

    public func submit(_ command: UsbipSubmitCommand, context: UsbipRequestContext) throws -> UsbipSubmitReply {
        do {
            try UsbipSubmitCommand.validateTransferFlags(
                command.transferFlags,
                direction: command.header.direction
            )
        } catch {
            return reply(for: command, status: -EINVAL, actualLength: 0, data: [])
        }
        // Accept both non-iso values produced/required by Linux USB/IP; positive counts are
        // isochronous and remain unsupported by this backend.
        guard command.numberOfPackets == 0 || command.numberOfPackets == UInt32.max else {
            return reply(for: command, status: -EPIPE, actualLength: 0, data: [])
        }
        guard command.header.endpoint <= 15,
              command.transferBufferLength <= UsbipSubmitCommand.maxTransferBytes,
              (command.header.direction == .in || command.transferBuffer.count == Int(command.transferBufferLength)) else {
            return reply(for: command, status: -EINVAL, actualLength: 0, data: [])
        }

        let endpointAddress = command.header.endpoint == 0
            ? UInt8(0)
            : Self.endpointAddress(number: command.header.endpoint, direction: command.header.direction)
        let key = RequestKey(contextID: context.id, sequenceNumber: command.header.sequenceNumber)
        let reservation = UInt64(command.transferBufferLength)
        if let admissionError = admit(key: key, endpointAddress: endpointAddress, bytes: reservation) {
            return reply(for: command, status: -admissionError, actualLength: 0, data: [])
        }
        defer { finish(key: key) }

        do {
            let result: HostUsbTransferResult
            if command.header.endpoint == 0 {
                let setup = try HostUsbControlSetup(usbipSetup: command.setup)
                let payload = command.header.direction == .out ? command.transferBuffer : []
                result = try backend.control(setup, payload: payload, direction: command.header.direction, timeout: timeout)
            } else {
                result = try backend.transfer(
                    endpointAddress: Self.endpointAddress(number: command.header.endpoint, direction: command.header.direction),
                    payload: command.header.direction == .out ? command.transferBuffer : [],
                    expectedLength: command.transferBufferLength,
                    direction: command.header.direction,
                    kind: command.interval == 0 ? .bulk : .interrupt,
                    timeout: timeout
                )
            }
            let validated = try validate(result: result, for: command)
            return reply(for: command, status: validated.status, actualLength: validated.actualLength, data: validated.data)
        } catch let error as HostUsbTransferError {
            return reply(for: command, status: Self.usbipStatus(for: error), actualLength: 0, data: [])
        } catch {
            return reply(for: command, status: -EIO, actualLength: 0, data: [])
        }
    }

    public func unlink(_ command: UsbipUnlinkCommand, context: UsbipRequestContext) throws -> UsbipUnlinkReply {
        let status: Int32
        let targetKey = RequestKey(contextID: context.id, sequenceNumber: command.unlinkSequenceNumber)
        state.lock()
        if let target = activeRequests[targetKey] {
            let endpointIsShared = activeRequests.contains { key, request in
                key != targetKey && request.endpointAddress == target.endpointAddress
            }
            if endpointIsShared || abortingEndpoints.contains(target.endpointAddress) {
                state.unlock()
                status = -EBUSY
            } else {
                abortingEndpoints.insert(target.endpointAddress)
                state.unlock()
                do {
                    // Endpoint zero means only default-control requests. nil is reserved for
                    // terminal device shutdown and is never used by an untrusted UNLINK.
                    try backend.abort(endpointAddress: target.endpointAddress)
                    status = 0
                } catch let error as HostUsbTransferError {
                    status = Self.usbipStatus(for: error)
                } catch {
                    status = -EIO
                }
                state.lock()
                abortingEndpoints.remove(target.endpointAddress)
                state.broadcast()
                state.unlock()
            }
        } else {
            state.unlock()
            status = -ENOENT
        }
        let header = UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipUnlinkReply(header: header, status: status)
    }

    public func closeSession(_ context: UsbipRequestContext) {
        // The synchronous stream pump cannot race-proof a disconnect cancellation against a new
        // request entering the same pipe. Fail closed: leave it to the finite host deadline instead
        // of risking an abort of a later or unrelated URB. Explicit UNLINK uses the locked identity
        // check above; terminal detach uses shutdown().
    }

    public func shutdown() {
        state.lock()
        if shuttingDown {
            state.unlock()
            return
        }
        shuttingDown = true
        state.broadcast()
        state.unlock()

        let deadline = Date().addingTimeInterval(shutdownTimeout)
        Self.abort(backend, endpointAddress: nil, timeout: shutdownTimeout)
        state.lock()
        while !activeRequests.isEmpty, state.wait(until: deadline) {}
        state.unlock()
    }

    deinit {
        state.lock()
        let alreadyShuttingDown = shuttingDown
        shuttingDown = true
        state.unlock()
        if !alreadyShuttingDown {
            Self.abort(backend, endpointAddress: nil, timeout: shutdownTimeout)
        }
    }

    nonisolated public static func endpointAddress(number: UInt32, direction: UsbipDirection) -> UInt8 {
        precondition(number <= 15)
        return UInt8(number) | (direction == .in ? 0x80 : 0x00)
    }

    private func reply(for command: UsbipSubmitCommand, status: Int32, actualLength: UInt32, data: [UInt8]) -> UsbipSubmitReply {
        let header = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipSubmitReply(header: header, status: status, actualLength: actualLength, transferBuffer: data)
    }

    private nonisolated static func usbipStatus(for error: HostUsbTransferError) -> Int32 {
        switch error {
        case .malformedSetup: -EINVAL
        case .endpointNotFound: -ENOENT
        case .failed(let errno): -abs(errno)
        }
    }

    private func admit(key: RequestKey, endpointAddress: UInt8, bytes: UInt64) -> Int32? {
        state.lock()
        defer { state.unlock() }
        guard !shuttingDown else { return ENODEV }
        guard activeRequests[key] == nil else { return EALREADY }
        guard activeRequests.count < maxConcurrentRequests else { return EBUSY }
        guard !abortingEndpoints.contains(endpointAddress) else { return EBUSY }
        let (newTotal, overflow) = inFlightBytes.addingReportingOverflow(bytes)
        guard !overflow, newTotal <= maxInFlightBytes else { return EBUSY }
        inFlightBytes = newTotal
        activeRequests[key] = ActiveRequest(endpointAddress: endpointAddress, reservedBytes: bytes)
        return nil
    }

    private func finish(key: RequestKey) {
        state.lock()
        if let removed = activeRequests.removeValue(forKey: key) {
            inFlightBytes -= removed.reservedBytes
        }
        state.broadcast()
        state.unlock()
    }

    private func validate(result: HostUsbTransferResult, for command: UsbipSubmitCommand) throws -> HostUsbTransferResult {
        guard result.actualLength <= command.transferBufferLength else {
            throw HostUsbTransferError.failed(errno: EPROTO)
        }
        if command.header.direction == .in {
            guard result.data.count >= Int(result.actualLength),
                  result.data.count <= Int(command.transferBufferLength) else {
                throw HostUsbTransferError.failed(errno: EPROTO)
            }
            let shortTransferRejected = result.status == 0
                && command.transferFlags & UsbipTransferFlag.shortNotOK != 0
                && result.actualLength < command.transferBufferLength
            return HostUsbTransferResult(
                status: shortTransferRejected ? -Self.linuxRemoteIO : result.status,
                actualLength: result.actualLength,
                data: Array(result.data.prefix(Int(result.actualLength)))
            )
        }
        return HostUsbTransferResult(status: result.status, actualLength: result.actualLength)
    }

    private nonisolated static func finiteDeadline(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(value, 0.01), 60)
    }

    private nonisolated static func abort(
        _ backend: any HostUsbBackend,
        endpointAddress: UInt8?,
        timeout: TimeInterval
    ) {
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? backend.abort(endpointAddress: endpointAddress)
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + timeout)
    }
}

public final class IOUSBHostDeviceBackend: HostUsbBackend, @unchecked Sendable {
    private let controlObject: IOUSBHostObject?
    private let pipes: [UInt8: IOUSBHostPipe]
    private let lifetime: IOUSBObjectLifetime
    private let controlHandler: (@Sendable (HostUsbControlSetup, [UInt8], UsbipDirection, TimeInterval) throws -> HostUsbTransferResult)?
    private let abortLock = NSLock()

    public init(
        controlObject: IOUSBHostObject? = nil,
        pipes: [UInt8: IOUSBHostPipe],
        retainedObjects: [IOUSBHostObject] = [],
        controlHandler: (@Sendable (HostUsbControlSetup, [UInt8], UsbipDirection, TimeInterval) throws -> HostUsbTransferResult)? = nil
    ) {
        self.controlObject = controlObject
        self.pipes = pipes
        self.lifetime = IOUSBObjectLifetime(objects: retainedObjects)
        self.controlHandler = controlHandler
    }

    public func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        if let controlHandler {
            return try controlHandler(setup, payload, direction, timeout)
        }
        guard let controlObject else { throw HostUsbTransferError.failed(errno: ENOTSUP) }
        let length = direction == .in ? Int(setup.length) : payload.count
        guard let data = NSMutableData(length: length) else { throw HostUsbTransferError.failed(errno: ENOMEM) }
        if direction == .out {
            data.replaceBytes(in: NSRange(location: 0, length: min(payload.count, data.length)), withBytes: payload)
        }
        let request = setup.ioUSBDeviceRequest()
        let lease = IOUSBRequestLease(data: data, resource: controlObject, lifetime: lifetime)
        let result = try HostUsbDeadlineWaiter.perform(
            timeout: timeout,
            enqueue: { completion in
                DoryIOUSBHostEnqueueDeviceRequest(controlObject, request, data, timeout, nil) { status, count in
                    _ = lease
                    completion(status, Int(count))
                }
            },
            abort: { [self] in abortControlRequests() }
        )
        guard result.status == kIOReturnSuccess else {
            throw HostUsbTransferError.failed(errno: Self.errno(for: result.status))
        }
        let transferred = result.count
        guard transferred >= 0, transferred <= data.length, UInt32(exactly: transferred) != nil else {
            throw HostUsbTransferError.failed(errno: EPROTO)
        }
        let bytes = direction == .in ? Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: min(transferred, data.length))) : []
        return HostUsbTransferResult(status: 0, actualLength: UInt32(transferred), data: bytes)
    }

    public func transfer(
        endpointAddress: UInt8,
        payload: [UInt8],
        expectedLength: UInt32,
        direction: UsbipDirection,
        kind: HostUsbTransferKind,
        timeout: TimeInterval
    ) throws -> HostUsbTransferResult {
        guard let pipe = pipes[endpointAddress] else { throw HostUsbTransferError.endpointNotFound(endpointAddress) }
        let actualKind = try Self.transferKind(endpointAttributes: pipe.descriptors.pointee.descriptor.bmAttributes)
        guard actualKind == kind else { throw HostUsbTransferError.failed(errno: EPROTO) }
        let length = direction == .in ? Int(expectedLength) : payload.count
        guard let data = NSMutableData(length: length) else { throw HostUsbTransferError.failed(errno: ENOMEM) }
        if direction == .out {
            data.replaceBytes(in: NSRange(location: 0, length: min(payload.count, data.length)), withBytes: payload)
        }
        let lease = IOUSBRequestLease(data: data, resource: pipe, lifetime: lifetime)
        // IOUSBHost requires a zero framework timeout for interrupt pipes. Dory still applies the
        // finite outer deadline below and synchronously asks the exact pipe to abort on expiry.
        let frameworkTimeout = kind == .interrupt ? 0 : timeout
        let result = try HostUsbDeadlineWaiter.perform(
            timeout: timeout,
            enqueue: { completion in
                do {
                    try pipe.enqueueIORequest(with: data, completionTimeout: frameworkTimeout) { status, count in
                        _ = lease
                        completion(status, count)
                    }
                    return true
                } catch {
                    return false
                }
            },
            abort: { [self, lease] in
                guard let retainedPipe = lease.resource as? IOUSBHostPipe else { return }
                abortPipe(retainedPipe)
            }
        )
        guard result.status == kIOReturnSuccess else {
            throw HostUsbTransferError.failed(errno: Self.errno(for: result.status))
        }
        let transferred = result.count
        guard transferred >= 0, transferred <= data.length, UInt32(exactly: transferred) != nil else {
            throw HostUsbTransferError.failed(errno: EPROTO)
        }
        let bytes = direction == .in ? Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: min(transferred, data.length))) : []
        return HostUsbTransferResult(status: 0, actualLength: UInt32(transferred), data: bytes)
    }

    public func abort(endpointAddress: UInt8?) throws {
        if let endpointAddress {
            if endpointAddress == 0 {
                guard controlObject != nil else {
                    throw HostUsbTransferError.endpointNotFound(endpointAddress)
                }
                guard abortControlRequests() else { throw HostUsbTransferError.failed(errno: EIO) }
                return
            }
            guard let pipe = pipes[endpointAddress] else {
                throw HostUsbTransferError.endpointNotFound(endpointAddress)
            }
            let ok = abortPipe(pipe)
            guard ok else { throw HostUsbTransferError.failed(errno: EIO) }
            return
        }
        var ok = true
        if controlObject != nil {
            ok = abortControlRequests()
        }
        guard ok else { throw HostUsbTransferError.failed(errno: EIO) }
        for pipe in pipes.values {
            let pipeOK = abortPipe(pipe)
            guard pipeOK else { throw HostUsbTransferError.failed(errno: EIO) }
        }
    }

    @discardableResult
    private func abortControlRequests() -> Bool {
        guard let controlObject else { return true }
        abortLock.lock()
        defer { abortLock.unlock() }
        return DoryIOUSBHostAbortDeviceRequests(controlObject, IOUSBHostAbortOption.synchronous, nil)
    }

    @discardableResult
    private func abortPipe(_ pipe: IOUSBHostPipe) -> Bool {
        abortLock.lock()
        defer { abortLock.unlock() }
        return DoryIOUSBHostAbortPipe(pipe, IOUSBHostAbortOption.synchronous, nil)
    }

    nonisolated static func errno(for status: IOReturn) -> Int32 {
        switch status {
        case kIOReturnNotPermitted: EPERM
        case kIOReturnNoDevice: ENODEV
        case kIOReturnNotFound: ENOENT
        case kIOReturnNoResources: ENOMEM
        case kIOReturnTimeout: ETIMEDOUT
        case kIOReturnAborted: ECANCELED
        case kIOReturnNotOpen: ENODEV
        case kIOReturnNotResponding: ETIMEDOUT
        case kIOReturnExclusiveAccess: EBUSY
        default: EIO
        }
    }

    /// USB endpoint descriptor bits 0...1 define control, isochronous, bulk, or interrupt. Dory
    /// never trusts the guest's interval field to reclassify the physical host pipe.
    nonisolated static func transferKind(endpointAttributes: UInt8) throws -> HostUsbTransferKind {
        switch endpointAttributes & 0x03 {
        case 0x02: .bulk
        case 0x03: .interrupt
        case 0x01: throw HostUsbTransferError.failed(errno: ENOTSUP)
        default: throw HostUsbTransferError.failed(errno: EPROTO)
        }
    }
}

struct HostUsbIOCompletion: Equatable, Sendable {
    var status: IOReturn
    var count: Int
}

enum HostUsbDeadlineWaiter {
    typealias Completion = @Sendable (IOReturn, Int) -> Void

    static func perform(
        timeout: TimeInterval,
        enqueue: (_ completion: @escaping Completion) -> Bool,
        abort: @escaping @Sendable () -> Void
    ) throws -> HostUsbIOCompletion {
        let finiteTimeout = timeout.isFinite && timeout > 0 ? min(timeout, 60) : 5
        let completion = IOUSBCompletionBox()
        guard enqueue({ status, count in completion.complete(status: status, count: count) }) else {
            throw HostUsbTransferError.failed(errno: EIO)
        }
        if completion.wait(timeout: finiteTimeout) {
            return completion.result
        }

        // Never let a synchronous IOUSBHost abort turn the watchdog into another unbounded wait.
        // The closure retains the exact object/request lifetime until abort returns, and a late
        // completion only touches the locked completion box.
        let abortFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            abort()
            abortFinished.signal()
        }
        _ = completion.wait(timeout: min(0.25, finiteTimeout))
        _ = abortFinished.wait(timeout: .now() + min(0.25, finiteTimeout))
        throw HostUsbTransferError.failed(errno: ETIMEDOUT)
    }
}

private final class IOUSBCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedStatus: IOReturn = kIOReturnError
    private var storedCount = 0
    private var completed = false

    func complete(status: IOReturn, count: Int) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        storedStatus = status
        storedCount = count
        completed = true
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        lock.lock()
        let alreadyCompleted = completed
        lock.unlock()
        if alreadyCompleted { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    var result: HostUsbIOCompletion {
        lock.lock()
        defer { lock.unlock() }
        return HostUsbIOCompletion(status: storedStatus, count: storedCount)
    }
}

private final class IOUSBObjectLifetime: @unchecked Sendable {
    private let objects: [IOUSBHostObject]

    init(objects: [IOUSBHostObject]) {
        self.objects = objects
    }

    deinit {
        for object in objects {
            DoryIOUSBHostDestroyObject(object, [])
        }
    }
}

private final class IOUSBRequestLease: @unchecked Sendable {
    let data: NSMutableData
    let resource: AnyObject
    let lifetime: IOUSBObjectLifetime

    init(data: NSMutableData, resource: AnyObject, lifetime: IOUSBObjectLifetime) {
        self.data = data
        self.resource = resource
        self.lifetime = lifetime
    }
}
