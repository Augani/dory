import AppKit
import DoryOperations
import SwiftUI

struct DoryCommands: Commands {
    static let openDoryWindowID = DoryApp.mainWindowID

    @Environment(\.openWindow) private var openWindow
    let store: AppStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") { DoryUpdater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Container") {
                store.section = .containers
                store.activeSheet = .newContainer
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Desktop") {
                openMain(.desktops)
                store.presentPrimary(for: .desktops)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            Button("New Server") {
                openMain(.machines)
                store.presentPrimary(for: .machines)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button(store.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                store.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            if store.section == .containers, store.selectedContainer != nil {
                Button(store.isContainerInspectorVisible ? "Hide Container Details" : "Show Container Details") {
                    store.isContainerInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            Divider()
            Button("Containers") { store.section = .containers }.keyboardShortcut("1", modifiers: .command)
            Button("Images") { store.section = .images }.keyboardShortcut("2", modifiers: .command)
            Button("Volumes") { store.section = .volumes }.keyboardShortcut("3", modifiers: .command)
            Button("Networks") { store.section = .networks }.keyboardShortcut("4", modifiers: .command)
            Button("Compose") { store.section = .compose }.keyboardShortcut("5", modifiers: .command)
            Button("Build Activity") { store.section = .builds }
            Button("Kubernetes") { store.section = .kubernetes }.keyboardShortcut("6", modifiers: .command)
            Button("Desktops") { store.section = .desktops }.keyboardShortcut("7", modifiers: .command)
            Button("Servers") { store.section = .machines }.keyboardShortcut("8", modifiers: .command)
            Button("Components") { store.section = .components }.keyboardShortcut("9", modifiers: .command)
            Button("Health") { store.section = .health }
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
            Button("Open Daemon Health") { openMain(.health) }
            Button("Process Memory") { openSettings(.resources) }
            Button("Local Tools") { openSettings(.localTools) }
            Button("Auto-Idle Settings") { openSettings(.autoIdle) }
            Divider()

            Menu("Local Tools") {
                ForEach(store.localDorydCapabilities, id: \.id) { capability in
                    Button("Copy \(capability.title) Command") {
                        copy(capability.command)
                    }
                }
                Divider()
                Button("Open Local Tools") { openSettings(.localTools) }
            }

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
                            Button("Review stack removal in Dory…") { openMain(.compose) }
                        }
                    }
                }
            }

            Menu("Linux Machines") {
                Button("New Desktop") {
                    openMain(.desktops)
                    store.presentPrimary(for: .desktops)
                }
                Button("New Server") {
                    openMain(.machines)
                    store.presentPrimary(for: .machines)
                }
                Divider()
                if store.machines.isEmpty {
                    Button("No machines") {}
                        .disabled(true)
                } else {
                    ForEach(store.machines, id: \.id) { machine in
                        Menu("\(machine.name) (\(machine.status.rawValue))") {
                            Button(machine.displayMode == .desktop ? "Show in Desktops" : "Show in Servers") {
                                openMain(machine.displayMode == .desktop ? .desktops : .machines)
                            }
                            if machine.displayMode == .desktop {
                                Button("Open Desktop") { store.openMachineDesktop(machine) }
                                    .disabled(!store.canOpenMachineDesktop(machine))
                            }
                            Button("Open Terminal") {
                                openWindow(value: store.terminalSession(for: machine))
                            }
                            .disabled(!store.canOpenMachineTerminal(machine))
                            if let command = store.machineTerminalCommand(machine) {
                                Button("Copy Terminal Command") {
                                    copy(command)
                                }
                            }
                            Button("Copy Address") {
                                copy(machine.ip)
                            }
                            Button("Edit Address & Resources") {
                                openMain(machine.displayMode == .desktop ? .desktops : .machines)
                                store.openMachineEdit(machine)
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
                    Button("Review cluster removal in Dory…") { openMain(.kubernetes) }
                } else {
                    Button("Enable Kubernetes") {
                        if AppInfo.componentAvailable(.kubernetes) {
                            Task { await store.enableKubernetes() }
                        } else {
                            openMain(.components)
                            store.actionError = "Install Kubernetes in Components before enabling the cluster."
                        }
                    }
                    .disabled(store.runtimeKind != .sharedVM || store.kubernetesBusy)
                }
            }
        }
        CommandMenu("Components") {
            Button("Open Components") { openMain(.components) }
            Button("Manage Components in Settings") { openSettings(.components) }
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

    private func openSettings(_ tab: SettingsTab) {
        store.settingsTab = tab
        openMain(.settings)
    }

    private func openContainer(_ container: Container, scope: ContainerScope) {
        store.revealContainer(container, scope: scope)
        store.windowOpenRequested = true
        openWindow(id: Self.openDoryWindowID)
    }

    private func startAll() {
        for container in store.containers where !container.isRunning { store.toggle(container) }
    }

    private func stopAll() {
        for container in store.containers where container.isRunning { store.toggle(container) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
