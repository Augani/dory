import Darwin
import DoryCore
import Foundation

public enum HostMemoryPressure: String, Sendable, Equatable {
    case nominal
    case warning
    case critical
}

public struct HostMemorySnapshot: Sendable, Equatable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var freeBytes: UInt64
    public var pressure: HostMemoryPressure

    public init(
        totalBytes: UInt64,
        availableBytes: UInt64,
        freeBytes: UInt64,
        pressure: HostMemoryPressure = .nominal
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.freeBytes = freeBytes
        self.pressure = pressure
    }

    public var availableRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(availableBytes) / Double(totalBytes)
    }
}

public enum BalloonGuestKind: String, Sendable, Equatable {
    case docker
    case virtualMachine
    case remote
}

public struct GuestMemorySnapshot: Sendable, Equatable {
    public var id: String
    public var kind: BalloonGuestKind
    public var telemetry: DoryTelemetry
    public var currentTargetMB: UInt64
    public var minimumTargetMB: UInt64
    public var maximumTargetMB: UInt64?
    public var canBalloon: Bool

    public init(
        id: String,
        kind: BalloonGuestKind,
        telemetry: DoryTelemetry,
        currentTargetMB: UInt64? = nil,
        minimumTargetMB: UInt64 = 512,
        maximumTargetMB: UInt64? = nil,
        canBalloon: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.telemetry = telemetry
        self.currentTargetMB = max(1, currentTargetMB ?? telemetry.memTotalKB / 1024)
        self.minimumTargetMB = max(1, minimumTargetMB)
        self.maximumTargetMB = maximumTargetMB
        self.canBalloon = canBalloon
    }

    public var guestAvailableRatio: Double {
        guard telemetry.memTotalKB > 0 else { return 0 }
        return Double(telemetry.memAvailableKB) / Double(telemetry.memTotalKB)
    }

    public var workingSetMB: UInt64 {
        let usedKB = telemetry.memTotalKB.saturatingSubtracting(telemetry.memAvailableKB)
        return usedKB.roundingUp(divisor: 1024)
    }
}

public enum BalloonTargetReason: String, Sendable, Equatable {
    case steady
    case hostWarning
    case hostCritical
    case guestPressure
    case protectedWorkingSet
    case notBalloonable
}

public struct BalloonTarget: Sendable, Equatable {
    public var id: String
    public var kind: BalloonGuestKind
    public var currentTargetMB: UInt64
    public var targetMB: UInt64
    public var reason: BalloonTargetReason
    public var canApply: Bool

    public init(
        id: String,
        kind: BalloonGuestKind,
        currentTargetMB: UInt64,
        targetMB: UInt64,
        reason: BalloonTargetReason,
        canApply: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.currentTargetMB = currentTargetMB
        self.targetMB = targetMB
        self.reason = reason
        self.canApply = canApply
    }
}

public struct BalloonPlan: Sendable, Equatable {
    public var host: HostMemorySnapshot
    public var targets: [BalloonTarget]

    public init(host: HostMemorySnapshot, targets: [BalloonTarget]) {
        self.host = host
        self.targets = targets
    }

    public var applicableTargets: [BalloonTarget] {
        targets.filter { $0.canApply && $0.targetMB != $0.currentTargetMB }
    }
}

public struct BalloonPolicy: Sendable, Equatable {
    public var warningHostAvailableRatio: Double
    public var criticalHostAvailableRatio: Double
    public var warningReclaimStepMB: UInt64
    public var criticalReclaimStepMB: UInt64
    public var guestGrowthStepMB: UInt64
    public var guestLowAvailableRatio: Double
    public var guestPSISomeWarning: Double
    public var guestPSIFullCritical: Double
    public var workingSetHeadroomRatio: Double

    public init(
        warningHostAvailableRatio: Double = 0.15,
        criticalHostAvailableRatio: Double = 0.08,
        warningReclaimStepMB: UInt64 = 256,
        criticalReclaimStepMB: UInt64 = 512,
        guestGrowthStepMB: UInt64 = 256,
        guestLowAvailableRatio: Double = 0.10,
        guestPSISomeWarning: Double = 10,
        guestPSIFullCritical: Double = 1,
        workingSetHeadroomRatio: Double = 1.15
    ) {
        self.warningHostAvailableRatio = warningHostAvailableRatio
        self.criticalHostAvailableRatio = criticalHostAvailableRatio
        self.warningReclaimStepMB = warningReclaimStepMB
        self.criticalReclaimStepMB = criticalReclaimStepMB
        self.guestGrowthStepMB = guestGrowthStepMB
        self.guestLowAvailableRatio = guestLowAvailableRatio
        self.guestPSISomeWarning = guestPSISomeWarning
        self.guestPSIFullCritical = guestPSIFullCritical
        self.workingSetHeadroomRatio = workingSetHeadroomRatio
    }

    public func hostPressure(for host: HostMemorySnapshot) -> HostMemoryPressure {
        if host.pressure == .critical || host.availableRatio <= criticalHostAvailableRatio {
            return .critical
        }
        if host.pressure == .warning || host.availableRatio <= warningHostAvailableRatio {
            return .warning
        }
        return .nominal
    }
}

public protocol HostMemoryProbing: Sendable {
    func snapshot() throws -> HostMemorySnapshot
}

public enum SystemHostMemoryProbeError: Error, Sendable, CustomStringConvertible {
    case pageSize(kern_return_t)
    case statistics(kern_return_t)

    public var description: String {
        switch self {
        case let .pageSize(code):
            return "host_page_size failed: \(code)"
        case let .statistics(code):
            return "host_statistics64 failed: \(code)"
        }
    }
}

