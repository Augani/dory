import DoryOperations
import Foundation

/// Lifecycle operations implemented by a daemon backend adapter. This is intentionally separate
/// from product support policy: it describes only what the concrete launch mechanism can do.
public struct MachineBackendLifecycleCapabilities: Codable, Sendable, Equatable, Hashable {
    public var start: Bool
    public var stop: Bool
    public var pause: Bool
    public var resume: Bool

    public init(start: Bool, stop: Bool, pause: Bool, resume: Bool) {
        self.start = start
        self.stop = stop
        self.pause = pause
        self.resume = resume
    }

    /// `MachineManager` currently exposes start and stop, but not pause and resume.
    public static let currentMachineManager = MachineBackendLifecycleCapabilities(
        start: true,
        stop: true,
        pause: false,
        resume: false
    )
}

public struct MachineBackendDescriptor: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var identity: DoryVirtualizationBackendIdentity
    /// Stable identity for the daemon adapter implementation, independent of the helper build.
    public var implementationIdentifier: String
    public var guestFamilies: [DoryGuestFamily]
    public var guestArchitectures: [DoryGuestArchitecture]
    public var bootMediaKinds: [DoryBootMediaKind]
    public var lifecycle: MachineBackendLifecycleCapabilities

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identity: DoryVirtualizationBackendIdentity,
        implementationIdentifier: String,
        guestFamilies: [DoryGuestFamily],
        guestArchitectures: [DoryGuestArchitecture],
        bootMediaKinds: [DoryBootMediaKind],
        lifecycle: MachineBackendLifecycleCapabilities
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.implementationIdentifier = implementationIdentifier
        self.guestFamilies = guestFamilies
        self.guestArchitectures = guestArchitectures
        self.bootMediaKinds = bootMediaKinds
        self.lifecycle = lifecycle
    }
}

public enum MachineBackendProbeState: String, Codable, Sendable, Equatable, Hashable {
    case available
    case unavailable
}

public enum MachineBackendFailureCode: String, Codable, Sendable, Equatable, Hashable {
    case componentNotConfigured = "component-not-configured"
    case componentUnavailable = "component-unavailable"
    case duplicateRegistration = "duplicate-registration"
    case backendNotRegistered = "backend-not-registered"
    case capabilityPlanRejected = "capability-plan-rejected"
    case capabilitySelectionInvalid = "capability-selection-invalid"
    case backendIdentityMismatch = "backend-identity-mismatch"
    case guestUnsupported = "guest-unsupported"
    case bootMediaUnsupported = "boot-media-unsupported"
    case machineConfigurationIncompatible = "machine-configuration-incompatible"
    case lifecycleOperationUnsupported = "lifecycle-operation-unsupported"
    case lifecycleOperationFailed = "lifecycle-operation-failed"
}

public struct MachineBackendFailure: Codable, Error, Sendable, Equatable, Hashable {
    public var code: MachineBackendFailureCode
    public var backend: DoryVirtualizationBackendIdentity?
    public var message: String

    public init(
        code: MachineBackendFailureCode,
        backend: DoryVirtualizationBackendIdentity? = nil,
        message: String
    ) {
        self.code = code
        self.backend = backend
        self.message = message
    }
}

public struct MachineBackendProbeResult: Codable, Sendable, Equatable, Hashable {
    public var descriptor: MachineBackendDescriptor
    public var state: MachineBackendProbeState
    public var failure: MachineBackendFailure?

    public var isAvailable: Bool { state == .available && failure == nil }

    public init(
        descriptor: MachineBackendDescriptor,
        state: MachineBackendProbeState,
        failure: MachineBackendFailure? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.failure = failure
    }
}

/// Daemon-local bridge between a persisted machine and an already evaluated product capability.
/// The adapter does not choose a support tier or downgrade the planner's requested devices.
public struct MachineBackendPlanRequest: Codable, Sendable, Equatable, Hashable {
    public var machine: DoryMachineConfiguration
    public var capabilityPlan: DoryVirtualMachineBackendPlanResult

