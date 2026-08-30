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
    case run(machine: URL)
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
        guard values.isEmpty else { throw CommandError.usage(usage) }
        return .run(machine: machine)
    default:
        throw CommandError.usage(usage)
    }
}

private let usage = """
Usage:
  dory-vzmac-qualification latest
  dory-vzmac-qualification prepare --ipsw <file> [--source-url <https-url>] --machine <bundle> [--cpus N] [--memory-gib N] [--disk-gib N]
  dory-vzmac-qualification install --ipsw <file> --machine <bundle>
  dory-vzmac-qualification run --machine <bundle>
"""

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
        Task { @MainActor in
            do {
                try await execute()
            } catch {
                FileHandle.standardError.write(Data("Dory VZMac qualification failed: \(error)\n".utf8))
                NSApp.terminate(nil)
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
            try await runtime.install(from: ipsw) { [weak self] fraction in
                self?.window?.title = "Dory — Installing macOS \(Int(fraction * 100))%"
            }
            window?.title = "Dory — macOS installation complete"
        case .run(let machine):
            let runtime = try makeRuntime(machine: machine)
            show(runtime: runtime, title: "Dory — macOS")
            try await runtime.start()
            window?.title = "Dory — macOS running"
        }
    }

    private func makeRuntime(machine: URL) throws -> DoryVZMacRuntime {
        let bundle = try DoryVZMacMachineBundle.load(from: machine)
        let runtime = try DoryVZMacRuntime(bundle: bundle) { message in
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
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime, runtime.virtualMachine.state == .running else { return .terminateNow }
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
