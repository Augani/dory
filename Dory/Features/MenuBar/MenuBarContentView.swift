import DoryOperations
import SwiftUI

struct MenuBarActions {
    var closePopover: () -> Void
    var openMainWindow: () -> Void
    var openTerminal: (TerminalSession) -> Void

    static let noop = MenuBarActions(closePopover: {}, openMainWindow: {}, openTerminal: { _ in })
}

struct MenuBarContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let actions: MenuBarActions
    @State private var servicesExpanded = true
    @State private var composeExpanded = true
    @State private var machinesExpanded = true
    @State private var kubernetesExpanded = true
    @State private var runtimeExpanded = true
    @State private var toolsExpanded = true
    @State private var memoryExpanded = true

    private func refreshPopover() {
        Task { await store.refreshMenuBar() }
    }

    private func closePopover() {
        actions.closePopover()
    }

    private func showMainWindow() {
        closePopover()
        store.windowOpenRequested = true
        actions.openMainWindow()
    }

    private func openSection(_ section: AppSection) {
        store.section = section
        showMainWindow()
    }

    private func openSettings(_ tab: SettingsTab) {
        store.settingsTab = tab
        openSection(.settings)
    }

    private func openContainer(_ container: Container, scope: ContainerScope = .all) {
        store.selectedContainerID = container.id
        store.setContainerScope(scope)
        openSection(.containers)
    }

    private func openTerminal(_ container: Container) {
        closePopover()
        actions.openTerminal(store.terminalSession(for: container))
    }

    private func openMachineTerminal(_ machine: Machine) {
        guard store.canOpenMachineTerminal(machine) else { return }
        closePopover()
        actions.openTerminal(store.terminalSession(for: machine))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            menuContent
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 340)
        .environment(\.palette, store.palette)
        .background(store.palette.bgWindow)
        .onAppear { refreshPopover() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DoryLogo(size: 28, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dory").font(.system(size: 13, weight: .bold)).foregroundStyle(p.text)
                Text("\(engineSummary) · \(store.processMemorySnapshot.totalResidentDisplay)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(engineStatusColor())
            }
            Spacer(minLength: 0)
            Button { refreshPopover() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.text3)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
    }

    private var orderedServices: [Container] {
        store.containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var runningServices: [Container] {
        orderedServices.filter(\.isRunning)
    }

    private var composeProjects: [(name: String, services: [Container])] {
        let grouped = Dictionary(grouping: store.containers.filter { $0.composeProject != nil }, by: { $0.composeProject ?? "" })
        return grouped.keys.sorted().map { name in (name, store.containers(inComposeProject: name)) }
    }

    private var orderedMachines: [Machine] {
        store.machines.sorted {
            if $0.status != $1.status { return $0.status == .running }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var menuContent: some View {
        ScrollView {
            VStack(spacing: 8) {
                runtimeSection
                localToolsSection
                memorySection
                servicesSection
                composeSection
                machinesSection
                kubernetesSection
            }
            .padding(8)
        }
        .frame(maxHeight: 430)
    }

    private var engineSummary: String {
        engineStatus.title
    }

    private var engineStatus: EnginePopoverStatus {
        EnginePopoverStatus(
            loadState: store.loadState,
            running: store.engineRunning,
            sleeping: store.engineSleeping,
            detail: store.sharedVMStatus
        )
    }

    private func engineStatusColor(_ status: EnginePopoverStatus? = nil) -> Color {
        switch (status ?? engineStatus).tone {
        case .running: p.green
        case .sleeping, .starting: p.amber
        case .off: p.text3
        case .error: p.red
        }
    }

    private var runtimeSection: some View {
        let engine = engineStatus
        return quickSection(
            title: "Daemon & Engine",
            subtitle: "\(engine.title) · \(store.runtimeMode)",
            systemImage: "bolt.horizontal.circle",
            expanded: $runtimeExpanded,
            open: { openSection(.health) }
        ) {
            quickRow(
                dot: store.dorydRuntimeActive ? p.green : p.text3,
                title: "doryd",
                subtitle: store.runtimeAuthorityDisplay,
                value: store.dorydRuntimeRequired ? "required" : "optional"
            ) {
                rowIcon("stethoscope", "Open Health") { openSection(.health) }
            }
            quickRow(
                dot: engineStatusColor(engine),
                title: "Engine",
                subtitle: engine.subtitle,
                value: engine.value
            ) {
                rowIcon("gearshape", "Engine Settings") { openSettings(.engine) }
            }
        }
    }

    private var localToolsSection: some View {
        let stableTools = store.localDorydCapabilities.filter { $0.status == "Stable" }
        return quickSection(
            title: "Local Tools",
            subtitle: "Doctor, agent, MCP, events",
            systemImage: "wrench.and.screwdriver",
            expanded: $toolsExpanded,
            open: { openSettings(.localTools) }
        ) {
            ForEach(stableTools.prefix(4)) { capability in
                quickRow(
                    dot: p.green,
                    title: capability.title,
                    subtitle: capability.summary,
                    value: capability.status
                ) {
                    rowIcon("doc.on.doc", "Copy \(capability.title)") { copy(capability.command) }
                }
            }
            moreLine("Open all local tools") { openSettings(.localTools) }
        }
    }

    private var memorySection: some View {
        let snapshot = store.processMemorySnapshot
        return quickSection(
            title: "Dory Memory",
            subtitle: "\(snapshot.totalResidentDisplay) resident",
            systemImage: "memorychip",
            expanded: $memoryExpanded,
            open: { openSection(.health) }
        ) {
            if snapshot.groupedRows.isEmpty {
                emptyLine("No Dory processes found")
            } else {
                ForEach(snapshot.groupedRows.prefix(5)) { row in
                    quickRow(
                        dot: memoryDot(row.role),
                        title: row.title,
                        subtitle: row.subtitle,
                        value: row.residentDisplay
                    ) {
                        EmptyView()
                    }
                }
                if snapshot.duplicateAppInstanceCount > 0 {
                    moreLine("\(snapshot.duplicateAppInstanceCount) extra app instance\(snapshot.duplicateAppInstanceCount == 1 ? "" : "s") detected") {
                        openSection(.health)
                    }
                }
            }
        }
    }

    private var servicesSection: some View {
        quickSection(
            title: "Running Services",
            subtitle: "\(runningServices.count) running",
            systemImage: "shippingbox",
            expanded: $servicesExpanded,
            open: { openSection(.containers) }
        ) {
            if runningServices.isEmpty {
                emptyLine("No running services")
            } else {
                ForEach(runningServices.prefix(5)) { container in
                    quickRow(
                        dot: container.status.dotColor(p),
                        title: container.composeService ?? container.name,
                        subtitle: container.composeProject ?? container.image,
                        value: String(format: "%.1f%%", container.cpuPercent)
                    ) {
                        rowIcon(container.isRunning ? "stop.fill" : "play.fill", container.isRunning ? "Stop" : "Start") {
                            store.toggle(container)
                        }
                        Menu {
                            Button("Open Details") { openContainer(container, scope: container.composeProject == nil ? .all : .compose) }
                            Button("Open Terminal") { openTerminal(container) }
                                .disabled(!container.isRunning)
                            Button("Restart") { store.restart(container) }
                                .disabled(!container.isRunning)
                        } label: {
                            chevronLabel
                        }
                        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }

                if runningServices.count > 5 {
                    moreLine("+\(runningServices.count - 5) more services") { openSection(.containers) }
                }
            }
        }
    }

    private var composeSection: some View {
        quickSection(
            title: "Compose Stacks",
            subtitle: "\(composeProjects.count) stacks",
            systemImage: "square.stack.3d.up",
            expanded: $composeExpanded,
            open: { openSection(.compose) }
        ) {
            if composeProjects.isEmpty {
                emptyLine("No Compose stacks")
            } else {
                ForEach(composeProjects.prefix(4), id: \.name) { project in
                    let running = project.services.filter(\.isRunning).count
                    quickRow(
                        dot: running > 0 ? p.green : p.text3,
                        title: project.name,
                        subtitle: "\(running) of \(project.services.count) services running",
                        value: "Compose"
                    ) {
                        if running < project.services.count {
                            rowIcon("play.fill", "Start \(project.name)") { store.startComposeProject(project.name) }
                        }
                        if running > 0 {
                            rowIcon("stop.fill", "Stop \(project.name)") { store.stopComposeProject(project.name) }
                        }
                        Menu {
                            Button("Open Stack") {
                                if let first = project.services.first { openContainer(first, scope: .compose) }
                                else { openSection(.compose) }
                            }
                            Button("Restart Running") { store.restartComposeProject(project.name) }
                                .disabled(running == 0)
                            Button("Down - stop and remove", role: .destructive) { Task { await store.composeDown(project.name) } }
                        } label: {
                            chevronLabel
                        }
                        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                if composeProjects.count > 4 {
                    moreLine("+\(composeProjects.count - 4) more stacks") { openSection(.compose) }
                }
            }
        }
    }

    private var machinesSection: some View {
        let running = store.machines.filter { $0.status == .running }.count
        return quickSection(
            title: "Machines",
            subtitle: "\(running) running · \(store.machines.count) total",
            systemImage: "terminal",
            expanded: $machinesExpanded,
            open: { openSection(.machines) }
        ) {
            if store.machines.isEmpty {
                emptyLine("No Linux machines")
            } else {
                ForEach(orderedMachines.prefix(4)) { machine in
                    quickRow(
                        dot: machine.status.dotColor(p),
                        title: machine.name,
                        subtitle: "\(machine.distro) \(machine.version)",
                        value: machine.status == .running ? machine.memoryDisplay : machine.status.label
                    ) {
                        rowIcon(machine.status == .running ? "stop.fill" : "play.fill", machine.actionLabel) {
                            store.toggleMachine(machine)
                        }
                        Menu {
                            Button("Open Machines") { openSection(.machines) }
                            Button("Open Terminal") { openMachineTerminal(machine) }
                                .disabled(machine.status != .running || !store.canOpenMachineTerminal(machine))
                            if let command = store.machineTerminalCommand(machine) {
                                Button("Copy Command") { copy(command) }
                            }
                            Button(DoryDNS.ipv4Bytes(machine.ip) != nil ? "Copy Address" : "Copy DNS Name") { copy(machine.ip) }
                            Button("Edit Address") {
                                store.openMachineEdit(machine)
                                openSection(.machines)
                            }
                        } label: {
                            chevronLabel
                        }
                        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                if store.machines.count > 4 {
                    moreLine("+\(store.machines.count - 4) more machines") { openSection(.machines) }
                }
            }
        }
    }

    private var kubernetesSection: some View {
        quickSection(
            title: "Kubernetes",
            subtitle: store.kubernetesReachable ? store.kubernetesInfo : "Cluster not running",
            systemImage: "hexagon",
            expanded: $kubernetesExpanded,
            open: { openSection(.kubernetes) }
        ) {
            quickRow(
                dot: store.kubernetesReachable ? p.green : p.text3,
                title: store.kubernetesReachable ? "Cluster ready" : "Cluster off",
                subtitle: store.kubernetesReachable ? "\(store.pods.count) pods" : "Start k3s inside Dory",
                value: store.kubernetesBusy ? "Busy" : ""
            ) {
                if store.kubernetesBusy {
                    ProgressView().controlSize(.small).frame(width: 24, height: 22)
                } else if store.kubernetesReachable {
                    rowIcon("arrow.clockwise", "Refresh Kubernetes") { Task { await store.loadKubernetes() } }
                    Menu {
                        Button("Open Kubernetes") { openSection(.kubernetes) }
                        Button("Disable Kubernetes", role: .destructive) { Task { await store.disableKubernetes() } }
                    } label: {
                        chevronLabel
                    }
                    .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                } else {
                    rowIcon("play.fill", AppInfo.componentAvailable(.kubernetes) ? "Enable Kubernetes" : "Get Kubernetes") {
                        if AppInfo.componentAvailable(.kubernetes) {
                            Task { await store.enableKubernetes() }
                        } else {
                            openSection(.components)
                        }
                    }
                    Menu {
                        Button("Open Kubernetes") { openSection(.kubernetes) }
                    } label: {
                        chevronLabel
                    }
                    .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }

    private func memoryDot(_ role: DoryProcessRole) -> Color {
        switch role {
        case .app: p.accentText
        case .daemon: p.green
        case .dockerVM: engineStatusColor()
        case .machineVM: p.green
        case .networking: p.accent
        case .helper: p.text3
        }
    }

    private func quickSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        expanded: Binding<Bool>,
        open: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.accentText)
                    .frame(width: 24, height: 24)
                    .background(p.accentWeak, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(p.text)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(p.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: open) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.text3)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open \(title)")
                Button { expanded.wrappedValue.toggle() } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.text3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            if expanded.wrappedValue {
                VStack(spacing: 0) { content() }
                    .padding(.bottom, 5)
            }
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
    }

    private func quickRow<Actions: View>(
        dot: Color,
        title: String,
        subtitle: String,
        value: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: dot, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !value.isEmpty {
                Text(value).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(p.text3)
                    .lineLimit(1)
            }
            actions()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func rowIcon(_ image: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(p.text2)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var chevronLabel: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(p.text3)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(p.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func moreLine(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.accentText)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(p.accentText)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { showMainWindow() } label: {
                Text("Open Dory").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.accentText)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { Rectangle().fill(p.border).frame(width: 1) }
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Dory").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
    }
}

private enum EnginePopoverTone {
    case running
    case sleeping
    case starting
    case off
    case error
}

private struct EnginePopoverStatus {
    var title: String
    var subtitle: String
    var value: String
    var tone: EnginePopoverTone

    init(loadState: LoadState, running: Bool, sleeping: Bool, detail: String) {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if sleeping {
            title = "Engine sleeping"
            subtitle = trimmedDetail.isEmpty ? "Docker use wakes it" : trimmedDetail
            value = "sleeping"
            tone = .sleeping
        } else if running || loadState == .ready {
            title = "Engine running"
            subtitle = trimmedDetail.isEmpty ? "Docker API is reachable" : trimmedDetail
            value = "running"
            tone = .running
        } else if loadState == .connecting {
            title = "Engine starting"
            subtitle = trimmedDetail.isEmpty ? "Waiting for doryd" : trimmedDetail
            value = "starting"
            tone = .starting
        } else if Self.detailLooksLikeError(trimmedDetail) {
            title = "Engine needs attention"
            subtitle = trimmedDetail.isEmpty ? "Open Health for details" : trimmedDetail
            value = "error"
            tone = .error
        } else {
            title = "Engine off"
            subtitle = trimmedDetail.isEmpty ? "Start Dory's engine to use Docker" : trimmedDetail
            value = "off"
            tone = .off
        }
    }

    private static func detailLooksLikeError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("could not")
            || lowered.contains("failed")
            || lowered.contains("failure")
            || lowered.contains("unavailable")
            || lowered.contains("did not answer")
            || lowered.contains("no docker")
            || lowered.contains("error")
    }
}
