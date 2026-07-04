import AppKit

final class DoryAppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        NSApp.setActivationPolicy(.accessory)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            SharedVMProvisioner.resyncClockAfterWake()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        DockerContext.deactivateSync()
        SharedVMProvisioner.stopEngineDetached()
    }
}

enum DoryActivation {
    @MainActor static func setForeground(_ foreground: Bool) {
        guard !DoryAppDelegate.isTestHost else { return }
        NSApp.setActivationPolicy(foreground ? .regular : .accessory)
        if foreground { NSApp.activate(ignoringOtherApps: true) }
    }
}
