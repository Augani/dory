import Foundation
import Virtualization

public enum DoryVZMacResourcePlanError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCPUCount(requested: Int, minimum: Int, maximum: Int)
    case invalidMemoryBytes(requested: UInt64, minimum: UInt64, maximum: UInt64)
    case memoryMustBeMiBAligned(UInt64)
    case diskTooSmall(requested: UInt64, minimum: UInt64)

    public var description: String {
        switch self {
        case .invalidCPUCount(let requested, let minimum, let maximum):
            "VZMac CPU count \(requested) is outside \(minimum)...\(maximum)"
        case .invalidMemoryBytes(let requested, let minimum, let maximum):
            "VZMac memory \(requested) is outside \(minimum)...\(maximum) bytes"
        case .memoryMustBeMiBAligned(let requested):
            "VZMac memory \(requested) must be aligned to one MiB"
        case .diskTooSmall(let requested, let minimum):
            "VZMac disk \(requested) is smaller than the \(minimum)-byte minimum"
        }
    }
}

public struct DoryVZMacResourcePlan: Codable, Sendable, Equatable {
    public static let mebibyte: UInt64 = 1_024 * 1_024
    public static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    public static let minimumDiskBytes: UInt64 = 64 * gibibyte

    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let diskBytes: UInt64

    public init(
        requestedCPUCount: Int?,
        requestedMemoryBytes: UInt64?,
        requestedDiskBytes: UInt64,
        minimumCPUCount: Int,
        minimumMemoryBytes: UInt64,
        maximumCPUCount: Int,
        maximumMemoryBytes: UInt64
    ) throws {
        let cpuCount = requestedCPUCount ?? minimumCPUCount
        guard cpuCount >= minimumCPUCount, cpuCount <= maximumCPUCount else {
            throw DoryVZMacResourcePlanError.invalidCPUCount(
                requested: cpuCount,
                minimum: minimumCPUCount,
                maximum: maximumCPUCount
            )
        }
        let memoryBytes = requestedMemoryBytes ?? minimumMemoryBytes
        guard memoryBytes >= minimumMemoryBytes, memoryBytes <= maximumMemoryBytes else {
            throw DoryVZMacResourcePlanError.invalidMemoryBytes(
                requested: memoryBytes,
                minimum: minimumMemoryBytes,
                maximum: maximumMemoryBytes
            )
        }
        guard memoryBytes.isMultiple(of: Self.mebibyte) else {
            throw DoryVZMacResourcePlanError.memoryMustBeMiBAligned(memoryBytes)
        }
        guard requestedDiskBytes >= Self.minimumDiskBytes else {
            throw DoryVZMacResourcePlanError.diskTooSmall(
                requested: requestedDiskBytes,
                minimum: Self.minimumDiskBytes
            )
        }
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = requestedDiskBytes
    }

    public init(
        requestedCPUCount: Int?,
        requestedMemoryBytes: UInt64?,
        requestedDiskBytes: UInt64,
        requirements: VZMacOSConfigurationRequirements
    ) throws {
        try self.init(
            requestedCPUCount: requestedCPUCount,
            requestedMemoryBytes: requestedMemoryBytes,
            requestedDiskBytes: requestedDiskBytes,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemoryBytes: requirements.minimumSupportedMemorySize,
            maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            maximumMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }
}
