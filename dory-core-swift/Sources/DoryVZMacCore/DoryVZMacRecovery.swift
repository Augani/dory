import Foundation

public enum DoryVZMacRecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case noInterruptedOperation(DoryVZMacMachineInstallationState)
    case explicitSavedStateDiscardRequired
    case missingSuspendedState

    public var description: String {
        switch self {
        case .noInterruptedOperation(let state):
            "VZMac machine state \(state.rawValue) has no interrupted operation to recover"
        case .explicitSavedStateDiscardRequired:
            "an interrupted VZMac restore requires explicit saved-state discard before cold boot"
        case .missingSuspendedState:
            "the VZMac manifest requires a suspended-state artifact that is missing"
        }
    }
}

public enum DoryVZMacRecovery {
    public static func recoverInterruptedOperation(
        in bundle: DoryVZMacMachineBundle,
        discardSavedStateAfterInterruptedRestore: Bool = false
    ) throws -> DoryVZMacMachineBundle {
        let lease = try DoryVZMacMachineLease(rootURL: bundle.rootURL)
        defer { withExtendedLifetime(lease) {} }

        switch bundle.manifest.installationState {
        case .installing:
            markInterruptedInstallFailed(in: bundle)
            return try bundle.updatingInstallationState(.installFailed)
        case .suspending:
            if FileManager.default.fileExists(atPath: bundle.suspendedStateURL.path) {
                _ = try DoryVZMacSavedStateArtifact.load(
                    from: bundle.suspendedStateURL,
                    for: bundle
                )
                return try bundle.updatingInstallationState(.suspended)
            }
            return try bundle.updatingInstallationState(.stopped)
        case .restoring:
            guard discardSavedStateAfterInterruptedRestore else {
                throw DoryVZMacRecoveryError.explicitSavedStateDiscardRequired
            }
            if FileManager.default.fileExists(atPath: bundle.suspendedStateURL.path) {
                try FileManager.default.removeItem(at: bundle.suspendedStateURL)
            }
            return try bundle.updatingInstallationState(.stopped)
        case .suspended:
            guard FileManager.default.fileExists(atPath: bundle.suspendedStateURL.path) else {
                throw DoryVZMacRecoveryError.missingSuspendedState
            }
            throw DoryVZMacRecoveryError.noInterruptedOperation(.suspended)
        case .prepared, .installFailed, .stopped:
            throw DoryVZMacRecoveryError.noInterruptedOperation(
                bundle.manifest.installationState
            )
        }
    }

    private static func markInterruptedInstallFailed(in bundle: DoryVZMacMachineBundle) {
        guard let current = try? DoryVZMacInstallJournal.load(from: bundle.installJournalURL)
        else { return }
        let failed = current.updating(
            phase: .failed,
            progress: current.progress,
            error: "VZMac installation process ended before completion"
        )
        try? failed.write(to: bundle.installJournalURL)
    }
}
