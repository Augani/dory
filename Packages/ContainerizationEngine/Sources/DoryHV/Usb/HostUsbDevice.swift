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

public enum HostUsbOpenMode: Equatable, Sendable {
    case userAuthorized
    case seize
    case capture
}

public struct HostUsbOpenPlan: Equatable, Sendable {
    public var mode: HostUsbOpenMode
    public var authorize: Bool
    public var requiresPrivilegedHelperForClaimedDevice: Bool
    public var optionNames: [String]
}

public enum HostUsbOpenError: Error, Equatable, Sendable {
    case notFound(String)
    case authorizationFailed(kern_return_t)
    case openDeviceFailed
}

public enum HostUsbDeviceFactory: Sendable {
    public static func plan(mode: HostUsbOpenMode) -> HostUsbOpenPlan {
        switch mode {
        case .userAuthorized:
            HostUsbOpenPlan(mode: mode, authorize: true, requiresPrivilegedHelperForClaimedDevice: false, optionNames: [])
        case .seize:
            HostUsbOpenPlan(mode: mode, authorize: true, requiresPrivilegedHelperForClaimedDevice: false, optionNames: ["deviceSeize"])
        case .capture:
            HostUsbOpenPlan(mode: mode, authorize: true, requiresPrivilegedHelperForClaimedDevice: true, optionNames: ["deviceCapture"])
        }
    }

    public static func open(busID: String, mode: HostUsbOpenMode = .userAuthorized) throws -> HostUsbDevice {
        let (candidate, service) = try findService(busID: busID)
        defer { IOObjectRelease(service) }
        let plan = plan(mode: mode)
        if plan.authorize {
            let kr = IOServiceAuthorize(service, UInt32(kIOServiceInteractionAllowed))
            guard kr == KERN_SUCCESS else { throw HostUsbOpenError.authorizationFailed(kr) }
        }
        guard let device = DoryIOUSBHostCreateDevice(service, options(for: mode), nil) else {
            throw HostUsbOpenError.openDeviceFailed
        }
        let opened = collectPipes(deviceService: service, mode: mode)
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

    private static func collectPipes(deviceService: io_service_t, mode: HostUsbOpenMode) -> (interfaces: [IOUSBHostInterface], pipes: [UInt8: IOUSBHostPipe]) {
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

public protocol HostUsbBackend: Sendable {
    func control(_ setup: HostUsbControlSetup, payload: [UInt8], direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult
    func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult
    func abort(endpointAddress: UInt8?) throws
}

public final class HostUsbDevice: UsbipExportedDevice, @unchecked Sendable {
    public let descriptor: UsbipDeviceDescriptor
    private let backend: any HostUsbBackend
    private let timeout: TimeInterval

    public init(descriptor: UsbipDeviceDescriptor, backend: any HostUsbBackend, timeout: TimeInterval = 5) {
        self.descriptor = descriptor
        self.backend = backend
        self.timeout = timeout
    }

    public func submit(_ command: UsbipSubmitCommand) throws -> UsbipSubmitReply {
        guard command.numberOfPackets == 0 || command.numberOfPackets == 0xffff_ffff else {
            return reply(for: command, status: -EPIPE, actualLength: 0, data: [])
        }

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
                    timeout: command.header.endpoint == 0 ? timeout : (command.interval == 0 ? 0 : timeout)
                )
            }
            return reply(for: command, status: result.status, actualLength: result.actualLength, data: result.data)
        } catch let error as HostUsbTransferError {
            return reply(for: command, status: Self.usbipStatus(for: error), actualLength: 0, data: [])
        }
    }

    public func unlink(_ command: UsbipUnlinkCommand) throws -> UsbipUnlinkReply {
        let status: Int32
        do {
            try backend.abort(endpointAddress: nil)
            status = 0
        } catch let error as HostUsbTransferError {
            status = Self.usbipStatus(for: error)
        }
        let header = UsbipHeaderBasic(command: .retUnlink, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
        return UsbipUnlinkReply(header: header, status: status)
    }

    nonisolated public static func endpointAddress(number: UInt32, direction: UsbipDirection) -> UInt8 {
        UInt8(number & 0x0f) | (direction == .in ? 0x80 : 0x00)
    }

    private func reply(for command: UsbipSubmitCommand, status: Int32, actualLength: UInt32, data: [UInt8]) -> UsbipSubmitReply {
        let header = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: command.header.direction, endpoint: 0)
        return UsbipSubmitReply(header: header, status: status, actualLength: actualLength, transferBuffer: data)
    }

    private nonisolated static func usbipStatus(for error: HostUsbTransferError) -> Int32 {
        switch error {
        case .malformedSetup: -EINVAL
        case .endpointNotFound: -ENOENT
        case .failed(let errno): -abs(errno)
        }
    }
}

public final class IOUSBHostDeviceBackend: HostUsbBackend, @unchecked Sendable {
    private let controlObject: IOUSBHostObject?
    private let pipes: [UInt8: IOUSBHostPipe]
    private let retainedObjects: [IOUSBHostObject]
    private let controlHandler: (@Sendable (HostUsbControlSetup, [UInt8], UsbipDirection, TimeInterval) throws -> HostUsbTransferResult)?
    private let lock = NSLock()

