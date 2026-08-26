import DoryOperations
import DoryVMContracts
import Foundation

/// Fail-closed errors for turning durable workspace intent into the RawHV ARM64 device ABI.
/// A topology is published only when the current helper can materialize every requested function.
public enum DoryRawHVVirtualHardwareTopologyPlanningError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case incompatibleGuest
    case incompatibleABI(UInt16)
    case unsupportedStorageTopology
    case readOnlySystemDisk
    case headlessDisplayUnsupported
    case asymmetricAudioUnsupported
    case missingStableNetworkInterface
    case resolvedDeviceContractMismatch
    case topologyDeviceSetMismatch

    public var description: String {
        switch self {
        case .incompatibleGuest:
            "RawHV ABI v1 requires an ARM64 Linux guest"
        case .incompatibleABI(let version):
            "RawHV does not implement virtual-hardware ABI \(version)"
        case .unsupportedStorageTopology:
            "RawHV currently materializes exactly one system disk and no data disks"
        case .readOnlySystemDisk:
            "RawHV requires its system disk to be writable"
        case .headlessDisplayUnsupported:
            "RawHV currently requires at least one resolved display"
        case .asymmetricAudioUnsupported:
            "RawHV exposes audio input and output through one combined device"
        case .missingStableNetworkInterface:
            "RawHV requires one valid, stable network-interface identity"
        case .resolvedDeviceContractMismatch:
            "the selected RawHV device contract differs from workspace intent"
        case .topologyDeviceSetMismatch:
            "the persisted RawHV topology does not describe the workspace device set"
        }
    }
}

/// The only production adapter from workspace desired state to the RawHV sparse-slot contract.
/// Reconciliation preserves surviving variable-function slots without allowing array order to
/// influence guest-visible addresses.
public enum DoryRawHVVirtualHardwareTopologyPlanner {
    public static func resolve(
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest,
        previousTopology: DoryRawHVVirtualHardwareTopology? = nil
    ) throws -> DoryRawHVVirtualHardwareTopology {
        let requested = try requestedDevices(
            definition: definition,
            resolvedDevices: resolvedDevices
        )
        return try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: requested,
            previousTopology: previousTopology
        )
    }

    /// Rebuilds the logical device set from current definition authority. Slots may retain holes,
    /// so validation compares identities and roles while the contract type validates every slot.
    public static func validate(
        _ topology: DoryRawHVVirtualHardwareTopology,
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest
    ) throws {
        let expected = try requestedDevices(
            definition: definition,
            resolvedDevices: resolvedDevices
        )
        let actual = topology.occupiedSlots.map {
            DoryRawHVVirtualDeviceRequest(logicalID: $0.logicalID, role: $0.role)
        }
        guard Set(actual) == Set(expected) else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.topologyDeviceSetMismatch
        }
    }

    public static func requestedDevices(
        definition: DoryVirtualMachineDefinition,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest
    ) throws -> [DoryRawHVVirtualDeviceRequest] {
        guard definition.guest.family == .linux,
              definition.guest.architecture == .arm64 else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.incompatibleGuest
        }
        guard definition.virtualHardwareABIVersion == 1 else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.incompatibleABI(
                definition.virtualHardwareABIVersion
            )
        }
        guard definition.storage.count == 1,
              let systemDisk = definition.storage.first,
              systemDisk.role == .system else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.unsupportedStorageTopology
        }
        guard !systemDisk.readOnly else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.readOnlySystemDisk
        }
        guard !resolvedDevices.displays.isEmpty else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.headlessDisplayUnsupported
        }
        guard resolvedDevices.audioInput == resolvedDevices.audioOutput else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.asymmetricAudioUnsupported
        }
        guard let networkInterface = resolvedDevices.networkInterface,
              networkInterface.isValid else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.missingStableNetworkInterface
        }
        guard resolvedDevices == expectedDeviceContract(for: definition) else {
            throw DoryRawHVVirtualHardwareTopologyPlanningError.resolvedDeviceContractMismatch
        }

        var requests = [
            DoryRawHVVirtualDeviceRequest(
                logicalID: try DoryVirtualDeviceID.derived(
                    namespace: .systemDisk,
                    stableID: systemDisk.id
                ),
                role: .systemDisk
            ),
            try fixedRequest(.graphics),
            try fixedRequest(.entropy),
            try fixedRequest(.balloon),
            try fixedRequest(.vsock),
        ]
        if resolvedDevices.keyboard { requests.append(try fixedRequest(.keyboard)) }
        if resolvedDevices.pointer { requests.append(try fixedRequest(.pointer)) }
        if resolvedDevices.audioInput { requests.append(try fixedRequest(.audio)) }

        // Disconnected is a link state, not removal of the NIC. Keeping the function present
        // preserves interface identity when connectivity policy changes.
        requests.append(DoryRawHVVirtualDeviceRequest(
            logicalID: try DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: networkInterface.id
            ),
            role: .network
        ))
        for share in definition.shares {
            requests.append(DoryRawHVVirtualDeviceRequest(
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
    ) throws -> DoryRawHVVirtualDeviceRequest {
        try DoryRawHVVirtualDeviceRequest(
            logicalID: "rawhv-\(role.rawValue)",
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
