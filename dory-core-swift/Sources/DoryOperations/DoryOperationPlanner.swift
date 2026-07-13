import Foundation

public enum DoryOperationPlannerError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptySelection
    case duplicateInventoryObject(DoryOperationObjectKey)
    case invalidInventoryObject(DoryOperationObjectKey, field: String)
    case duplicateSelection(DoryOperationObjectKey)
    case unknownSelection(DoryOperationObjectKey)
    case duplicateDependency(object: DoryOperationObjectKey, dependency: DoryOperationObjectKey)
    case missingDependency(object: DoryOperationObjectKey, dependency: DoryOperationObjectKey)
    case dependencyCycle([DoryOperationObjectKey])
    case duplicateIntent(DoryOperationObjectKey)
    case missingIntent(DoryOperationObjectKey)
    case extraneousIntent(DoryOperationObjectKey)
    case invalidIntent(DoryOperationObjectKey, field: String)
    case duplicateTargetName(kind: DoryOperationObjectKind, name: String)
    case invalidContext
    case invalidPlan(String)

    public var description: String {
        switch self {
        case .emptySelection:
            return "operation selection is empty"
        case let .duplicateInventoryObject(key):
            return "source inventory contains duplicate object \(key)"
        case let .invalidInventoryObject(key, field):
            return "source inventory object \(key) has invalid \(field)"
        case let .duplicateSelection(key):
            return "operation selection contains duplicate object \(key)"
        case let .unknownSelection(key):
            return "operation selection references missing object \(key)"
        case let .duplicateDependency(object, dependency):
            return "object \(object) repeats dependency \(dependency)"
        case let .missingDependency(object, dependency):
            return "object \(object) references missing dependency \(dependency)"
        case let .dependencyCycle(keys):
            return "operation dependency cycle contains: \(keys.map(\.description).joined(separator: ", "))"
        case let .duplicateIntent(key):
            return "operation contains duplicate target intent for \(key)"
        case let .missingIntent(key):
            return "operation has no target intent for selected object \(key)"
        case let .extraneousIntent(key):
            return "operation has target intent outside its dependency closure for \(key)"
        case let .invalidIntent(key, field):
            return "operation target intent for \(key) has invalid \(field)"
        case let .duplicateTargetName(kind, name):
            return "operation maps multiple \(kind.rawValue) objects to target name \(name)"
        case .invalidContext:
            return "operation planning context contains an invalid digest"
        case let .invalidPlan(reason):
            return "invalid operation completeness plan: \(reason)"
        }
    }
}

