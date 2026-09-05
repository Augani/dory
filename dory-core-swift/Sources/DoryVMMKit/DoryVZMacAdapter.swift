import DoryVZMacCore
import DoryOperations
import Foundation
@preconcurrency import Virtualization

public enum DoryVZMacAdapterState: String, Sendable, Equatable {
    case prepared
    case installing
    case installFailed = "install-failed"
    case stopped
    case starting
    case running
    case pausing
    case paused
    case suspending
    case suspended
    case restoring
    case stopping
    case failed

    public var runtimeState: DoryVirtualMachineState {
        switch self {
        case .prepared: .created
        case .installing: .installing
        case .installFailed, .failed: .failed
        case .stopped: .stopped
        case .starting: .starting
        case .running, .pausing: .running
        case .paused: .paused
        case .suspending, .stopping: .stopping
        case .suspended: .suspended
        case .restoring: .recovering
        }
    }
}

public struct DoryVZMacAdapterObservation: Sendable, Equatable {
    public let state: DoryVZMacAdapterState
    public let failure: String?

    public init(state: DoryVZMacAdapterState, failure: String? = nil) {
        self.state = state
        self.failure = failure
    }
}

public enum DoryVZMacAdapterError: Error, Sendable, Equatable, CustomStringConvertible {
    case transitionInProgress
    case invalidState(expected: [DoryVZMacAdapterState], actual: DoryVZMacAdapterState)

    public var description: String {
        switch self {
        case .transitionInProgress:
            "another VZMac lifecycle transition is already in progress"
        case .invalidState(let expected, let actual):
            "VZMac is \(actual.rawValue); expected \(expected.map(\.rawValue).joined(separator: " or "))"
        }
    }
}

/// Immutable host inputs for the production ARM64 macOS adapter.
///
/// Guest Tools is exposed read-only and USB disk images use virtual mass storage. Physical USB
/// authorization remains a separate macOS 27 capability and is never inferred from this value.
public struct DoryVZMacAdapterConfiguration: Sendable, Equatable {
    public let machineBundleURL: URL
    public let guestToolsURL: URL?
    public let usbDiskURL: URL?
    public let usbDiskReadOnly: Bool
    public let devicePolicy: DoryVZMacDevicePolicy

    public init(
        machineBundleURL: URL,
        guestToolsURL: URL? = nil,
        usbDiskURL: URL? = nil,
        usbDiskReadOnly: Bool = true,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault
    ) {
        self.machineBundleURL = machineBundleURL.standardizedFileURL
        self.guestToolsURL = guestToolsURL?.standardizedFileURL
        self.usbDiskURL = usbDiskURL?.standardizedFileURL
        self.usbDiskReadOnly = usbDiskReadOnly
        self.devicePolicy = devicePolicy
    }
}

/// Production Virtualization.framework adapter for native ARM64 macOS guests.
///
/// The adapter owns the exclusive machine lease, VZ runtime, one supported Mac display, camera
/// bridge, lifecycle serialization, and truthful state projection. It deliberately does not own an
/// NSWindow: Dory Desktop embeds `displayView` in its normal window/presentation boundary.
@MainActor
public final class DoryVZMacAdapter: NSObject, @MainActor VZVirtualMachineDelegate {
    public nonisolated static let maximumGuestDisplayCount = 1

    public let runtime: DoryVZMacRuntime
    public let displayView: VZVirtualMachineView
    public private(set) var observation: DoryVZMacAdapterObservation
    public var onObservation: (@MainActor @Sendable (DoryVZMacAdapterObservation) -> Void)?

    private var transitionInProgress = false

