import Foundation

public enum DoryVZMacRecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case noInterruptedOperation(DoryVZMacMachineInstallationState)
    case explicitSavedStateDiscardRequired
    case missingSuspendedState
    case installationJournalConflict
    case bundleChanged

    public var description: String {
        switch self {
        case .noInterruptedOperation(let state):
            "VZMac machine state \(state.rawValue) has no interrupted operation to recover"
        case .explicitSavedStateDiscardRequired:
            "an interrupted VZMac restore requires explicit saved-state discard before cold boot"
        case .missingSuspendedState:
            "the VZMac manifest requires a suspended-state artifact that is missing"
        case .installationJournalConflict:
            "the interrupted installation has no matching recoverable journal; its artifacts were preserved"
        case .bundleChanged:
            "the VZMac bundle changed since recovery was requested; reopen its current state"
        }
    }
}

public enum DoryVZMacRecovery {
    enum Checkpoint { case installationJournalCommitted, savedStateRetired, manifestCommitted }
    struct IO {
        var metadata = DoryVZMacMetadataFile.WriteIO()
        var retirement = DoryVZMacSavedStateRetirement.IO()
        var loadBundle: (URL) throws -> DoryVZMacMachineBundle = { try DoryVZMacMachineBundle.load(from: $0) }
        var checkpoint: (Checkpoint) throws -> Void = { _ in }
    }

    /// The explicit discard option also permits cold recovery from incompatible suspended
    /// RAM and partial suspension. It never deletes disks, identity or auxiliary storage.
    public static func recoverInterruptedOperation(
        in bundle: DoryVZMacMachineBundle,
        discardSavedStateAfterInterruptedRestore: Bool = false
    ) throws -> DoryVZMacMachineBundle {
        try recoverInterruptedOperation(
            in: bundle, discardSavedStateAfterInterruptedRestore: discardSavedStateAfterInterruptedRestore,
            io: IO()
        )
    }

    static func recoverInterruptedOperation(
        in requested: DoryVZMacMachineBundle,
        discardSavedStateAfterInterruptedRestore discard: Bool = false,
        io: IO
    ) throws -> DoryVZMacMachineBundle {
        // Negative requests need no writes/lease file. Actual recovery repeats admission
        // against the current bundle after acquiring its exclusive machine lease.
        if requested.manifest.installationState == .restoring && !discard {
            throw DoryVZMacRecoveryError.explicitSavedStateDiscardRequired
        }
        if !discard, [.prepared, .stopped].contains(requested.manifest.installationState) {
            throw DoryVZMacRecoveryError.noInterruptedOperation(requested.manifest.installationState)
        }
        let lease = try DoryVZMacMachineLease(rootURL: requested.rootURL)
        return try recoverInterruptedOperation(in: requested, holding: lease,
            discardSavedStateAfterInterruptedRestore: discard, io: io)
    }

