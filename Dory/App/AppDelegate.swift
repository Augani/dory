import AppKit
import Darwin
import SwiftUI

final class DoryAppDelegate: NSObject, NSApplicationDelegate {
    fileprivate static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("dory.main-window")
    private static let instanceLock = NSLock()
    private static var instanceLockFD: Int32 = -1
    private static let statusItemController = DoryStatusItemController()

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["DORY_UI_TEST"] == "1"
    }

    static func isNetworkHelperRegistration(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().contains("--register-network-helper")
    }

    static func exitDuplicateInstanceIfNeeded() {
        guard !isNetworkHelperRegistration() else { return }
        guard !isTestHost, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard acquireInstanceLock() else {
            runningInstance(bundleIdentifier: bundleIdentifier)?.activate(options: [.activateAllWindows])
            exit(EXIT_SUCCESS)
        }
        terminateStaleInstances(bundleIdentifier: bundleIdentifier)
    }

    @MainActor static func configureMenuBar(store: AppStore) {
        guard !isTestHost else { return }
        statusItemController.configure(store: store)
    }

    @MainActor static func refreshMenuBarVisibility() {
        guard !isTestHost else { return }
        statusItemController.applyVisibility()
    }

    @MainActor static func openMainWindow() {
        statusItemController.openMainWindow()
    }

    nonisolated static func hasOtherInstance(currentProcessIdentifier: pid_t, candidates: [pid_t]) -> Bool {
        candidates.contains { $0 > 0 && $0 != currentProcessIdentifier }
    }

    nonisolated static func staleInstancePIDs(currentProcessIdentifier: pid_t, candidates: [pid_t]) -> [pid_t] {
        candidates.filter { $0 > 0 && $0 != currentProcessIdentifier }
    }

    nonisolated static func instanceLockPath(home: String) -> String {
        "\(home)/.dory/dory-app.lock"
    }

    private static func acquireInstanceLock(home: String = NSHomeDirectory()) -> Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if instanceLockFD >= 0 { return true }

        let path = instanceLockPath(home: home)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return true }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    private static func runningInstance(bundleIdentifier: String) -> NSRunningApplication? {
        let current = getpid()
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current }
        return candidates.first(where: { $0.isActive }) ?? candidates.first
    }

    private static func terminateStaleInstances(bundleIdentifier: String) {
        let current = getpid()
        let stale = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current }
        guard !stale.isEmpty else { return }
        stale.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for app in stale where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        if Self.isNetworkHelperRegistration() {
            Task {
                do {
                    try await AppStore.refreshPrivilegedNetworkDaemonFromCurrentBundle()
                    FileHandle.standardOutput.write(Data("network-helper=enabled\n".utf8))
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("network-helper=error: \(error.localizedDescription)\n".utf8))
                    exit(78)
                }
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Self.refreshMenuBarVisibility()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            Self.closeDuplicateMainWindows()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Self.closeDuplicateMainWindows() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isTestHost,
           !UserDefaults.standard.bool(forKey: AppStore.keepDorydRunningAfterQuitKey) {
            DorydLaunchAgent.bootoutCurrentSynchronously()
        }
        Self.instanceLock.lock()
        let fd = Self.instanceLockFD
        Self.instanceLockFD = -1
        Self.instanceLock.unlock()
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    @MainActor static func markMainWindow(_ window: NSWindow) {
        window.identifier = mainWindowIdentifier
        window.title = "Dory"
        closeDuplicateMainWindows(keeping: window)
    }

    @MainActor static func hasVisibleMainWindow() -> Bool {
        NSApp.windows.contains { $0.identifier == mainWindowIdentifier && $0.isVisible }
    }

    @MainActor static func closeDuplicateMainWindows(keeping preferred: NSWindow? = nil) {
        let windows = NSApp.windows.filter { $0.identifier == mainWindowIdentifier }
        guard windows.count > 1 else { return }
        let keeper = preferred ?? windows.first(where: { $0.isKeyWindow }) ?? windows.first
        for window in windows where window !== keeper {
            window.close()
        }
    }
}

enum DoryActivation {
    @MainActor static func setForeground(_ foreground: Bool) {
        guard !DoryAppDelegate.isTestHost else { return }
        let target: NSApplication.ActivationPolicy = foreground ? .regular : .accessory
        // Keep activation changes idempotent; repeated flips still make windows and popovers flicker.
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
        if foreground { NSApp.activate(ignoringOtherApps: true) }
    }
}

@MainActor
private final class DoryStatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private weak var store: AppStore?
    private var mainWindow: NSWindow?
    private var terminalWindows: [String: NSWindow] = [:]

    func configure(store: AppStore) {
        self.store = store
        popover.behavior = .transient
        popover.delegate = self
        applyVisibility()
    }

    func applyVisibility() {
        guard let store else { return }
        if store.showMenuBarIcon {
            installStatusItemIfNeeded()
        } else {
            closePopover()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    func openMainWindow() {
        guard let store else { return }
        if let existing = NSApp.windows.first(where: { $0.identifier == DoryAppDelegate.mainWindowIdentifier }) {
            existing.makeKeyAndOrderFront(nil)
            DoryActivation.setForeground(true)
            return
        }

        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            let controller = NSHostingController(
                rootView: RootView()
                    .environment(store)
                    .environment(\.palette, store.palette)
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 766),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 1000, height: 660)
            window.setFrameAutosaveName("DoryMainWindow")
            window.center()
            window.delegate = self
            mainWindow = window
        }

        DoryAppDelegate.markMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        DoryActivation.setForeground(true)
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Dory"
        item.button?.setAccessibilityLabel("Dory")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let store else { return }
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(actions: MenuBarActions(
                closePopover: { [weak self] in self?.closePopover() },
                openMainWindow: { [weak self] in self?.openMainWindow() },
                openTerminal: { [weak self] session in self?.openTerminal(session) }
            ))
            .environment(store)
            .environment(\.palette, store.palette)
            .preferredColorScheme(store.appearance.colorScheme)
        )
        popover.contentSize = NSSize(width: 340, height: 560)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func openTerminal(_ session: TerminalSession) {
        guard let store else { return }
        if let window = terminalWindows[session.id] {
            window.makeKeyAndOrderFront(nil)
            DoryActivation.setForeground(true)
            return
        }

        let controller = NSHostingController(
            rootView: TerminalWindowView(session: session)
                .environment(store)
                .environment(\.palette, store.palette)
                .preferredColorScheme(store.appearance.colorScheme)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.title
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.delegate = self
        terminalWindows[session.id] = window
        window.makeKeyAndOrderFront(nil)
        DoryActivation.setForeground(true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                if !DoryAppDelegate.hasVisibleMainWindow() {
                    DoryActivation.setForeground(false)
                }
            }
            return
        }
        if let match = terminalWindows.first(where: { $0.value === window })?.key {
            terminalWindows.removeValue(forKey: match)
        }
    }

    private func statusImage() -> NSImage? {
        let image = NSImage(named: "MenuBarFish")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }
}
