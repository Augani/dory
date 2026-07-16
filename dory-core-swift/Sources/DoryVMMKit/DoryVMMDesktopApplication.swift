import AppKit
import Foundation
@preconcurrency import Virtualization

@MainActor
final class DoryVMMDesktopApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let application: NSApplication
    private let runtime: DoryVMMRuntime
    private let machineView: VZVirtualMachineView
    private let window: NSWindow
    private var pendingDisplayResize: DispatchWorkItem?
    private var requestedPixelSize: CGSize?
    private var stopError: String?

    private init(runtime: DoryVMMRuntime, machineID: String) {
        self.application = NSApplication.shared
        self.runtime = runtime

        let windowSize = NSSize(width: 1_280, height: 800)
        let machineView = VZVirtualMachineView(frame: NSRect(origin: .zero, size: windowSize))
        machineView.virtualMachine = runtime.machine.virtualMachineForDisplay
        // Apple's automatic path currently requests the view's point size on Retina displays.
        // Dory drives the scanout with backing pixels so a 1280x800-point window renders a true
        // 2560x1600 guest framebuffer instead of stretching a low-resolution desktop.
        machineView.automaticallyReconfiguresDisplay = false
        machineView.capturesSystemKeys = false
        self.machineView = machineView

        self.window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
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
        reconfigureDisplayNow()

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

    func windowDidResize(_ notification: Notification) {
        scheduleDisplayReconfiguration()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        reconfigureDisplayNow()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        reconfigureDisplayNow()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        reconfigureDisplayNow()
    }

    nonisolated static func targetPixelSize(
        viewSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        // Keep the Linux desktop at a 2x render scale even on a 1x host display. Retina screens
        // map those pixels directly; lower-density screens get a supersampled image instead of a
        // visibly coarse guest framebuffer.
        let scale = max(2, backingScaleFactor)
        return CGSize(
            width: max(1, (viewSize.width * scale).rounded()),
            height: max(1, (viewSize.height * scale).rounded())
        )
    }

    private func scheduleDisplayReconfiguration() {
        pendingDisplayResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconfigureDisplayNow()
        }
        pendingDisplayResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func reconfigureDisplayNow() {
        pendingDisplayResize?.cancel()
        pendingDisplayResize = nil
        let size = Self.targetPixelSize(
            viewSize: machineView.bounds.size,
            backingScaleFactor: window.backingScaleFactor
        )
        guard size != requestedPixelSize else { return }
        do {
            try runtime.machine.reconfigurePrimaryDisplay(sizeInPixels: size)
            requestedPixelSize = size
        } catch {
            FileHandle.standardError.write(Data(
                "dory-vmm: desktop resize to \(Int(size.width))x\(Int(size.height)) failed: \(error)\n".utf8
            ))
        }
    }
}
