import DoryOperations
import Foundation

public typealias MachineBackendLegacyStartHandler = @Sendable (
    String
) throws -> MachineBackendRuntimeObservation
public typealias MachineBackendLifecycleHandler = @Sendable (
    MachineBackendRuntimeRequest
) throws -> MachineBackendRuntimeObservation
public typealias MachineBackendAuthorizedStartHandler = @Sendable (
    MachineBackendLaunchBinding
) throws -> MachineBackendRuntimeObservation

/// Hooks implemented by the existing machine launcher. Keeping them injectable lets the seam be
/// qualified before MachineManager starts consuming BackendRegistry.
public struct MachineBackendCompatibilityOperations: Sendable {
    public var start: MachineBackendLegacyStartHandler
    public var authorizedStart: MachineBackendAuthorizedStartHandler
    public var stop: MachineBackendLifecycleHandler
    public var pause: MachineBackendLifecycleHandler
    public var resume: MachineBackendLifecycleHandler

    public init(
        start: @escaping MachineBackendLegacyStartHandler,
        stop: @escaping MachineBackendLifecycleHandler,
        pause: @escaping MachineBackendLifecycleHandler,
        resume: @escaping MachineBackendLifecycleHandler
    ) {
        self.start = start
        authorizedStart = { binding in try start(binding.machineID) }
        self.stop = stop
        self.pause = pause
        self.resume = resume
    }

    public init(
        authorizedStart: @escaping MachineBackendAuthorizedStartHandler,
        stop: @escaping MachineBackendLifecycleHandler,
        pause: @escaping MachineBackendLifecycleHandler,
        resume: @escaping MachineBackendLifecycleHandler
    ) {
        start = { _ in
            throw MachineBackendFailure(
                code: .lifecycleOperationFailed,
                message: "An adapter-issued launch binding is required."
            )
        }
        self.authorizedStart = authorizedStart
        self.stop = stop
        self.pause = pause
        self.resume = resume
    }

}

public extension MachineBackendRuntimeObservation {
    init(_ status: DoryMachineStatus) {
        self.init(
            machineID: status.id,
            state: MachineBackendRuntimeState(status.state),
            processIdentifier: status.pid,
            failureMessage: status.lastError
        )
    }
}

private extension MachineBackendRuntimeState {
    init(_ state: DoryMachineState) {
        switch state {
        case .created: self = .created
        case .starting: self = .starting
        case .running: self = .running
        case .paused: self = .paused
        case .suspended: self = .suspended
        case .stopped: self = .stopped
        case .failed: self = .failed
        }
    }
}

private final class LinuxMachineBackendAdapterCore: @unchecked Sendable {
    typealias MachineValidator = @Sendable (
        DoryMachineConfiguration,
        DoryVirtualMachineCapabilityDescriptor
    ) -> String?

    let descriptor: MachineBackendDescriptor
    private let componentIdentifier: String
    private let executablePath: String?
    private let executableIsAvailable: @Sendable (String) -> Bool
    private let operations: MachineBackendCompatibilityOperations
    private let validateMachine: MachineValidator

    init(
        descriptor: MachineBackendDescriptor,
        componentIdentifier: String,
        executablePath: String?,
        executableIsAvailable: @escaping @Sendable (String) -> Bool,
        operations: MachineBackendCompatibilityOperations,
        validateMachine: @escaping MachineValidator
    ) {
        self.descriptor = descriptor
        self.componentIdentifier = componentIdentifier
        self.executablePath = executablePath
        self.executableIsAvailable = executableIsAvailable
        self.operations = operations
        self.validateMachine = validateMachine
    }

    func probe() -> MachineBackendProbeResult {
        guard let executablePath, !executablePath.isEmpty else {
            return unavailableProbe(
                code: .componentNotConfigured,
                message: "The backend helper path is not configured."
            )
        }
        guard executableIsAvailable(executablePath) else {
            return unavailableProbe(
                code: .componentUnavailable,
                message: "The configured backend helper is unavailable or not executable."
            )
        }
        return MachineBackendProbeResult(descriptor: descriptor, state: .available)
    }

