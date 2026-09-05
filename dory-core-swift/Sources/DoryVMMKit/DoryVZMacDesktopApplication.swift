import AppKit
import Darwin
import DoryCore
import DorydKit
import DoryOperations
import DoryVZMacCore
import Foundation

public enum DoryVZMacDesktopOperation: String, Sendable, Equatable {
    case install
    case run
    case resume
}

@MainActor
final class DoryVZMacDesktopInstallLifecycle {
    private enum Phase {
        case idle
        case installingRestore
        case startingFirstBoot
    }

    private var phase: Phase = .idle

    func installThenStart(
        install: @MainActor () async throws -> Void,
        alreadyRunning: @MainActor () -> Bool = { false },
        start: @MainActor () async throws -> Void
    ) async throws {
        phase = .installingRestore
        do {
            try await install()
            if !alreadyRunning() {
                phase = .startingFirstBoot
                try await start()
            }
            phase = .idle
        } catch {
            phase = .idle
            throw error
        }
    }

    func shouldFinishStoppedObservation(
        operation: DoryVZMacDesktopOperation
    ) -> Bool {
        !(operation == .install && phase == .installingRestore)
    }
}

public struct DoryVZMacDesktopArguments: Sendable, Equatable {
    public var operation: DoryVZMacDesktopOperation
    public var machineBundleURL: URL
    public var restoreImageURL: URL?
    public var guestToolsURL: URL?
    public var usbDiskURL: URL?
    public var usbDiskReadOnly: Bool
    public var devicePolicy: DoryVZMacDevicePolicy
    public var restoreStateURL: URL?
    public var machineID: String?
    public var operationID: UUID?
    public var stateDirectoryURL: URL?
    public var controlSocketPath: String?
    public var handoffSocketPath: String?
    public var reconnectIdentity: DoryRuntimeReconnectLaunchIdentity?

    public init(
        operation: DoryVZMacDesktopOperation,
        machineBundleURL: URL,
        restoreImageURL: URL? = nil,
        guestToolsURL: URL? = nil,
        usbDiskURL: URL? = nil,
        usbDiskReadOnly: Bool = true,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        restoreStateURL: URL? = nil,
        machineID: String? = nil,
        operationID: UUID? = nil,
        stateDirectoryURL: URL? = nil,
        controlSocketPath: String? = nil,
        handoffSocketPath: String? = nil,
        reconnectIdentity: DoryRuntimeReconnectLaunchIdentity? = nil
    ) {
        self.operation = operation
        self.machineBundleURL = machineBundleURL.standardizedFileURL
        self.restoreImageURL = restoreImageURL?.standardizedFileURL
        self.guestToolsURL = guestToolsURL?.standardizedFileURL
        self.usbDiskURL = usbDiskURL?.standardizedFileURL
        self.usbDiskReadOnly = usbDiskReadOnly
        self.devicePolicy = devicePolicy
        self.restoreStateURL = restoreStateURL?.standardizedFileURL
        self.machineID = machineID
        self.operationID = operationID
        self.stateDirectoryURL = stateDirectoryURL?.standardizedFileURL
        self.controlSocketPath = controlSocketPath
        self.handoffSocketPath = handoffSocketPath
        self.reconnectIdentity = reconnectIdentity
    }

    public var hasManagedLifecycleContract: Bool {
        machineID != nil && operationID != nil && stateDirectoryURL != nil
            && controlSocketPath != nil && handoffSocketPath != nil
            && reconnectIdentity != nil
    }
}

