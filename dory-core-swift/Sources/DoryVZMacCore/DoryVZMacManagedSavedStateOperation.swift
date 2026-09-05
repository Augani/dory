import Foundation

public enum DoryVZMacManagedRuntimeState: Sendable, Equatable {
    case running
    case paused
    case stopped
    case other
}

public struct DoryVZMacManagedSavedStateHooks {
    public var runtimeState: () -> DoryVZMacManagedRuntimeState
    public var updateInstallationState: (DoryVZMacMachineInstallationState) throws -> Void
    public var pause: () async throws -> Void
    public var resume: () async throws -> Void
    public var save: (URL) async throws -> Void
    public var restore: (URL) async throws -> Void
    public var secureSavedState: (URL) throws -> Void
    public var removeSavedState: (URL) -> Void

    public init(
        runtimeState: @escaping () -> DoryVZMacManagedRuntimeState,
        updateInstallationState: @escaping (DoryVZMacMachineInstallationState) throws -> Void,
        pause: @escaping () async throws -> Void,
        resume: @escaping () async throws -> Void,
        save: @escaping (URL) async throws -> Void,
        restore: @escaping (URL) async throws -> Void,
        secureSavedState: @escaping (URL) throws -> Void,
        removeSavedState: @escaping (URL) -> Void
    ) {
        self.runtimeState = runtimeState
        self.updateInstallationState = updateInstallationState
        self.pause = pause
        self.resume = resume
        self.save = save
        self.restore = restore
        self.secureSavedState = secureSavedState
        self.removeSavedState = removeSavedState
    }
}

@MainActor
enum DoryVZMacManagedSavedStateOperation {
    static func suspend(
        to stateURL: URL,
        hooks: DoryVZMacManagedSavedStateHooks
    ) async throws {
        try hooks.updateInstallationState(.suspending)
        do {
            try await hooks.pause()
            try await hooks.save(stateURL)
            try hooks.secureSavedState(stateURL)
            try hooks.updateInstallationState(.suspended)
        } catch {
            hooks.removeSavedState(stateURL)
            await recoverSuspendFailure(hooks: hooks)
            throw error
        }
    }

    static func restore(
        from stateURL: URL,
        hooks: DoryVZMacManagedSavedStateHooks
    ) async throws {
        try hooks.secureSavedState(stateURL)
        try hooks.updateInstallationState(.restoring)
        do {
            try await hooks.restore(stateURL)
            try await hooks.resume()
            do {
                try hooks.updateInstallationState(.stopped)
            } catch {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "VZMac restored and is already running, but the suspended manifest could not be cleared: \(error)"
                )
            }
        } catch {
            if hooks.runtimeState() == .running {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "VZMac restore reached a running guest before metadata commit failed: \(error)"
                )
            }
            try? hooks.updateInstallationState(.suspended)
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
