import Foundation

/// Host capacity captured by the platform layer and supplied to the resource policy.
///
/// The policy intentionally does not read `ProcessInfo`, filesystem state, or any other
/// process-global value. A caller can therefore evaluate the same facts during creation,
/// editing, recovery, and tests and receive the same result.
public struct DoryVMHostResources: Codable, Sendable, Equatable {
    public let logicalCPUCount: UInt64
    public let physicalMemoryBytes: UInt64
    public let freeStorageBytes: UInt64
    /// Virtual CPUs admitted to VMs that are running or in the process of starting.
    /// Stopped VM configurations must not be included in this admission counter.
    public let admittedVirtualCPUCount: UInt64
    /// Memory admitted to VMs that are running or in the process of starting.
    /// Stopped VM configurations must not be included in this admission counter.
    public let admittedMemoryBytes: UInt64
    /// Free-storage capacity already reserved for other VM disks.
    public let reservedStorageBytes: UInt64

    public init(
        logicalCPUCount: UInt64,
        physicalMemoryBytes: UInt64,
        freeStorageBytes: UInt64,
        admittedVirtualCPUCount: UInt64 = 0,
        admittedMemoryBytes: UInt64 = 0,
        reservedStorageBytes: UInt64 = 0
    ) {
        self.logicalCPUCount = logicalCPUCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.freeStorageBytes = freeStorageBytes
        self.admittedVirtualCPUCount = admittedVirtualCPUCount
        self.admittedMemoryBytes = admittedMemoryBytes
        self.reservedStorageBytes = reservedStorageBytes
    }

    /// Compatibility bridge for callers of the initial admission API. The old "committed" name
    /// was ambiguous; values passed here must represent running + starting VMs only.
    @available(*, deprecated, message: "Use admittedVirtualCPUCount/admittedMemoryBytes; exclude stopped VMs")
    public init(
        logicalCPUCount: UInt64,
        physicalMemoryBytes: UInt64,
        freeStorageBytes: UInt64,
        committedVirtualCPUCount: UInt64,
        committedMemoryBytes: UInt64,
        reservedStorageBytes: UInt64 = 0
    ) {
        self.init(
            logicalCPUCount: logicalCPUCount,
            physicalMemoryBytes: physicalMemoryBytes,
            freeStorageBytes: freeStorageBytes,
            admittedVirtualCPUCount: committedVirtualCPUCount,
            admittedMemoryBytes: committedMemoryBytes,
            reservedStorageBytes: reservedStorageBytes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case logicalCPUCount
        case physicalMemoryBytes
        case freeStorageBytes
        case admittedVirtualCPUCount
        case admittedMemoryBytes
        // Schema-zero aliases decoded for migration only; new payloads never encode them.
        case committedVirtualCPUCount
        case committedMemoryBytes
        case reservedStorageBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logicalCPUCount = try container.decode(UInt64.self, forKey: .logicalCPUCount)
        physicalMemoryBytes = try container.decode(UInt64.self, forKey: .physicalMemoryBytes)
        freeStorageBytes = try container.decode(UInt64.self, forKey: .freeStorageBytes)
        admittedVirtualCPUCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .admittedVirtualCPUCount
        ) ?? (try container.decodeIfPresent(UInt64.self, forKey: .committedVirtualCPUCount)) ?? 0
        admittedMemoryBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .admittedMemoryBytes
        ) ?? (try container.decodeIfPresent(UInt64.self, forKey: .committedMemoryBytes)) ?? 0
        reservedStorageBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .reservedStorageBytes
        ) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logicalCPUCount, forKey: .logicalCPUCount)
        try container.encode(physicalMemoryBytes, forKey: .physicalMemoryBytes)
        try container.encode(freeStorageBytes, forKey: .freeStorageBytes)
        try container.encode(admittedVirtualCPUCount, forKey: .admittedVirtualCPUCount)
        try container.encode(admittedMemoryBytes, forKey: .admittedMemoryBytes)
        try container.encode(reservedStorageBytes, forKey: .reservedStorageBytes)
    }
}

