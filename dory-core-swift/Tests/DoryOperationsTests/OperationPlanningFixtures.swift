@testable import DoryOperations
import Foundation

enum OperationPlanningFixtures {
    static let image = key(.image, "sha256:image")
    static let volume = key(.volume, "project_data")
    static let network = key(.network, "project_backend")
    static let writableLayer = key(.writableLayer, "container-api-layer")
    static let database = key(.container, "container-db")
    static let api = key(.container, "container-api")
    static let unselectedImage = key(.image, "sha256:unselected")

    static func key(_ kind: DoryOperationObjectKind, _ id: String) -> DoryOperationObjectKey {
        DoryOperationObjectKey(kind: kind, sourceID: id)
    }

    static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    static func inventory(unselectedDigest: String = digest("7")) -> [DoryOperationInventoryObject] {
        [
            object(image, "1", "2"),
            object(volume, "2", "3"),
            object(network, "3", "4"),
            object(writableLayer, "4", "5", dependencies: [image]),
            object(database, "5", "6", dependencies: [network, volume, image]),
            object(api, "6", "7", dependencies: [database, writableLayer, image, network]),
            DoryOperationInventoryObject(
                key: unselectedImage,
                sourceFingerprint: digest("7"),
                specificationDigest: unselectedDigest
            )
        ]
    }

    static func intents() -> [DoryOperationObjectIntent] {
        [
            intent(image, "sha256:image", .present),
            intent(volume, "project_data", .present),
            intent(network, "project_backend", .present),
            intent(writableLayer, "container-api-layer", .applied),
            intent(database, "project-db", .exited),
            intent(api, "project-api", .running)
        ]
    }

    static var context: DoryOperationPlanningContext {
        DoryOperationPlanningContext(
            targetInventoryDigest: digest("a"),
            unownedTargetInventoryDigest: digest("b"),
            capabilitiesDigest: digest("c"),
            capacityDigest: digest("d"),
            quiescenceDigest: digest("e")
        )
    }

    static func plan() throws -> DoryOperationCompletenessPlan {
        try DoryOperationPlanner.plan(
            inventory: inventory(),
            intents: intents(),
            userSelection: [api],
            context: context
        )
    }

    static func evidence(
        for plan: DoryOperationCompletenessPlan
    ) -> [DoryOperationObjectEvidence] {
        plan.objects.enumerated().map { index, object in
            let target = DoryOperationTargetIdentity(
                id: "target-\(object.source.sourceID)",
                fingerprint: digest(Character(String((index + 1) % 10)))
            )
            return DoryOperationObjectEvidence(
                source: object.source,
                verifiedTarget: target,
                postPublicationTarget: target,
                verificationManifestDigest: digest("f"),
                finalState: object.acceptedFinalState
            )
        }
    }

    private static func object(
        _ key: DoryOperationObjectKey,
        _ fingerprint: Character,
        _ specification: Character,
        dependencies: [DoryOperationObjectKey] = []
    ) -> DoryOperationInventoryObject {
        DoryOperationInventoryObject(
            key: key,
            sourceFingerprint: digest(fingerprint),
            specificationDigest: digest(specification),
            dependencies: dependencies
        )
    }

    private static func intent(
        _ source: DoryOperationObjectKey,
        _ target: String,
        _ state: DoryOperationAcceptedFinalState
    ) -> DoryOperationObjectIntent {
        DoryOperationObjectIntent(
            source: source,
            normalizedTargetName: target,
            acceptedFinalState: state
        )
    }
}
