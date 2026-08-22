import CoreFoundation
import Foundation
import IOKit

/// A bounded, non-secret projection of one attachable host USB device. Serial numbers and registry
/// paths are intentionally excluded from the public control plane.
public struct DoryHostUSBDevice: Equatable, Sendable {
    public var busID: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var vendorName: String
    public var productName: String
    public var deviceClass: UInt8
    public var speed: UInt32

    public init(
        busID: String,
        vendorID: UInt16,
        productID: UInt16,
        vendorName: String = "",
        productName: String = "",
        deviceClass: UInt8 = 0,
        speed: UInt32 = 0
    ) {
        self.busID = busID
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.productName = productName
        self.deviceClass = deviceClass
        self.speed = speed
    }

    var isValid: Bool {
        Self.isValidBusID(busID)
            && Self.isValidDisplayName(vendorName)
            && Self.isValidDisplayName(productName)
    }

    var xpcDictionary: NSDictionary {
        [
            "busID": busID,
            "vendorID": vendorID,
            "productID": productID,
            "vendorName": vendorName,
            "productName": productName,
            "deviceClass": deviceClass,
            "speed": speed,
        ]
    }

    fileprivate static func isValidBusID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1..<32).contains(bytes.count),
              bytes.first.map({ (48...57).contains($0) }) == true,
              bytes.last.map({ (48...57).contains($0) }) == true else {
            return false
        }
        return bytes.allSatisfy { (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }

    fileprivate static func isValidDisplayName(_ value: String) -> Bool {
        value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public protocol DoryHostUSBDiscovering: Sendable {
    func devices() throws -> [DoryHostUSBDevice]
}

public enum DoryHostUSBDiscoveryError: Error, Equatable, Sendable, CustomStringConvertible {
    case matchingFailed(kern_return_t)
    case invalidDeviceProjection
    case duplicateBusID(String)
    case tooManyDevices

    public var description: String {
        switch self {
        case let .matchingFailed(code):
            return "host USB discovery failed with IOKit status \(code)"
        case .invalidDeviceProjection:
            return "host USB discovery returned an invalid device projection"
        case let .duplicateBusID(busID):
            return "host USB discovery returned duplicate bus identifier \(busID)"
        case .tooManyDevices:
            return "host USB discovery exceeded its bounded device limit"
        }
    }
}

enum DoryHostUSBProjection {
    static let maximumDeviceCount = 256

    static func validated(_ devices: [DoryHostUSBDevice]) throws -> [DoryHostUSBDevice] {
        guard devices.count <= maximumDeviceCount else {
            throw DoryHostUSBDiscoveryError.tooManyDevices
        }
        guard devices.allSatisfy(\.isValid) else {
            throw DoryHostUSBDiscoveryError.invalidDeviceProjection
        }
        let sorted = devices.sorted { $0.busID < $1.busID }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.busID == pair.1.busID {
            throw DoryHostUSBDiscoveryError.duplicateBusID(pair.0.busID)
        }
        return sorted
    }
}

/// Read-only IOKit discovery. Attachment still reopens and validates the selected device inside the
/// launch-pinned raw-HV helper, so this advisory snapshot never grants device authority.
public struct IOKitDoryHostUSBDiscovery: DoryHostUSBDiscovering, Sendable {
    public init() {}

    public func devices() throws -> [DoryHostUSBDevice] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        )
        guard status == KERN_SUCCESS else {
            throw DoryHostUSBDiscoveryError.matchingFailed(status)
        }
        defer { IOObjectRelease(iterator) }

        var devices: [DoryHostUSBDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any],
            let device = Self.device(from: dictionary, service: service) else {
                continue
            }
            devices.append(device)
        }

        return try DoryHostUSBProjection.validated(devices)
    }

    static func device(
        from properties: [String: Any],
        service: io_registry_entry_t = 0
    ) -> DoryHostUSBDevice? {
        guard let vendorID = uint16(properties, keys: ["idVendor", "USB Vendor ID"]),
              let productID = uint16(properties, keys: ["idProduct", "USB Product ID"]),
              let deviceNumber = uint32(
                  properties,
                  keys: ["USB Address", "bDeviceAddress", "Device Address"]
              ) ?? (service == 0 ? nil : UInt32(service & 0xffff)),
              deviceNumber > 0 else {
            return nil
        }
        let locationID = uint32(
            properties,
            keys: ["locationID", "LocationID", "USB LocationID"]
        )
        let busNumber = locationID.map { max(1, ($0 >> 24) & 0xff) } ?? 0
        let busID = properties["DoryBusID"] as? String ?? "\(busNumber)-\(deviceNumber)"
        let candidate = DoryHostUSBDevice(
            busID: busID,
            vendorID: vendorID,
            productID: productID,
            vendorName: boundedName(
                properties,
                keys: ["USB Vendor Name", "kUSBVendorString", "iManufacturer"]
            ),
            productName: boundedName(
                properties,
                keys: ["USB Product Name", "kUSBProductString", "iProduct"]
            ),
            deviceClass: uint8(
                properties,
                keys: ["bDeviceClass", "USB Device Class"]
            ) ?? 0,
            speed: uint32(properties, keys: ["Device Speed", "speed", "USB Speed"]) ?? 0
        )
        return candidate.isValid ? candidate : nil
    }

    private static func boundedName(_ properties: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = properties[key] as? String, !value.isEmpty else { continue }
            if DoryHostUSBDevice.isValidDisplayName(value) { return value }
        }
        return ""
    }

    private static func uint8(_ properties: [String: Any], keys: [String]) -> UInt8? {
        uint32(properties, keys: keys).flatMap(UInt8.init(exactly:))
    }

    private static func uint16(_ properties: [String: Any], keys: [String]) -> UInt16? {
        uint32(properties, keys: keys).flatMap(UInt16.init(exactly:))
    }

    private static func uint32(_ properties: [String: Any], keys: [String]) -> UInt32? {
        for key in keys {
            guard let raw = properties[key] else { continue }
            if let value = raw as? UInt32 { return value }
            if let value = raw as? UInt16 { return UInt32(value) }
            if let value = raw as? UInt8 { return UInt32(value) }
            if let value = raw as? Int, value >= 0 { return UInt32(exactly: value) }
            if let value = raw as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID(),
               value.doubleValue.isFinite,
               value.doubleValue >= 0,
               value.doubleValue.rounded(.towardZero) == value.doubleValue,
               value.doubleValue <= Double(UInt32.max) {
                return UInt32(value.uint64Value)
            }
            if let value = raw as? String {
                if value.lowercased().hasPrefix("0x") {
                    return UInt32(value.dropFirst(2), radix: 16)
                }
                return UInt32(value)
            }
        }
        return nil
    }
}
