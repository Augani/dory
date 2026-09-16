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
    case hostOperatingSystemVersionMismatch(saved: String, current: String)
    case hostBuildMismatch(saved: String, current: String)
    case machineIdentityMismatch
    case filesystem(String, Int32)

    public var description: String {
        switch self {
        case .invalidVirtualMachineState(let detail): detail
        case .saveRestoreUnsupported(let detail): "VZMac save/restore is unsupported: \(detail)"
        case .destinationExists(let path): "VZMac saved-state destination exists: \(path)"
        case .invalidArtifact(let detail): "invalid VZMac saved-state artifact: \(detail)"
        case .hostMismatch: "VZMac saved state belongs to a different physical Mac"
        case let .hostOperatingSystemVersionMismatch(saved, current):
            "VZMac saved state requires macOS \(saved); this host is running \(current). Discard the saved state and cold boot."
        case let .hostBuildMismatch(saved, current):
            "VZMac saved state requires macOS build \(saved); this host is running \(current). Discard the saved state and cold boot."
        case .machineIdentityMismatch: "VZMac saved state does not match this machine identity"
        case .filesystem(let operation, let code): "\(operation) failed with errno \(code)"
        }
    }
}

public struct DoryVZMacSavedStateReceipt: Codable, Sendable, Equatable {
    public static let schema = "dory.vzmac-saved-state@4"
    /// @3 used three small fixed samples. It remains loadable so an app update
    /// does not strand an otherwise valid local suspended machine; new saves
    /// always use @4's configuration-keyed bounded sampler.
    static let legacySchema = "dory.vzmac-saved-state@3"

    public let schema: String
    public let createdAt: String
    public let hostIdentifierSHA256: String
    public let hostOperatingSystemVersion: String
    public let hostBuildVersion: String
    public let hardwareModelSHA256: String
    public let machineIdentifierSHA256: String
    public let configurationSHA256: String
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
        configurationSHA256: String,
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
        self.configurationSHA256 = configurationSHA256
        self.stateBytes = stateBytes
        self.stateSHA256 = stateSHA256
    }

    public func validate() throws {
        guard [Self.legacySchema, Self.schema].contains(schema),
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
            configurationSHA256,
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
        for bundle: DoryVZMacMachineBundle,
        expectedConfigurationSHA256: String? = nil
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
        try validateHostCompatibility(receipt, host: try currentHostFacts())
        guard receipt.hardwareModelSHA256 == bundle.manifest.hardwareModelSHA256,
              receipt.machineIdentifierSHA256 == bundle.manifest.machineIdentifierSHA256 else {
            throw DoryVZMacSavedStateError.machineIdentityMismatch
        }
        if let expectedConfigurationSHA256,
           receipt.configurationSHA256 != expectedConfigurationSHA256 {
            throw DoryVZMacSavedStateError.invalidArtifact(
                "runtime configuration differs from the saved state"
            )
        }
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        guard let stateBytes = stateAttributes[.size] as? NSNumber,
              stateBytes.uint64Value == receipt.stateBytes,
              try savedStateSHA256(
                  of: stateURL,
                  schema: receipt.schema,
                  configurationSHA256: receipt.configurationSHA256
              ) == receipt.stateSHA256 else {
            throw DoryVZMacSavedStateError.invalidArtifact("state size or SHA-256 differs")
        }
        return Self(rootURL: rootURL, receipt: receipt)
    }

    /// VZ machine-state blobs are tied to both the physical machine and the exact
    /// OS build. Keep this preflight independent of file I/O so callers and tests
    /// receive a typed discard-and-cold-boot error before Virtualization.framework
    /// is asked to restore an incompatible state blob.
    static func validateHostCompatibility(
        _ receipt: DoryVZMacSavedStateReceipt,
        host: DoryVZMacSavedStateHostFacts
    ) throws {
        guard receipt.hostIdentifierSHA256 == host.identifierSHA256 else {
            throw DoryVZMacSavedStateError.hostMismatch
        }
        guard receipt.hostOperatingSystemVersion == host.operatingSystemVersion else {
            throw DoryVZMacSavedStateError.hostOperatingSystemVersionMismatch(
                saved: receipt.hostOperatingSystemVersion,
                current: host.operatingSystemVersion
            )
        }
        guard receipt.hostBuildVersion == host.buildVersion else {
            throw DoryVZMacSavedStateError.hostBuildMismatch(
                saved: receipt.hostBuildVersion,
                current: host.buildVersion
            )
        }
    }
}

struct DoryVZMacSavedStateHostFacts: Sendable, Equatable {
    let identifierSHA256: String
    let operatingSystemVersion: String
    let buildVersion: String
}