public enum DoryVZMacDesktopArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingOperation
    case unsupportedOperation(String)
    case missingValue(String)
    case duplicateArgument(String)
    case unknownArgument(String)
    case missingMachineBundle
    case restoreImageRequired
    case restoreImageUnexpected
    case restoreStateRequired
    case restoreStateUnexpected
    case usbReadOnlyWithoutDisk
    case pathMustBeAbsolute(String)
    case incompleteManagedLifecycleContract
    case invalidMachineID
    case invalidOperationID
    case invalidNetworkPolicy(String)
    case invalidBoolean(String, String)

    public var description: String {
        switch self {
        case .missingOperation: "missing VZMac operation"
        case .unsupportedOperation(let value): "unsupported VZMac operation: \(value)"
        case .missingValue(let flag): "missing value for \(flag)"
        case .duplicateArgument(let flag): "duplicate VZMac argument: \(flag)"
        case .unknownArgument(let flag): "unknown VZMac argument: \(flag)"
        case .missingMachineBundle: "--machine is required"
        case .restoreImageRequired: "--ipsw is required for VZMac installation"
        case .restoreImageUnexpected: "--ipsw is accepted only for VZMac installation"
        case .restoreStateRequired: "--restore-state is required for managed VZMac resume"
        case .restoreStateUnexpected: "--restore-state is accepted only for VZMac resume"
        case .usbReadOnlyWithoutDisk: "--usb-disk-read-only requires --usb-disk"
        case .pathMustBeAbsolute(let flag): "\(flag) must name an absolute path"
        case .incompleteManagedLifecycleContract:
            "managed VZMac launch requires machine, operation, state, control, and handoff identity"
        case .invalidMachineID: "--machine-id is not a safe machine identifier"
        case .invalidOperationID: "--operation-id is not a canonical UUID"
        case .invalidNetworkPolicy(let value):
            "unsupported VZMac network policy: \(value)"
        case .invalidBoolean(let flag, let value):
            "\(flag) must be true or false, not \(value)"
        }
    }
}

