import SwiftUI

struct DoryCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Container") {
                store.section = .containers
                store.activeSheet = .newContainer
            }
            .keyboardShortcut("n", modifiers: .command)
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