    // The native runtime already owns this lease. Taking a second flock would reject its
    // own recovery; accepting the actual owner keeps recovery and installation serialized.
    static func recoverInterruptedOperation(
        in requested: DoryVZMacMachineBundle,
        holding lease: DoryVZMacMachineLease,
        discardSavedStateAfterInterruptedRestore discard: Bool = false,
        io: IO = IO()
    ) throws -> DoryVZMacMachineBundle {
        defer { withExtendedLifetime(lease) {} }
        guard lease.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL else {
            throw DoryVZMacRecoveryError.bundleChanged
        }
        let bundle = try io.loadBundle(requested.rootURL)
        guard bundle.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              bundle.manifest.replacingInstallationState(requested.manifest.installationState) == requested.manifest else {
            throw DoryVZMacRecoveryError.bundleChanged
        }

        switch bundle.manifest.installationState {
        case .installing, .installFailed:
            let recoveredState = try recoverInstallationJournal(in: bundle, io: io)
            try io.checkpoint(.installationJournalCommitted)
            return try commit(recoveredState, in: bundle, io: io)
        case .suspending:
            if discard { return try recoverCold(in: bundle, io: io) }
            if try stateExists(in: bundle) {
                _ = try DoryVZMacSavedStateArtifact.load(
                    from: bundle.suspendedStateURL,
                    for: bundle
                )
                return try commit(.suspended, in: bundle, io: io)
            }
            return try recoverCold(in: bundle, io: io)
        case .restoring:
            guard discard else {
                throw DoryVZMacRecoveryError.explicitSavedStateDiscardRequired
            }
            return try recoverCold(in: bundle, io: io)
        case .suspended:
            if discard { return try recoverCold(in: bundle, io: io) }
            guard try stateExists(in: bundle) else {
                throw DoryVZMacRecoveryError.missingSuspendedState
            }
            try DoryVZSavedStateConsumption.requireUnconsumed(
                stateURL: bundle.suspendedStateURL.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName)
            )
            throw DoryVZMacRecoveryError.noInterruptedOperation(.suspended)
        case .stopped:
            if requested.manifest.installationState == .installing {
                // The prior attempt may have published the stopped manifest before a
                // directory flush failed. Recommit both records instead of reinstalling.
                guard try matchingInstallationJournal(in: bundle).phase == .completed else {
                    throw DoryVZMacRecoveryError.installationJournalConflict
                }
                _ = try recoverInstallationJournal(in: bundle, io: io)
                try io.checkpoint(.installationJournalCommitted)
                return try commit(.stopped, in: bundle, io: io)
            }
            if discard || requested.manifest.installationState == .suspending {
                return try recoverCold(in: bundle, io: io)
            }
            throw DoryVZMacRecoveryError.noInterruptedOperation(.stopped)
        case .prepared:
            throw DoryVZMacRecoveryError.noInterruptedOperation(
                bundle.manifest.installationState
            )
        }
    }

    private static func recoverCold(in bundle: DoryVZMacMachineBundle, io: IO) throws -> DoryVZMacMachineBundle {
        try DoryVZMacSavedStateRetirement.retire(
            at: bundle.suspendedStateURL, policy: .explicitColdRecovery,
            barrierFileURL: bundle.manifestURL, io: io.retirement
        )
        try io.checkpoint(.savedStateRetired)
        return try commit(.stopped, in: bundle, io: io)
    }

    private static func stateExists(in bundle: DoryVZMacMachineBundle) throws -> Bool {
        try DoryVZMacMetadataFile.entryExists(at: bundle.rootURL.appendingPathComponent(
            DoryVZMacMachineBundle.suspendedStateDirectoryName, isDirectory: false
        ))
    }

    private static func matchingInstallationJournal(in bundle: DoryVZMacMachineBundle) throws -> DoryVZMacInstallJournal {
        guard let bytes = try DoryVZMacMetadataFile.readIfPresent(from: bundle.installJournalURL),
              let current = try? JSONDecoder().decode(DoryVZMacInstallJournal.self, from: bytes) else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        try current.validate()
        guard current.machineIdentifierSHA256 == bundle.manifest.machineIdentifierSHA256,
              current.restoreImageSHA256 == bundle.manifest.restoreImageSHA256 else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        return current
    }

    private static func recoverInstallationJournal(
        in bundle: DoryVZMacMachineBundle, io: IO
    ) throws -> DoryVZMacMachineInstallationState {
        let current = try matchingInstallationJournal(in: bundle)
        if current.phase == .completed {
            guard [.installing, .stopped].contains(bundle.manifest.installationState) else {
                throw DoryVZMacRecoveryError.installationJournalConflict
            }
            // Apple success is recorded before exposing a bootable system disk. This exact
            // completed journal is roll-forward evidence, never permission to reinstall.
            try DoryVZMacMetadataFile.write(encode(current), to: bundle.installJournalURL, io: io.metadata)
            return .stopped
        }
        // Keep the original operation ID and, if already failed, its original diagnostic.
        // A missing/corrupt/foreign journal is not permission to invent a new operation.
        let failed = current.phase == .failed ? current : current.updating(
            phase: .failed,
            progress: current.progress,
            error: "VZMac installation process ended before completion"
        )
        try failed.validate()
        try DoryVZMacMetadataFile.write(encode(failed), to: bundle.installJournalURL, io: io.metadata)
        return .installFailed
    }

    /// A new attempt may replace a verified failed journal, never unknown or completed
    /// evidence. Interrupted validation must first be recovered by the lease owner.
    static func beginInstallation(
        _ journal: DoryVZMacInstallJournal,
        in requested: DoryVZMacMachineBundle,
        holding lease: DoryVZMacMachineLease,
        io: IO = IO()
    ) throws -> DoryVZMacMachineBundle {
        defer { withExtendedLifetime(lease) {} }
        try journal.validate()
        guard lease.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              journal.phase == .validatingRestore, journal.progress == 0 else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        let bundle = try io.loadBundle(requested.rootURL)
        guard bundle.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              bundle.manifest == requested.manifest else {
            throw DoryVZMacRecoveryError.bundleChanged
        }
        guard [.prepared, .installFailed].contains(bundle.manifest.installationState),
              journal.machineIdentifierSHA256 == bundle.manifest.machineIdentifierSHA256,
              journal.restoreImageSHA256 == bundle.manifest.restoreImageSHA256 else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        if try DoryVZMacMetadataFile.entryExists(at: bundle.installJournalURL) {
            let previous = try matchingInstallationJournal(in: bundle)
            guard previous.phase == .failed
                || (bundle.manifest.installationState == .prepared && previous.phase == .validatingRestore) else {
                throw DoryVZMacRecoveryError.installationJournalConflict
            }
        } else if bundle.manifest.installationState == .installFailed {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        try DoryVZMacMetadataFile.write(encode(journal), to: bundle.installJournalURL, io: io.metadata)
        return bundle
    }

    /// Publish the installer callback's outcome before changing boot admission. Errors
    /// remain recoverable under the same journal; a successful callback is never demoted.
    static func commitInstallationOutcome(
        _ outcome: DoryVZMacInstallJournal,
        in requested: DoryVZMacMachineBundle,
        holding lease: DoryVZMacMachineLease,
        io: IO = IO()
    ) throws -> DoryVZMacMachineBundle {
        defer { withExtendedLifetime(lease) {} }
        try outcome.validate()
        guard lease.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              outcome.phase == .completed || outcome.phase == .failed else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        let bundle = try io.loadBundle(requested.rootURL)
        guard bundle.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              bundle.manifest.replacingInstallationState(requested.manifest.installationState) == requested.manifest else {
            throw DoryVZMacRecoveryError.bundleChanged
        }
        let current = try matchingInstallationJournal(in: bundle)
        guard current.operationID == outcome.operationID, current.startedAt == outcome.startedAt,
              current.restoreImageSHA256 == outcome.restoreImageSHA256,
              current.machineIdentifierSHA256 == outcome.machineIdentifierSHA256 else {
            throw DoryVZMacRecoveryError.installationJournalConflict
        }
        let target: DoryVZMacMachineInstallationState
        if outcome.phase == .completed {
            guard [.installing, .stopped].contains(bundle.manifest.installationState),
                  current.phase == .installing || current == outcome else {
                throw DoryVZMacRecoveryError.installationJournalConflict
            }
            target = .stopped
        } else {
            guard [.prepared, .installing, .installFailed].contains(bundle.manifest.installationState),
                  current.phase == .validatingRestore || current.phase == .installing || current == outcome else {
                throw DoryVZMacRecoveryError.installationJournalConflict
            }
            target = .installFailed
        }
        try DoryVZMacMetadataFile.write(encode(outcome), to: bundle.installJournalURL, io: io.metadata)
        try io.checkpoint(.installationJournalCommitted)
        return try commit(target, in: bundle, io: io)
    }

    private static func commit(
        _ state: DoryVZMacMachineInstallationState, in bundle: DoryVZMacMachineBundle, io: IO
    ) throws -> DoryVZMacMachineBundle {
        guard try io.loadBundle(bundle.rootURL).manifest == bundle.manifest else {
            throw DoryVZMacRecoveryError.bundleChanged
        }
        let manifest = bundle.manifest.replacingInstallationState(state)
        try manifest.validate()
        try DoryVZMacMetadataFile.write(encode(manifest), to: bundle.manifestURL, io: io.metadata)
        try io.checkpoint(.manifestCommitted)
        return try io.loadBundle(bundle.rootURL)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
