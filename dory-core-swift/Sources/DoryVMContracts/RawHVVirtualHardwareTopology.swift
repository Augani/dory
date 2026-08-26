import CryptoKit
import Foundation

public enum DoryVMContractHardwareABIVersion: String, Codable, Sendable, Hashable {
    case rawHVARM64V1 = "raw-hv-arm64-v1"
}

public enum DoryVMContractBackend: String, Codable, Sendable, Hashable {
    case rawHV = "raw-hv"
    case virtualizationFramework = "virtualization-framework"
}

public enum DoryVMContractArchitecture: String, Codable, Sendable, Hashable {
    case arm64
    case x86_64 = "x86-64"
}

/// A guest-stable function. Display count is deliberately absent: ABI v1 represents every display
/// through the one `graphics` device instead of allocating one MMIO function per scanout.
public enum DoryVirtualDeviceRole: String, CaseIterable, Codable, Sendable, Hashable {
    case systemDisk = "system-disk"
    case graphics
    case entropy
    case balloon
    case vsock
    case keyboard
    case pointer
    case audio
    case network
    case auxiliaryBlock = "auxiliary-block"
    case removableStorage = "removable-storage"
    case directoryShare = "directory-share"
    case usbController = "usb-controller"
}

public enum DoryVMContractError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidLogicalDeviceID(String)
    case unsupportedSchemaVersion(UInt32)
    case incompatibleABI(DoryVMContractHardwareABIVersion)
    case incompatibleBackend(DoryVMContractBackend)
    case incompatibleArchitecture(DoryVMContractArchitecture)
    case unknownFields(type: String, fields: [String])
    case nonCanonicalOccupiedSlotOrder
    case invalidDerivationStableIDLength(actual: Int, maximum: Int)
    case tooManyDevices(actual: Int, maximum: Int)
    case duplicateLogicalDeviceID(DoryVirtualDeviceID)
    case duplicateMMIOSlot(Int)
    case mmioSlotOutOfRange(Int)
    case reservedMMIOSlot(Int)
    case roleSlotMismatch(role: DoryVirtualDeviceRole, slot: Int)
    case roleCapacityExceeded(role: DoryVirtualDeviceRole, maximum: Int)
    case auxiliaryStorageCapacityExceeded(maximum: Int)
    case roleMutation(
        logicalID: DoryVirtualDeviceID,
        previous: DoryVirtualDeviceRole,
        requested: DoryVirtualDeviceRole
    )
    case noAvailableSlot(DoryVirtualDeviceRole)

    public var description: String {
        switch self {
        case .invalidLogicalDeviceID(let value):
            "invalid logical virtual-device ID: \(value)"
        case .unsupportedSchemaVersion(let version):
            "unsupported virtual-hardware topology schema version: \(version)"
        case .incompatibleABI(let abi):
            "incompatible virtual-hardware ABI: \(abi.rawValue)"
        case .incompatibleBackend(let backend):
            "incompatible virtualization backend: \(backend.rawValue)"
        case .incompatibleArchitecture(let architecture):
            "incompatible guest architecture: \(architecture.rawValue)"
        case .unknownFields(let type, let fields):
            "unknown fields in \(type): \(fields.joined(separator: ", "))"
        case .nonCanonicalOccupiedSlotOrder:
            "decoded occupiedSlots must be ordered by increasing virtio-mmio slot"
        case .invalidDerivationStableIDLength(let actual, let maximum):
            "stable device ID has \(actual) UTF-8 bytes; expected 1...\(maximum)"
        case .tooManyDevices(let actual, let maximum):
            "virtual-hardware topology has \(actual) devices; maximum is \(maximum)"
        case .duplicateLogicalDeviceID(let logicalID):
            "duplicate logical virtual-device ID: \(logicalID.rawValue)"
        case .duplicateMMIOSlot(let slot):
            "duplicate virtio-mmio slot: \(slot)"
        case .mmioSlotOutOfRange(let slot):
            "virtio-mmio slot is outside ABI v1: \(slot)"
        case .reservedMMIOSlot(let slot):
            "virtio-mmio slot is reserved and unassignable: \(slot)"
        case .roleSlotMismatch(let role, let slot):
            "role \(role.rawValue) cannot occupy virtio-mmio slot \(slot)"
        case .roleCapacityExceeded(let role, let maximum):
            "role \(role.rawValue) exceeds ABI v1 capacity \(maximum)"
        case .auxiliaryStorageCapacityExceeded(let maximum):
            "auxiliary block/removable storage exceeds shared ABI v1 capacity \(maximum)"
        case .roleMutation(let logicalID, let previous, let requested):
            "logical device \(logicalID.rawValue) cannot mutate from \(previous.rawValue) to \(requested.rawValue)"
        case .noAvailableSlot(let role):
            "no ABI v1 virtio-mmio slot remains for role \(role.rawValue)"
        }
    }
}

