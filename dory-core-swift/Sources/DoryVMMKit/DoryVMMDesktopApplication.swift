import AppKit
import Foundation
@preconcurrency import Virtualization

@MainActor
final class DoryVMMDesktopApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let application: NSApplication
    private let runtime: DoryVMMRuntime
    private let window: NSWindow
    private var stopError: String?

    private init(runtime: DoryVMMRuntime, machineID: String) {
        self.application = NSApplication.shared
        self.runtime = runtime

        let machineView = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1_440, height: 900))
        machineView.virtualMachine = runtime.machine.virtualMachineForDisplay
        machineView.automaticallyReconfiguresDisplay = true
        machineView.capturesSystemKeys = false

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "\(machineID) — Dory Linux"
        self.window.contentView = machineView
        self.window.minSize = NSSize(width: 640, height: 400)
        self.window.center()
        super.init()
        self.window.delegate = self
    }

    static func run(runtime: DoryVMMRuntime, machineID: String) throws {
        let controller = DoryVMMDesktopApplication(runtime: runtime, machineID: machineID)
        try controller.runUntilStopped()
    }

    private func runUntilStopped() throws {
        application.setActivationPolicy(.regular)
        application.delegate = self
        window.makeKeyAndOrderFront(nil)
        application.activate()

        let runtime = self.runtime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error: String?
            do {
                try runtime.waitUntilStopped()
                error = nil
            } catch let waitError {
                error = "\(waitError)"
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish(error: error)
            }
        }

        application.run()
        if let stopError {
            throw DoryVZMachineError.stoppedWithError(stopError)
        }
    }

    private func finish(error: String?) {
        stopError = error
        application.stop(nil)
        if let wakeEvent = NSEvent.otherEvent(
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
            application.postEvent(wakeEvent, atStart: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window.orderOut(nil)
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
