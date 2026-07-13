import Darwin
import Foundation

extension DoryOperationJournalStore {
    func begin(
        _ plan: DoryOperationPlan,
        completenessPlanData: Data?,
        specifications: [DoryOperationSpecification],
        at date: Date,
        fileManager: FileManager
    ) throws -> DoryOperationLease {
        guard plan.isValid else {
            throw DoryOperationJournalError.invalidPlan(plan.id.uuidString.lowercased())
        }
        try prepareRoot(fileManager: fileManager)
        let lock = try acquireMutationLock()
        let destination = operationDirectory(for: plan.id)
        guard !Self.pathEntryExists(destination) else {
            throw DoryOperationJournalError.operationExists(plan.id)
        }

        let partial = root + "/." + plan.id.uuidString.lowercased() + "."
            + UUID().uuidString.lowercased() + ".partial"
        do {
            try Self.createPrivateDirectory(partial)
            for component in ["specs", "manifests", "logs"] {
                try Self.createPrivateDirectory(partial + "/" + component)
            }
            if completenessPlanData != nil {
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
                for specification in specifications.sorted(by: { $0.digest < $1.digest }) {
                    try Self.publish(
                        specification.data,
                        to: partial + "/specs/objects/" + specification.digest
                    )
                }
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
