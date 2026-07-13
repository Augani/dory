import Foundation

extension DoryOperationJournalStore {
    /// Atomically publishes the immutable semantic object plan with the journal. An import journal
    /// must never become visible without the exact dependency and success contract needed to
    /// resume it, and the semantic plan must bind to the three digests in `plan.json`.
    public func begin(
        _ plan: DoryOperationPlan,
        completenessPlan: DoryOperationCompletenessPlan,
        specifications: [DoryOperationSpecification],
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        let binding = try completenessPlan.journalBinding()
        guard binding.selectionDigest == plan.selectionDigest,
              binding.dependencyClosureDigest == plan.dependencyClosureDigest,
              binding.successCriteriaDigest == plan.successCriteriaDigest else {
            throw DoryOperationJournalError.invalidPlan(
                "semantic completeness plan does not match journal bindings"
            )
        }
        let expectedDigests = Set(completenessPlan.objects.map(\.specificationDigest))
        let providedDigests = Set(specifications.map(\.digest))
        guard specifications.allSatisfy(\.isValid),
              providedDigests.count == specifications.count,
              providedDigests == expectedDigests else {
            throw DoryOperationJournalError.invalidPlan(
                "semantic completeness plan specifications are missing, duplicated, or unbound"
            )
        }
        return try begin(
            plan,
            completenessPlanData: Self.encoded(completenessPlan, pretty: true),
            specifications: specifications,
            at: date,
            fileManager: fileManager
        )
    }
}
