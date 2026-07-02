import SwiftUI

struct DoryCommands: Commands {
    static let openDoryWindowID = DoryApp.mainWindowID

    @Environment(\.openWindow) private var openWindow
    let store: AppStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Releases") { DoryUpdater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Container") {
                store.section = .containers
                store.activeSheet = .newContainer
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Containers") { store.section = .containers }.keyboardShortcut("1", modifiers: .command)
            Button("Images") { store.section = .images }.keyboardShortcut("2", modifiers: .command)
            Button("Volumes") { store.section = .volumes }.keyboardShortcut("3", modifiers: .command)
            Button("Networks") { store.section = .networks }.keyboardShortcut("4", modifiers: .command)
            Button("Compose") { store.section = .compose }.keyboardShortcut("5", modifiers: .command)
            Button("Kubernetes") { store.section = .kubernetes }.keyboardShortcut("6", modifiers: .command)
            Button("Machines") { store.section = .machines }.keyboardShortcut("7", modifiers: .command)
            Button("Settings") { store.section = .settings }.keyboardShortcut(",", modifiers: .command)
            Button("Filter") { if store.section != .settings { store.filterFocusToken += 1 } }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Open Dory") {
                store.windowOpenRequested = true
                openWindow(id: Self.openDoryWindowID)
            }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandMenu("Containers") {
            Button("Start All") { startAll() }
            Button("Stop All") { stopAll() }
            Divider()
            Button("Refresh") { Task { await store.reload() } }
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func startAll() {
        for container in store.containers where !container.isRunning { store.toggle(container) }
    }

    private func stopAll() {
        for container in store.containers where container.isRunning { store.toggle(container) }
    }
}