    public init(
        controlObject: IOUSBHostObject? = nil,
        pipes: [UInt8: IOUSBHostPipe],
        retainedObjects: [IOUSBHostObject] = [],
        controlHandler: (@Sendable (HostUsbControlSetup, [UInt8], UsbipDirection, TimeInterval) throws -> HostUsbTransferResult)? = nil
    ) {
        self.controlObject = controlObject
        self.pipes = pipes
        self.retainedObjects = retainedObjects
        self.controlHandler = controlHandler
    }

    deinit {
        for object in retainedObjects {
            DoryIOUSBHostDestroyObject(object, [])
        }
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
        var transferred = 0
        let request = setup.ioUSBDeviceRequest()
        let ok = locked {
            DoryIOUSBHostSendDeviceRequest(controlObject, request, data, &transferred, timeout, nil)
        }
        guard ok else { throw HostUsbTransferError.failed(errno: EIO) }
        let bytes = direction == .in ? Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: min(transferred, data.length))) : []
        return HostUsbTransferResult(status: 0, actualLength: UInt32(transferred), data: bytes)
    }

    public func transfer(endpointAddress: UInt8, payload: [UInt8], expectedLength: UInt32, direction: UsbipDirection, timeout: TimeInterval) throws -> HostUsbTransferResult {
        guard let pipe = pipes[endpointAddress] else { throw HostUsbTransferError.endpointNotFound(endpointAddress) }
        let length = direction == .in ? Int(expectedLength) : payload.count
        guard let data = NSMutableData(length: length) else { throw HostUsbTransferError.failed(errno: ENOMEM) }
        if direction == .out {
            data.replaceBytes(in: NSRange(location: 0, length: min(payload.count, data.length)), withBytes: payload)
        }
        let completion = IOUSBCompletionBox()
        let status = locked {
            let semaphore = DispatchSemaphore(value: 0)
            do {
                try pipe.enqueueIORequest(with: data, completionTimeout: timeout) { status, count in
                    completion.set(status: status, count: count)
                    semaphore.signal()
                }
            } catch {
                return kIOReturnError
            }
            semaphore.wait()
            return completion.result.status
        }
        guard status == kIOReturnSuccess else { throw HostUsbTransferError.failed(errno: Self.errno(for: status)) }
        let transferred = completion.result.count
        let bytes = direction == .in ? Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: min(transferred, data.length))) : []
        return HostUsbTransferResult(status: 0, actualLength: UInt32(transferred), data: bytes)
    }

    public func abort(endpointAddress: UInt8?) throws {
        if let endpointAddress {
            guard let pipe = pipes[endpointAddress] else {
                throw HostUsbTransferError.endpointNotFound(endpointAddress)
            }
            let ok = locked {
                DoryIOUSBHostAbortPipe(pipe, IOUSBHostAbortOption.synchronous, nil)
            }
            guard ok else { throw HostUsbTransferError.failed(errno: EIO) }
            return
        }
        var ok = true
        if let controlObject {
            ok = locked {
                DoryIOUSBHostAbortDeviceRequests(controlObject, IOUSBHostAbortOption.synchronous, nil)
            }
        }
        guard ok else { throw HostUsbTransferError.failed(errno: EIO) }
        for pipe in pipes.values {
            let pipeOK = locked {
                DoryIOUSBHostAbortPipe(pipe, IOUSBHostAbortOption.synchronous, nil)
            }
            guard pipeOK else { throw HostUsbTransferError.failed(errno: EIO) }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
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
}

private final class IOUSBCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: IOReturn = kIOReturnError
    private var storedCount = 0

    func set(status: IOReturn, count: Int) {
        lock.lock()
        storedStatus = status
        storedCount = count
        lock.unlock()
    }

    var result: (status: IOReturn, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (storedStatus, storedCount)
    }
}