    public init(
        configuration: DoryVZMacAdapterConfiguration,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let bundle = try DoryVZMacMachineBundle.load(from: configuration.machineBundleURL)
        let shares = try configuration.guestToolsURL.map {
            [try DoryVZMacSharedDirectory(name: "Dory Guest Tools", url: $0, readOnly: true)]
        } ?? []
        let usbMassStorage = try configuration.usbDiskURL.map {
            try DoryVZMacUSBMassStorage(url: $0, readOnly: configuration.usbDiskReadOnly)
        }
        runtime = try DoryVZMacRuntime(
            bundle: bundle,
            sharedDirectories: shares,
            usbMassStorage: usbMassStorage,
            devicePolicy: configuration.devicePolicy,
            log: log
        )
        displayView = VZVirtualMachineView()
        displayView.virtualMachine = runtime.virtualMachine
        displayView.capturesSystemKeys = true
        displayView.automaticallyReconfiguresDisplay = true
        observation = DoryVZMacAdapterObservation(
            state: Self.initialState(for: bundle.manifest.installationState)
        )
        super.init()
        runtime.virtualMachine.delegate = self
    }

    public func install(
        from restoreImageURL: URL,
        operationID: UUID,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try beginTransition(expected: [.prepared, .installFailed], next: .installing)
        do {
            try await runtime.install(
                from: restoreImageURL,
                operationID: operationID,
                progress: progress
            )
            endTransition(.stopped)
        } catch {
            endTransition(.failed, failure: error)
            throw error
        }
    }

    public func start() async throws {
        try beginTransition(expected: [.stopped], next: .starting)
        do {
            try await runtime.start()
            endTransition(.running)
        } catch {
            endTransition(.failed, failure: error)
            throw error
        }
    }

    public func restoreSuspendedState(from managedStateURL: URL? = nil) async throws {
        try beginTransition(expected: [.suspended], next: .restoring)
        do {
            try await runtime.restoreSuspendedState(from: managedStateURL)
            endTransition(.running)
        } catch {
            endTransition(.suspended, failure: error)
            throw error
        }
    }

    public func pause() async throws {
        try beginTransition(expected: [.running], next: .pausing)
        do {
            try await runtime.pause()
            endTransition(.paused)
        } catch {
            endTransition(.running, failure: error)
            throw error
        }
    }

    public func resume() async throws {
        try beginTransition(expected: [.paused], next: .starting)
        do {
            try await runtime.resume()
            endTransition(.running)
        } catch {
            endTransition(.paused, failure: error)
            throw error
        }
    }

    public func suspend(to managedStateURL: URL? = nil) async throws {
        try beginTransition(expected: [.running], next: .suspending)
        do {
            try await runtime.suspend(to: managedStateURL)
            endTransition(.suspended)
        } catch {
            endTransition(.running, failure: error)
            throw error
        }
    }

    public func requestStop() throws {
        try beginTransition(expected: [.running], next: .stopping)
        do {
            try runtime.requestStop()
            transitionInProgress = false
        } catch {
            endTransition(.running, failure: error)
            throw error
        }
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        transitionInProgress = false
        publish(.stopped)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        transitionInProgress = false
        publish(.failed, failure: error)
    }

    private func beginTransition(
        expected: [DoryVZMacAdapterState],
        next: DoryVZMacAdapterState
    ) throws {
        guard !transitionInProgress else {
            throw DoryVZMacAdapterError.transitionInProgress
        }
        guard expected.contains(observation.state) else {
            throw DoryVZMacAdapterError.invalidState(
                expected: expected,
                actual: observation.state
            )
        }
        transitionInProgress = true
        publish(next)
    }

    private func endTransition(_ state: DoryVZMacAdapterState, failure: Error? = nil) {
        transitionInProgress = false
        publish(state, failure: failure)
    }

    private func publish(_ state: DoryVZMacAdapterState, failure: Error? = nil) {
        observation = DoryVZMacAdapterObservation(
            state: state,
            failure: failure.map { String(String(describing: $0).prefix(1_024)) }
        )
        onObservation?(observation)
    }

    nonisolated static func initialState(
        for state: DoryVZMacMachineInstallationState
    ) -> DoryVZMacAdapterState {
        switch state {
        case .prepared: .prepared
        case .installing: .installing
        case .stopped: .stopped
        case .suspending: .suspending
        case .suspended: .suspended
        case .restoring: .restoring
        case .installFailed: .installFailed
        }
    }
}
