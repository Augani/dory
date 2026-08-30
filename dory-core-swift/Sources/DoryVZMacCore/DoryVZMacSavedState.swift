import CryptoKit
import Darwin
import Foundation
import IOKit

public enum DoryVZMacSavedStateError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidVirtualMachineState(String)
    case saveRestoreUnsupported(String)
    case destinationExists(String)
    case invalidArtifact(String)
    case hostMismatch
    case machineIdentityMismatch
    case filesystem(String, Int32)

    public var description: String {
        switch self {
        case .invalidVirtualMachineState(let detail): detail
        case .saveRestoreUnsupported(let detail): "VZMac save/restore is unsupported: \(detail)"
        case .destinationExists(let path): "VZMac saved-state destination exists: \(path)"
        case .invalidArtifact(let detail): "invalid VZMac saved-state artifact: \(detail)"
        case .hostMismatch: "VZMac saved state belongs to a different physical Mac"
        case .machineIdentityMismatch: "VZMac saved state does not match this machine identity"
        case .filesystem(let operation, let code): "\(operation) failed with errno \(code)"
        }
    }
}

public struct DoryVZMacSavedStateReceipt: Codable, Sendable, Equatable {
    public static let schema = "dory.vzmac-saved-state@1"

    public let schema: String
    public let createdAt: String
    public let hostIdentifierSHA256: String
    public let hostOperatingSystemVersion: String
    public let hostBuildVersion: String
    public let hardwareModelSHA256: String
    public let machineIdentifierSHA256: String
    public let stateBytes: UInt64
    public let stateSHA256: String

    public init(
        schema: String = Self.schema,
        createdAt: String,
        hostIdentifierSHA256: String,
        hostOperatingSystemVersion: String,
        hostBuildVersion: String,
        hardwareModelSHA256: String,
        machineIdentifierSHA256: String,
        stateBytes: UInt64,
        stateSHA256: String
    ) {
        self.schema = schema
        self.createdAt = createdAt
        self.hostIdentifierSHA256 = hostIdentifierSHA256
        self.hostOperatingSystemVersion = hostOperatingSystemVersion
        self.hostBuildVersion = hostBuildVersion
        self.hardwareModelSHA256 = hardwareModelSHA256
        self.machineIdentifierSHA256 = machineIdentifierSHA256
        self.stateBytes = stateBytes
        self.stateSHA256 = stateSHA256
    }

    public func validate() throws {
        guard schema == Self.schema,
              ISO8601DateFormatter().date(from: createdAt) != nil,
              !hostOperatingSystemVersion.isEmpty,
              !hostBuildVersion.isEmpty,
              stateBytes > 0 else {
            throw DoryVZMacSavedStateError.invalidArtifact("receipt metadata is invalid")
        }
        for digest in [
            hostIdentifierSHA256,
            hardwareModelSHA256,
            machineIdentifierSHA256,
            stateSHA256,
        ] {
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw DoryVZMacSavedStateError.invalidArtifact(
                    "receipt SHA-256 digest is not canonical"
                )
            }
        }
    }
}

public struct DoryVZMacSavedStateArtifact: Sendable {
    public static let stateName = "machine-state.bin"
    public static let receiptName = "receipt.json"
    public static let maximumReceiptBytes = 1_048_576

    public let rootURL: URL
    public let receipt: DoryVZMacSavedStateReceipt

    public var stateURL: URL { rootURL.appendingPathComponent(Self.stateName) }
    public var receiptURL: URL { rootURL.appendingPathComponent(Self.receiptName) }

    public static func load(
        from rootURL: URL,
        for bundle: DoryVZMacMachineBundle
    ) throws -> Self {
        try requireSavedStateDirectory(rootURL)
        let stateURL = rootURL.appendingPathComponent(Self.stateName)
        let receiptURL = rootURL.appendingPathComponent(Self.receiptName)
        try requireSavedStateRegularFile(stateURL, label: Self.stateName)
        try requireSavedStateRegularFile(receiptURL, label: Self.receiptName)
        let receiptAttributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        guard let receiptBytes = receiptAttributes[.size] as? NSNumber,
              receiptBytes.uint64Value > 0,
              receiptBytes.uint64Value <= UInt64(Self.maximumReceiptBytes) else {
            throw DoryVZMacSavedStateError.invalidArtifact("receipt size is invalid")
        }
        let receipt: DoryVZMacSavedStateReceipt
        do {
            receipt = try JSONDecoder().decode(
                DoryVZMacSavedStateReceipt.self,
                from: Data(contentsOf: receiptURL, options: [.mappedIfSafe])
            )
        } catch {
            throw DoryVZMacSavedStateError.invalidArtifact("receipt JSON cannot be decoded")
        }
        try receipt.validate()
        guard receipt.hostIdentifierSHA256 == (try currentHostIdentifierSHA256()) else {
            throw DoryVZMacSavedStateError.hostMismatch
        }
        guard receipt.hardwareModelSHA256 == bundle.manifest.hardwareModelSHA256,
              receipt.machineIdentifierSHA256 == bundle.manifest.machineIdentifierSHA256 else {
            throw DoryVZMacSavedStateError.machineIdentityMismatch
        }
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        guard let stateBytes = stateAttributes[.size] as? NSNumber,
              stateBytes.uint64Value == receipt.stateBytes,
              try savedStateSHA256(of: stateURL) == receipt.stateSHA256 else {
            throw DoryVZMacSavedStateError.invalidArtifact("state size or SHA-256 differs")
        }
        return Self(rootURL: rootURL, receipt: receipt)
    }
}

func makeSavedStateReceipt(
    stateURL: URL,
    bundle: DoryVZMacMachineBundle
) throws -> DoryVZMacSavedStateReceipt {
    let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
    guard let stateBytes = attributes[.size] as? NSNumber, stateBytes.uint64Value > 0 else {
        throw DoryVZMacSavedStateError.invalidArtifact("saved state is empty")
    }
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    let receipt = DoryVZMacSavedStateReceipt(
        createdAt: ISO8601DateFormatter().string(from: Date()),
        hostIdentifierSHA256: try currentHostIdentifierSHA256(),
        hostOperatingSystemVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
        hostBuildVersion: hostBuildVersion(),
        hardwareModelSHA256: bundle.manifest.hardwareModelSHA256,
        machineIdentifierSHA256: bundle.manifest.machineIdentifierSHA256,
        stateBytes: stateBytes.uint64Value,
        stateSHA256: try savedStateSHA256(of: stateURL)
    )
    try receipt.validate()
    return receipt
}

private func currentHostIdentifierSHA256() throws -> String {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
    )
    guard service != IO_OBJECT_NULL else {
        throw DoryVZMacSavedStateError.invalidArtifact("host identity is unavailable")
    }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(
        service,
        "IOPlatformUUID" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? String,
          !value.isEmpty else {
        throw DoryVZMacSavedStateError.invalidArtifact("host identity is unavailable")
    }
    return savedStateSHA256(of: Data(value.utf8))
}

private func hostBuildVersion() -> String {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
        return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
        return "unknown"
    }
    let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: content, as: UTF8.self)
}

private func savedStateSHA256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func savedStateSHA256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func requireSavedStateDirectory(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
        throw DoryVZMacSavedStateError.invalidArtifact("root is not a direct directory")
    }
}

private func requireSavedStateRegularFile(_ url: URL, label: String) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
        throw DoryVZMacSavedStateError.invalidArtifact("\(label) is not a direct regular file")
    }
}
