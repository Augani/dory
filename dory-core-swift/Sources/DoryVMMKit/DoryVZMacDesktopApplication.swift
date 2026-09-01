import AppKit
import Foundation

public enum DoryVZMacDesktopOperation: String, Sendable, Equatable {
    case install
    case run
    case resume
}

public struct DoryVZMacDesktopArguments: Sendable, Equatable {
    public var operation: DoryVZMacDesktopOperation
    public var machineBundleURL: URL
    public var restoreImageURL: URL?
    public var guestToolsURL: URL?
    public var usbDiskURL: URL?
    public var usbDiskReadOnly: Bool

    public init(
        operation: DoryVZMacDesktopOperation,
        machineBundleURL: URL,
        restoreImageURL: URL? = nil,
        guestToolsURL: URL? = nil,
        usbDiskURL: URL? = nil,
        usbDiskReadOnly: Bool = true
    ) {
        self.operation = operation
        self.machineBundleURL = machineBundleURL.standardizedFileURL
        self.restoreImageURL = restoreImageURL?.standardizedFileURL
        self.guestToolsURL = guestToolsURL?.standardizedFileURL
        self.usbDiskURL = usbDiskURL?.standardizedFileURL
        self.usbDiskReadOnly = usbDiskReadOnly
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
    case usbReadOnlyWithoutDisk
    case pathMustBeAbsolute(String)

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
        case .usbReadOnlyWithoutDisk: "--usb-disk-read-only requires --usb-disk"
        case .pathMustBeAbsolute(let flag): "\(flag) must name an absolute path"
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
        guard ["--machine", "--ipsw", "--guest-tools", "--usb-disk"].contains(flag) else {
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
    let toolsURL = try values["--guest-tools"].map {
        try absoluteFileURL($0, flag: "--guest-tools", isDirectory: true)
    }
    let usbURL = try values["--usb-disk"].map {
        try absoluteFileURL($0, flag: "--usb-disk", isDirectory: false)
    }
    if sawUSBReadOnlyFlag, usbURL == nil {
        throw DoryVZMacDesktopArgumentError.usbReadOnlyWithoutDisk
    }
    return DoryVZMacDesktopArguments(
        operation: operation,
        machineBundleURL: machineURL,
        restoreImageURL: restoreURL,
        guestToolsURL: toolsURL,
        usbDiskURL: usbURL,
        usbDiskReadOnly: usbDiskReadOnly
    )
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

    init(application: NSApplication, arguments: DoryVZMacDesktopArguments) throws {
        self.application = application
        self.arguments = arguments
        adapter = try DoryVZMacAdapter(configuration: DoryVZMacAdapterConfiguration(
            machineBundleURL: arguments.machineBundleURL,
            guestToolsURL: arguments.guestToolsURL,
            usbDiskURL: arguments.usbDiskURL,
            usbDiskReadOnly: arguments.usbDiskReadOnly
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
                    try await adapter.install(from: restoreImageURL) { [weak self] fraction in
                        self?.window.title = "\(self?.machineName ?? "macOS") — Installing macOS \(Int(fraction * 100))%"
                    }
                case .run:
                    try await adapter.start()
                case .resume:
                    try await adapter.restoreSuspendedState()
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
        case .pausing:
            window.title = "\(machineName) — Pausing macOS"
        case .paused:
            window.title = "\(machineName) — macOS paused"
        case .suspending:
            window.title = "\(machineName) — Suspending macOS"
        case .suspended:
            window.title = "\(machineName) — macOS suspended"
            finish()
        case .restoring:
            window.title = "\(machineName) — Restoring macOS"
        case .stopping:
            window.title = "\(machineName) — Shutting down macOS"
        case .stopped:
            finish()
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
