import CoreGraphics
import Darwin
import Foundation

public struct Phase0AHostIdentity: Codable, Equatable, Sendable {
    public var architecture: String
    public var hardwareModel: String
    public var marketingModel: String
    public var chip: String
    public var firmwareVersion: String
    public var osLoaderVersion: String
    public var physicalMemoryBytes: UInt64
    public var physicalProcessorCount: Int
    public var logicalProcessorCount: Int
    public var performanceCoreCount: Int?
    public var efficiencyCoreCount: Int?
    public var osProductVersion: String
    public var osBuildVersion: String
    public var bootSessionIdentifier: String
    public var powerSource: String
    public var lowPowerModeEnabled: Bool
    public var thermalState: String

    public init(
        architecture: String,
        hardwareModel: String,
        marketingModel: String,
        chip: String,
        firmwareVersion: String,
        osLoaderVersion: String,
        physicalMemoryBytes: UInt64,
        physicalProcessorCount: Int,
        logicalProcessorCount: Int,
        performanceCoreCount: Int?,
        efficiencyCoreCount: Int?,
        osProductVersion: String,
        osBuildVersion: String,
        bootSessionIdentifier: String,
        powerSource: String,
        lowPowerModeEnabled: Bool,
        thermalState: String
    ) {
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.marketingModel = marketingModel
        self.chip = chip
        self.firmwareVersion = firmwareVersion
        self.osLoaderVersion = osLoaderVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.physicalProcessorCount = physicalProcessorCount
        self.logicalProcessorCount = logicalProcessorCount
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.osProductVersion = osProductVersion
        self.osBuildVersion = osBuildVersion
        self.bootSessionIdentifier = bootSessionIdentifier
        self.powerSource = powerSource
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
    }
}

public struct Phase0AStorageContext: Codable, Equatable, Sendable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var deviceIdentifier: String
    public var busProtocol: String
    public var internalDevice: Bool?
    public var solidState: Bool?

    public init(
        totalBytes: UInt64,
        freeBytes: UInt64,
        deviceIdentifier: String,
        busProtocol: String,
        internalDevice: Bool?,
        solidState: Bool?
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.deviceIdentifier = deviceIdentifier
        self.busProtocol = busProtocol
        self.internalDevice = internalDevice
        self.solidState = solidState
    }
}

public struct Phase0ADisplayContext: Codable, Equatable, Sendable {
    public var ordinal: Int
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRateHz: Double
    public var rotationDegrees: Double

    public init(
        ordinal: Int,
        isMain: Bool,
        isBuiltIn: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRateHz: Double,
        rotationDegrees: Double
    ) {
        self.ordinal = ordinal
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateHz = refreshRateHz
        self.rotationDegrees = rotationDegrees
    }
}

public struct Phase0AReferenceMatrixState: Codable, Equatable, Sendable {
    public var candidateTier: String
    public var inventoryComplete: Bool
    public var baselinesComplete: Bool
    public var physicalMatrixComplete: Bool
    public var blockers: [String]

    public init(
        candidateTier: String,
        inventoryComplete: Bool,
        baselinesComplete: Bool,
        physicalMatrixComplete: Bool,
        blockers: [String]
    ) {
        self.candidateTier = candidateTier
        self.inventoryComplete = inventoryComplete
        self.baselinesComplete = baselinesComplete
        self.physicalMatrixComplete = physicalMatrixComplete
        self.blockers = blockers
    }
}

public struct Phase0AHostQualificationReceipt: Codable, Equatable, Sendable {
    public static let schema = "dory.phase0a.host-qualification@1"

    public var schema: String
    public var collectedAt: String
    public var host: Phase0AHostIdentity
    public var rootStorage: Phase0AStorageContext
    public var displays: [Phase0ADisplayContext]
    public var referenceMatrix: Phase0AReferenceMatrixState

    public init(
        collectedAt: String,
        host: Phase0AHostIdentity,
        rootStorage: Phase0AStorageContext,
        displays: [Phase0ADisplayContext]
    ) {
        let inventoryBlockers = Self.inventoryBlockers(
            host: host,
            rootStorage: rootStorage,
            displays: displays
        )
        self.schema = Self.schema
        self.collectedAt = collectedAt
        self.host = host
        self.rootStorage = rootStorage
        self.displays = displays
        self.referenceMatrix = Phase0AReferenceMatrixState(
            candidateTier: "unassigned",
            inventoryComplete: inventoryBlockers.isEmpty,
            baselinesComplete: false,
            physicalMatrixComplete: false,
            blockers: inventoryBlockers + [
                "candidate has not been assigned to a frozen low/mid/high tier",
                "candidate-bound native, minimal-harness, and Dory baselines have not completed",
                "all three physical reference tiers have not completed the same campaign",
            ]
        )
    }

