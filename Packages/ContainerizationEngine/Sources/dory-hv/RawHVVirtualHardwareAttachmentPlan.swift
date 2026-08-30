import DoryOperations
import DoryVMContracts
import Foundation

enum RawHVVirtualHardwareAttachmentPlanError: Error, Equatable, Sendable {
    case duplicateMaterializedDevice(DoryVirtualDeviceID)
    case materializedDeviceSetMismatch
    case incompleteLaunchAuthority
    case resolvedDeviceContractMismatch
}

enum RawHVVirtualHardwareDiskAuthorityKind: Equatable, Sendable {
    case legacyPath
    case resolvedDescriptor
}

enum RawHVVirtualHardwareBootAuthorityKind: Equatable, Sendable {
    case legacyPaths
    case resolvedImmutableBytes
    case verifiedUEFIArtifacts
}

enum RawHVVirtualHardwareAttachmentMode: Equatable, Sendable {
    case legacy
    case resolved([RawHVVirtualHardwareAttachmentAssignment])
}

struct RawHVVirtualHardwareAttachmentAssignment: Equatable, Sendable {
    let request: DoryARMVirtV1DeviceRequest
    let mmioSlot: Int
}

/// Joins the daemon-authorized sparse topology to the exact device functions the helper actually
/// constructed. Neither construction order nor array order is permitted to choose an MMIO slot.
enum RawHVVirtualHardwareAttachmentPlan {
    /// Validates the entire launch-authority tuple and derives the helper's expected device set
    /// without consulting the durable topology. This preflight must run before constructing any
    /// backend, opening a share, or starting an external network process.
    static func launchMode(
        diskAuthority: RawHVVirtualHardwareDiskAuthorityKind,
        bootAuthority: RawHVVirtualHardwareBootAuthorityKind,
        topology: DoryARMVirtV1Topology?,
        resolvedGraphics: DoryGraphicsAccelerationLevel?,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?,
        resolvedPortForwards: [DoryVMPortForward]?,
        resolvedSystemDiskLogicalID: DoryVirtualDeviceID?,
        directoryShareStableIDs: [String],
        additionalBootDevices: [DoryARMVirtV1DeviceRequest] = []
    ) throws -> RawHVVirtualHardwareAttachmentMode {
        if diskAuthority == .legacyPath,
           bootAuthority == .legacyPaths,
           topology == nil,
           resolvedGraphics == nil,
           resolvedDevices == nil,
           resolvedPortForwards == nil,
           resolvedSystemDiskLogicalID == nil {
            return .legacy
        }

        guard diskAuthority == .resolvedDescriptor,
              (bootAuthority == .resolvedImmutableBytes
                || bootAuthority == .verifiedUEFIArtifacts),
              let topology,
              let resolvedGraphics,
              let resolvedDevices,
              resolvedPortForwards != nil,
              let resolvedSystemDiskLogicalID else {
            throw RawHVVirtualHardwareAttachmentPlanError.incompleteLaunchAuthority
        }
        guard (resolvedDevices.displays.isEmpty
                ? resolvedGraphics == .none : resolvedGraphics != .none),
              resolvedDevices.directorySharing == !directoryShareStableIDs.isEmpty,
              let networkInterface = resolvedDevices.networkInterface,
              networkInterface.isValid else {
            throw RawHVVirtualHardwareAttachmentPlanError.resolvedDeviceContractMismatch
        }

        let expectedDevices = try expectedResolvedDevices(
            systemDiskLogicalID: resolvedSystemDiskLogicalID,
            resolvedDevices: resolvedDevices,
            networkStableID: networkInterface.id,
            directoryShareStableIDs: directoryShareStableIDs,
            additionalBootDevices: additionalBootDevices
        )
        return .resolved(try assignments(
            topology: topology,
            materializedDevices: expectedDevices
        ))
    }

    /// Builds canonical device-function identities from launch inputs owned independently of the
    /// topology. Fixed singleton IDs intentionally match the daemon planner's ABI-v1 namespace.
    static func expectedResolvedDevices(
        systemDiskLogicalID: DoryVirtualDeviceID,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest,
        networkStableID: String,
        directoryShareStableIDs: [String],
        additionalBootDevices: [DoryARMVirtV1DeviceRequest] = []
    ) throws -> [DoryARMVirtV1DeviceRequest] {
        var requests = [
            DoryARMVirtV1DeviceRequest(
                logicalID: systemDiskLogicalID,
                role: .systemDisk
            ),
            try canonicalFixedRequest(.entropy),
            try canonicalFixedRequest(.balloon),
            try canonicalFixedRequest(.vsock),
        ]
        if !resolvedDevices.displays.isEmpty {
            requests.append(try canonicalFixedRequest(.graphics))
        }
        if resolvedDevices.keyboard {
            requests.append(try canonicalFixedRequest(.keyboard))
        }
        if resolvedDevices.pointer {
            requests.append(try canonicalFixedRequest(.pointer))
        }
        if resolvedDevices.audioInput || resolvedDevices.audioOutput {
            requests.append(try canonicalFixedRequest(.audio))
        }
        requests.append(DoryARMVirtV1DeviceRequest(
            logicalID: try DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: networkStableID
            ),
            role: .network
        ))
        for stableID in directoryShareStableIDs {
            requests.append(DoryARMVirtV1DeviceRequest(
                logicalID: try DoryVirtualDeviceID.derived(
                    namespace: .directoryShare,
                    stableID: stableID
                ),
                role: .directoryShare
            ))
        }
        requests.append(contentsOf: additionalBootDevices)
        return requests
    }

    static func canonicalFixedRequest(
        _ role: DoryVirtualDeviceRole
    ) throws -> DoryARMVirtV1DeviceRequest {
        switch role {
        case .graphics, .entropy, .balloon, .vsock, .keyboard, .pointer, .audio:
            return try DoryARMVirtV1DeviceRequest(
                logicalID: "armvirt-\(role.rawValue)",
                role: role
            )
        case .systemDisk, .network, .auxiliaryBlock, .removableStorage,
             .directoryShare, .usbController:
            throw RawHVVirtualHardwareAttachmentPlanError.resolvedDeviceContractMismatch
        }
    }

    static func assignments(
        topology: DoryARMVirtV1Topology,
        materializedDevices: [DoryARMVirtV1DeviceRequest]
    ) throws -> [RawHVVirtualHardwareAttachmentAssignment] {
        var materializedByID = [DoryVirtualDeviceID: DoryARMVirtV1DeviceRequest]()
        for request in materializedDevices {
            guard materializedByID.updateValue(request, forKey: request.logicalID) == nil else {
                throw RawHVVirtualHardwareAttachmentPlanError.duplicateMaterializedDevice(
                    request.logicalID
                )
            }
        }
        let authorized = topology.occupiedSlots.map {
            DoryARMVirtV1DeviceRequest(logicalID: $0.logicalID, role: $0.role)
        }
        guard Set(materializedDevices) == Set(authorized) else {
            throw RawHVVirtualHardwareAttachmentPlanError.materializedDeviceSetMismatch
        }
        return topology.occupiedSlots.map {
            RawHVVirtualHardwareAttachmentAssignment(
                request: DoryARMVirtV1DeviceRequest(
                    logicalID: $0.logicalID,
                    role: $0.role
                ),
                mmioSlot: $0.mmioSlot
            )
        }
    }
}