    func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult {
        let currentProbe = probe()
        guard currentProbe.isAvailable else {
            return MachineBackendPlanResult(
                plan: nil,
                probe: currentProbe,
                failure: currentProbe.failure
            )
        }
        guard request.capabilityPlan.failure == nil,
              let capability = request.capabilityPlan.selectedDescriptor else {
            return failedPlan(
                probe: currentProbe,
                code: .capabilityPlanRejected,
                message: "The product capability planner did not select a backend."
            )
        }
        guard request.capabilityPlan.evaluatedDescriptors.contains(capability),
              capability.schemaVersion == DoryVirtualMachineCapabilityDescriptor.currentSchemaVersion,
              capability.evaluatorVersion == DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
              capability.availability.isUsable,
              capability.resolvedDevices == capability.request.devices else {
            return failedPlan(
                probe: currentProbe,
                code: .capabilitySelectionInvalid,
                message: "The selected capability is not a complete usable planner result."
            )
        }
        guard capability.request.backend == descriptor.identity else {
            return failedPlan(
                probe: currentProbe,
                code: .backendIdentityMismatch,
                message: "The selected capability belongs to a different backend."
            )
        }
        guard descriptor.guestFamilies.contains(capability.request.guest.family),
              descriptor.guestArchitectures.contains(capability.request.guest.architecture) else {
            return failedPlan(
                probe: currentProbe,
                code: .guestUnsupported,
                message: "The selected guest is not implemented by this backend adapter."
            )
        }
        guard descriptor.bootMediaKinds.contains(capability.request.bootMedia.kind) else {
            return failedPlan(
                probe: currentProbe,
                code: .bootMediaUnsupported,
                message: "The selected boot-media kind is not implemented by this backend adapter."
            )
        }
        if let validationFailure = validateMachine(request.machine, capability) {
            return failedPlan(
                probe: currentProbe,
                code: .machineConfigurationIncompatible,
                message: validationFailure
            )
        }
        return MachineBackendPlanResult(
            plan: MachineBackendPlan(
                backend: descriptor,
                machine: request.machine,
                capability: capability
            ),
            probe: currentProbe,
            failure: nil
        )
    }

    func start(_ request: MachineBackendStartRequest) -> MachineBackendOperationResult {
        let plan = request.plan
        guard request.hasValidOperationIdentity else {
            return failedOperation(
                .start,
                code: .lifecycleOperationIdentityInvalid,
                message: "The start request has no valid durable operation identity."
            )
        }
        guard plan.backend == descriptor,
              plan.capability.request.backend == descriptor.identity else {
            return failedOperation(
                .start,
                code: .backendIdentityMismatch,
                message: "The launch plan belongs to a different backend adapter."
            )
        }
        let revalidated = self.plan(MachineBackendPlanRequest(
            machine: plan.machine,
            capabilityPlan: DoryVirtualMachineBackendPlanResult(
                selectedDescriptor: plan.capability,
                evaluatedDescriptors: [plan.capability],
                failure: nil
            )
        ))
        guard revalidated.plan == plan else {
            return failedOperation(
                .start,
                code: revalidated.failure?.code ?? .capabilitySelectionInvalid,
                message: revalidated.failure?.message
                    ?? "The backend launch plan could not be revalidated."
            )
        }
        guard descriptor.lifecycle.start else {
            return unsupportedOperation(.start)
        }
        guard let executablePath, !executablePath.isEmpty else {
            return failedOperation(
                .start,
                code: .componentNotConfigured,
                message: "The backend helper path is not configured."
            )
        }
        return performAuthorizedStart(MachineBackendLaunchBinding(
            machineID: plan.machine.id,
            operationID: request.operationID,
            backend: descriptor,
            componentIdentifier: componentIdentifier,
            executablePath: executablePath,
            graphics: plan.capability.request.graphics,
            devices: plan.capability.request.devices
        ))
    }