public final class SystemHostMemoryProbe: HostMemoryProbing, @unchecked Sendable {
    private let policy: BalloonPolicy

    public init(policy: BalloonPolicy = BalloonPolicy()) {
        self.policy = policy
    }

    public func snapshot() throws -> HostMemorySnapshot {
        let host = mach_host_self()
        var pageSize = vm_size_t(0)
        let pageSizeResult = host_page_size(host, &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            throw SystemHostMemoryProbeError.pageSize(pageSizeResult)
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let statsResult = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard statsResult == KERN_SUCCESS else {
            throw SystemHostMemoryProbeError.statistics(statsResult)
        }

        let page = UInt64(pageSize)
        let free = UInt64(stats.free_count) * page
        let availablePages = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        let total = ProcessInfo.processInfo.physicalMemory
        var snapshot = HostMemorySnapshot(
            totalBytes: total,
            availableBytes: availablePages * page,
            freeBytes: free
        )
        snapshot.pressure = policy.hostPressure(for: snapshot)
        return snapshot
    }
}

public protocol BalloonActuator: Sendable {
    func apply(targets: [BalloonTarget]) throws
}

public final class BalloonController: @unchecked Sendable {
    private let hostProbe: any HostMemoryProbing
    private let policy: BalloonPolicy
    private let actuator: (any BalloonActuator)?

    public init(
        hostProbe: any HostMemoryProbing = SystemHostMemoryProbe(),
        policy: BalloonPolicy = BalloonPolicy(),
        actuator: (any BalloonActuator)? = nil
    ) {
        self.hostProbe = hostProbe
        self.policy = policy
        self.actuator = actuator
    }

    public func currentPlan(guests: [GuestMemorySnapshot]) throws -> BalloonPlan {
        plan(host: try hostProbe.snapshot(), guests: guests)
    }

    public func reconcile(guests: [GuestMemorySnapshot]) throws -> BalloonPlan {
        let plan = try currentPlan(guests: guests)
        try actuator?.apply(targets: plan.applicableTargets)
        return plan
    }

    public func plan(
        host: HostMemorySnapshot,
        guests: [GuestMemorySnapshot]
    ) -> BalloonPlan {
        let pressure = policy.hostPressure(for: host)
        let targets = guests.map { target(for: $0, hostPressure: pressure) }
        return BalloonPlan(host: host, targets: targets)
    }

    private func target(
        for guest: GuestMemorySnapshot,
        hostPressure: HostMemoryPressure
    ) -> BalloonTarget {
        guard guest.canBalloon else {
            return BalloonTarget(
                id: guest.id,
                kind: guest.kind,
                currentTargetMB: guest.currentTargetMB,
                targetMB: guest.currentTargetMB,
                reason: .notBalloonable,
                canApply: false
            )
        }

        switch hostPressure {
        case .critical:
            return reclaimTarget(for: guest, stepMB: policy.criticalReclaimStepMB, reason: .hostCritical)
        case .warning:
            return reclaimTarget(for: guest, stepMB: policy.warningReclaimStepMB, reason: .hostWarning)
        case .nominal:
            if guestIsPressured(guest) {
                let grown = clamp(
                    guest.currentTargetMB + policy.guestGrowthStepMB,
                    minimum: guest.minimumTargetMB,
                    maximum: guest.maximumTargetMB
                )
                return BalloonTarget(
                    id: guest.id,
                    kind: guest.kind,
                    currentTargetMB: guest.currentTargetMB,
                    targetMB: grown,
                    reason: grown == guest.currentTargetMB ? .protectedWorkingSet : .guestPressure
                )
            }
            return BalloonTarget(
                id: guest.id,
                kind: guest.kind,
                currentTargetMB: guest.currentTargetMB,
                targetMB: guest.currentTargetMB,
                reason: .steady
            )
        }
    }

    private func reclaimTarget(
        for guest: GuestMemorySnapshot,
        stepMB: UInt64,
        reason: BalloonTargetReason
    ) -> BalloonTarget {
        let floor = protectedFloor(for: guest)
        let reduced = guest.currentTargetMB.saturatingSubtracting(stepMB)
        let reclaimed = min(guest.currentTargetMB, max(floor, reduced))
        let target = clamp(reclaimed, minimum: guest.minimumTargetMB, maximum: guest.maximumTargetMB)
        return BalloonTarget(
            id: guest.id,
            kind: guest.kind,
            currentTargetMB: guest.currentTargetMB,
            targetMB: target,
            reason: target < guest.currentTargetMB ? reason : .protectedWorkingSet
        )
    }

    private func protectedFloor(for guest: GuestMemorySnapshot) -> UInt64 {
        let headroom = UInt64((Double(guest.workingSetMB) * policy.workingSetHeadroomRatio).rounded(.up))
        return max(guest.minimumTargetMB, headroom)
    }

    private func guestIsPressured(_ guest: GuestMemorySnapshot) -> Bool {
        guest.guestAvailableRatio <= policy.guestLowAvailableRatio
            || guest.telemetry.psiSomeAvg10 >= policy.guestPSISomeWarning
            || guest.telemetry.psiFullAvg10 >= policy.guestPSIFullCritical
    }
}

private func clamp(_ value: UInt64, minimum: UInt64, maximum: UInt64?) -> UInt64 {
    var clamped = max(value, minimum)
    if let maximum {
        clamped = min(clamped, maximum)
    }
    return clamped
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }

    func roundingUp(divisor: UInt64) -> UInt64 {
        guard divisor > 0 else { return self }
        return (self + divisor - 1) / divisor
    }
}
