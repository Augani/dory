/// One state vocabulary for workspace operations, backend observations and clients. Absence,
/// definition and deletion describe workspace ownership before or after runtime existence.
public enum DoryVirtualMachineState: String, Codable, CaseIterable, Sendable, Hashable {
    case absent
    case defined
    case created
    case installing
    case starting
    case running
    case stopping
    case paused
    case suspended
    case recovering
    case stopped
    case failed
    case deleting
}

public typealias DoryWorkspaceLifecycleState = DoryVirtualMachineState

/// Observed guest/runtime readiness. Distinct from `DoryVirtualMachineState`, which is the
/// control-plane lifecycle. A running helper is not a booted guest or a connected desktop.
public struct DoryVirtualMachineReadiness: Codable, Sendable, Equatable, Hashable {
    public var processAlive: Bool
    public var vmStarted: Bool
    public var guestBooted: Bool
    public var toolsConnected: Bool
    public var desktopVisible: Bool
    public var workloadReady: Bool

    public init(
        processAlive: Bool = false,
        vmStarted: Bool = false,
        guestBooted: Bool = false,
        toolsConnected: Bool = false,
        desktopVisible: Bool = false,
        workloadReady: Bool = false
    ) {
        self.processAlive = processAlive
        self.vmStarted = vmStarted
        self.guestBooted = guestBooted
        self.toolsConnected = toolsConnected
        self.desktopVisible = desktopVisible
        self.workloadReady = workloadReady
    }

    public static let none = DoryVirtualMachineReadiness()
}

