import SwiftUI

@main
struct DoryApp: App {
    @State private var store = AppStore()

    init() {
        // Writing to a socket whose peer has closed otherwise raises SIGPIPE and kills the process;
        // ignore it so the POSIX write paths return EPIPE and are handled gracefully.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
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

        MenuBarExtra(isInserted: Binding(get: { store.showMenuBarIcon }, set: { store.setShowMenuBarIcon($0) })) {
            MenuBarContentView()
                .environment(store)
        } label: {
            Image(systemName: "fish")
        }
        .menuBarExtraStyle(.window)
    }
}
