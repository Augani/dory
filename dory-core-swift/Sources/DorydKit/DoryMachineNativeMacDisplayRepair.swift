import DoryVZMacCore
import Foundation

/// Diagnostic recovery choices only. They do not constitute a resolved launch contract.
public struct DoryMachineNativeMacDisplayRepairSummary: Sendable, Equatable {
    public let originalManifestSHA256: String
    public let displays: [DoryVZMacDisplay]
    public var pendingSelectedDisplayIndex: Int?
    public let preservesSavedState: Bool
    public let bundleRepairCompleted: Bool

    init(_ assessment: DoryVZMacDisplayRepairAssessment) {
        originalManifestSHA256 = assessment.originalManifestSHA256
        displays = assessment.displays
        pendingSelectedDisplayIndex = assessment.pendingSelectedDisplayIndex
        preservesSavedState = assessment.preservesSavedState
        bundleRepairCompleted = assessment.bundleRepairCompleted
    }
}

enum DoryMachineNativeMacColdBundleAdmission {
    struct IO {
        var load: (URL) throws -> DoryVZMacMachineBundle = { try DoryVZMacMachineBundle.load(from: $0) }
        var inspectRepair: (URL) throws -> DoryVZMacDisplayRepairAssessment? = {
            try DoryVZMacMachineBundle.assessPersistedDisplayTopologyRepair(at: $0, preserveManagedSavedState: true)
        }
    }

    /// Only a verified one-display candidate can keep an incompatible machine visible.
    /// The caller must publish failed/recovery status, never boot/resume admission.
    static func inspect(at root: URL, needsWorkspaceRepair: Bool, io: IO = IO()) throws
        -> (manifest: DoryVZMacMachineManifest, repair: DoryMachineNativeMacDisplayRepairSummary?) {
        let loaded: DoryVZMacMachineBundle
        do { loaded = try io.load(root) }
        catch {
            guard let assessment = try io.inspectRepair(root) else { throw error }
            return (assessment.candidateManifest, DoryMachineNativeMacDisplayRepairSummary(assessment))
        }
        guard needsWorkspaceRepair else { return (loaded.manifest, nil) }
        guard let assessment = try io.inspectRepair(root), assessment.pendingSelectedDisplayIndex != nil,
              assessment.candidateManifest == loaded.manifest else {
            throw DoryVZMacMachineBundleError.invalidBundle("workspace display topology differs from its Mac bundle")
        }
        return (loaded.manifest, DoryMachineNativeMacDisplayRepairSummary(assessment))
    }
}