public func parseDoryVZMacDesktopArguments(
    _ raw: [String]
) throws -> DoryVZMacDesktopArguments {
    guard let rawOperation = raw.first else {
        throw DoryVZMacDesktopArgumentError.missingOperation
    }
    guard let operation = DoryVZMacDesktopOperation(rawValue: rawOperation) else {
        throw DoryVZMacDesktopArgumentError.unsupportedOperation(rawOperation)
    }
    var values: [String: String] = [:]
    let usbDiskReadOnly = true
    var sawUSBReadOnlyFlag = false
    var index = 1
    while index < raw.count {
        let flag = raw[index]
        if flag == "--usb-disk-read-only" {
            guard !sawUSBReadOnlyFlag else {
                throw DoryVZMacDesktopArgumentError.duplicateArgument(flag)
            }
            sawUSBReadOnlyFlag = true
            index += 1
            continue
        }
        guard [
            "--machine", "--ipsw", "--guest-tools", "--usb-disk", "--machine-id",
            "--operation-id", "--state-dir", "--control-sock", "--handoff-sock",
            "--restore-state", "--network", "--audio-input", "--audio-output", "--clipboard",
            "--directory-sharing",
            DoryRuntimeReconnectContract.fileDescriptorArgument,
        ].contains(flag) else {
            throw DoryVZMacDesktopArgumentError.unknownArgument(flag)
        }
        guard values[flag] == nil else {
            throw DoryVZMacDesktopArgumentError.duplicateArgument(flag)
        }
        guard index + 1 < raw.count else {
            throw DoryVZMacDesktopArgumentError.missingValue(flag)
        }
        values[flag] = raw[index + 1]
        index += 2
    }

    guard let machinePath = values["--machine"] else {
        throw DoryVZMacDesktopArgumentError.missingMachineBundle
    }
    let machineURL = try absoluteFileURL(machinePath, flag: "--machine", isDirectory: true)
    let restoreURL = try values["--ipsw"].map {
        try absoluteFileURL($0, flag: "--ipsw", isDirectory: false)
    }
    if operation == .install, restoreURL == nil {
        throw DoryVZMacDesktopArgumentError.restoreImageRequired
    }
    if operation != .install, restoreURL != nil {
        throw DoryVZMacDesktopArgumentError.restoreImageUnexpected
    }
    let restoreStateURL = try values["--restore-state"].map {
        try absoluteFileURL($0, flag: "--restore-state", isDirectory: false)
    }
    if operation != .resume, restoreStateURL != nil {
        throw DoryVZMacDesktopArgumentError.restoreStateUnexpected
    }
    let toolsURL = try values["--guest-tools"].map {
        try absoluteFileURL($0, flag: "--guest-tools", isDirectory: true)
    }
    let usbURL = try values["--usb-disk"].map {
        try absoluteFileURL($0, flag: "--usb-disk", isDirectory: false)
    }
    if sawUSBReadOnlyFlag, usbURL == nil {
        throw DoryVZMacDesktopArgumentError.usbReadOnlyWithoutDisk
    }
    let networkPolicy: DoryVZMacNetworkPolicy
    if let rawNetwork = values["--network"] {
        guard let parsed = DoryVZMacNetworkPolicy(rawValue: rawNetwork) else {
            throw DoryVZMacDesktopArgumentError.invalidNetworkPolicy(rawNetwork)
        }
        networkPolicy = parsed
    } else {
        networkPolicy = .sharedNAT
    }
    let devicePolicy = DoryVZMacDevicePolicy(
        network: networkPolicy,
        audio: DoryVZMacAudioPolicy(
            inputEnabled: try parseOptionalBoolean(
                values["--audio-input"],
                flag: "--audio-input",
                defaultValue: true
            ),
            outputEnabled: try parseOptionalBoolean(
                values["--audio-output"],
                flag: "--audio-output",
                defaultValue: true
            )
        ),
        clipboardEnabled: try parseOptionalBoolean(
            values["--clipboard"],
            flag: "--clipboard",
            defaultValue: true
        ),
        directorySharingEnabled: try parseOptionalBoolean(
            values["--directory-sharing"],
            flag: "--directory-sharing",
            defaultValue: true
        )
    )
    let machineID = values["--machine-id"]
    if let machineID,
       machineID.isEmpty || machineID.utf8.count > 63
        || !machineID.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 95
        }) {
        throw DoryVZMacDesktopArgumentError.invalidMachineID
    }
    let operationID: UUID?
    if let rawOperationID = values["--operation-id"] {
        guard let parsed = DoryOperationIdentity.parseCanonical(rawOperationID) else {
            throw DoryVZMacDesktopArgumentError.invalidOperationID
        }
        operationID = parsed
    } else {
        operationID = nil
    }
    let stateDirectoryURL = try values["--state-dir"].map {
        try absoluteFileURL($0, flag: "--state-dir", isDirectory: true)
    }
    let controlSocketPath = try values["--control-sock"].map {
        try absoluteFileURL($0, flag: "--control-sock", isDirectory: false).path
    }
    let handoffSocketPath = try values["--handoff-sock"].map {
        try absoluteFileURL($0, flag: "--handoff-sock", isDirectory: false).path
    }
    let reconnectIdentity = try values[DoryRuntimeReconnectContract.fileDescriptorArgument].map {
        guard let descriptor = Int32($0),
              descriptor == DoryRuntimeReconnectContract.childFileDescriptor else {
            throw DoryVZMacDesktopArgumentError.invalidOperationID
        }
        return try DoryRuntimeReconnectLaunchIdentity.decode(fileDescriptor: descriptor)
    }
    let managedValuesPresent = [
        machineID != nil,
        operationID != nil,
        stateDirectoryURL != nil,
        controlSocketPath != nil,
        handoffSocketPath != nil,
        reconnectIdentity != nil,
    ]
    guard managedValuesPresent.allSatisfy({ $0 })
            || managedValuesPresent.allSatisfy({ !$0 }) else {
        throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
    }
    if let reconnectIdentity {
        guard reconnectIdentity.machineID == machineID,
              reconnectIdentity.operationID
                == operationID.map(DoryOperationIdentity.canonical) else {
            throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
        }
    }
    if let restoreStateURL {
        guard managedValuesPresent.allSatisfy({ $0 }), let stateDirectoryURL else {
            throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
        }
        try validateManagedRestoreStateURL(
            restoreStateURL,
            stateDirectoryURL: stateDirectoryURL
        )
    }
    if managedValuesPresent.allSatisfy({ $0 }), operation == .resume,
       restoreStateURL == nil {
        throw DoryVZMacDesktopArgumentError.restoreStateRequired
    }
    return DoryVZMacDesktopArguments(
        operation: operation,
        machineBundleURL: machineURL,
        restoreImageURL: restoreURL,
        guestToolsURL: toolsURL,
        usbDiskURL: usbURL,
        usbDiskReadOnly: usbDiskReadOnly,
        devicePolicy: devicePolicy,
        restoreStateURL: restoreStateURL,
        machineID: machineID,
        operationID: operationID,
        stateDirectoryURL: stateDirectoryURL,
        controlSocketPath: controlSocketPath,
        handoffSocketPath: handoffSocketPath,
        reconnectIdentity: reconnectIdentity
    )
}

