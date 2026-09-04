import DoryOperations
import Foundation

/// Planning is a checkpoint of a caller-owned start. The unchanged desired definition is the
/// request authority; this immutable checkpoint binds the exact replacement plan before spawn.
extension DoryOperationLease {
    func startPlanCheckpoint() throws -> DoryResolvedMachinePlan? {
        let operation = try readWorkspaceLifecycleOperation()
        guard operation.kind == .starting, operation.target.plannedRuntime != nil else {
            throw MachineManagerError.persistence("start checkpoint requires a planned-runtime start root")
        }
        let prefix = "start.plan."
        var previous: DoryResolvedMachinePlan?
        for event in try events() where event.stepID.hasPrefix(prefix) {
            let data = try readManifest(digest: String(event.stepID.dropFirst(prefix.count)))
            let plan = try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data)
            try validateStartPlanCheckpoint(plan, operation: operation, previous: previous)
            previous = plan
        }
        return previous
    }

    func publishStartPlanCheckpoint(_ plan: DoryResolvedMachinePlan) throws {
        let operation = try readWorkspaceLifecycleOperation()
        let previous = try startPlanCheckpoint()
        if previous == plan { return }
        try validateStartPlanCheckpoint(plan, operation: operation, previous: previous)
        let digest = try publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(plan))
        let state = try read().state
        _ = try transition(to: state.phase, status: state.status, expectedRevision: state.revision,
                           stepID: "start.plan." + digest)
    }

    private func validateStartPlanCheckpoint(_ plan: DoryResolvedMachinePlan,
        operation: DoryWorkspaceLifecycleOperation, previous: DoryResolvedMachinePlan?) throws {
        guard operation.validate().isEmpty, operation.kind == .starting,
              plan.validate().isEmpty, plan.machineID == operation.target.workspaceID,
              plan.definitionRevision == operation.target.definitionRevision,
              plan.definitionSHA256 == operation.target.configurationAuthority?.canonicalDefinitionSHA256,
              plan.virtualHardwareABIVersion == operation.target.plannedRuntime?.virtualHardwareABIVersion else {
            throw MachineManagerError.persistence("start plan differs from the caller's exact target definition")
        }
        if let previous {
            guard plan.planRevision > previous.planRevision,
                  plan.backend == previous.backend, plan.guest == previous.guest,
                  plan.platform == previous.platform else {
                throw MachineManagerError.persistence("start admission renewal changed runtime authority")
            }
        }
    }
}
