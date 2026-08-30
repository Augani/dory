import DoryOperations
import DoryVMContracts
import Foundation

/// Fail-closed errors for turning durable workspace intent into the DoryARMVirt-v1 device ABI.
/// A topology is published only when the current helper can materialize every requested function.
public enum DoryARMVirtV1TopologyPlanningError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case incompatibleGuest
    case incompatibleABI(UInt16)
    case unsupportedStorageTopology
    case readOnlySystemDisk
    case missingStableNetworkInterface
    case resolvedDeviceContractMismatch
    case topologyDeviceSetMismatch

    public var description: String {
        switch self {
        case .incompatibleGuest:
            "DoryARMVirt-v1 requires an ARM64 Linux guest"
        case .incompatibleABI(let version):
            "DoryARMVirt-v1 does not implement virtual-hardware ABI \(version)"
        case .unsupportedStorageTopology:
            "DoryARMVirt-v1 currently materializes exactly one system disk and no data disks"
        case .readOnlySystemDisk:
            "DoryARMVirt-v1 requires its system disk to be writable"
        case .missingStableNetworkInterface:
            "DoryARMVirt-v1 requires one valid, stable network-interface identity"
        case .resolvedDeviceContractMismatch:
            "the selected DoryARMVirt-v1 device contract differs from workspace intent"
        case .topologyDeviceSetMismatch:
            "the persisted DoryARMVirt-v1 topology does not describe the workspace device set"
        }
    }
}

/// The only production adapter from workspace desired state to the DoryARMVirt-v1 sparse-slot contract.
/// Reconciliation preserves surviving variable-function slots without allowing array order to
/// influence guest-visible addresses.
public enum DoryARMVirtV1TopologyPlanner {
    public static func resolve(
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest,
        previousTopology: DoryARMVirtV1Topology? = nil
    ) throws -> DoryARMVirtV1Topology {
        let requested = try requestedDevices(
            definition: definition,
            resolvedDevices: resolvedDevices
        )
        return try DoryARMVirtV1TopologyReconciler.reconcile(
            requestedDevices: requested,
            previousTopology: previousTopology
        )
    }

    /// Rebuilds the logical device set from current definition authority. Slots may retain holes,
    /// so validation compares identities and roles while the contract type validates every slot.
    public static func validate(
        _ topology: DoryARMVirtV1Topology,
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest
    ) throws {
        let expected = try requestedDevices(
            definition: definition,
            resolvedDevices: resolvedDevices
        )
        let actual = topology.occupiedSlots.map {
            DoryARMVirtV1DeviceRequest(logicalID: $0.logicalID, role: $0.role)
        }
        guard Set(actual) == Set(expected) else {
            throw DoryARMVirtV1TopologyPlanningError.topologyDeviceSetMismatch
        }
    }

    public static func requestedDevices(
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest
    ) throws -> [DoryARMVirtV1DeviceRequest] {
        guard definition.guest.family == .linux,
              definition.guest.architecture == .arm64 else {
            throw DoryARMVirtV1TopologyPlanningError.incompatibleGuest
        }
        guard definition.virtualHardwareABIVersion == 1 else {
            throw DoryARMVirtV1TopologyPlanningError.incompatibleABI(
                definition.virtualHardwareABIVersion
            )
        }
        guard definition.storage.count == 1,
              let systemDisk = definition.storage.first,
              systemDisk.role == .system else {
            throw DoryARMVirtV1TopologyPlanningError.unsupportedStorageTopology
        }
        guard !systemDisk.readOnly else {
            throw DoryARMVirtV1TopologyPlanningError.readOnlySystemDisk
        }
        guard let networkInterface = resolvedDevices.networkInterface,
              networkInterface.isValid else {
            throw DoryARMVirtV1TopologyPlanningError.missingStableNetworkInterface
        }
        guard resolvedDevices == expectedDeviceContract(for: definition) else {
            throw DoryARMVirtV1TopologyPlanningError.resolvedDeviceContractMismatch
        }

        var requests = [
            DoryARMVirtV1DeviceRequest(
                logicalID: try DoryVirtualDeviceID.derived(
                    namespace: .systemDisk,
                    stableID: systemDisk.id
                ),
                role: .systemDisk
            ),
            try fixedRequest(.entropy),
            try fixedRequest(.balloon),
            try fixedRequest(.vsock),
        ]
        if !resolvedDevices.displays.isEmpty {
            requests.append(try fixedRequest(.graphics))
        }
        if resolvedDevices.keyboard { requests.append(try fixedRequest(.keyboard)) }
        if resolvedDevices.pointer { requests.append(try fixedRequest(.pointer)) }
        if resolvedDevices.audioInput || resolvedDevices.audioOutput {
            requests.append(try fixedRequest(.audio))
        }

        // Disconnected is a link state, not removal of the NIC. Keeping the function present
        // preserves interface identity when connectivity policy changes.
        requests.append(DoryARMVirtV1DeviceRequest(
            logicalID: try DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: networkInterface.id
            ),
            role: .network
        ))
        for share in definition.shares {
            requests.append(DoryARMVirtV1DeviceRequest(
                logicalID: try DoryVirtualDeviceID.derived(
                    namespace: .directoryShare,
                    stableID: share.id
                ),
                role: .directoryShare
            ))
        }

        // removableUSBHotplug is implemented by the bounded USB/IP guest-tools channel over the
        // already-present vsock function. It must not reserve or advertise an xHCI controller.
        return requests
    }

    private static func fixedRequest(
        _ role: DoryVirtualDeviceRole
    ) throws -> DoryARMVirtV1DeviceRequest {
        try DoryARMVirtV1DeviceRequest(
            logicalID: "armvirt-\(role.rawValue)",
            role: role
        )
    }

    private static func expectedDeviceContract(
        for definition: DoryVirtualMachineDefinition
    ) -> DoryVirtualMachineDeviceCapabilityRequest {
        let networkAttachment: DoryVirtualMachineNetworkAttachmentMode
        switch definition.networkMode {
        case .disconnected: networkAttachment = .disconnected
        case .sharedNAT: networkAttachment = .sharedNAT
        case .bridged: networkAttachment = .bridged
        case .isolated: networkAttachment = .isolated
        }
        return DoryVirtualMachineDeviceCapabilityRequest(
            networkAttachment: networkAttachment,
            networkInterface: .stable(machineID: definition.identity.id),
            displays: definition.displays.map {
                DoryVirtualMachineDisplayCapabilityRequest(
                    id: $0.id,
                    widthPixels: $0.widthPixels,
                    heightPixels: $0.heightPixels,
                    backingScaleFactor: $0.backingScaleFactor,
                    guestUIScaleFactor: $0.guestUIScaleFactor
                )
            },
            audioInput: definition.audio.inputEnabled,
            audioOutput: definition.audio.outputEnabled,
            cameraInput: definition.camera.enabled,
            keyboard: definition.input.keyboardEnabled,
            pointer: definition.input.pointerEnabled,
            directorySharing: !definition.shares.isEmpty,
            clipboard: definition.clipboardPolicy.isEnabled,
            clipboardPolicy: definition.clipboardPolicy,
            clockSynchronization: definition.integrations.contains(.clockSynchronization),
            dynamicDisplay: definition.integrations.contains(.dynamicDisplay),
            gracefulShutdown: definition.integrations.contains(.gracefulShutdown),
            intelApplicationTranslation:
                definition.integrations.contains(.intelApplicationTranslation),
            removableUSBHotplug: definition.integrations.contains(.removableUSBHotplug)
        )
    }
}