    public static func inventoryBlockers(
        host: Phase0AHostIdentity,
        rootStorage: Phase0AStorageContext,
        displays: [Phase0ADisplayContext]
    ) -> [String] {
        var blockers: [String] = []
        if host.architecture != "arm64" { blockers.append("host is not Apple silicon") }
        if host.hardwareModel.isEmpty { blockers.append("hardware model is unavailable") }
        if host.chip.isEmpty { blockers.append("chip identity is unavailable") }
        if host.firmwareVersion.isEmpty { blockers.append("firmware identity is unavailable") }
        if host.osBuildVersion.isEmpty { blockers.append("macOS build is unavailable") }
        if host.bootSessionIdentifier.isEmpty { blockers.append("boot session identity is unavailable") }
        if rootStorage.totalBytes == 0 { blockers.append("root storage capacity is unavailable") }
        if displays.isEmpty { blockers.append("no active physical display was observed") }
        return blockers
    }
}

public enum Phase0AHostCollector {
    public static func collect(now: Date = Date()) throws -> Phase0AHostQualificationReceipt {
        let hardware = try hardwareProfile()
        let host = Phase0AHostIdentity(
            architecture: systemValue("/usr/bin/uname", ["-m"]),
            hardwareModel: systemValue("/usr/sbin/sysctl", ["-n", "hw.model"]),
            marketingModel: hardware["machine_name"] ?? "",
            chip: hardware["chip_type"]
                ?? systemValue("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            firmwareVersion: hardware["boot_rom_version"] ?? "",
            osLoaderVersion: hardware["os_loader_version"] ?? "",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            physicalProcessorCount: integerSystemValue("hw.physicalcpu")
                ?? ProcessInfo.processInfo.processorCount,
            logicalProcessorCount: integerSystemValue("hw.logicalcpu")
                ?? ProcessInfo.processInfo.activeProcessorCount,
            performanceCoreCount: integerSystemValue("hw.perflevel0.physicalcpu"),
            efficiencyCoreCount: integerSystemValue("hw.perflevel1.physicalcpu"),
            osProductVersion: systemValue("/usr/bin/sw_vers", ["-productVersion"]),
            osBuildVersion: systemValue("/usr/bin/sw_vers", ["-buildVersion"]),
            bootSessionIdentifier: systemValue("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]),
            powerSource: currentPowerSource(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState)
        )
        return Phase0AHostQualificationReceipt(
            collectedAt: ISO8601DateFormatter().string(from: now),
            host: host,
            rootStorage: try rootStorageContext(),
            displays: activeDisplays()
        )
    }

    private static func systemValue(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private static func integerSystemValue(_ name: String) -> Int? {
        Int(systemValue("/usr/sbin/sysctl", ["-n", name]))
    }

    private static func hardwareProfile() throws -> [String: String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        let object = try JSONSerialization.jsonObject(
            with: output.fileHandleForReading.readDataToEndOfFile()
        )
        guard
            let root = object as? [String: Any],
            let rows = root["SPHardwareDataType"] as? [[String: Any]],
            let row = rows.first
        else { return [:] }
        let allowedKeys = [
            "machine_name", "chip_type", "boot_rom_version", "os_loader_version",
        ]
        return Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            guard let value = row[key] as? String else { return nil }
            return (key, value)
        })
    }

    private static func currentPowerSource() -> String {
        let value = systemValue("/usr/bin/pmset", ["-g", "batt"])
        if value.contains("AC Power") { return "ac" }
        if value.contains("Battery Power") { return "battery" }
        return "unknown"
    }

    private static func rootStorageContext() throws -> Phase0AStorageContext {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let details = diskDetails()
        return Phase0AStorageContext(
            totalBytes: (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0,
            freeBytes: (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0,
            deviceIdentifier: details["DeviceIdentifier"] as? String ?? "",
            busProtocol: details["BusProtocol"] as? String ?? "",
            internalDevice: details["Internal"] as? Bool,
            solidState: details["SolidState"] as? Bool
        )
    }

    private static func diskDetails() -> [String: Any] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let object = try PropertyListSerialization.propertyList(
                from: output.fileHandleForReading.readDataToEndOfFile(),
                format: nil
            )
            return object as? [String: Any] ?? [:]
        } catch {
            return [:]
        }
    }

    private static func activeDisplays() -> [Phase0ADisplayContext] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return [] }
        return identifiers.prefix(Int(count)).enumerated().map { ordinal, identifier in
            let mode = CGDisplayCopyDisplayMode(identifier)
            return Phase0ADisplayContext(
                ordinal: ordinal,
                isMain: CGDisplayIsMain(identifier) != 0,
                isBuiltIn: CGDisplayIsBuiltin(identifier) != 0,
                pixelWidth: mode?.pixelWidth ?? 0,
                pixelHeight: mode?.pixelHeight ?? 0,
                refreshRateHz: mode?.refreshRate ?? 0,
                rotationDegrees: CGDisplayRotation(identifier)
            )
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