    func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        guard request.hasValidOperationIdentity else {
            return failedOperation(
                .stop,
                code: .lifecycleOperationIdentityInvalid,
                message: "The stop request has no valid durable operation identity."
            )
        }
        guard request.backend == descriptor.identity else {
            return failedOperation(
                .stop,
                code: .backendIdentityMismatch,
                message: "The runtime request belongs to a different backend adapter."
            )
        }
        guard descriptor.lifecycle.stop else {
            return unsupportedOperation(.stop)
        }
        return perform(.stop, request: request, operation: operations.stop)
    }

    func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        guard request.hasValidOperationIdentity else {
            return failedOperation(
                .pause,
                code: .lifecycleOperationIdentityInvalid,
                message: "The pause request has no valid durable operation identity."
            )
        }
        guard request.backend == descriptor.identity else {
            return failedOperation(
                .pause,
                code: .backendIdentityMismatch,
                message: "The runtime request belongs to a different backend adapter."
            )
        }
        guard descriptor.lifecycle.pause else {
            return unsupportedOperation(.pause)
        }
        return perform(.pause, request: request, operation: operations.pause)
    }

    func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        guard request.hasValidOperationIdentity else {
            return failedOperation(
                .resume,
                code: .lifecycleOperationIdentityInvalid,
                message: "The resume request has no valid durable operation identity."
            )
        }
        guard request.backend == descriptor.identity else {
            return failedOperation(
                .resume,
                code: .backendIdentityMismatch,
                message: "The runtime request belongs to a different backend adapter."
            )
        }
        guard descriptor.lifecycle.resume else {
            return unsupportedOperation(.resume)
        }
        return perform(.resume, request: request, operation: operations.resume)
    }

    private func unavailableProbe(
        code: MachineBackendFailureCode,
        message: String
    ) -> MachineBackendProbeResult {
        MachineBackendProbeResult(
            descriptor: descriptor,
            state: .unavailable,
            failure: MachineBackendFailure(
                code: code,
                backend: descriptor.identity,
                message: message
            )
        )
    }

    private func failedPlan(
        probe: MachineBackendProbeResult,
        code: MachineBackendFailureCode,
        message: String
    ) -> MachineBackendPlanResult {
        MachineBackendPlanResult(
            plan: nil,
            probe: probe,
            failure: MachineBackendFailure(
                code: code,
                backend: descriptor.identity,
                message: message
            )
        )
    }

    private func perform(
        _ operation: MachineBackendLifecycleOperation,
        request: MachineBackendRuntimeRequest,
        operation handler: MachineBackendLifecycleHandler
    ) -> MachineBackendOperationResult {
        do {
            return MachineBackendOperationResult(
                operation: operation,
                backend: descriptor.identity,
                observation: try handler(request),
                failure: nil
            )
        } catch {
            return failedOperation(
                operation,
                code: .lifecycleOperationFailed,
                message: String(describing: error)
            )
        }
    }

    private func performAuthorizedStart(
        _ binding: MachineBackendLaunchBinding
    ) -> MachineBackendOperationResult {
        do {
            return MachineBackendOperationResult(
                operation: .start,
                backend: descriptor.identity,
                observation: try operations.authorizedStart(binding),
                failure: nil
            )
        } catch {
            return failedOperation(
                .start,
                code: .lifecycleOperationFailed,
                message: String(describing: error)
            )
        }
    }

    private func unsupportedOperation(
        _ operation: MachineBackendLifecycleOperation
    ) -> MachineBackendOperationResult {
        failedOperation(
            operation,
            code: .lifecycleOperationUnsupported,
            message: "The current backend adapter does not implement \(operation.rawValue)."
        )
    }

    private func failedOperation(
        _ operation: MachineBackendLifecycleOperation,
        code: MachineBackendFailureCode,
        message: String
    ) -> MachineBackendOperationResult {
        MachineBackendOperationResult(
            operation: operation,
            backend: descriptor.identity,
            observation: nil,
            failure: MachineBackendFailure(
                code: code,
                backend: descriptor.identity,
                message: message
            )
        )
    }
}

/// Compatibility adapter for Dory's current direct-kernel/raw-Hypervisor Linux desktop path.
public final class RawHVLinuxMachineBackend: MachineBackend, @unchecked Sendable {
    public static let backendDescriptor = MachineBackendDescriptor(
        identity: .doryHypervisor,
        implementationIdentifier: "dory.raw-hv-linux.compatibility.v1",
        guestFamilies: [.linux],
        guestArchitectures: [.arm64],
        bootMediaKinds: [.linuxKernel, .installedLinuxBootBundle],
        lifecycle: .currentMachineManager
    )

    private let core: LinuxMachineBackendAdapterCore

    public var descriptor: MachineBackendDescriptor { core.descriptor }

