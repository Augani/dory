import AppKit

final class DoryAppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("dory.main-window")

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["DORY_UI_TEST"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            Self.closeDuplicateMainWindows()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            SharedVMProvisioner.recoverAfterWake()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Self.closeDuplicateMainWindows() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        DockerContext.deactivateSync()
        SharedVMProvisioner.stopEngineDetached()
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
        NSApp.setActivationPolicy(foreground ? .regular : .accessory)
        if foreground { NSApp.activate(ignoringOtherApps: true) }
    }
}