/// A bounded, path-safe identity that survives topology reconciliation and guest device churn.
public struct DoryVirtualDeviceID: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public static let maximumUTF8Length = 64
    public static let derivationEncodingVersion: UInt16 = 1
    public static let maximumDerivationStableIDUTF8Length = 4_096
    public static let derivedDigestByteCount = 30

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw DoryVMContractError.invalidLogicalDeviceID(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Derives one bounded logical ID from an exact caller-owned stable identity. The typed role is
    /// the collision namespace, so the same external identity used for a share, disk, and NIC cannot
    /// alias. `stableID` is hashed as its exact UTF-8 bytes; no lossy normalization is performed.
    ///
    /// Version 1 input, all integers big-endian:
    /// `"DORYVID\0"[8] | version:u16 | role:u8 | stableIDLength:u32 | stableID:UTF8`.
    /// The returned ID is `dv1-` followed by the first 30 SHA-256 bytes as lowercase hex (240 bits,
    /// exactly 64 ASCII bytes including the prefix).
    public static func derived(
        namespace: DoryVirtualDeviceRole,
        stableID: String
    ) throws -> Self {
        let digest = SHA256.hash(
            data: try canonicalDerivationInput(namespace: namespace, stableID: stableID)
        )
        let digestPrefix = digest.prefix(derivedDigestByteCount)
            .map { String(format: "%02x", $0) }
            .joined()
        return try Self("dv1-\(digestPrefix)")
    }

    public static func canonicalDerivationInput(
        namespace: DoryVirtualDeviceRole,
        stableID: String
    ) throws -> Data {
        let stableIDLength = stableID.utf8.count
        guard (1...maximumDerivationStableIDUTF8Length).contains(stableIDLength) else {
            throw DoryVMContractError.invalidDerivationStableIDLength(
                actual: stableIDLength,
                maximum: maximumDerivationStableIDUTF8Length
            )
        }

        let stableIDBytes = Array(stableID.utf8)
        var data = Data("DORYVID\0".utf8)
        data.appendBigEndian(derivationEncodingVersion)
        data.append(namespace.canonicalFingerprintTag)
        data.appendBigEndian(UInt32(stableIDBytes.count))
        data.append(contentsOf: stableIDBytes)
        return data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Length,
              let first = bytes.first, isASCIIAlphaNumeric(first) else {
            return false
        }
        return bytes.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
}

/// The complete RawHV ARM64 ABI-v1 slot policy. Slot 31 is intentionally absent from every role
/// range so it remains a hard reservation rather than an accidentally allocatable future device.
public enum DoryRawHVARM64ABIV1SlotPolicy {
    public static let slotCount = 32
    public static let maximumOccupiedSlots = 31
    public static let reservedSlot = 31
    public static let maximumNetworkFunctions = 4
    public static let maximumAuxiliaryStorageDevices = 8
    public static let maximumDirectoryShares = 10

    public static func allowedSlots(for role: DoryVirtualDeviceRole) -> ClosedRange<Int> {
        switch role {
        case .systemDisk: 0...0
        case .graphics: 1...1
        case .entropy: 2...2
        case .balloon: 3...3
        case .vsock: 4...4
        case .keyboard: 5...5
        case .pointer: 6...6
        case .audio: 7...7
        case .network: 8...11
        case .auxiliaryBlock, .removableStorage: 12...19
        case .directoryShare: 20...29
        case .usbController: 30...30
        }
    }

    public static func fixedSlot(for role: DoryVirtualDeviceRole) -> Int? {
        let range = allowedSlots(for: role)
        return range.lowerBound == range.upperBound ? range.lowerBound : nil
    }

    public static func maximumCount(for role: DoryVirtualDeviceRole) -> Int {
        let range = allowedSlots(for: role)
        return range.upperBound - range.lowerBound + 1
    }

    public static func validate(role: DoryVirtualDeviceRole, slot: Int) throws {
        guard (0..<slotCount).contains(slot) else {
            throw DoryVMContractError.mmioSlotOutOfRange(slot)
        }
        guard slot != reservedSlot else {
            throw DoryVMContractError.reservedMMIOSlot(slot)
        }
        guard allowedSlots(for: role).contains(slot) else {
            throw DoryVMContractError.roleSlotMismatch(role: role, slot: slot)
        }
    }

    static func validateRoleCounts(_ roles: [DoryVirtualDeviceRole]) throws {
        let counts = Dictionary(grouping: roles, by: { $0 }).mapValues(\.count)
        for role in DoryVirtualDeviceRole.allCases {
            let count = counts[role, default: 0]
            let maximum = maximumCount(for: role)
            guard count <= maximum else {
                throw DoryVMContractError.roleCapacityExceeded(role: role, maximum: maximum)
            }
        }

        let auxiliaryStorageCount = counts[.auxiliaryBlock, default: 0]
            + counts[.removableStorage, default: 0]
        guard auxiliaryStorageCount <= maximumAuxiliaryStorageDevices else {
            throw DoryVMContractError.auxiliaryStorageCapacityExceeded(
                maximum: maximumAuxiliaryStorageDevices
            )
        }
    }
}

public struct DoryRawHVVirtualDeviceSlot: Codable, Sendable, Hashable {
    public let logicalID: DoryVirtualDeviceID
    public let role: DoryVirtualDeviceRole
    public let mmioSlot: Int

    public init(
        logicalID: DoryVirtualDeviceID,
        role: DoryVirtualDeviceRole,
        mmioSlot: Int
    ) throws {
        try DoryRawHVARM64ABIV1SlotPolicy.validate(role: role, slot: mmioSlot)
        self.logicalID = logicalID
        self.role = role
        self.mmioSlot = mmioSlot
    }

    public init(
        logicalID: String,
        role: DoryVirtualDeviceRole,
        mmioSlot: Int
    ) throws {
        try self.init(logicalID: DoryVirtualDeviceID(logicalID), role: role, mmioSlot: mmioSlot)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case logicalID
        case role
        case mmioSlot
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownDoryVMContractFields(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            type: "DoryRawHVVirtualDeviceSlot"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalID: container.decode(DoryVirtualDeviceID.self, forKey: .logicalID),
            role: container.decode(DoryVirtualDeviceRole.self, forKey: .role),
            mmioSlot: container.decode(Int.self, forKey: .mmioSlot)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logicalID, forKey: .logicalID)
        try container.encode(role, forKey: .role)
        try container.encode(mmioSlot, forKey: .mmioSlot)
    }
}

/// Versioned, self-validating RawHV ARM64 virtual-hardware topology. `occupiedSlots` is stored in
/// slot order, so equality, hashing, encoded bytes, and fingerprints do not depend on caller order.
public struct DoryRawHVVirtualHardwareTopology: Codable, Sendable, Hashable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let canonicalFingerprintEncodingVersion: UInt16 = 1

    public let schemaVersion: UInt32
    public let abiVersion: DoryVMContractHardwareABIVersion
    public let backend: DoryVMContractBackend
    public let architecture: DoryVMContractArchitecture
    public let occupiedSlots: [DoryRawHVVirtualDeviceSlot]

    public init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        abiVersion: DoryVMContractHardwareABIVersion = .rawHVARM64V1,
        backend: DoryVMContractBackend = .rawHV,
        architecture: DoryVMContractArchitecture = .arm64,
        occupiedSlots: [DoryRawHVVirtualDeviceSlot]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DoryVMContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard abiVersion == .rawHVARM64V1 else {
            throw DoryVMContractError.incompatibleABI(abiVersion)
        }
        guard backend == .rawHV else {
            throw DoryVMContractError.incompatibleBackend(backend)
        }
        guard architecture == .arm64 else {
            throw DoryVMContractError.incompatibleArchitecture(architecture)
        }
        guard occupiedSlots.count <= DoryRawHVARM64ABIV1SlotPolicy.maximumOccupiedSlots else {
            throw DoryVMContractError.tooManyDevices(
                actual: occupiedSlots.count,
                maximum: DoryRawHVARM64ABIV1SlotPolicy.maximumOccupiedSlots
            )
        }
        try DoryRawHVARM64ABIV1SlotPolicy.validateRoleCounts(occupiedSlots.map(\.role))

        var logicalIDs = Set<DoryVirtualDeviceID>()
        var mmioSlots = Set<Int>()
        for device in occupiedSlots {
            try DoryRawHVARM64ABIV1SlotPolicy.validate(role: device.role, slot: device.mmioSlot)
            guard logicalIDs.insert(device.logicalID).inserted else {
                throw DoryVMContractError.duplicateLogicalDeviceID(device.logicalID)
            }
            guard mmioSlots.insert(device.mmioSlot).inserted else {
                throw DoryVMContractError.duplicateMMIOSlot(device.mmioSlot)
            }
        }

        self.schemaVersion = schemaVersion
        self.abiVersion = abiVersion
        self.backend = backend
        self.architecture = architecture
        self.occupiedSlots = occupiedSlots.sorted(by: Self.deviceOrder)
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Explicit ABI fingerprint stream, independent of JSONEncoder implementation details.
    ///
    /// Layout, all integers big-endian:
    /// `"DORYVHW\0"[8] | formatVersion:u16 | schemaVersion:u32 | abi:u8 | backend:u8 |
    /// architecture:u8 | deviceCount:u8 | repeated(slot:u8, role:u8, idLength:u8, id:UTF8)`.
    /// Devices are already sorted by slot and logical IDs are bounded to 64 ASCII bytes.
    public func canonicalFingerprintInput() -> Data {
        var data = Data("DORYVHW\0".utf8)
        data.appendBigEndian(Self.canonicalFingerprintEncodingVersion)
        data.appendBigEndian(schemaVersion)
        data.append(1) // raw-hv-arm64-v1
        data.append(1) // raw-hv
        data.append(1) // arm64
        data.append(UInt8(occupiedSlots.count))
        for device in occupiedSlots {
            let logicalID = Array(device.logicalID.rawValue.utf8)
            data.append(UInt8(device.mmioSlot))
            data.append(device.role.canonicalFingerprintTag)
            data.append(UInt8(logicalID.count))
            data.append(contentsOf: logicalID)
        }
        return data
    }

    public func canonicalSHA256Fingerprint() -> String {
        SHA256.hash(data: canonicalFingerprintInput())
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case abiVersion
        case backend
        case architecture
        case occupiedSlots
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownDoryVMContractFields(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            type: "DoryRawHVVirtualHardwareTopology"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let occupiedSlots = try container.decode(
            [DoryRawHVVirtualDeviceSlot].self,
            forKey: .occupiedSlots
        )
        guard occupiedSlots == occupiedSlots.sorted(by: Self.deviceOrder) else {
            throw DoryVMContractError.nonCanonicalOccupiedSlotOrder
        }
        try self.init(
            schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
            abiVersion: container.decode(DoryVMContractHardwareABIVersion.self, forKey: .abiVersion),
            backend: container.decode(DoryVMContractBackend.self, forKey: .backend),
            architecture: container.decode(DoryVMContractArchitecture.self, forKey: .architecture),
            occupiedSlots: occupiedSlots
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(abiVersion, forKey: .abiVersion)
        try container.encode(backend, forKey: .backend)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(occupiedSlots, forKey: .occupiedSlots)
    }

    private static func deviceOrder(
        _ lhs: DoryRawHVVirtualDeviceSlot,
        _ rhs: DoryRawHVVirtualDeviceSlot
    ) -> Bool {
        if lhs.mmioSlot != rhs.mmioSlot { return lhs.mmioSlot < rhs.mmioSlot }
        if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
        return lhs.logicalID < rhs.logicalID
    }
}

private extension DoryVirtualDeviceRole {
    var canonicalFingerprintTag: UInt8 {
        switch self {
        case .systemDisk: 1
        case .graphics: 2
        case .entropy: 3
        case .balloon: 4
        case .vsock: 5
        case .keyboard: 6
        case .pointer: 7
        case .audio: 8
        case .network: 9
        case .auxiliaryBlock: 10
        case .removableStorage: 11
        case .directoryShare: 12
        case .usbController: 13
        }
    }
}

struct DoryVMContractDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

func rejectUnknownDoryVMContractFields(
    in decoder: Decoder,
    allowed: Set<String>,
    type: String
) throws {
    let container = try decoder.container(keyedBy: DoryVMContractDynamicCodingKey.self)
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
        throw DoryVMContractError.unknownFields(type: type, fields: unknown)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