private func parseOptionalBoolean(
    _ value: String?,
    flag: String,
    defaultValue: Bool
) throws -> Bool {
    guard let value else { return defaultValue }
    switch value {
    case "true": return true
    case "false": return false
    default: throw DoryVZMacDesktopArgumentError.invalidBoolean(flag, value)
    }
}

private enum DoryVZMacManagedSavedStateLeaf {
    case temporaryState
    case publishedState
}

private func validateManagedRestoreStateURL(
    _ stateURL: URL,
    stateDirectoryURL: URL
) throws {
    try validateManagedSavedStatePathShape(
        stateURL,
        stateDirectoryURL: stateDirectoryURL,
        expectedLeaf: .publishedState
    )
    try validateManagedSavedStateParent(
        stateDirectoryURL: stateDirectoryURL,
        leafName: stateURL.lastPathComponent,
        mustExist: true
    )
}

private func validateManagedSavedStatePathShape(
    _ stateURL: URL,
    stateDirectoryURL: URL,
    expectedLeaf: DoryVZMacManagedSavedStateLeaf
) throws {
    let root = stateDirectoryURL.standardizedFileURL
    let savedStateRoot = root.appendingPathComponent(
        DoryMachineSavedStateStore.directoryName,
        isDirectory: true
    )
    guard stateURL.deletingLastPathComponent().path == savedStateRoot.path else {
        throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
    }
    switch expectedLeaf {
    case .temporaryState:
        guard isCanonicalSavedStateTemporaryName(stateURL.lastPathComponent) else {
            throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
        }
    case .publishedState:
        guard stateURL.lastPathComponent == DoryMachineSavedStateManifest.stateFileName else {
            throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
        }
    }
}

