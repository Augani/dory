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
        CommandMenu("Runtime") {
            Menu("Running Services") {
                if runningServices.isEmpty {
                    Button("No running services") {}
                        .disabled(true)
                } else {
                    ForEach(runningServices.prefix(12), id: \.id) { container in
                        Menu(serviceTitle(container)) {
                            Button("Open Details") {
                                openContainer(container, scope: container.composeProject == nil ? .all : .compose)
                            }
                            Button("Open Terminal") {
                                openWindow(value: store.terminalSession(for: container))
                            }
                            Divider()
                            Button("Restart") { store.restart(container) }
                            Button("Stop") { if container.isRunning { store.toggle(container) } }
                        }
                    }
                }
            }

            Menu("Compose Stacks") {
                if composeProjects.isEmpty {
                    Button("No Compose stacks") {}
                        .disabled(true)
                } else {
                    ForEach(composeProjects, id: \.name) { project in
                        Menu("\(project.name) (\(composeRunningCount(project.services))/\(project.services.count) running)") {
                            Button("Open Stack") {
                                if let first = project.services.first {
                                    openContainer(first, scope: .compose)
                                } else {
                                    openMain(.compose)
                                }
                            }
                            Divider()
                            Button("Start") { store.startComposeProject(project.name) }
                            Button("Stop") { store.stopComposeProject(project.name) }
                            Button("Restart") { store.restartComposeProject(project.name) }
                            Button("Down - stop and remove", role: .destructive) {
                                Task { await store.composeDown(project.name) }
                            }
                        }
                    }
                }
            }

            Menu("Linux Machines") {
                if store.machines.isEmpty {
                    Button("No machines") {}
                        .disabled(true)
                } else {
                    ForEach(store.machines, id: \.id) { machine in
                        Menu("\(machine.name) (\(machine.status.rawValue))") {
                            Button("Open Machines") { openMain(.machines) }
                            Button("Open Terminal") {
                                openWindow(value: store.terminalSession(for: machine))
                            }
                            Divider()
                            Button(machine.status == .running ? "Stop" : "Start") {
                                store.toggleMachine(machine)
                            }
                        }
                    }
                }
            }

            Menu("Kubernetes") {
                Button("Open Kubernetes") { openMain(.kubernetes) }
                Button("Refresh") { Task { await store.loadKubernetes() } }
                Divider()
                if store.kubernetesReachable {
                    Button("Disable Kubernetes", role: .destructive) {
                        Task { await store.disableKubernetes() }
                    }
                } else {
                    Button("Enable Kubernetes") {
                        Task { await store.enableKubernetes() }
                    }
                    .disabled(store.runtimeKind != .sharedVM || store.kubernetesBusy)
                }
            }
        }
    }

    private var runningServices: [Container] {
        store.containers
            .filter(\.isRunning)
            .sorted { serviceTitle($0).localizedCaseInsensitiveCompare(serviceTitle($1)) == .orderedAscending }
    }

    private var composeProjects: [(name: String, services: [Container])] {
        let grouped = Dictionary(grouping: store.containers.filter { $0.composeProject != nil }, by: { $0.composeProject ?? "" })
        return grouped.keys.sorted().map { name in
            (
                name: name,
                services: (grouped[name] ?? []).sorted {
                    serviceTitle($0).localizedCaseInsensitiveCompare(serviceTitle($1)) == .orderedAscending
                }
            )
        }
    }

    private func composeRunningCount(_ services: [Container]) -> Int {
        services.filter(\.isRunning).count
    }

    private func serviceTitle(_ container: Container) -> String {
        container.composeService ?? container.name
    }

    private func openMain(_ section: AppSection) {
        store.section = section
        store.windowOpenRequested = true
        openWindow(id: Self.openDoryWindowID)
    }

    private func openContainer(_ container: Container, scope: ContainerScope) {
        store.setContainerScope(scope)
        store.section = .containers
        store.selectedContainerID = container.id
        store.windowOpenRequested = true
        openWindow(id: Self.openDoryWindowID)
    }

    private func startAll() {
        for container in store.containers where !container.isRunning { store.toggle(container) }
    }

    private func stopAll() {
        for container in store.containers where container.isRunning { store.toggle(container) }
    }
}
