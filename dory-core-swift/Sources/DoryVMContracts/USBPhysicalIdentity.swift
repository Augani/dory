import CryptoKit
import Foundation

public struct DoryUSBPhysicalIdentityToken: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

public enum DoryUSBPhysicalIdentityError: Error, Equatable, Sendable {
    case invalidLocationID
    case invalidSerialNumber
}

/// Stable physical identity used between read-only discovery and the later privileged open. The
/// transient USB address is deliberately excluded: reconnecting at the same physical topology can
/// change that address, while a different VID/PID/revision/serial tuple must never inherit a prior
/// selection. Only this digest crosses the public control plane; the device serial remains local.
public struct DoryUSBPhysicalIdentity: Equatable, Sendable {
    public static let maximumSerialNumberUTF8Bytes = 512

    public let locationID: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    public let bcdDevice: UInt16
    public let serialNumber: String

    public init(
        locationID: UInt32,
        vendorID: UInt16,
        productID: UInt16,
        bcdDevice: UInt16,
        serialNumber: String
    ) throws {
        guard locationID != 0 else { throw DoryUSBPhysicalIdentityError.invalidLocationID }
        let serialBytes = Array(serialNumber.utf8)
        guard serialBytes.count <= Self.maximumSerialNumberUTF8Bytes,
              !serialBytes.contains(0),
              serialNumber.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DoryUSBPhysicalIdentityError.invalidSerialNumber
        }
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
        self.bcdDevice = bcdDevice
        self.serialNumber = serialNumber
    }

    public var token: DoryUSBPhysicalIdentityToken {
        var bytes = Data("dory.usb.physical-identity@1\0".utf8)
        appendBigEndian(locationID, to: &bytes)
        appendBigEndian(vendorID, to: &bytes)
        appendBigEndian(productID, to: &bytes)
        appendBigEndian(bcdDevice, to: &bytes)
        let serialBytes = Data(serialNumber.utf8)
        appendBigEndian(UInt16(serialBytes.count), to: &bytes)
        bytes.append(serialBytes)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return DoryUSBPhysicalIdentityToken(rawValue: digest)!
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