/// Resources requested for a single virtual machine.
public struct DoryVMResourceRequest: Codable, Sendable, Equatable {
    public let virtualCPUCount: UInt64
    public let memoryBytes: UInt64
    public let diskBytes: UInt64

    public init(virtualCPUCount: UInt64, memoryBytes: UInt64, diskBytes: UInt64) {
        self.virtualCPUCount = virtualCPUCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

public enum DoryVMResourceRequirementKind: String, Codable, CaseIterable, Sendable {
    case image
    case component
}

/// Explicit sizing requirements supplied by an image manifest or optional VM component.
/// Workload policy stays guest-neutral; platform-specific requirements are composed here.
public struct DoryVMResourceRequirement: Codable, Sendable, Equatable {
    public let kind: DoryVMResourceRequirementKind
    public let identifier: String
    public let minimum: DoryVMResourceRequest
    public let recommended: DoryVMResourceRequest

    public init(
        kind: DoryVMResourceRequirementKind,
        identifier: String,
        minimum: DoryVMResourceRequest,
        recommended: DoryVMResourceRequest
    ) {
        self.kind = kind
        self.identifier = identifier
        self.minimum = minimum
        self.recommended = recommended
    }
}

/// The primary workload the virtual machine must support.
public enum DoryVMWorkloadProfile: String, Codable, CaseIterable, Sendable {
    /// An interactive graphical workstation, including development tools and browsers.
    case desktop
    /// A headless or service-oriented machine with a smaller interactive footprint.
    case server
    /// A temporary live environment that must have enough capacity to install an OS.
    case installer
}

/// Guidance for one resource dimension.
///
/// `minimum` is the workload's hard requirement, `recommended` is the best target that fits
/// this host, and `maximum` is the most the host can safely offer after its reserve is
/// protected. On an undersized host, `maximum` can be lower than `minimum`; `isFeasible`
/// makes that state explicit rather than disguising it by clamping one of the limits.
public struct DoryVMResourceGuidance: Codable, Sendable, Equatable {
    public let minimum: UInt64
    public let recommended: UInt64
    public let maximum: UInt64

    public init(minimum: UInt64, recommended: UInt64, maximum: UInt64) {
        self.minimum = minimum
        self.recommended = recommended
        self.maximum = maximum
    }

    public var isFeasible: Bool {
        maximum >= minimum
    }
}

/// Capacity deliberately retained for macOS and other host applications.
public struct DoryVMHostReserve: Codable, Sendable, Equatable {
    public let logicalCPUCount: UInt64
    public let memoryBytes: UInt64
    public let storageBytes: UInt64

    public init(logicalCPUCount: UInt64, memoryBytes: UInt64, storageBytes: UInt64) {
        self.logicalCPUCount = logicalCPUCount
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
    }
}

public struct DoryVMResourceRecommendation: Codable, Sendable, Equatable {
    public let virtualCPUCount: DoryVMResourceGuidance
    public let memoryBytes: DoryVMResourceGuidance
    public let diskBytes: DoryVMResourceGuidance
    public let hostReserve: DoryVMHostReserve

    public init(
        virtualCPUCount: DoryVMResourceGuidance,
        memoryBytes: DoryVMResourceGuidance,
        diskBytes: DoryVMResourceGuidance,
        hostReserve: DoryVMHostReserve
    ) {
        self.virtualCPUCount = virtualCPUCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.hostReserve = hostReserve
    }

    public var isFeasible: Bool {
        virtualCPUCount.isFeasible && memoryBytes.isFeasible && diskBytes.isFeasible
    }
}

public enum DoryVMResourceDimension: String, Codable, CaseIterable, Sendable {
    case cpu
    case memory
    case storage
}

public enum DoryVMResourceValidationSeverity: String, Codable, CaseIterable, Sendable {
    case warning
    case error
}

public enum DoryVMResourceValidationCode: String, Codable, CaseIterable, Sendable {
    case invalidHostCapacity
    case hostAdmissionExceedsCapacity
    case storageReservationExceedsCapacity
    case hostCapacityBelowWorkloadMinimum
    case requestBelowWorkloadMinimum
    case requestBelowRecommendation
    case requestExceedsHostSafeMaximum
}

/// A stable, machine-readable validation result suitable for UI, CLI, and API clients.
public struct DoryVMResourceValidationIssue: Codable, Sendable, Equatable {
    public let code: DoryVMResourceValidationCode
    public let severity: DoryVMResourceValidationSeverity
    public let resource: DoryVMResourceDimension
    /// The value being diagnosed: host capacity for host issues, requested capacity otherwise.
    public let actual: UInt64
    /// The workload minimum, recommendation, or host-safe maximum associated with the issue.
    public let threshold: UInt64

    public init(
        code: DoryVMResourceValidationCode,
        severity: DoryVMResourceValidationSeverity,
        resource: DoryVMResourceDimension,
        actual: UInt64,
        threshold: UInt64
    ) {
        self.code = code
        self.severity = severity
        self.resource = resource
        self.actual = actual
        self.threshold = threshold
    }
}

public struct DoryVMResourceAssessment: Codable, Sendable, Equatable {
    public let host: DoryVMHostResources
    public let workload: DoryVMWorkloadProfile
    public let requirements: [DoryVMResourceRequirement]
    public let request: DoryVMResourceRequest
    public let recommendation: DoryVMResourceRecommendation
    public let issues: [DoryVMResourceValidationIssue]

    public init(
        host: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement] = [],
        request: DoryVMResourceRequest,
        recommendation: DoryVMResourceRecommendation,
        issues: [DoryVMResourceValidationIssue]
    ) {
        self.host = host
        self.workload = workload
        self.requirements = requirements
        self.request = request
        self.recommendation = recommendation
        self.issues = issues
    }

    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }
}

