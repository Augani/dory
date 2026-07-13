import Foundation

public enum DoryOperationObjectKind: String, Codable, CaseIterable, Sendable, Hashable {
    case image
    case volume
    case network
    case writableLayer
    case container
}

public enum DoryOperationAcceptedFinalState: String, Codable, CaseIterable, Sendable {
    case present
    case applied
    case created
    case exited
    case running
    case paused
    case createdStoppedAwaitingPort

    func isAllowed(for kind: DoryOperationObjectKind) -> Bool {
        switch kind {
        case .image, .volume, .network:
            return self == .present
        case .writableLayer:
            return self == .applied
        case .container:
            return self == .created || self == .exited || self == .running || self == .paused
                || self == .createdStoppedAwaitingPort
        }
    }
}

public enum DoryOperationTargetCollisionDecision: String, Codable, CaseIterable, Sendable {
    case create
    case reuseVerified
    case resumeOperationOwned

    func isAllowed(for kind: DoryOperationObjectKind) -> Bool {
        switch self {
        case .create, .resumeOperationOwned:
            return true
        case .reuseVerified:
            return kind == .image
        }
    }
}

public struct DoryOperationObjectKey: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let kind: DoryOperationObjectKind
    public let sourceID: String

    public init(kind: DoryOperationObjectKind, sourceID: String) {
        self.kind = kind
        self.sourceID = sourceID
    }

    public var description: String {
        "\(kind.rawValue):\(sourceID)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.sourceID < rhs.sourceID
    }
}

/// One strict source inventory entry. The fingerprint identifies the source object, while the
/// specification digest binds its complete inspected configuration or content manifest.
public struct DoryOperationInventoryObject: Codable, Sendable, Equatable {
    public let key: DoryOperationObjectKey
    public let sourceFingerprint: String
    public let specificationDigest: String
    public let dependencies: [DoryOperationObjectKey]

    public init(
        key: DoryOperationObjectKey,
        sourceFingerprint: String,
        specificationDigest: String,
        dependencies: [DoryOperationObjectKey] = []
    ) {
        self.key = key
        self.sourceFingerprint = sourceFingerprint
        self.specificationDigest = specificationDigest
        self.dependencies = dependencies
    }
}

/// Target naming and state accepted by the user for one object in the computed closure.
public struct DoryOperationObjectIntent: Codable, Sendable, Equatable {
    public let source: DoryOperationObjectKey
    public let normalizedTargetName: String
    public let collisionDecision: DoryOperationTargetCollisionDecision
    public let acceptedFinalState: DoryOperationAcceptedFinalState

    public init(
        source: DoryOperationObjectKey,
        normalizedTargetName: String,
        collisionDecision: DoryOperationTargetCollisionDecision = .create,
        acceptedFinalState: DoryOperationAcceptedFinalState
    ) {
        self.source = source
        self.normalizedTargetName = normalizedTargetName
        self.collisionDecision = collisionDecision
        self.acceptedFinalState = acceptedFinalState
    }
}

public struct DoryOperationPlanningContext: Codable, Sendable, Equatable {
    public let targetInventoryDigest: String
    public let unownedTargetInventoryDigest: String
    public let capabilitiesDigest: String
    public let capacityDigest: String
    public let quiescenceDigest: String

    public init(
        targetInventoryDigest: String,
        unownedTargetInventoryDigest: String,
        capabilitiesDigest: String,
        capacityDigest: String,
        quiescenceDigest: String
    ) {
        self.targetInventoryDigest = targetInventoryDigest
        self.unownedTargetInventoryDigest = unownedTargetInventoryDigest
        self.capabilitiesDigest = capabilitiesDigest
        self.capacityDigest = capacityDigest
        self.quiescenceDigest = quiescenceDigest
    }

    var isValid: Bool {
        [
            targetInventoryDigest,
            unownedTargetInventoryDigest,
            capabilitiesDigest,
            capacityDigest,
            quiescenceDigest
        ].allSatisfy(DoryOperationJournalStore.isDigest)
    }
}

public struct DoryOperationPlannedObject: Codable, Sendable, Equatable {
    public let source: DoryOperationObjectKey
    public let sourceFingerprint: String
    public let specificationDigest: String
    public let dependencies: [DoryOperationObjectKey]
    public let normalizedTargetName: String
    public let collisionDecision: DoryOperationTargetCollisionDecision
    public let acceptedFinalState: DoryOperationAcceptedFinalState

    init(inventory: DoryOperationInventoryObject, intent: DoryOperationObjectIntent) {
        source = inventory.key
        sourceFingerprint = inventory.sourceFingerprint
        specificationDigest = inventory.specificationDigest
        dependencies = inventory.dependencies.sorted()
        normalizedTargetName = intent.normalizedTargetName
        collisionDecision = intent.collisionDecision
        acceptedFinalState = intent.acceptedFinalState
    }
}

/// Canonical, immutable object closure and all baselines needed by the exact success equation.
public struct DoryOperationCompletenessPlan: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let sourceInventoryDigest: String
    public let unselectedSourceInventoryDigest: String
    public let context: DoryOperationPlanningContext
    public let userSelection: [DoryOperationObjectKey]
    public let objects: [DoryOperationPlannedObject]

    init(
        sourceInventoryDigest: String,
        unselectedSourceInventoryDigest: String,
        context: DoryOperationPlanningContext,
        userSelection: [DoryOperationObjectKey],
        objects: [DoryOperationPlannedObject]
    ) {
        schemaVersion = Self.schemaVersion
        self.sourceInventoryDigest = sourceInventoryDigest
        self.unselectedSourceInventoryDigest = unselectedSourceInventoryDigest
        self.context = context
        self.userSelection = userSelection
        self.objects = objects
    }

    public var selectedObjectKeys: [DoryOperationObjectKey] {
        objects.map(\.source).sorted()
    }

    public func canonicalDigest() throws -> String {
        try DoryOperationPlanner.validate(self)
        return try DoryOperationPlanner.digest(self)
    }

    public func journalBinding() throws -> DoryOperationPlanBinding {
        try DoryOperationPlanner.binding(for: self)
    }
}

public struct DoryOperationPlanBinding: Sendable, Equatable {
    public let selectionDigest: String
    public let dependencyClosureDigest: String
    public let successCriteriaDigest: String
}

public extension DoryOperationPlan {
    init(
        id: UUID = UUID(),
        kind: DoryOperationKind,
        createdAt: Date = Date(),
        source: DoryOperationAuthority,
        target: DoryOperationAuthority,
        completenessPlan: DoryOperationCompletenessPlan
    ) throws {
        let binding = try completenessPlan.journalBinding()
        self.init(
            id: id,
            kind: kind,
            createdAt: createdAt,
            source: source,
            target: target,
            selectionDigest: binding.selectionDigest,
            dependencyClosureDigest: binding.dependencyClosureDigest,
            successCriteriaDigest: binding.successCriteriaDigest
        )
    }
}