public enum DoryOperationPlanner {
    public static func plan(
        inventory: [DoryOperationInventoryObject],
        intents: [DoryOperationObjectIntent],
        userSelection: [DoryOperationObjectKey],
        context: DoryOperationPlanningContext
    ) throws -> DoryOperationCompletenessPlan {
        guard context.isValid else { throw DoryOperationPlannerError.invalidContext }
        guard !userSelection.isEmpty else { throw DoryOperationPlannerError.emptySelection }

        let inventoryByKey = try validatedInventory(inventory)
        let canonicalSelection = try validatedSelection(userSelection, inventory: inventoryByKey)
        let closure = try dependencyClosure(selection: canonicalSelection, inventory: inventoryByKey)
        let intentsByKey = try validatedIntents(intents, closure: closure)
        let orderedKeys = try topologicalOrder(keys: closure, inventory: inventoryByKey)
        let plannedObjects = orderedKeys.map {
            DoryOperationPlannedObject(inventory: inventoryByKey[$0]!, intent: intentsByKey[$0]!)
        }

        let fullInventory = inventoryByKey.values.sorted { $0.key < $1.key }.map(canonicalInventoryObject)
        let unselectedInventory = inventoryByKey.values
            .filter { !closure.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(canonicalInventoryObject)
        let result = DoryOperationCompletenessPlan(
            sourceInventoryDigest: try digest(fullInventory),
            unselectedSourceInventoryDigest: try digest(unselectedInventory),
            context: context,
            userSelection: canonicalSelection,
            objects: plannedObjects
        )
        try validate(result)
        return result
    }

    static func validate(_ plan: DoryOperationCompletenessPlan) throws {
        guard plan.schemaVersion == DoryOperationCompletenessPlan.schemaVersion else {
            throw DoryOperationPlannerError.invalidPlan("unsupported schema version")
        }
        guard DoryOperationJournalStore.isDigest(plan.sourceInventoryDigest),
              DoryOperationJournalStore.isDigest(plan.unselectedSourceInventoryDigest),
              plan.context.isValid else {
            throw DoryOperationPlannerError.invalidPlan("invalid baseline digest")
        }
        guard !plan.userSelection.isEmpty, plan.userSelection == plan.userSelection.sorted(),
              Set(plan.userSelection).count == plan.userSelection.count else {
            throw DoryOperationPlannerError.invalidPlan("selection is empty or non-canonical")
        }

        let inventory = try validatedInventory(plan.objects.map {
            DoryOperationInventoryObject(
                key: $0.source,
                sourceFingerprint: $0.sourceFingerprint,
                specificationDigest: $0.specificationDigest,
                dependencies: $0.dependencies
            )
        })
        let closure = try dependencyClosure(selection: plan.userSelection, inventory: inventory)
        guard closure == Set(inventory.keys) else {
            throw DoryOperationPlannerError.invalidPlan("objects exist outside the dependency closure")
        }
        let order = try topologicalOrder(keys: closure, inventory: inventory)
        guard order == plan.objects.map(\.source) else {
            throw DoryOperationPlannerError.invalidPlan("objects are not in canonical dependency order")
        }
        _ = try validatedIntents(plan.objects.map {
            DoryOperationObjectIntent(
                source: $0.source,
                normalizedTargetName: $0.normalizedTargetName,
                collisionDecision: $0.collisionDecision,
                acceptedFinalState: $0.acceptedFinalState
            )
        }, closure: closure)
    }

    static func binding(for plan: DoryOperationCompletenessPlan) throws -> DoryOperationPlanBinding {
        try validate(plan)
        return DoryOperationPlanBinding(
            selectionDigest: try digest(plan.userSelection),
            dependencyClosureDigest: try digest(plan.objects.map(DependencyContract.init)),
            successCriteriaDigest: try digest(SuccessContract(plan: plan))
        )
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        DoryOperationJournalStore.digest(try DoryOperationJournalStore.encoded(value, pretty: false))
    }

    private static func validatedInventory(
        _ inventory: [DoryOperationInventoryObject]
    ) throws -> [DoryOperationObjectKey: DoryOperationInventoryObject] {
        var result: [DoryOperationObjectKey: DoryOperationInventoryObject] = [:]
        for object in inventory {
            guard DoryOperationJournalStore.isPrivateText(object.key.sourceID, maximumLength: 1_024) else {
                throw DoryOperationPlannerError.invalidInventoryObject(object.key, field: "source identity")
            }
            guard DoryOperationJournalStore.isDigest(object.sourceFingerprint) else {
                throw DoryOperationPlannerError.invalidInventoryObject(object.key, field: "source fingerprint")
            }
            guard DoryOperationJournalStore.isDigest(object.specificationDigest) else {
                throw DoryOperationPlannerError.invalidInventoryObject(object.key, field: "specification digest")
            }
            guard result.updateValue(object, forKey: object.key) == nil else {
                throw DoryOperationPlannerError.duplicateInventoryObject(object.key)
            }
            var dependencies = Set<DoryOperationObjectKey>()
            for dependency in object.dependencies where !dependencies.insert(dependency).inserted {
                throw DoryOperationPlannerError.duplicateDependency(object: object.key, dependency: dependency)
            }
        }
        return result
    }

    private static func validatedSelection(
        _ selection: [DoryOperationObjectKey],
        inventory: [DoryOperationObjectKey: DoryOperationInventoryObject]
    ) throws -> [DoryOperationObjectKey] {
        var seen = Set<DoryOperationObjectKey>()
        for key in selection {
            guard seen.insert(key).inserted else { throw DoryOperationPlannerError.duplicateSelection(key) }
            guard inventory[key] != nil else { throw DoryOperationPlannerError.unknownSelection(key) }
        }
        return selection.sorted()
    }

    private static func dependencyClosure(
        selection: [DoryOperationObjectKey],
        inventory: [DoryOperationObjectKey: DoryOperationInventoryObject]
    ) throws -> Set<DoryOperationObjectKey> {
        var closure = Set<DoryOperationObjectKey>()
        var pending = selection
        while let key = pending.popLast() {
            guard closure.insert(key).inserted else { continue }
            guard let object = inventory[key] else { throw DoryOperationPlannerError.unknownSelection(key) }
            for dependency in object.dependencies.sorted().reversed() {
                guard inventory[dependency] != nil else {
                    throw DoryOperationPlannerError.missingDependency(object: key, dependency: dependency)
                }
                pending.append(dependency)
            }
        }
        return closure
    }

    private static func validatedIntents(
        _ intents: [DoryOperationObjectIntent],
        closure: Set<DoryOperationObjectKey>
    ) throws -> [DoryOperationObjectKey: DoryOperationObjectIntent] {
        var result: [DoryOperationObjectKey: DoryOperationObjectIntent] = [:]
        var targetNames = Set<TargetName>()
        for intent in intents {
            guard result.updateValue(intent, forKey: intent.source) == nil else {
                throw DoryOperationPlannerError.duplicateIntent(intent.source)
            }
            guard closure.contains(intent.source) else {
                throw DoryOperationPlannerError.extraneousIntent(intent.source)
            }
            guard DoryOperationJournalStore.isPrivateText(intent.normalizedTargetName, maximumLength: 1_024) else {
                throw DoryOperationPlannerError.invalidIntent(intent.source, field: "target name")
            }
            guard intent.acceptedFinalState.isAllowed(for: intent.source.kind) else {
                throw DoryOperationPlannerError.invalidIntent(intent.source, field: "accepted final state")
            }
            guard intent.collisionDecision.isAllowed(for: intent.source.kind) else {
                throw DoryOperationPlannerError.invalidIntent(intent.source, field: "collision decision")
            }
            let target = TargetName(kind: intent.source.kind, name: intent.normalizedTargetName)
            guard targetNames.insert(target).inserted else {
                throw DoryOperationPlannerError.duplicateTargetName(kind: target.kind, name: target.name)
            }
        }
        for key in closure where result[key] == nil {
            throw DoryOperationPlannerError.missingIntent(key)
        }
        return result
    }

    private static func topologicalOrder(
        keys: Set<DoryOperationObjectKey>,
        inventory: [DoryOperationObjectKey: DoryOperationInventoryObject]
    ) throws -> [DoryOperationObjectKey] {
        var remaining = keys
        var emitted = Set<DoryOperationObjectKey>()
        var result: [DoryOperationObjectKey] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { key in
                inventory[key]!.dependencies.allSatisfy(emitted.contains)
            }.sorted()
            guard !ready.isEmpty else { throw DoryOperationPlannerError.dependencyCycle(remaining.sorted()) }
            for key in ready {
                remaining.remove(key)
                emitted.insert(key)
                result.append(key)
            }
        }
        return result
    }

