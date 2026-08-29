import Foundation

public struct DoryRawHVVirtualDeviceRequest: Codable, Sendable, Hashable {
    public let logicalID: DoryVirtualDeviceID
    public let role: DoryVirtualDeviceRole

    public init(logicalID: DoryVirtualDeviceID, role: DoryVirtualDeviceRole) {
        self.logicalID = logicalID
        self.role = role
    }

    public init(logicalID: String, role: DoryVirtualDeviceRole) throws {
        self.init(logicalID: try DoryVirtualDeviceID(logicalID), role: role)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case logicalID
        case role
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownDoryVMContractFields(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            type: "DoryRawHVVirtualDeviceRequest"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            logicalID: try container.decode(DoryVirtualDeviceID.self, forKey: .logicalID),
            role: try container.decode(DoryVirtualDeviceRole.self, forKey: .role)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logicalID, forKey: .logicalID)
        try container.encode(role, forKey: .role)
    }
}

/// Reconciles requested logical devices with an optional prior topology. Existing logical IDs keep
/// their exact slots, absent devices disappear without compaction, and new devices receive the
/// lowest free slot in their role range using an order independent of request-array ordering.
public enum DoryRawHVVirtualHardwareTopologyReconciler {
    public static func reconcile(
        requestedDevices: [DoryRawHVVirtualDeviceRequest],
        previousTopology: DoryRawHVVirtualHardwareTopology? = nil
    ) throws -> DoryRawHVVirtualHardwareTopology {
        guard requestedDevices.count <= DoryRawHVARM64ABIV1SlotPolicy.maximumOccupiedSlots else {
            throw DoryVMContractError.tooManyDevices(
                actual: requestedDevices.count,
                maximum: DoryRawHVARM64ABIV1SlotPolicy.maximumOccupiedSlots
            )
        }

        var requestedByID = [DoryVirtualDeviceID: DoryRawHVVirtualDeviceRequest]()
        for request in requestedDevices {
            guard requestedByID.updateValue(request, forKey: request.logicalID) == nil else {
                throw DoryVMContractError.duplicateLogicalDeviceID(request.logicalID)
            }
        }

        let previousByID = Dictionary(
            uniqueKeysWithValues: (previousTopology?.occupiedSlots ?? []).map { ($0.logicalID, $0) }
        )
        for request in requestedDevices {
            guard let previous = previousByID[request.logicalID] else { continue }
            guard previous.role == request.role else {
                throw DoryVMContractError.roleMutation(
                    logicalID: request.logicalID,
                    previous: previous.role,
                    requested: request.role
                )
            }
        }
        try DoryRawHVARM64ABIV1SlotPolicy.validateRoleCounts(requestedDevices.map(\.role))

        var assignments = [DoryRawHVVirtualDeviceSlot]()
        var occupiedSlots = Set<Int>()
        for previous in previousTopology?.occupiedSlots ?? [] {
            guard requestedByID[previous.logicalID] != nil else { continue }
            assignments.append(previous)
            occupiedSlots.insert(previous.mmioSlot)
        }

        let newRequests = requestedDevices
            .filter { previousByID[$0.logicalID] == nil }
            .sorted(by: allocationOrder)
        for request in newRequests {
            let allowed = DoryRawHVARM64ABIV1SlotPolicy.allowedSlots(for: request.role)
            guard let slot = allowed.first(where: { !occupiedSlots.contains($0) }) else {
                throw DoryVMContractError.noAvailableSlot(request.role)
            }
            assignments.append(try DoryRawHVVirtualDeviceSlot(
                logicalID: request.logicalID,
                role: request.role,
                mmioSlot: slot
            ))
            occupiedSlots.insert(slot)
        }

        return try DoryRawHVVirtualHardwareTopology(occupiedSlots: assignments)
    }

    private static func allocationOrder(
        _ lhs: DoryRawHVVirtualDeviceRequest,
        _ rhs: DoryRawHVVirtualDeviceRequest
    ) -> Bool {
        let lhsRange = DoryRawHVARM64ABIV1SlotPolicy.allowedSlots(for: lhs.role)
        let rhsRange = DoryRawHVARM64ABIV1SlotPolicy.allowedSlots(for: rhs.role)
        if lhsRange.lowerBound != rhsRange.lowerBound {
            return lhsRange.lowerBound < rhsRange.lowerBound
        }
        if lhsRange.upperBound != rhsRange.upperBound {
            return lhsRange.upperBound < rhsRange.upperBound
        }
        if lhs.logicalID != rhs.logicalID { return lhs.logicalID < rhs.logicalID }
        return lhs.role.rawValue < rhs.role.rawValue
    }
}
