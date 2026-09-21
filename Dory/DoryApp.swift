import SwiftUI

@main
struct DoryApp: App {
    static let mainWindowID = "dory-main"

    @NSApplicationDelegateAdaptor(DoryAppDelegate.self) private var appDelegate
    @State private var store: AppStore
    private let displayQualification: DoryDisplayQualificationLaunch?

    init() {
        let displayQualification: DoryDisplayQualificationLaunch?
        do {
            displayQualification = try DoryDisplayQualificationLaunch.parse(
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            FileHandle.standardError.write(
                Data("Dory display qualification: \(error)\n".utf8)
            )
            exit(EX_USAGE)
        }
        self.displayQualification = displayQualification
        DoryUpgradeRollbackHelper.runIfRequested()
        // Writing to a socket whose peer has closed otherwise raises SIGPIPE and kills the process;
        // ignore it so the POSIX write paths return EPIPE and are handled gracefully.
        signal(SIGPIPE, SIG_IGN)
        DoryAppDelegate.exitDuplicateInstanceIfNeeded(
            displayQualification: displayQualification
        )
        let store = AppStore()
        if displayQualification == nil {
            DoryUpdater.shared.configure(store: store)
        }
        if !DoryAppDelegate.isNetworkHelperMaintenance(), displayQualification == nil {
            store.startBackendIfNeeded()
            DoryAppDelegate.configureMenuBar(store: store)
        }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            Group {
                if displayQualification == nil {
                    RootView()
                } else {
                    // The qualification process is a display client only. Do not instantiate the
                    // normal root hierarchy, whose inventory and settings tasks belong to the
                    // user's installed app instance.
                    Color.clear
                }
            }
            .environment(store)
            .modifier(
                LaunchWindowGate(
                    store: store,
                    displayQualification: displayQualification
                )
            )
            .modifier(LinuxMachineDisplayWindowBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 766)
        .windowResizability(.contentMinSize)
        .commands { DoryCommands(store: store) }

        WindowGroup("Terminal", for: TerminalSession.self) { $session in
            if let session {
                TerminalWindowView(session: session)
                    .environment(store)
                    .environment(\.palette, store.palette)
            }
        }
        .defaultSize(width: 760, height: 480)

        WindowGroup("Desktop", for: LinuxMachineDisplayWindow.self) { $display in
            if let display {
                LinuxMachineDisplayScene(display: display)
                    .environment(store)
            }
        }
        .defaultSize(width: 960, height: 600)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.palette, store.palette)
                .frame(width: 720, height: 560)
        }
    }
}

private struct LinuxMachineDisplayWindowBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .doryOpenLinuxMachineDisplay)
        ) { notification in
            guard let display = notification.object as? LinuxMachineDisplayWindow else { return }
            openWindow(value: display)
        }
    }
}

private struct LaunchWindowGate: ViewModifier {
    let store: AppStore
    let displayQualification: DoryDisplayQualificationLaunch?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task {
                guard !DoryAppDelegate.isTestHost else { return }
                if let displayQualification {
                    DoryActivation.setForeground(true)
                    openWindow(value: displayQualification.display)
                    await Task.yield()
                    dismissWindow(id: DoryApp.mainWindowID)
                    return
                }
                if store.windowOpenRequested {
                    store.windowOpenRequested = false
                    DoryActivation.setForeground(true)
                    return
                }
                if store.shouldOpenWindowOnLaunch {
                    DoryActivation.setForeground(true)
                    return
                }
                dismissWindow(id: DoryApp.mainWindowID)
            }
            .onDisappear {
                guard displayQualification == nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    if !DoryAppDelegate.hasVisibleMainWindow() {
                        DoryActivation.setForeground(false)
                    }
                }
            }
    }
}
