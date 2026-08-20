import AppKit
import DoryOperations
import Foundation
@preconcurrency import Virtualization

@MainActor
final class DoryVMMDesktopApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let application: NSApplication
    private let runtime: DoryVMMRuntime
    private let machineView: VZVirtualMachineView
    private let window: NSWindow
    private let clipboard: DoryDesktopClipboardCoordinator
    private var pendingDisplayResize: DispatchWorkItem?
    private var requestedPixelSize: CGSize?
    private var stopError: String?

    private init(runtime: DoryVMMRuntime, machineID: String, environment: [String: String]) {
        self.application = NSApplication.shared
        self.runtime = runtime

        let windowSize = NSSize(width: 1_280, height: 800)
        let machineView = DoryVirtualMachineView(frame: NSRect(origin: .zero, size: windowSize))
        machineView.virtualMachine = runtime.machine.virtualMachineForDisplay
        // Apple's automatic path currently requests the view's point size on Retina displays.
        // Dory drives the scanout with backing pixels so a 1280x800-point window renders a true
        // 2560x1600 guest framebuffer instead of stretching a low-resolution desktop.
        machineView.automaticallyReconfiguresDisplay = false
        machineView.capturesSystemKeys = true
        self.machineView = machineView

        let requestedPolicy = DoryDesktopClipboardPolicy(environment: environment)
        // Bidirectional sharing is already handled by Apple's efficient SPICE transport. The
        // shared coordinator still translates Mac shortcuts, while directional modes use its
        // agent-backed data path to enforce the selected boundary.
        let coordinatorPolicy: DoryDesktopClipboardPolicy = requestedPolicy == .bidirectional
            ? .off
            : requestedPolicy
        self.clipboard = DoryDesktopClipboardCoordinator(
            policy: coordinatorPolicy,
            execute: { argv, stdin, timeoutMs, outputLimitBytes in
                try runtime.executeDesktopIntegration(
                    argv: argv,
                    stdin: stdin,
                    timeoutMs: timeoutMs,
                    outputLimitBytes: outputLimitBytes
                )
            },
            sendShortcut: { keyCode in machineView.sendControlShortcut(linuxKeyCode: keyCode) },
            log: { message in
                FileHandle.standardError.write(Data("dory-vmm clipboard: \(message)\n".utf8))
            }
        )

        self.window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "\(machineID) — Dory Linux"
        self.window.contentView = machineView
        self.window.minSize = NSSize(width: 640, height: 400)
        self.window.collectionBehavior.insert(.fullScreenPrimary)
        self.window.tabbingMode = .disallowed
        self.window.center()
        super.init()
        self.window.delegate = self
        machineView.onMacShortcut = { [weak clipboard] event in
            clipboard?.handleMacShortcut(event) ?? false
        }
    }

    static func run(
        runtime: DoryVMMRuntime,
        machineID: String,
        environment: [String: String]
    ) throws {
        let controller = DoryVMMDesktopApplication(
            runtime: runtime,
            machineID: machineID,
            environment: environment
        )
        try controller.runUntilStopped()
    }

    private func runUntilStopped() throws {
        application.setActivationPolicy(.regular)
        application.delegate = self
        clipboard.start()
        clipboard.markGuestReady()
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
        clipboard.stop()
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

/// `VZVirtualMachineView` forwards the device-oriented Core Graphics wheel deltas to Linux.
/// AppKit normally applies the user's macOS natural-scrolling preference before an `NSView`
/// consumes those deltas, but the VM view bypasses that normalization. Preserve all of the event's
/// phase and momentum metadata while correcting the delta fields only when AppKit says the host
/// preference inverted them from the physical device.
@MainActor
private final class DoryVirtualMachineView: VZVirtualMachineView {
    var onMacShortcut: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onMacShortcut?(event) == true { return }
        super.keyDown(with: event)
    }

    func sendControlShortcut(linuxKeyCode: UInt16) {
        guard let macKeyCode = Self.macKeyCode(forLinuxKeyCode: linuxKeyCode) else { return }
        for keyDown in [true, false] {
            guard let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(macKeyCode),
                keyDown: keyDown
            ) else { continue }
            cgEvent.flags = .maskControl
            if let event = NSEvent(cgEvent: cgEvent) {
                if keyDown { super.keyDown(with: event) } else { super.keyUp(with: event) }
            }
        }
    }

    private static func macKeyCode(forLinuxKeyCode code: UInt16) -> UInt16? {
        switch code {
        case 46: 8  // C
        case 45: 7  // X
        case 47: 9  // V
        default: nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.isDirectionInvertedFromDevice,
              let correctedCGEvent = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }

        Self.invertIntegerDelta(.scrollWheelEventDeltaAxis1, in: correctedCGEvent)
        Self.invertIntegerDelta(.scrollWheelEventDeltaAxis2, in: correctedCGEvent)
        Self.invertIntegerDelta(.scrollWheelEventPointDeltaAxis1, in: correctedCGEvent)
        Self.invertIntegerDelta(.scrollWheelEventPointDeltaAxis2, in: correctedCGEvent)
        Self.invertFixedPointDelta(.scrollWheelEventFixedPtDeltaAxis1, in: correctedCGEvent)
        Self.invertFixedPointDelta(.scrollWheelEventFixedPtDeltaAxis2, in: correctedCGEvent)
        guard let correctedEvent = NSEvent(cgEvent: correctedCGEvent) else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: correctedEvent)
    }

    private static func invertIntegerDelta(_ field: CGEventField, in event: CGEvent) {
        event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
    }

    private static func invertFixedPointDelta(_ field: CGEventField, in event: CGEvent) {
        event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
    }
}
