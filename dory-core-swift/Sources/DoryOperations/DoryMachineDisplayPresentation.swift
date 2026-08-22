import Foundation

/// Host-only presentation preference for a guest display. This is deliberately excluded from
/// `DoryVirtualMachineDefinition` and `DoryResolvedMachinePlan`: attaching, removing, or moving a
/// Mac display must never change the guest hardware contract or invalidate a launch plan.
public enum DoryGuestDisplayPresentationMode: String, Codable, Sendable, Hashable {
    case windowed
    case dedicatedFullscreen = "dedicated-fullscreen"
}

public struct DoryGuestDisplayPresentationAssignment: Codable, Sendable, Hashable {
    public var guestDisplayID: String
    public var mode: DoryGuestDisplayPresentationMode
    /// Lowercase UUID produced by `CGDisplayCreateUUIDFromDisplayID`. A UUID is stable across
    /// display reordering and is therefore suitable for remembering the user's chosen monitor.
    public var hostDisplayUUID: String?

    public init(
        guestDisplayID: String,
        mode: DoryGuestDisplayPresentationMode,
        hostDisplayUUID: String? = nil
    ) {
        self.guestDisplayID = guestDisplayID
        self.mode = mode
        self.hostDisplayUUID = hostDisplayUUID
    }

    public var isValid: Bool {
        guard DoryVMDisplayConfiguration.isValidIdentifier(guestDisplayID) else { return false }
        switch mode {
        case .windowed:
            return hostDisplayUUID == nil
        case .dedicatedFullscreen:
            guard let hostDisplayUUID,
                  let uuid = UUID(uuidString: hostDisplayUUID) else { return false }
            return uuid.uuidString.lowercased() == hostDisplayUUID
        }
    }
}

public struct DoryMachineDisplayPresentation: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1
    public static let maximumAssignments = 16

    public var schemaVersion: Int
    public var assignments: [DoryGuestDisplayPresentationAssignment]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        assignments: [DoryGuestDisplayPresentationAssignment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.assignments = assignments
    }

    public static let windowed = DoryMachineDisplayPresentation()

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              assignments.count <= Self.maximumAssignments,
              assignments.allSatisfy(\.isValid) else { return false }
        let guestIDs = assignments.map(\.guestDisplayID)
        guard Set(guestIDs).count == guestIDs.count else { return false }
        let dedicatedHostIDs = assignments.compactMap { assignment -> String? in
            assignment.mode == .dedicatedFullscreen ? assignment.hostDisplayUUID : nil
        }
        return Set(dedicatedHostIDs).count == dedicatedHostIDs.count
    }

    public var canonicalized: DoryMachineDisplayPresentation {
        DoryMachineDisplayPresentation(
            schemaVersion: schemaVersion,
            assignments: assignments.sorted {
                if $0.guestDisplayID != $1.guestDisplayID {
                    return $0.guestDisplayID < $1.guestDisplayID
                }
                return $0.mode.rawValue < $1.mode.rawValue
            }
        )
    }

    public func assignment(
        forGuestDisplayID guestDisplayID: String
    ) -> DoryGuestDisplayPresentationAssignment? {
        assignments.first { $0.guestDisplayID == guestDisplayID }
    }
}