    public init(
        machine: DoryMachineConfiguration,
        capabilityPlan: DoryVirtualMachineBackendPlanResult
    ) {
        self.machine = machine
        self.capabilityPlan = capabilityPlan
    }
}

public struct MachineBackendPlan: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var backend: MachineBackendDescriptor
    public var machine: DoryMachineConfiguration
    public var capability: DoryVirtualMachineCapabilityDescriptor

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        backend: MachineBackendDescriptor,
        machine: DoryMachineConfiguration,
        capability: DoryVirtualMachineCapabilityDescriptor
    ) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        self.machine = machine
        self.capability = capability
    }
}

public struct MachineBackendPlanResult: Codable, Sendable, Equatable, Hashable {
    public var plan: MachineBackendPlan?
    public var probe: MachineBackendProbeResult?
    public var failure: MachineBackendFailure?

    public var isSuccess: Bool { plan != nil && failure == nil }

    public init(
        plan: MachineBackendPlan?,
        probe: MachineBackendProbeResult?,
        failure: MachineBackendFailure?
    ) {
        self.plan = plan
        self.probe = probe
        self.failure = failure
    }
}

public enum MachineBackendRuntimeState: String, Codable, Sendable, Equatable, Hashable {
    case created
    case starting
    case running
    case paused
    case stopped
    case failed
}

public struct MachineBackendRuntimeObservation: Codable, Sendable, Equatable, Hashable {
    public var machineID: String
    public var state: MachineBackendRuntimeState
    public var processIdentifier: Int32?
    public var failureMessage: String?

    public init(
        machineID: String,
        state: MachineBackendRuntimeState,
        processIdentifier: Int32? = nil,
        failureMessage: String? = nil
    ) {
        self.machineID = machineID
        self.state = state
        self.processIdentifier = processIdentifier
        self.failureMessage = failureMessage
    }
}

public struct MachineBackendRuntimeRequest: Codable, Sendable, Equatable, Hashable {
    public var machineID: String
    public var backend: DoryVirtualizationBackendIdentity

    public init(machineID: String, backend: DoryVirtualizationBackendIdentity) {
        self.machineID = machineID
        self.backend = backend
    }
}

/// Daemon-local launch authority issued by the exact adapter instance that revalidated a plan.
/// It is deliberately not Codable: host executable paths are runtime wiring, never persisted VM
/// desired state or portable plan evidence.
public struct MachineBackendLaunchBinding: Sendable, Equatable {
    public var machineID: String
    public var backend: MachineBackendDescriptor
    public var componentIdentifier: String
    public var executablePath: String

    public init(
        machineID: String,
        backend: MachineBackendDescriptor,
        componentIdentifier: String,
        executablePath: String
    ) {
        self.machineID = machineID
        self.backend = backend
        self.componentIdentifier = componentIdentifier
        self.executablePath = executablePath
    }
}

public enum MachineBackendLifecycleOperation: String, Codable, Sendable, Equatable, Hashable {
    case start
    case stop
    case pause
    case resume
}

public struct MachineBackendOperationResult: Codable, Sendable, Equatable, Hashable {
    public var operation: MachineBackendLifecycleOperation
    public var backend: DoryVirtualizationBackendIdentity
    public var observation: MachineBackendRuntimeObservation?
    public var failure: MachineBackendFailure?

    public var isSuccess: Bool { observation != nil && failure == nil }

    public init(
        operation: MachineBackendLifecycleOperation,
        backend: DoryVirtualizationBackendIdentity,
        observation: MachineBackendRuntimeObservation?,
        failure: MachineBackendFailure?
    ) {
        self.operation = operation
        self.backend = backend
        self.observation = observation
        self.failure = failure
    }
}