private func validateManagedSavedStateParent(
    stateDirectoryURL: URL,
    leafName: String,
    mustExist: Bool
) throws {
    let root = try DoryTrustedDirectoryRoot(
        canonicalAbsolutePath: stateDirectoryURL.standardizedFileURL.path
    )
    let savedStateRoot = try root.openPrivateChildDirectory(
        DoryTrustedPathComponent(validating: DoryMachineSavedStateStore.directoryName)
    )
    try savedStateRoot.withBorrowedDescriptor { descriptor in
        let leaf = try DoryTrustedPathComponent(validating: leafName)
        let opened = openat(
            descriptor,
            leaf.value,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        if mustExist {
            guard opened >= 0 else { throw POSIXError(.ENOENT) }
            defer { close(opened) }
            try validateManagedSavedStateOpenFile(opened)
        } else if opened >= 0 {
            close(opened)
            throw DoryVZMacSavedStateError.destinationExists(leaf.value)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func validateManagedSavedStateOpenFile(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG,
          status.st_uid == geteuid(),
          status.st_nlink == 1,
          (status.st_mode & 0o077) == 0,
          status.st_size > 0 else {
        throw DoryVZMacSavedStateError.invalidArtifact("managed saved-state payload is not private")
    }
}

private func isCanonicalSavedStateTemporaryName(_ name: String) -> Bool {
    guard name.hasPrefix(DoryMachineSavedStateStore.temporaryStatePrefix) else { return false }
    let suffix = String(name.dropFirst(DoryMachineSavedStateStore.temporaryStatePrefix.count))
    guard suffix == suffix.lowercased(), UUID(uuidString: suffix) != nil else { return false }
    return suffix.count == 36
}

private func absoluteFileURL(
    _ path: String,
    flag: String,
    isDirectory: Bool
) throws -> URL {
    guard path.hasPrefix("/"), !path.contains("\0") else {
        throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute(flag)
    }
    let url = URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
    guard url.path == path || url.path + (isDirectory ? "/" : "") == path else {
        throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute(flag)
    }
    return url
}

/// Entry point used by the signed, LaunchServices-started DoryVMM application for native macOS.
/// The main Dory process never owns a VZ virtual machine; closing a console requests guest power
/// off while this isolated process retains the VM, its lease, and its display until teardown.
public enum DoryVZMacDesktopMain {
    @MainActor
    public static func run(_ rawArguments: [String]) -> Int32 {
        do {
            let arguments = try parseDoryVZMacDesktopArguments(rawArguments)
            let application = NSApplication.shared
            let controller = try DoryVZMacDesktopApplication(
                application: application,
                arguments: arguments
            )
            return try controller.run()
        } catch {
            FileHandle.standardError.write(Data("dory-vmm VZMac: \(error)\n".utf8))
            return 2
        }
    }
}

@MainActor
private final class DoryVZMacDesktopApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let application: NSApplication
    private let arguments: DoryVZMacDesktopArguments
    private let adapter: DoryVZMacAdapter
    private let window: NSWindow
    private var terminalError: Error?
    private var stopRequested = false
    private var controlServer: DoryVZMacControlServer?
    private var handoffPublished = false
    private let installLifecycle = DoryVZMacDesktopInstallLifecycle()

    init(application: NSApplication, arguments: DoryVZMacDesktopArguments) throws {
        self.application = application
        self.arguments = arguments
        adapter = try DoryVZMacAdapter(configuration: DoryVZMacAdapterConfiguration(
            machineBundleURL: arguments.machineBundleURL,
            guestToolsURL: arguments.guestToolsURL,
            usbDiskURL: arguments.usbDiskURL,
            usbDiskReadOnly: arguments.usbDiskReadOnly,
            devicePolicy: arguments.devicePolicy
        )) { message in
            FileHandle.standardError.write(Data("dory-vmm VZMac: \(message)\n".utf8))
        }
        let contentSize = NSSize(width: 1_280, height: 800)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = adapter.displayView
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.center()
        super.init()
        window.delegate = self
        adapter.onObservation = { [weak self] observation in
            self?.observe(observation)
        }
    }

    func run() throws -> Int32 {
        DoryDesktopApplicationIdentity.install(on: application)
        application.setActivationPolicy(.regular)
        application.delegate = self
        window.title = initialTitle
        window.makeKeyAndOrderFront(nil)
        application.activate()
        installViewMenu()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch arguments.operation {
                case .install:
                    guard let restoreImageURL = arguments.restoreImageURL else {
                        throw DoryVZMacDesktopArgumentError.restoreImageRequired
                    }
                    guard let operationID = arguments.operationID else {
                        throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
                    }
                    try await installLifecycle.installThenStart {
                        try await adapter.install(
                            from: restoreImageURL,
                            operationID: operationID
                        ) { [weak self] fraction in
                            self?.window.title = "\(self?.machineName ?? "macOS") — Installing macOS \(Int(fraction * 100))%"
                        }
                    } alreadyRunning: {
                        adapter.observation.state == .running
                    } start: {
                        try await adapter.start()
                    }
                case .run:
                    try await adapter.start()
                case .resume:
                    try await adapter.restoreSuspendedState(from: arguments.restoreStateURL)
                }
            } catch {
                terminalError = error
                finish()
            }
        }
        application.run()
        if let terminalError { throw terminalError }
        return 0
    }

    private var machineName: String {
        arguments.machineBundleURL.deletingPathExtension().lastPathComponent
    }

    private var initialTitle: String {
        switch arguments.operation {
        case .install: "\(machineName) — Preparing macOS installation"
        case .run: "\(machineName) — Starting macOS"
        case .resume: "\(machineName) — Resuming macOS"
        }
    }

    private func observe(_ observation: DoryVZMacAdapterObservation) {
        switch observation.state {
        case .installing:
            break
        case .starting:
            window.title = "\(machineName) — Starting macOS"
        case .running:
            window.title = "\(machineName) — macOS"
            publishManagedReadyIfNeeded()
        case .pausing:
            window.title = "\(machineName) — Pausing macOS"
        case .paused:
            window.title = "\(machineName) — macOS paused"
        case .suspending:
            window.title = "\(machineName) — Suspending macOS"
        case .suspended:
            window.title = "\(machineName) — macOS suspended"
            if !arguments.hasManagedLifecycleContract {
                finish()
            }
        case .restoring:
            window.title = "\(machineName) — Restoring macOS"
        case .stopping:
            window.title = "\(machineName) — Shutting down macOS"
        case .stopped:
            if installLifecycle.shouldFinishStoppedObservation(operation: arguments.operation) {
                finish()
            } else {
                window.title = "\(machineName) — Starting macOS"
            }
        case .installFailed, .failed:
            terminalError = NSError(
                domain: "DoryVZMacDesktop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: observation.failure ?? "macOS VM failed"]
            )
            finish()
        case .prepared:
            break
        }
    }

    private func finish() {
        controlServer?.stop()
        controlServer = nil
        application.stop(nil)
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            application.postEvent(event, atStart: false)
        }
    }

    private func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        do {
            try adapter.requestStop()
        } catch {
            terminalError = error
            finish()
        }
    }

    private func publishManagedReadyIfNeeded() {
        guard !handoffPublished, arguments.hasManagedLifecycleContract,
              let machineID = arguments.machineID,
              let operationID = arguments.operationID,
              let stateDirectoryURL = arguments.stateDirectoryURL,
              let controlSocketPath = arguments.controlSocketPath,
              let handoffSocketPath = arguments.handoffSocketPath else {
            return
        }
        do {
            let server = try DoryVZMacControlServer(
                machineID: machineID,
                launchOperationID: operationID,
                stateDirectory: stateDirectoryURL.path,
                socketPath: controlSocketPath
            ) { [weak self] request in
                guard let self else {
                    return VmmControlResponse(ok: false, message: "VZMac controller exited")
                }
                return await self.handleManagedControlRequest(request)
            }
            try server.start()
            controlServer = server
            try VmmHandoffClient.send(
                path: handoffSocketPath,
                ready: VmmReadyMessage(
                    machineID: machineID,
                    operationID: DoryOperationIdentity.canonical(operationID),
                    agentBuild: "dory-vmm/vzmac",
                    controlSocketPath: controlSocketPath,
                    detail: "native ARM64 macOS is running through Virtualization.framework"
                )
            )
            handoffPublished = true
        } catch {
            terminalError = error
            requestStop()
        }
    }

    private func handleManagedControlRequest(
        _ request: VmmControlRequest
    ) async -> VmmControlResponse {
        switch request.command {
        case "authenticateRuntime":
            guard request.targetMB == nil, request.statePath == nil,
                  request.lifecycleAction == nil, request.operationID == nil,
                  request.directoryShares == nil,
                  let challenge = request.reconnectChallenge,
                  let reconnectIdentity = arguments.reconnectIdentity else {
                return VmmControlResponse(ok: false, message: "invalid VZMac runtime authentication request")
            }
            do {
                return VmmControlResponse(
                    ok: true,
                    reconnect: try DoryRuntimeReconnectResponse(
                        launchIdentity: reconnectIdentity,
                        challenge: challenge,
                        processIdentity: DoryHostProcessIdentity.capture(),
                        runtimeState: adapter.observation.state.runtimeState
                    )
                )
            } catch {
                return VmmControlResponse(ok: false, message: "\(error)")
            }
        case "pauseMachine":
            guard let receipt = lifecycleReceipt(request, expected: .preparePause) else {
                return VmmControlResponse(ok: false, message: "invalid VZMac pause request")
            }
            do {
                try await adapter.pause()
                return receipt
            } catch {
                return VmmControlResponse(ok: false, message: "\(error)")
            }
        case "resumeMachine":
            guard let receipt = lifecycleReceipt(request, expected: .resumed) else {
                return VmmControlResponse(ok: false, message: "invalid VZMac resume request")
            }
            do {
                try await adapter.resume()
                return receipt
            } catch {
                return VmmControlResponse(ok: false, message: "\(error)")
            }
        case "acknowledgeLifecycle":
            guard let action = request.lifecycleAction,
                  let receipt = lifecycleReceipt(request, expected: action) else {
                return VmmControlResponse(
                    ok: false,
                    message: "invalid VZMac lifecycle acknowledgement"
                )
            }
            return receipt
        case "deviceTelemetry":
            guard request.targetMB == nil, request.statePath == nil,
                  request.lifecycleAction == nil, request.operationID == nil,
                  request.directoryShares == nil,
                  request.reconnectChallenge == nil else {
                return VmmControlResponse(
                    ok: false,
                    message: "invalid VZMac telemetry request"
                )
            }
            return VmmControlResponse(
                ok: true,
                deviceTelemetry: controlServer?.nextTelemetrySnapshot()
            )
        case "saveMachineState":
            guard request.targetMB == nil,
                  request.lifecycleAction == nil,
                  request.operationID == nil,
                  request.directoryShares == nil,
                  request.reconnectChallenge == nil,
                  let statePath = request.statePath else {
                return VmmControlResponse(
                    ok: false,
                    message: "native macOS saved-state payload is outside private saved-state authority"
                )
            }
            do {
                let acceptedStateURL = try acceptedSavedStateURL(statePath)
                if adapter.observation.state == .paused {
                    try await adapter.resume()
                }
                try await adapter.suspend(to: acceptedStateURL)
                guard let stateDirectoryURL = arguments.stateDirectoryURL?.standardizedFileURL else {
                    throw VmmControlError.rejected("managed state directory is unavailable")
                }
                try validateManagedSavedStateParent(
                    stateDirectoryURL: stateDirectoryURL,
                    leafName: acceptedStateURL.lastPathComponent,
                    mustExist: true
                )
                let bundle = try DoryVZMacMachineBundle.load(
                    from: arguments.machineBundleURL
                )
                guard bundle.manifest.installationState == .suspended else {
                    throw DoryVZMacMachineBundleError.invalidBundle(
                        "suspend completed without a durable suspended manifest"
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.finish()
                }
                return VmmControlResponse(ok: true)
            } catch {
                return VmmControlResponse(ok: false, message: "\(error)")
            }
        default:
            return VmmControlResponse(
                ok: false,
                message: "VZMac does not support control command \(request.command)"
            )
        }
    }

    private func lifecycleReceipt(
        _ request: VmmControlRequest,
        expected action: DoryLifecycleReceiptAction
    ) -> VmmControlResponse? {
        guard request.targetMB == nil, request.statePath == nil,
              request.directoryShares == nil,
              request.reconnectChallenge == nil,
              request.lifecycleAction == action,
              let operationID = request.operationID,
              DoryOperationIdentity.parseCanonical(operationID) != nil else {
            return nil
        }
        return VmmControlResponse(
            ok: true,
            lifecycleAction: action,
            operationID: operationID
        )
    }

    private func acceptedSavedStateURL(_ path: String) throws -> URL {
        guard let root = arguments.stateDirectoryURL?.standardizedFileURL else {
            throw VmmControlError.rejected("managed state directory is unavailable")
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        try validateManagedSavedStatePathShape(
            candidate,
            stateDirectoryURL: root,
            expectedLeaf: .temporaryState
        )
        try validateManagedSavedStateParent(
            stateDirectoryURL: root,
            leafName: candidate.lastPathComponent,
            mustExist: false
        )
        return candidate
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if adapter.observation.state == .running {
            window.orderOut(nil)
            requestStop()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSSound.beep()
        }
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if adapter.observation.state == .running {
            sender.orderOut(nil)
            requestStop()
        } else {
            NSSound.beep()
        }
        return false
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window.toggleFullScreen(sender)
    }

    private func installViewMenu() {
        let mainMenu = NSMenu()
        let viewRoot = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullscreen = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.target = self
        viewMenu.addItem(fullscreen)
        viewRoot.submenu = viewMenu
        mainMenu.addItem(viewRoot)
        application.mainMenu = mainMenu
    }
}

private final class DoryVZMacControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (VmmControlRequest) async -> VmmControlResponse

    private let machineID: String
    private let launchOperationID: UUID
    private let stateDirectory: String
    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.dory.dory-vmm.vzmac-control")
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var sampleSequence: UInt64 = 0

    init(
        machineID: String,
        launchOperationID: UUID,
        stateDirectory: String,
        socketPath: String,
        handler: @escaping Handler
    ) throws {
        let canonicalState = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .standardizedFileURL.path
        guard canonicalState == stateDirectory,
              socketPath.hasPrefix("/"), !socketPath.contains("\0") else {
            throw VmmControlError.rejected("invalid managed VZMac control paths")
        }
        self.machineID = machineID
        self.launchOperationID = launchOperationID
        self.stateDirectory = canonicalState
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        do {
            var noPipe: Int32 = 1
            guard setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw VmmControlError.syscall("setsockopt(SO_NOSIGPIPE)", errno)
            }
            var address = try Self.unixAddress(path: socketPath)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw VmmControlError.syscall("bind", errno) }
            guard chmod(socketPath, 0o600) == 0 else {
                throw VmmControlError.syscall("chmod", errno)
            }
            guard listen(fd, 16) == 0 else {
                throw VmmControlError.syscall("listen", errno)
            }
            lock.withLock { listenerFD = fd }
            queue.async { [weak self] in self?.acceptLoop(listenerFD: fd) }
        } catch {
            close(fd)
            unlink(socketPath)
            throw error
        }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let current = listenerFD
            listenerFD = -1
            return current
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    func nextTelemetrySnapshot() -> DoryDeviceTelemetrySnapshot {
        let sequence = lock.withLock { () -> UInt64 in
            sampleSequence = sampleSequence == UInt64.max ? 1 : sampleSequence + 1
            return sampleSequence
        }
        return DoryDeviceTelemetrySnapshot(
            machineID: machineID,
            operationID: DoryOperationIdentity.canonical(launchOperationID),
            backend: .appleVirtualizationFramework,
            sampleSequence: sequence,
            sampledAtUnixMilliseconds: UInt64(max(
                1,
                Int64(Date().timeIntervalSince1970 * 1_000)
            )),
            monotonicNanoseconds: max(1, DispatchTime.now().uptimeNanoseconds),
            devices: [DoryDeviceTelemetryDevice(
                id: "vzmac-platform",
                kind: .platform,
                health: .healthy,
                metrics: [.measured(.queueStateChanges, value: 0)]
            )]
        )
    }

    private func acceptLoop(listenerFD: Int32) {
        while lock.withLock({ self.listenerFD == listenerFD }) {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        let response: VmmControlResponse
        do {
            let data = try Self.readAll(from: clientFD)
            let request = try JSONDecoder().decode(VmmControlRequest.self, from: data)
            let box = DoryVZMacControlResponseBox()
            Task {
                let response = await handler(request)
                box.publish(response)
            }
            response = box.wait()
        } catch {
            response = VmmControlResponse(ok: false, message: "\(error)")
        }
        do {
            try Self.writeAll(try JSONEncoder().encode(response), to: clientFD)
        } catch {
            FileHandle.standardError.write(Data(
                "dory-vmm VZMac control response failed: \(error)\n".utf8
            ))
        }
    }

    private static func readAll(from fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VmmControlError.syscall("read", errno) }
            if count == 0 { break }
            guard result.count + count <= 1_048_576 else {
                throw VmmControlError.rejected("VZMac control request is too large")
            }
            result.append(buffer, count: count)
        }
        guard !result.isEmpty else { throw VmmControlError.emptyResponse }
        return result
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VmmControlError.syscall("write", errno) }
                offset += count
            }
        }
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty,
              bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw VmmControlError.pathTooLong(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    deinit { stop() }
}

private final class DoryVZMacControlResponseBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var response: VmmControlResponse?

    func publish(_ response: VmmControlResponse) {
        condition.lock()
        self.response = response
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> VmmControlResponse {
        condition.lock()
        while response == nil { condition.wait() }
        let result = response!
        condition.unlock()
        return result
    }
}
