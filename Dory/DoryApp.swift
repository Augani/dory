import SwiftUI

@main
struct DoryApp: App {
    static let mainWindowID = "dory-main"

    @NSApplicationDelegateAdaptor(DoryAppDelegate.self) private var appDelegate
    @State private var store: AppStore

    init() {
        // Writing to a socket whose peer has closed otherwise raises SIGPIPE and kills the process;
        // ignore it so the POSIX write paths return EPIPE and are handled gracefully.
        signal(SIGPIPE, SIG_IGN)
        let store = AppStore()
        store.startBackendIfNeeded()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(store)
                .modifier(LaunchWindowGate(store: store))
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

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.palette, store.palette)
                .frame(width: 720, height: 560)
        }

        MenuBarExtra(isInserted: Binding(get: { store.showMenuBarIcon }, set: { store.setShowMenuBarIcon($0) })) {
            MenuBarContentView()
                .environment(store)
        } label: {
            Image("MenuBarFish")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct LaunchWindowGate: ViewModifier {
    let store: AppStore
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .task {
                guard !DoryAppDelegate.isTestHost else { return }
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
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    if !DoryAppDelegate.hasVisibleMainWindow() {
                        DoryActivation.setForeground(false)
                    }
                }
            }
    }
}