    private static func canonicalInventoryObject(
        _ object: DoryOperationInventoryObject
    ) -> CanonicalInventoryObject {
        CanonicalInventoryObject(
            key: object.key,
            sourceFingerprint: object.sourceFingerprint,
            specificationDigest: object.specificationDigest,
            dependencies: object.dependencies.sorted()
        )
    }
}

private struct TargetName: Hashable {
    let kind: DoryOperationObjectKind
    let name: String
}

private struct CanonicalInventoryObject: Encodable {
    let key: DoryOperationObjectKey
    let sourceFingerprint: String
    let specificationDigest: String
    let dependencies: [DoryOperationObjectKey]
}

private struct DependencyContract: Encodable {
    let source: DoryOperationObjectKey
    let sourceFingerprint: String
    let specificationDigest: String
    let dependencies: [DoryOperationObjectKey]

    init(_ object: DoryOperationPlannedObject) {
        source = object.source
        sourceFingerprint = object.sourceFingerprint
        specificationDigest = object.specificationDigest
        dependencies = object.dependencies
    }
}

private struct SuccessContract: Encodable {
    let sourceInventoryDigest: String
    let unselectedSourceInventoryDigest: String
    let context: DoryOperationPlanningContext
    let targets: [TargetContract]

    init(plan: DoryOperationCompletenessPlan) {
        sourceInventoryDigest = plan.sourceInventoryDigest
        unselectedSourceInventoryDigest = plan.unselectedSourceInventoryDigest
        context = plan.context
        targets = plan.objects.map(TargetContract.init)
    }
}

private struct TargetContract: Encodable {
    let source: DoryOperationObjectKey
    let normalizedTargetName: String
    let collisionDecision: DoryOperationTargetCollisionDecision
    let acceptedFinalState: DoryOperationAcceptedFinalState

    init(_ object: DoryOperationPlannedObject) {
        source = object.source
        normalizedTargetName = object.normalizedTargetName
        collisionDecision = object.collisionDecision
        acceptedFinalState = object.acceptedFinalState
    }
}
