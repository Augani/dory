import AppKit
import DoryVZMacCore
import Foundation
@preconcurrency import Virtualization

private enum Command {
    case latest
    case prepare(
        ipsw: URL,
        source: URL?,
        machine: URL,
        cpus: Int?,
        memoryBytes: UInt64?,
        diskBytes: UInt64
    )
    case install(ipsw: URL, machine: URL)
    case run(
        machine: URL,
        guestTools: URL?,
        usbMassStorage: DoryVZMacUSBMassStorage?,
        suspendOnExit: Bool
    )
    case resume(
        machine: URL,
        guestTools: URL?,
        usbMassStorage: DoryVZMacUSBMassStorage?,
        suspendOnExit: Bool
    )
    case clone(machine: URL, destination: URL)
    case export(machine: URL, destination: URL)
    case `import`(source: URL, machine: URL)
    case status(machine: URL)
    case recover(machine: URL, discardSavedState: Bool)
}

private enum CommandError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let detail): detail
        }
    }
}

private func parseCommand(_ arguments: [String]) throws -> Command {
    guard let verb = arguments.first else {
        throw CommandError.usage(usage)
    }
    var values = Array(arguments.dropFirst())
    func take(_ flag: String) throws -> String {
        guard let index = values.firstIndex(of: flag), index + 1 < values.count else {
            throw CommandError.usage("missing \(flag)\n\n\(usage)")
        }
        let value = values[index + 1]
        values.removeSubrange(index ... index + 1)
        return value
    }
    func takeUSBMassStorage() throws -> DoryVZMacUSBMassStorage? {
        let readOnly = values.contains("--usb-disk-read-only")
        values.removeAll { $0 == "--usb-disk-read-only" }
        guard values.contains("--usb-disk") else {
            if readOnly {
                throw CommandError.usage("--usb-disk-read-only requires --usb-disk\n\n\(usage)")
            }
            return nil
        }
        return try DoryVZMacUSBMassStorage(
            url: URL(fileURLWithPath: take("--usb-disk")),
            readOnly: readOnly
        )
    }
    switch verb {
    case "latest":
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .latest
    case "prepare":
        let ipsw = URL(fileURLWithPath: try take("--ipsw"))
        let source = values.contains("--source-url") ? URL(string: try take("--source-url")) : nil
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let cpus = values.contains("--cpus") ? Int(try take("--cpus")) : nil
        let memoryGiB = values.contains("--memory-gib") ? UInt64(try take("--memory-gib")) : nil
        let diskGiB = values.contains("--disk-gib")
            ? UInt64(try take("--disk-gib"))
            : 80
        guard values.isEmpty, cpus != 0, memoryGiB != 0, let diskGiB else {
            throw CommandError.usage(usage)
        }
        return .prepare(
            ipsw: ipsw,
            source: source,
            machine: machine,
            cpus: cpus,
            memoryBytes: memoryGiB.map { $0 * DoryVZMacResourcePlan.gibibyte },
            diskBytes: diskGiB * DoryVZMacResourcePlan.gibibyte
        )
    case "install":
        let ipsw = URL(fileURLWithPath: try take("--ipsw"))
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .install(ipsw: ipsw, machine: machine)
    case "run":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let guestTools = values.contains("--guest-tools")
            ? URL(fileURLWithPath: try take("--guest-tools"), isDirectory: true)
            : nil
        let usbMassStorage = try takeUSBMassStorage()
        let suspendOnExit = values.contains("--suspend-on-exit")
        values.removeAll { $0 == "--suspend-on-exit" }
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .run(
            machine: machine,
            guestTools: guestTools,
            usbMassStorage: usbMassStorage,
            suspendOnExit: suspendOnExit
        )
    case "resume":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let guestTools = values.contains("--guest-tools")
            ? URL(fileURLWithPath: try take("--guest-tools"), isDirectory: true)
            : nil
        let usbMassStorage = try takeUSBMassStorage()
        let suspendOnExit = values.contains("--suspend-on-exit")
        values.removeAll { $0 == "--suspend-on-exit" }
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .resume(
            machine: machine,
            guestTools: guestTools,
            usbMassStorage: usbMassStorage,
            suspendOnExit: suspendOnExit
        )
    case "clone":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let destination = URL(
            fileURLWithPath: try take("--destination"),
            isDirectory: true
        )
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .clone(machine: machine, destination: destination)
    case "export":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let destination = URL(
            fileURLWithPath: try take("--destination"),
            isDirectory: true
        )
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .export(machine: machine, destination: destination)
    case "import":
        let source = URL(fileURLWithPath: try take("--source"), isDirectory: true)
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .import(source: source, machine: machine)
    case "status":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .status(machine: machine)
    case "recover":
        let machine = URL(fileURLWithPath: try take("--machine"), isDirectory: true)
        let discardSavedState = values.contains("--discard-saved-state")
        values.removeAll { $0 == "--discard-saved-state" }
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .recover(machine: machine, discardSavedState: discardSavedState)
    default:
        throw CommandError.usage(usage)
    }
}

