import Darwin
import Foundation

extension DoryOperationJournalStore {
    func begin(
        _ plan: DoryOperationPlan,
        completenessPlanData: Data?,
        specifications: [DoryOperationSpecification],
        at date: Date,
        fileManager: FileManager,
        mutationScope: String? = nil,
        heldMutationLock: EngineStateDirectoryLock? = nil
    ) throws -> DoryOperationLease {
        guard plan.isValid else {
            throw DoryOperationJournalError.invalidPlan(plan.id.uuidString.lowercased())
        }
        try prepareRoot(fileManager: fileManager)
        let lock: EngineStateDirectoryLock
        if let heldMutationLock {
            let expectedLockName = mutationScope.map { ".mutation.\($0).lock" }
                ?? ".mutation.lock"
            guard heldMutationLock.path == root + "/" + expectedLockName else {
                throw DoryOperationJournalError.invalidPlan(
                    "held mutation lock does not match authenticated scope"
                )
            }
            lock = heldMutationLock
        } else {
            lock = try acquireMutationLock(scope: mutationScope)
        }
        let destination = operationDirectory(for: plan.id)
        guard !Self.pathEntryExists(destination) else {
            throw DoryOperationJournalError.operationExists(plan.id)
        }
        try requireNoUnfinishedOperation(mutationScope: mutationScope)

        let partial = root + "/." + plan.id.uuidString.lowercased() + "."
            + UUID().uuidString.lowercased() + ".partial"
        do {
            try Self.createPrivateDirectory(partial)
            try Self.createOperationDirectories(in: partial)
            if completenessPlanData != nil || !specifications.isEmpty {
                try Self.createPrivateDirectory(partial + "/specs/objects")
            }

            let planData = try Self.encoded(plan, pretty: true)
            let initial = Self.initialState(plan: plan, planData: planData, date: date)
            try Self.publish(planData, to: partial + "/plan.json")
            if let completenessPlanData {
                try Self.publish(
                    completenessPlanData,
                    to: partial + "/specs/completeness-plan.json"
                )
            }
            for specification in specifications.sorted(by: { $0.digest < $1.digest }) {
                try Self.publish(
                    specification.data,
                    to: partial + "/specs/objects/" + specification.digest
                )
            }
            try Self.publish(try Self.encoded(initial.state, pretty: true), to: partial + "/state.json")
            try Self.publish(try Self.encoded(initial.event, pretty: false), to: partial + "/events.ndjson")
            try Self.syncDirectory(partial)
            guard Darwin.rename(partial, destination) == 0 else {
                throw DoryOperationJournalError.filesystem(
                    "publish Dory operation journal at \(destination): errno \(errno)"
                )
            }
            try Self.syncDirectory(root)
            return DoryOperationLease(store: self, operationID: plan.id, lock: lock)
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw error
        }
    }

    private func requireNoUnfinishedOperation(mutationScope: String?) throws {
        if let unfinished = try list().first(where: {
            guard $0.state.status != .completed && $0.state.status != .failed else {
                return false
            }
            guard let mutationScope else { return true }
            return $0.plan.source.id == mutationScope || $0.plan.target.id == mutationScope
        }) {
            throw DoryOperationJournalError.operationInUse(
                "Dory operation \(unfinished.plan.id.uuidString.lowercased()) requires recovery "
                    + "before another data operation can begin"
            )
        }
    }

    private static func createOperationDirectories(in root: String) throws {
        for component in [
            "specs",
            "manifests",
            "logs",
            "manifests/objects",
            "manifests/staged",
            "manifests/evidence"
        ] {
            try createPrivateDirectory(root + "/" + component)
        }
    }

    private static func initialState(
        plan: DoryOperationPlan,
        planData: Data,
        date: Date
    ) -> (event: DoryOperationEvent, state: DoryOperationState) {
        let event = DoryOperationEvent(
            operationID: plan.id,
            revision: 0,
            timestamp: date,
            phase: .planned,
            status: .running,
            result: nil,
            stepID: "operation.created",
            recoveryAction: nil
        )
        return (
            event,
            DoryOperationState(
                operationID: plan.id,
                planDigest: digest(planData),
                revision: 0,
                phase: .planned,
                status: .running,
                event: event
            )
        )
    }
}
