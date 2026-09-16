import DoryCore
import DoryVZMacCore
import DorydKit
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
    case missingHostOnlyNetworkInputs

    public var description: String {
        switch self {
        case .transitionInProgress:
            "another VZMac lifecycle transition is already in progress"
        case .invalidState(let expected, let actual):
            "VZMac is \(actual.rawValue); expected \(expected.map(\.rawValue).joined(separator: " or "))"
        case .missingHostOnlyNetworkInputs:
            "VZMac host-only networking requires a daemon-owned gvproxy and state directory"
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
    /// User-selected directory roots already admitted by the daemon for this launch.
    public let shares: [DoryMachineShareConfiguration]
    public let devicePolicy: DoryVZMacDevicePolicy
    /// The daemon resolves this executable; it is consumed only when the exact device policy
    /// asks for host-only networking.
    public let gvproxyPath: String?
    /// Per-machine daemon state root. The adapter creates and owns only its network leaf here.
    public let networkStateDirectoryURL: URL?
    /// Resolved daemon port mappings. They are meaningful only for the gvproxy-backed host-only
    /// attachment and are never inferred from a machine bundle.
    public let portForwards: [DoryVMPortForward]

    public init(
        machineBundleURL: URL,
        guestToolsURL: URL? = nil,
        usbDiskURL: URL? = nil,
        usbDiskReadOnly: Bool = true,
        shares: [DoryMachineShareConfiguration] = [],
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        gvproxyPath: String? = nil,
        networkStateDirectoryURL: URL? = nil,
        portForwards: [DoryVMPortForward] = []
    ) {
        self.machineBundleURL = machineBundleURL.standardizedFileURL
        self.guestToolsURL = guestToolsURL?.standardizedFileURL
        self.usbDiskURL = usbDiskURL?.standardizedFileURL
        self.usbDiskReadOnly = usbDiskReadOnly
        self.shares = shares.map { share in
            var normalized = share
            normalized.hostPath = URL(fileURLWithPath: share.hostPath).standardizedFileURL.path
            return normalized
        }
        self.devicePolicy = devicePolicy
        self.gvproxyPath = gvproxyPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.networkStateDirectoryURL = networkStateDirectoryURL?.standardizedFileURL
        self.portForwards = portForwards
    }
}

/// Production Virtualization.framework adapter for native ARM64 macOS guests.
///
/// The adapter owns the exclusive machine lease, VZ runtime, every persisted Mac display, camera
/// bridge, lifecycle serialization, and truthful state projection. It deliberately does not own
/// NSWindows: Dory Desktop embeds `displayViews` in its presentation boundary.
@MainActor
public final class DoryVZMacAdapter: NSObject, @MainActor VZVirtualMachineDelegate {
    public nonisolated static let maximumGuestDisplayCount = DoryVZMacResourcePlan.maximumDisplayCount

    public let runtime: DoryVZMacRuntime
    /// One view per persisted graphics display. Virtualization.framework binds each view to a
    /// distinct guest display when the same VM has several display configurations.
    public let displayViews: [VZVirtualMachineView]
    /// Compatibility alias for callers that intentionally present only the primary display.
    public let displayView: VZVirtualMachineView
    public private(set) var observation: DoryVZMacAdapterObservation
    public var onObservation: (@MainActor @Sendable (DoryVZMacAdapterObservation) -> Void)?

    private var transitionInProgress = false
    /// Retained for the whole VM lifetime so its file descriptor, child process, and cleanup
    /// cannot outlive the VZ network device that consumes them.
    private let gvproxyNetwork: DoryVMMGVProxyNetwork?

    public init(
        configuration: DoryVZMacAdapterConfiguration,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let bundle = try DoryVZMacMachineBundle.load(from: configuration.machineBundleURL)
        let gvproxyNetwork: DoryVMMGVProxyNetwork?
        if configuration.devicePolicy.network == .isolated {
            guard let gvproxyPath = configuration.gvproxyPath,
                  let stateDirectoryURL = configuration.networkStateDirectoryURL else {
                throw DoryVZMacAdapterError.missingHostOnlyNetworkInputs
            }
            guard !configuration.portForwards.contains(where: { $0.exposure == .lan }),
                  let resolvedPortForwards = PublishedPortForwardPlan.resolvedForwards(
                    configuration.portForwards,
                    guestIP: "192.168.127.2"
                  ) else {
                throw DoryVZMachineError.validation(
                    "VZMac host-only networking accepts only valid loopback port forwards"
                )
            }
            gvproxyNetwork = try DoryVMMGVProxyNetwork(
                gvproxyPath: gvproxyPath,
                stateDirectory: stateDirectoryURL
                    .appendingPathComponent("vzmac-network", isDirectory: true).path,
                networkAttachment: .isolated,
                networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest(
                    macAddress: bundle.manifest.macAddress
                ),
                resolvedPortForwards: resolvedPortForwards
            )
        } else {
            guard configuration.portForwards.isEmpty else {
                throw DoryVZMachineError.validation(
                    "VZMac port forwards require the gvproxy-backed host-only network"
                )
            }
            gvproxyNetwork = nil
        }
        self.gvproxyNetwork = gvproxyNetwork
        var sharedDirectories = try configuration.shares.map { share in
            try DoryVZMacSharedDirectory(
                name: share.tag,
                url: URL(fileURLWithPath: share.hostPath, isDirectory: true),
                readOnly: share.readOnly
            )
        }
        if let guestToolsURL = configuration.guestToolsURL {
            sharedDirectories.append(try DoryVZMacSharedDirectory(
                name: "Dory Guest Tools",
                url: guestToolsURL,
                readOnly: true
            ))
        }
        let usbMassStorage = try configuration.usbDiskURL.map {
            try DoryVZMacUSBMassStorage(url: $0, readOnly: configuration.usbDiskReadOnly)
        }
        runtime = try DoryVZMacRuntime(
            bundle: bundle,
            sharedDirectories: sharedDirectories,
            usbMassStorage: usbMassStorage,
            devicePolicy: configuration.devicePolicy,
            networkAttachment: gvproxyNetwork?.attachment,
            log: log
        )
        let virtualMachine = runtime.virtualMachine
        let displayCount = bundle.manifest.resources.displays.count
        let displayViews = (0..<displayCount).map { _ in
            let view = VZVirtualMachineView()
            view.virtualMachine = virtualMachine
            view.capturesSystemKeys = true
            view.automaticallyReconfiguresDisplay = true
            return view
        }
        guard let displayView = displayViews.first else {
            throw DoryVZMachineError.validation("VZMac requires at least one graphics display")
        }
        self.displayViews = displayViews
        self.displayView = displayView
        observation = DoryVZMacAdapterObservation(
            state: Self.initialState(for: bundle.manifest.installationState)
        )
        super.init()
        runtime.virtualMachine.delegate = self
    }

    func stopHostOnlyNetwork() {
        gvproxyNetwork?.stop()
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
            endTransition(Self.observedState(runtimeState: Self.managedState(for: runtime.virtualMachine.state)))
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
            endTransition(
                Self.stateAfterFailedRestore(runtimeState: Self.managedState(for: runtime.virtualMachine.state)),
                failure: error
            )
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
            endTransition(
                Self.observedState(runtimeState: Self.managedState(for: runtime.virtualMachine.state)),
                failure: error
            )
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

    nonisolated static func observedState(
        runtimeState: DoryVZMacManagedRuntimeState
    ) -> DoryVZMacAdapterState {
        switch runtimeState {
        case .running: .running
        case .paused: .paused
        case .stopped: .stopped
        case .other: .failed
        }
    }

    nonisolated static func stateAfterFailedRestore(
        runtimeState: DoryVZMacManagedRuntimeState
    ) -> DoryVZMacAdapterState {
        switch runtimeState {
        case .running: .running
        case .paused: .paused
        case .stopped: .suspended
        case .other: .failed
        }
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

    private nonisolated static func managedState(
        for state: VZVirtualMachine.State
    ) -> DoryVZMacManagedRuntimeState {
        switch state {
        case .running: .running
        case .paused: .paused
        case .stopped: .stopped
        default: .other
        }
    }
}