private let usage = """
Usage:
  dory-vzmac-qualification latest
  dory-vzmac-qualification prepare --ipsw <file> [--source-url <https-url>] --machine <bundle> [--cpus N] [--memory-gib N] [--disk-gib N]
  dory-vzmac-qualification install --ipsw <file> --machine <bundle>
  dory-vzmac-qualification run --machine <bundle> [--guest-tools <directory>] [--usb-disk <image> [--usb-disk-read-only]] [--suspend-on-exit]
  dory-vzmac-qualification resume --machine <bundle> [--guest-tools <directory>] [--usb-disk <image> [--usb-disk-read-only]] [--suspend-on-exit]
  dory-vzmac-qualification clone --machine <bundle> --destination <bundle>
  dory-vzmac-qualification export --machine <bundle> --destination <dorymachine>
  dory-vzmac-qualification import --source <dorymachine> --machine <bundle>
  dory-vzmac-qualification status --machine <bundle>
  dory-vzmac-qualification recover --machine <bundle> [--discard-saved-state]
"""

private struct MachineStatus: Codable {
    static let schema = "dory.vzmac-machine-status@1"

    let schema: String
    let inspectedAt: String
    let manifest: DoryVZMacMachineManifest
    let configurationValid: Bool
    let saveRestoreSupported: Bool
    let saveRestoreError: String?
    let installJournal: DoryVZMacInstallJournal?
    let suspendedStatePresent: Bool
}