/// Mechanism boundary owned by doryd. Implementations validate a planner selection and adapt an
/// existing launcher; they must not decide product support tiers or silently alter capabilities.
public protocol MachineBackend: Sendable {
    var descriptor: MachineBackendDescriptor { get }

    func probe() -> MachineBackendProbeResult
    func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult
    func start(_ plan: MachineBackendPlan) -> MachineBackendOperationResult
    func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult
    func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult
    func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult
}

/// Immutable registry for deterministic backend discovery and dispatch.
public struct BackendRegistry: Sendable {
    private let backends: [DoryVirtualizationBackendIdentity: any MachineBackend]

    public init(backends: [any MachineBackend]) throws {
        var indexed: [DoryVirtualizationBackendIdentity: any MachineBackend] = [:]
        for backend in backends {
            let identity = backend.descriptor.identity
            guard indexed[identity] == nil else {
                throw MachineBackendFailure(
                    code: .duplicateRegistration,
                    backend: identity,
                    message: "A backend is already registered for \(identity.rawValue)."
                )
            }
            indexed[identity] = backend
        }
        self.backends = indexed
    }

    public var descriptors: [MachineBackendDescriptor] {
        orderedBackends.map(\.descriptor)
    }

    public func backend(
        for identity: DoryVirtualizationBackendIdentity
    ) -> (any MachineBackend)? {
        backends[identity]
    }

    public func probeAll() -> [MachineBackendProbeResult] {
        orderedBackends.map { $0.probe() }
    }

    public func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult {
        guard request.capabilityPlan.failure == nil,
              let selected = request.capabilityPlan.selectedDescriptor else {
            return MachineBackendPlanResult(
                plan: nil,
                probe: nil,
                failure: MachineBackendFailure(
                    code: .capabilityPlanRejected,
                    message: "The product capability planner did not select a backend."
                )
            )
        }
        let identity = selected.request.backend
        guard let backend = backends[identity] else {
            return MachineBackendPlanResult(
                plan: nil,
                probe: nil,
                failure: MachineBackendFailure(
                    code: .backendNotRegistered,
                    backend: identity,
                    message: "No daemon adapter is registered for \(identity.rawValue)."
                )
            )
        }
        return backend.plan(request)
    }

    public func start(_ plan: MachineBackendPlan) -> MachineBackendOperationResult {
        guard let backend = backends[plan.backend.identity] else {
            return missingBackendResult(operation: .start, identity: plan.backend.identity)
        }
        return backend.start(plan)
    }

    public func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        dispatch(.stop, request: request) { $0.stop(request) }
    }

    public func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        dispatch(.pause, request: request) { $0.pause(request) }
    }

    public func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        dispatch(.resume, request: request) { $0.resume(request) }
    }

    private var orderedBackends: [any MachineBackend] {
        backends.values.sorted {
            let left = $0.descriptor
            let right = $1.descriptor
            if left.identity.rawValue != right.identity.rawValue {
                return left.identity.rawValue < right.identity.rawValue
            }
            return left.implementationIdentifier < right.implementationIdentifier
        }
    }

    private func dispatch(
        _ operation: MachineBackendLifecycleOperation,
        request: MachineBackendRuntimeRequest,
        action: (any MachineBackend) -> MachineBackendOperationResult
    ) -> MachineBackendOperationResult {
        guard let backend = backends[request.backend] else {
            return missingBackendResult(operation: operation, identity: request.backend)
        }
        return action(backend)
    }

    private func missingBackendResult(
        operation: MachineBackendLifecycleOperation,
        identity: DoryVirtualizationBackendIdentity
    ) -> MachineBackendOperationResult {
        MachineBackendOperationResult(
            operation: operation,
            backend: identity,
            observation: nil,
            failure: MachineBackendFailure(
                code: .backendNotRegistered,
                backend: identity,
                message: "No daemon adapter is registered for \(identity.rawValue)."
            )
        )
    }
}