func makeSavedStateReceipt(
    stateURL: URL,
    bundle: DoryVZMacMachineBundle,
    configurationSHA256: String
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
        configurationSHA256: configurationSHA256,
        stateBytes: stateBytes.uint64Value,
        stateSHA256: try savedStateSHA256(
            of: stateURL,
            schema: DoryVZMacSavedStateReceipt.schema,
            configurationSHA256: configurationSHA256
        )
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

private func currentHostFacts() throws -> DoryVZMacSavedStateHostFacts {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    return try DoryVZMacSavedStateHostFacts(
        identifierSHA256: currentHostIdentifierSHA256(),
        operatingSystemVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
        buildVersion: hostBuildVersion()
    )
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

struct DoryVZMacSavedStateSampleRegion: Sendable, Equatable {
    let offset: UInt64
    let byteCount: UInt64
}

/// Returns the bounded, deterministic @4 sample layout without opening the state
/// file. Keeping this separate makes the coverage contract testable: at most
/// 72 MiB is read (two 4 MiB edges and 64 1 MiB interior windows).
func savedStateSampleRegions(
    fileSize: UInt64,
    configurationSHA256: String
) -> [DoryVZMacSavedStateSampleRegion] {
    guard fileSize > 0 else { return [] }
    let edgeBytes: UInt64 = 4 * 1_024 * 1_024
    let interiorBytes: UInt64 = 1 * 1_024 * 1_024
    var regions: [DoryVZMacSavedStateSampleRegion] = [
        .init(offset: 0, byteCount: min(edgeBytes, fileSize)),
    ]
    if fileSize > edgeBytes {
        regions.append(.init(offset: fileSize - edgeBytes, byteCount: edgeBytes))
    }
    guard fileSize > interiorBytes else { return regions }

    let maximumOffset = fileSize - interiorBytes
    var selected = Set(regions.map(\.offset))
    // A tiny file may have fewer than 64 distinct byte-aligned interiors.
    // Otherwise, re-key a colliding candidate until all 64 are distinct.
    let interiorCount = Int(min(UInt64(64), maximumOffset + 1))
    for index in 0..<interiorCount {
        var attempt = 0
        while true {
            let seed = Data("\(configurationSHA256)\0\(fileSize)\0\(index)\0\(attempt)".utf8)
            let digest = SHA256.hash(data: seed)
            let value = digest.prefix(MemoryLayout<UInt64>.size).reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            let offset = value % (maximumOffset + 1)
            if selected.insert(offset).inserted {
                regions.append(.init(offset: offset, byteCount: interiorBytes))
                break
            }
            attempt += 1
        }
    }
    return regions
}

func savedStateSHA256(
    of url: URL,
    schema: String,
    configurationSHA256: String
) throws -> String {
    if schema == DoryVZMacSavedStateReceipt.legacySchema {
        return try legacySavedStateSHA256(of: url)
    }
    guard schema == DoryVZMacSavedStateReceipt.schema else {
        throw DoryVZMacSavedStateError.invalidArtifact("saved-state digest schema is unsupported")
    }
    // A full digest of a multi-GiB VZ state delays resume for seconds. @4 instead
    // binds the configuration and file size to 72 MiB of deterministic samples:
    // 4 MiB from each end plus 64 configuration-keyed 1 MiB interior regions.
    // Configuration-keyed positions make a corrupt state less able to predict and
    // avoid the sampled regions, while keeping validation bounded and repeatable.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let fileSize = try handle.seekToEnd()
    guard fileSize > 0 else { return savedStateSHA256(of: Data()) }

    var hasher = SHA256()
    hasher.update(data: Data("dory.vzmac-saved-state-sampler@4\0\(configurationSHA256)\0".utf8))
    hasher.update(data: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })

    for region in savedStateSampleRegions(
        fileSize: fileSize,
        configurationSHA256: configurationSHA256
    ) {
        hasher.update(data: withUnsafeBytes(of: region.offset.littleEndian) { Data($0) })
        hasher.update(data: withUnsafeBytes(of: region.byteCount.littleEndian) { Data($0) })
        try handle.seek(toOffset: region.offset)
        let chunk = try handle.read(upToCount: Int(region.byteCount))
        guard let chunk, UInt64(chunk.count) == region.byteCount else {
            throw DoryVZMacSavedStateError.invalidArtifact("saved state changed while sampling")
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func legacySavedStateSHA256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let fileSize = try handle.seekToEnd()
    guard fileSize > 0 else { return savedStateSHA256(of: Data()) }
    var hasher = SHA256()
    hasher.update(data: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
    let sampleSize: UInt64 = 4 * 1_024
    let sampleOffsets: [UInt64] = [
        0,
        fileSize > 2 * sampleSize ? (fileSize - sampleSize) / 2 : 0,
        fileSize > sampleSize ? fileSize - sampleSize : 0,
    ]
    for offset in sampleOffsets {
        try handle.seek(toOffset: offset)
        let chunk = try handle.read(upToCount: Int(min(sampleSize, fileSize - offset)))
        if let chunk, !chunk.isEmpty {
            hasher.update(data: chunk)
        }
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