@MainActor
private final class QualificationAppDelegate: NSObject, NSApplicationDelegate,
    @MainActor VZVirtualMachineDelegate, NSWindowDelegate
{
    private let command: Command
    private var runtime: DoryVZMacRuntime?
    private var window: NSWindow?
    private var awaitingTermination = false

    init(command: Command) {
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Dory Mac Qualification",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                try await execute()
            } catch {
                FileHandle.standardError.write(Data("Dory VZMac qualification failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }

    private func execute() async throws {
        switch command {
        case .latest:
            let image = try await VZMacOSRestoreImage.latestSupported
            let version = image.operatingSystemVersion
            let requirements = image.mostFeaturefulSupportedConfiguration
            let receipt: [String: Any] = [
                "schema": "dory.vzmac-latest-restore-image@1",
                "url": image.url.absoluteString,
                "buildVersion": image.buildVersion,
                "operatingSystemVersion": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                "minimumCPUCount": requirements?.minimumSupportedCPUCount as Any,
                "minimumMemoryBytes": requirements?.minimumSupportedMemorySize as Any,
                "supportedConfigurationAvailable": requirements != nil,
            ]
            FileHandle.standardOutput.write(
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            )
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .prepare(let ipsw, let source, let machine, let cpus, let memoryBytes, let diskBytes):
            let bundle = try await DoryVZMacMachineBundle.prepare(
                at: machine,
                restoreImageURL: ipsw,
                restoreImageSourceURL: source,
                requestedCPUCount: cpus,
                requestedMemoryBytes: memoryBytes,
                diskBytes: diskBytes
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(bundle.manifest))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .install(let ipsw, let machine):
            let runtime = try makeRuntime(machine: machine)
            show(runtime: runtime, title: "Dory — Installing macOS")
            try await runtime.install(from: ipsw, operationID: UUID()) { [weak self] fraction in
                self?.window?.title = "Dory — Installing macOS \(Int(fraction * 100))%"
            }
            window?.title = "Dory — macOS installation complete"
        case .run(let machine, let guestTools, let usbMassStorage, _):
            let runtime = try makeRuntime(
                machine: machine,
                guestTools: guestTools,
                usbMassStorage: usbMassStorage
            )
            show(runtime: runtime, title: "Dory — macOS")
            try await runtime.start()
            window?.title = "Dory — macOS running"
        case .resume(let machine, let guestTools, let usbMassStorage, _):
            let runtime = try makeRuntime(
                machine: machine,
                guestTools: guestTools,
                usbMassStorage: usbMassStorage
            )
            show(runtime: runtime, title: "Dory — Restoring macOS")
            try await runtime.restoreSuspendedState()
            window?.title = "Dory — macOS resumed"
        case .clone(let machine, let destination):
            let source = try DoryVZMacMachineBundle.load(from: machine)
            let clone = try source.clone(to: destination)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(clone.manifest))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .export(let machine, let destination):
            let source = try DoryVZMacMachineBundle.load(from: machine)
            let portable = try DoryVZMacPortableBundle.export(
                machine: source,
                to: destination
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(portable.manifest))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .import(let source, let machine):
            let portable = try DoryVZMacPortableBundle.load(from: source)
            let restored = try portable.restore(to: machine)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(restored.manifest))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .status(let machine):
            let bundle = try DoryVZMacMachineBundle.load(from: machine)
            let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(for: bundle)
            let saveRestoreSupported: Bool
            let saveRestoreError: String?
            do {
                try configuration.validateSaveRestoreSupport()
                saveRestoreSupported = true
                saveRestoreError = nil
            } catch {
                saveRestoreSupported = false
                saveRestoreError = String(String(describing: error).prefix(1_024))
            }
            let journal = FileManager.default.fileExists(atPath: bundle.installJournalURL.path)
                ? try DoryVZMacInstallJournal.load(from: bundle.installJournalURL)
                : nil
            let receipt = MachineStatus(
                schema: MachineStatus.schema,
                inspectedAt: ISO8601DateFormatter().string(from: Date()),
                manifest: bundle.manifest,
                configurationValid: true,
                saveRestoreSupported: saveRestoreSupported,
                saveRestoreError: saveRestoreError,
                installJournal: journal,
                suspendedStatePresent: FileManager.default.fileExists(
                    atPath: bundle.suspendedStateURL.path
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(receipt))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        case .recover(let machine, let discardSavedState):
            let bundle = try DoryVZMacMachineBundle.load(from: machine)
            let recovered = try DoryVZMacRecovery.recoverInterruptedOperation(
                in: bundle,
                discardSavedStateAfterInterruptedRestore: discardSavedState
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(recovered.manifest))
            FileHandle.standardOutput.write(Data([0x0a]))
            NSApp.terminate(nil)
        }
    }

    private func makeRuntime(
        machine: URL,
        guestTools: URL? = nil,
        usbMassStorage: DoryVZMacUSBMassStorage? = nil
    ) throws -> DoryVZMacRuntime {
        let bundle = try DoryVZMacMachineBundle.load(from: machine)
        let shares = try guestTools.map {
            [try DoryVZMacSharedDirectory(name: "Dory Guest Tools", url: $0, readOnly: true)]
        } ?? []
        let runtime = try DoryVZMacRuntime(
            bundle: bundle,
            sharedDirectories: shares,
            usbMassStorage: usbMassStorage
        ) { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        runtime.virtualMachine.delegate = self
        self.runtime = runtime
        return runtime
    }

    private func show(runtime: DoryVZMacRuntime, title: String) {
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 800))
        view.autoresizingMask = [.width, .height]
        view.virtualMachine = runtime.virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        window?.title = "Dory — macOS stopped"
        if awaitingTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        window?.title = "Dory — macOS stopped with an error"
        FileHandle.standardError.write(Data("VZMac stopped: \(error)\n".utf8))
        if awaitingTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !awaitingTermination else { return .terminateCancel }
        guard let runtime, runtime.virtualMachine.state == .running else { return .terminateNow }
        let suspendOnExit: Bool
        switch command {
        case .run(_, _, _, let enabled), .resume(_, _, _, let enabled):
            suspendOnExit = enabled
        default:
            suspendOnExit = false
        }
        if suspendOnExit {
            awaitingTermination = true
            window?.title = "Dory — Suspending macOS"
            Task { @MainActor in
                do {
                    try await runtime.suspend()
                    NSApp.reply(toApplicationShouldTerminate: true)
                } catch {
                    awaitingTermination = false
                    FileHandle.standardError.write(
                        Data("VZMac suspension failed: \(error)\n".utf8)
                    )
                    window?.title = "Dory — Suspension failed"
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        }
        do {
            try runtime.requestStop()
            awaitingTermination = true
            window?.title = "Dory — Waiting for macOS to shut down"
            return .terminateLater
        } catch {
            FileHandle.standardError.write(Data("VZMac graceful stop failed: \(error)\n".utf8))
            return .terminateCancel
        }
    }
}

do {
    let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
    let app = NSApplication.shared
    let delegate = QualificationAppDelegate(command: command)
    app.delegate = delegate
    app.run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(64)
}