    public init(
        executablePath: String?,
        operations: MachineBackendCompatibilityOperations,
        executableIsAvailable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        core = LinuxMachineBackendAdapterCore(
            descriptor: Self.backendDescriptor,
            componentIdentifier: "dory-hv",
            executablePath: executablePath,
            executableIsAvailable: executableIsAvailable,
            operations: operations,
            validateMachine: { machine, capability in
                guard machine.displayMode == .desktop else {
                    return "The current raw-HV machine path is implemented only for desktop Linux."
                }
                if let display = capability.request.devices.display, !display.isValid {
                    return "The raw-HV display geometry is outside the supported pixel bounds."
                }
                guard machine.installerISOPath == nil else {
                    return "The raw-HV machine path cannot boot attached installer media."
                }
                switch capability.request.bootMedia.kind {
                case .linuxKernel:
                    guard machine.bootMode == .linuxKernel,
                          !DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
                        return "A raw-HV Linux-kernel plan requires one raw direct-boot kernel."
                    }
                case .installedLinuxBootBundle:
                    guard machine.bootMode == .efi,
                          DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
                        return "A raw-HV installed-Linux plan requires a verified boot bundle."
                    }
                default:
                    return "The selected media is not implemented by the raw-HV adapter."
                }
                do {
                    guard try DoryDesktopVMMPreference(environment: machine.environment) != .compatible else {
                        return "The machine explicitly requests the Virtualization.framework compatibility path."
                    }
                } catch {
                    return "The machine contains an invalid desktop backend preference."
                }
                return nil
            }
        )
    }

    public func probe() -> MachineBackendProbeResult { core.probe() }
    public func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult { core.plan(request) }
    public func start(_ request: MachineBackendStartRequest) -> MachineBackendOperationResult {
        core.start(request)
    }
    public func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.stop(request) }
    public func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.pause(request) }
    public func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.resume(request) }
}

/// Compatibility adapter for the current Virtualization.framework EFI Linux helper path.
public final class VirtualizationFrameworkLinuxMachineBackend: MachineBackend, @unchecked Sendable {
    public static let backendDescriptor = MachineBackendDescriptor(
        identity: .appleVirtualizationFramework,
        implementationIdentifier: "dory.vz-linux.compatibility.v1",
        guestFamilies: [.linux],
        guestArchitectures: [.arm64],
        bootMediaKinds: [.linuxKernel, .installedLinuxBootBundle, .installerISO, .virtualDisk],
        lifecycle: .currentMachineManager
    )

    private let core: LinuxMachineBackendAdapterCore

    public var descriptor: MachineBackendDescriptor { core.descriptor }

    public init(
        executablePath: String?,
        operations: MachineBackendCompatibilityOperations,
        executableIsAvailable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        core = LinuxMachineBackendAdapterCore(
            descriptor: Self.backendDescriptor,
            componentIdentifier: "dory-vmm",
            executablePath: executablePath,
            executableIsAvailable: executableIsAvailable,
            operations: operations,
            validateMachine: { machine, capability in
                if machine.displayMode == .headless,
                   capability.request.devices.display != nil {
                    return "A headless VZ machine cannot attach a resolved display."
                }
                if let display = capability.request.devices.display, !display.isValid {
                    return "The VZ display geometry is outside the supported pixel bounds."
                }
                switch capability.request.bootMedia.kind {
                case .linuxKernel:
                    guard machine.bootMode == .linuxKernel,
                          machine.installerISOPath == nil,
                          !DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
                        return "A direct Linux kernel plan requires one raw kernel without installer media."
                    }
                case .installedLinuxBootBundle:
                    guard machine.bootMode == .efi,
                          machine.installerISOPath == nil,
                          DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
                        return "An installed Linux VZ plan requires a verified boot bundle without installer media."
                    }
                case .installerISO:
                    guard machine.bootMode == .efi, machine.displayMode == .desktop,
                          machine.installerISOPath?.isEmpty == false else {
                        return "An installer capability requires attached installer media."
                    }
                case .virtualDisk:
                    guard machine.bootMode == .efi, machine.displayMode == .desktop,
                          machine.installerISOPath == nil else {
                        return "A virtual-disk capability cannot retain attached installer media."
                    }
                    if DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) {
                        do {
                            guard try DoryDesktopVMMPreference(environment: machine.environment) == .compatible else {
                                return "An installed-Linux boot bundle must explicitly select the compatibility path to use this adapter."
                            }
                        } catch {
                            return "The machine contains an invalid desktop backend preference."
                        }
                    }
                default:
                    return "The selected media is not implemented by the Virtualization.framework Linux adapter."
                }
                return nil
            }
        )
    }

    public func probe() -> MachineBackendProbeResult { core.probe() }
    public func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult { core.plan(request) }
    public func start(_ request: MachineBackendStartRequest) -> MachineBackendOperationResult {
        core.start(request)
    }
    public func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.stop(request) }
    public func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.pause(request) }
    public func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult { core.resume(request) }
}