/// Deterministic policy for sizing one VM while preserving enough capacity for the host.
public enum DoryVMResourcePolicy {
    private static let gibibyte: UInt64 = 1_073_741_824

    /// Compute host-aware sizing guidance before a user has made a selection.
    public static func recommend(
        host: DoryVMHostResources,
        workload: DoryVMWorkloadProfile
    ) -> DoryVMResourceRecommendation {
        recommend(host: host, workload: workload, requirements: [])
    }

    /// Compute guidance after composing image and component requirements with the workload.
    /// Each resource dimension is merged independently using its strictest requirement.
    public static func recommend(
        host: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement]
    ) -> DoryVMResourceRecommendation {
        let requirements = mergedRequirements(for: workload, additional: requirements)
        let reserve = hostReserve(for: host)
        let maximum = DoryVMResourceRequest(
            virtualCPUCount: availableCapacity(
                total: host.logicalCPUCount,
                allocated: host.admittedVirtualCPUCount,
                reserve: reserve.logicalCPUCount
            ),
            memoryBytes: availableCapacity(
                total: host.physicalMemoryBytes,
                allocated: host.admittedMemoryBytes,
                reserve: reserve.memoryBytes
            ),
            diskBytes: availableCapacity(
                total: host.freeStorageBytes,
                allocated: host.reservedStorageBytes,
                reserve: reserve.storageBytes
            )
        )
        return DoryVMResourceRecommendation(
            virtualCPUCount: guidance(
                minimum: requirements.minimum.virtualCPUCount,
                ideal: requirements.recommended.virtualCPUCount,
                maximum: maximum.virtualCPUCount
            ),
            memoryBytes: guidance(
                minimum: requirements.minimum.memoryBytes,
                ideal: requirements.recommended.memoryBytes,
                maximum: maximum.memoryBytes
            ),
            diskBytes: guidance(
                minimum: requirements.minimum.diskBytes,
                ideal: requirements.recommended.diskBytes,
                maximum: maximum.diskBytes
            ),
            hostReserve: reserve
        )
    }

    /// Evaluate a request against explicit host facts and workload requirements.
    public static func assess(
        host: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        request: DoryVMResourceRequest
    ) -> DoryVMResourceAssessment {
        assess(host: host, workload: workload, requirements: [], request: request)
    }

    /// Evaluate a request using workload, image, and component requirements together.
    public static func assess(
        host: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement],
        request: DoryVMResourceRequest
    ) -> DoryVMResourceAssessment {
        let recommendation = recommend(
            host: host,
            workload: workload,
            requirements: requirements
        )

        var issues: [DoryVMResourceValidationIssue] = []
        appendIssues(
            resource: .cpu,
            hostCapacity: host.logicalCPUCount,
            allocated: host.admittedVirtualCPUCount,
            overCapacityCode: .hostAdmissionExceedsCapacity,
            requested: request.virtualCPUCount,
            guidance: recommendation.virtualCPUCount,
            to: &issues
        )
        appendIssues(
            resource: .memory,
            hostCapacity: host.physicalMemoryBytes,
            allocated: host.admittedMemoryBytes,
            overCapacityCode: .hostAdmissionExceedsCapacity,
            requested: request.memoryBytes,
            guidance: recommendation.memoryBytes,
            to: &issues
        )
        appendIssues(
            resource: .storage,
            hostCapacity: host.freeStorageBytes,
            allocated: host.reservedStorageBytes,
            overCapacityCode: .storageReservationExceedsCapacity,
            requested: request.diskBytes,
            guidance: recommendation.diskBytes,
            to: &issues
        )

        return DoryVMResourceAssessment(
            host: host,
            workload: workload,
            requirements: requirements,
            request: request,
            recommendation: recommendation,
            issues: issues
        )
    }

    private struct Requirements {
        let minimum: DoryVMResourceRequest
        let recommended: DoryVMResourceRequest
    }

    private static func mergedRequirements(
        for workload: DoryVMWorkloadProfile,
        additional: [DoryVMResourceRequirement]
    ) -> Requirements {
        let baseline = requirements(for: workload)
        let minimum = additional.reduce(baseline.minimum) { current, requirement in
            maximum(current, requirement.minimum)
        }
        let requestedRecommendation = additional.reduce(baseline.recommended) {
            current,
            requirement in
            maximum(current, requirement.recommended)
        }
        return Requirements(
            minimum: minimum,
            // A malformed manifest cannot lower the recommendation below its own minimum.
            recommended: maximum(minimum, requestedRecommendation)
        )
    }

    private static func maximum(
        _ lhs: DoryVMResourceRequest,
        _ rhs: DoryVMResourceRequest
    ) -> DoryVMResourceRequest {
        DoryVMResourceRequest(
            virtualCPUCount: max(lhs.virtualCPUCount, rhs.virtualCPUCount),
            memoryBytes: max(lhs.memoryBytes, rhs.memoryBytes),
            diskBytes: max(lhs.diskBytes, rhs.diskBytes)
        )
    }

    private static func requirements(for workload: DoryVMWorkloadProfile) -> Requirements {
        switch workload {
        case .desktop:
            return Requirements(
                minimum: DoryVMResourceRequest(
                    virtualCPUCount: 2,
                    memoryBytes: 4 * gibibyte,
                    diskBytes: 32 * gibibyte
                ),
                recommended: DoryVMResourceRequest(
                    virtualCPUCount: 4,
                    memoryBytes: 8 * gibibyte,
                    diskBytes: 64 * gibibyte
                )
            )
        case .server:
            return Requirements(
                minimum: DoryVMResourceRequest(
                    virtualCPUCount: 1,
                    memoryBytes: 2 * gibibyte,
                    diskBytes: 16 * gibibyte
                ),
                recommended: DoryVMResourceRequest(
                    virtualCPUCount: 2,
                    memoryBytes: 4 * gibibyte,
                    diskBytes: 32 * gibibyte
                )
            )
        case .installer:
            return Requirements(
                minimum: DoryVMResourceRequest(
                    virtualCPUCount: 2,
                    memoryBytes: 4 * gibibyte,
                    diskBytes: 40 * gibibyte
                ),
                recommended: DoryVMResourceRequest(
                    virtualCPUCount: 4,
                    memoryBytes: 8 * gibibyte,
                    diskBytes: 64 * gibibyte
                )
            )
        }
    }

    private static func hostReserve(for host: DoryVMHostResources) -> DoryVMHostReserve {
        // Keep at least one logical CPU and 25% of compute capacity available to the host.
        let cpuReserve = max(1, ceilingFraction(host.logicalCPUCount, denominator: 4))
        // Keep at least 2 GiB and 25% of physical memory available to the host.
        let memoryReserve = max(2 * gibibyte, ceilingFraction(host.physicalMemoryBytes, denominator: 4))
        // Do not consume the host's final 10 GiB or final 10% of reported free storage.
        let storageReserve = max(10 * gibibyte, ceilingFraction(host.freeStorageBytes, denominator: 10))
        return DoryVMHostReserve(
            logicalCPUCount: min(cpuReserve, host.logicalCPUCount),
            memoryBytes: min(memoryReserve, host.physicalMemoryBytes),
            storageBytes: min(storageReserve, host.freeStorageBytes)
        )
    }

    /// Computes ceil(value / denominator) without multiplication or addition overflow.
    private static func ceilingFraction(_ value: UInt64, denominator: UInt64) -> UInt64 {
        let quotient = value / denominator
        return quotient + (value % denominator == 0 ? 0 : 1)
    }

    private static func subtractingWithoutUnderflow(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        value >= amount ? value - amount : 0
    }

    private static func availableCapacity(
        total: UInt64,
        allocated: UInt64,
        reserve: UInt64
    ) -> UInt64 {
        subtractingWithoutUnderflow(subtractingWithoutUnderflow(total, allocated), reserve)
    }

    private static func guidance(
        minimum: UInt64,
        ideal: UInt64,
        maximum: UInt64
    ) -> DoryVMResourceGuidance {
        // Keep the selectable default inside the safe range whenever the workload is feasible.
        let recommended = maximum >= minimum ? min(ideal, maximum) : minimum
        return DoryVMResourceGuidance(
            minimum: minimum,
            recommended: recommended,
            maximum: maximum
        )
    }

    private static func appendIssues(
        resource: DoryVMResourceDimension,
        hostCapacity: UInt64,
        allocated: UInt64,
        overCapacityCode: DoryVMResourceValidationCode,
        requested: UInt64,
        guidance: DoryVMResourceGuidance,
        to issues: inout [DoryVMResourceValidationIssue]
    ) {
        if hostCapacity == 0 {
            issues.append(DoryVMResourceValidationIssue(
                code: .invalidHostCapacity,
                severity: .error,
                resource: resource,
                actual: hostCapacity,
                threshold: 1
            ))
        }

        if allocated > hostCapacity {
            issues.append(DoryVMResourceValidationIssue(
                code: overCapacityCode,
                severity: .error,
                resource: resource,
                actual: allocated,
                threshold: hostCapacity
            ))
        }

        if !guidance.isFeasible {
            issues.append(DoryVMResourceValidationIssue(
                code: .hostCapacityBelowWorkloadMinimum,
                severity: .error,
                resource: resource,
                actual: guidance.maximum,
                threshold: guidance.minimum
            ))
        }

        if requested < guidance.minimum {
            issues.append(DoryVMResourceValidationIssue(
                code: .requestBelowWorkloadMinimum,
                severity: .error,
                resource: resource,
                actual: requested,
                threshold: guidance.minimum
            ))
        } else if requested < guidance.recommended {
            issues.append(DoryVMResourceValidationIssue(
                code: .requestBelowRecommendation,
                severity: .warning,
                resource: resource,
                actual: requested,
                threshold: guidance.recommended
            ))
        }

        if requested > guidance.maximum {
            issues.append(DoryVMResourceValidationIssue(
                code: .requestExceedsHostSafeMaximum,
                severity: .error,
                resource: resource,
                actual: requested,
                threshold: guidance.maximum
            ))
        }
    }
}
