import Foundation

public struct DoryOperationTargetIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String

    public init(id: String, fingerprint: String) {
        self.id = id
        self.fingerprint = fingerprint
    }

    var isValid: Bool {
        DoryOperationJournalStore.isPrivateText(id, maximumLength: 1_024)
            && DoryOperationJournalStore.isDigest(fingerprint)
    }
}

public struct DoryOperationObjectEvidence: Codable, Sendable, Equatable {
    public let source: DoryOperationObjectKey
    public let verifiedTarget: DoryOperationTargetIdentity
    public let postPublicationTarget: DoryOperationTargetIdentity
    public let verificationManifestDigest: String
    public let finalState: DoryOperationAcceptedFinalState

    public init(
        source: DoryOperationObjectKey,
        verifiedTarget: DoryOperationTargetIdentity,
        postPublicationTarget: DoryOperationTargetIdentity,
        verificationManifestDigest: String,
        finalState: DoryOperationAcceptedFinalState
    ) {
        self.source = source
        self.verifiedTarget = verifiedTarget
        self.postPublicationTarget = postPublicationTarget
        self.verificationManifestDigest = verificationManifestDigest
        self.finalState = finalState
    }

    var isValid: Bool {
        verifiedTarget.isValid
            && postPublicationTarget.isValid
            && DoryOperationJournalStore.isDigest(verificationManifestDigest)
            && finalState.isAllowed(for: source.kind)
    }
}

/// Read-back evidence evaluated against an immutable completeness plan. This is a ledger of exact
/// identities rather than a count summary; partial evidence always produces an incomplete result.
public struct DoryOperationCompletionLedger: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let planDigest: String
    public let evidence: [DoryOperationObjectEvidence]
    public let unselectedSourceInventoryDigest: String
    public let unownedTargetInventoryDigest: String

    public init(
        planDigest: String,
        evidence: [DoryOperationObjectEvidence],
        unselectedSourceInventoryDigest: String,
        unownedTargetInventoryDigest: String
    ) {
        schemaVersion = Self.schemaVersion
        self.planDigest = planDigest
        self.evidence = evidence
        self.unselectedSourceInventoryDigest = unselectedSourceInventoryDigest
        self.unownedTargetInventoryDigest = unownedTargetInventoryDigest
    }

    public func evaluate(
        against plan: DoryOperationCompletenessPlan
    ) throws -> DoryOperationCompletenessEvaluation {
        try DoryOperationPlanner.validate(plan)
        guard schemaVersion == Self.schemaVersion else {
            return DoryOperationCompletenessEvaluation(issues: [.unsupportedLedgerSchema(schemaVersion)])
        }
        let expectedPlanDigest = try plan.canonicalDigest()
        let issues = baselineIssues(plan: plan, expectedPlanDigest: expectedPlanDigest)
            + objectIssues(plan: plan)
        return DoryOperationCompletenessEvaluation(issues: issues.sorted())
    }

    private func baselineIssues(
        plan: DoryOperationCompletenessPlan,
        expectedPlanDigest: String
    ) -> [DoryOperationCompletenessIssue] {
        var issues: [DoryOperationCompletenessIssue] = []
        if planDigest != expectedPlanDigest {
            issues.append(.planDigestMismatch(expected: expectedPlanDigest, actual: planDigest))
        }
        if !DoryOperationJournalStore.isDigest(unselectedSourceInventoryDigest) {
            issues.append(.invalidUnselectedSourceInventoryDigest)
        } else if unselectedSourceInventoryDigest != plan.unselectedSourceInventoryDigest {
            issues.append(.unselectedSourceInventoryChanged)
        }
        if !DoryOperationJournalStore.isDigest(unownedTargetInventoryDigest) {
            issues.append(.invalidUnownedTargetInventoryDigest)
        } else if unownedTargetInventoryDigest != plan.context.unownedTargetInventoryDigest {
            issues.append(.unownedTargetInventoryChanged)
        }
        return issues
    }

    private func objectIssues(
        plan: DoryOperationCompletenessPlan
    ) -> [DoryOperationCompletenessIssue] {
        var issues: [DoryOperationCompletenessIssue] = []
        let planned = Dictionary(uniqueKeysWithValues: plan.objects.map { ($0.source, $0) })
        var observed: [DoryOperationObjectKey: DoryOperationObjectEvidence] = [:]
        for item in evidence {
            guard let plannedObject = planned[item.source] else {
                issues.append(.unplannedEvidence(item.source))
                continue
            }
            guard observed[item.source] == nil else {
                issues.append(.duplicateEvidence(item.source))
                continue
            }
            observed[item.source] = item
            guard item.isValid else {
                issues.append(.invalidEvidence(item.source))
                continue
            }
            if item.verifiedTarget != item.postPublicationTarget {
                issues.append(.targetMappingChanged(item.source))
            }
            if item.finalState != plannedObject.acceptedFinalState {
                issues.append(.finalStateMismatch(
                    item.source,
                    expected: plannedObject.acceptedFinalState,
                    actual: item.finalState
                ))
            }
        }
        for key in plan.selectedObjectKeys where observed[key] == nil {
            issues.append(.missingEvidence(key))
        }
        return issues
    }
}

public enum DoryOperationCompletenessIssue: Sendable, Equatable, CustomStringConvertible {
    case unsupportedLedgerSchema(Int)
    case planDigestMismatch(expected: String, actual: String)
    case invalidUnselectedSourceInventoryDigest
    case invalidUnownedTargetInventoryDigest
    case unselectedSourceInventoryChanged
    case unownedTargetInventoryChanged
    case unplannedEvidence(DoryOperationObjectKey)
    case duplicateEvidence(DoryOperationObjectKey)
    case invalidEvidence(DoryOperationObjectKey)
    case targetMappingChanged(DoryOperationObjectKey)
    case finalStateMismatch(
        DoryOperationObjectKey,
        expected: DoryOperationAcceptedFinalState,
        actual: DoryOperationAcceptedFinalState
    )
    case missingEvidence(DoryOperationObjectKey)

    public var description: String {
        switch self {
        case let .unsupportedLedgerSchema(version):
            return "unsupported completion ledger schema \(version)"
        case .planDigestMismatch:
            return "completion evidence belongs to a different immutable plan"
        case .invalidUnselectedSourceInventoryDigest:
            return "completion evidence has an invalid unselected-source inventory digest"
        case .invalidUnownedTargetInventoryDigest:
            return "completion evidence has an invalid unowned-target inventory digest"
        case .unselectedSourceInventoryChanged:
            return "unselected source inventory changed"
        case .unownedTargetInventoryChanged:
            return "unowned target inventory changed"
        case let .unplannedEvidence(key):
            return "completion evidence contains unplanned object \(key)"
        case let .duplicateEvidence(key):
            return "completion evidence contains duplicate object \(key)"
        case let .invalidEvidence(key):
            return "completion evidence for \(key) is invalid"
        case let .targetMappingChanged(key):
            return "verified target mapping for \(key) changed after publication"
        case let .finalStateMismatch(key, expected, actual):
            return "final state for \(key) is \(actual.rawValue), expected \(expected.rawValue)"
        case let .missingEvidence(key):
            return "completion evidence is missing selected object \(key)"
        }
    }

    fileprivate var sortKey: String {
        description
    }
}

extension DoryOperationCompletenessIssue: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

public struct DoryOperationCompletenessEvaluation: Sendable, Equatable {
    public let issues: [DoryOperationCompletenessIssue]

    public var isComplete: Bool {
        issues.isEmpty
    }
}
