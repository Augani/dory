import Foundation

public enum DoryVZMacManagedRuntimeState: Sendable, Equatable {
    case running
    case paused
    case stopped
    case other
}

@MainActor
public struct DoryVZMacManagedSavedStateHooks {
    public var runtimeState: @MainActor () -> DoryVZMacManagedRuntimeState
    public var updateInstallationState: @MainActor (DoryVZMacMachineInstallationState) throws -> Void
    public var pause: @MainActor () async throws -> Void
    public var resume: @MainActor () async throws -> Void
    public var save: @MainActor (URL) async throws -> Void
    public var restore: @MainActor (URL) async throws -> Void
    public var secureSavedState: @MainActor (URL) throws -> Void
    public var removeSavedState: @MainActor (URL) throws -> Void
    public var isSavedStateConsumed: @MainActor (URL) throws -> Bool
    public var consumeSavedState: @MainActor (URL) throws -> Void

    public init(
        runtimeState: @escaping @MainActor () -> DoryVZMacManagedRuntimeState,
        updateInstallationState: @escaping @MainActor (DoryVZMacMachineInstallationState) throws -> Void,
        pause: @escaping @MainActor () async throws -> Void,
        resume: @escaping @MainActor () async throws -> Void,
        save: @escaping @MainActor (URL) async throws -> Void,
        restore: @escaping @MainActor (URL) async throws -> Void,
        secureSavedState: @escaping @MainActor (URL) throws -> Void,
        removeSavedState: @escaping @MainActor (URL) throws -> Void,
        isSavedStateConsumed: @escaping @MainActor (URL) throws -> Bool = {
            try DoryVZSavedStateConsumption.isConsumed(stateURL: $0)
        },
        consumeSavedState: @escaping @MainActor (URL) throws -> Void = {
            try DoryVZSavedStateConsumption.consume(stateURL: $0)
        }
    ) {
        self.runtimeState = runtimeState
        self.updateInstallationState = updateInstallationState
        self.pause = pause
        self.resume = resume
        self.save = save
        self.restore = restore
        self.secureSavedState = secureSavedState
        self.removeSavedState = removeSavedState
        self.isSavedStateConsumed = isSavedStateConsumed
        self.consumeSavedState = consumeSavedState
    }
}

@MainActor
enum DoryVZMacManagedSavedStateOperation {
    static func suspend(
        to stateURL: URL,
        hooks: DoryVZMacManagedSavedStateHooks
    ) async throws {
        try Task.checkCancellation()
        try hooks.updateInstallationState(.suspending)
        do {
            try await hooks.pause()
            try Task.checkCancellation()
            try await hooks.save(stateURL)
            try hooks.secureSavedState(stateURL)
            try Task.checkCancellation()
            try hooks.updateInstallationState(.suspended)
        } catch {
            let suspensionError = error
            do {
                // Even a failed save or metadata commit may leave complete RAM on disk.
                // Retire it durably before the live guest is allowed to advance its disks.
                try hooks.removeSavedState(stateURL)
            } catch {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "suspension failed (\(suspensionError)); saved RAM retirement failed (\(error)); cold recovery required"
                )
            }
            await recoverSuspendFailure(hooks: hooks)
            throw suspensionError
        }
    }

    static func restore(
        from stateURL: URL,
        hooks: DoryVZMacManagedSavedStateHooks
    ) async throws {
        try Task.checkCancellation()
        guard hooks.runtimeState() == .stopped else {
            throw DoryVZMacSavedStateError.invalidVirtualMachineState("restore requires a stopped VM")
        }
        guard try !hooks.isSavedStateConsumed(stateURL) else {
            throw DoryVZMacSavedStateError.alreadyConsumed
        }
        try hooks.secureSavedState(stateURL)
        var resumeInvoked = false
        do {
            try hooks.updateInstallationState(.restoring)
            try Task.checkCancellation()
            try await hooks.restore(stateURL)
            guard hooks.runtimeState() == .paused else {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "Apple restore did not leave the VM paused"
                )
            }
            try Task.checkCancellation()
            try hooks.consumeSavedState(stateURL)
            // Both the deny-only marker and cold-boot manifest precede the first resume.
            // Once execution is attempted, a paused/stopped callback is not proof that the
            // guest never advanced its disks; do not turn this RAM image back into a snapshot.
            try hooks.updateInstallationState(.stopped)
            try Task.checkCancellation()
            resumeInvoked = true
            try await hooks.resume()
            guard hooks.runtimeState() == .running else {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "Apple resume did not leave the VM running"
                )
            }
        } catch {
            if hooks.runtimeState() == .running {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "VZMac restore reached an already running guest; its saved state must not replay: \(error)"
                )
            }
            // Only a stopped VM, before any resume attempt and with a provably absent fence,
            // can roll back to resumable. A paused restored VM remains an interrupted restore.
            if !resumeInvoked, hooks.runtimeState() == .stopped,
               (try? hooks.isSavedStateConsumed(stateURL)) == false {
                try? hooks.updateInstallationState(.suspended)
            }
            throw error
        }
    }

    private static func recoverSuspendFailure(
        hooks: DoryVZMacManagedSavedStateHooks
    ) async {
        switch hooks.runtimeState() {
        case .paused:
            do {
                try await hooks.resume()
                try hooks.updateInstallationState(.stopped)
            } catch {
                return
            }
        case .running, .stopped:
            try? hooks.updateInstallationState(.stopped)
        case .other:
            break
        }
    }
}
