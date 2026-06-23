import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)]

    var body: some View {
        content
            .sheet(item: Binding(get: { store.machineTerminal }, set: { store.machineTerminal = $0 })) { machine in
                MachineTerminalSheet(machine: machine)
            }
            .sheet(item: Binding(get: { store.editMachineTarget }, set: { store.editMachineTarget = $0 })) { machine in
                MachineEditSheet(machine: machine)
            }
    }

    @ViewBuilder private var content: some View {
        if store.machines.isEmpty && store.filter.isEmpty {
            emptyState
        } else if store.filteredMachines.isEmpty {
            TableEmptyState(
                glyph: .machines,
                title: "No matches",
                message: "No machines match \u{201C}\(store.filter)\u{201D}."
            )
        } else {
            machineGrid
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Glyph(glyph: .machines, size: 44, color: p.accent)
                    .frame(width: 78, height: 78)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                VStack(spacing: 8) {
                    Text("No Linux machines yet").font(.system(size: 22, weight: .bold)).foregroundStyle(p.text)
                    Text("Spin up a full Linux distro — Ubuntu, Debian, Fedora, Rocky, openSUSE and more — each with systemd and an instant root shell, running inside Dory's engine.")
                        .font(.system(size: 13.5)).foregroundStyle(p.text2)
                        .multilineTextAlignment(.center).lineSpacing(4)
                        .frame(maxWidth: 460)
                }
                featurePills.padding(.top, 2)
                Button { store.activeSheet = .newMachine } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Create a machine").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityIdentifier("create-first-machine")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64).padding(.bottom, 32).padding(.horizontal, 24)
        }
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            featurePill("systemd", "gearshape.2")
            featurePill("Root shell", "terminal")
            featurePill("Persistent disk", "internaldrive")
            featurePill("Apple Silicon", "cpu")
        }
    }

    private func featurePill(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(p.text2)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(p.pill, in: Capsule())
    }

    private var machineGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(store.filteredMachines) { machine in
                    MachineCard(machine: machine)
                }
            }
            .padding(18)
        }
    }
}

private struct MachineCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine
    @State private var confirmingDelete = false

    private var isRunning: Bool { machine.status == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                distroBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(machine.distro) \(machine.version)").font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
                        if machine.isEmulated {
                            Text(machine.arch.uppercased())
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(p.amber).tracking(0.3)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(p.amberWeak, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                Spacer(minLength: 8)
                statusPill
                overflowMenu
            }

            HStack(alignment: .top, spacing: 0) {
                metric("CPU", isRunning ? String(format: "%.1f%%", machine.cpuPercent) : "—")
                metric("MEMORY", isRunning ? machine.memoryDisplay : "—")
                VStack(alignment: .leading, spacing: 3) {
                    Text("ADDRESS").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
                    Text(machine.ip).font(.mono(12.5, weight: .semibold)).foregroundStyle(isRunning ? p.accentText : p.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16).padding(.bottom, 14)

            if machine.username != "root" {
                Text("\(machine.username) · \(machine.loginShell) · ~ shared")
                    .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
                    .padding(.bottom, 12)
            }

            Divider().overlay(p.border)

            HStack(spacing: 8) {
                actionButton(isRunning ? "stop.fill" : "play.fill", isRunning ? "Stop" : "Start", prominent: !isRunning) {
                    store.toggleMachine(machine)
                }
                actionButton("terminal", "Terminal", prominent: false, enabled: isRunning) {
                    store.openMachineTerminal(machine)
                }
                iconButton("trash") { confirmingDelete = true }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.border))
        .confirmationDialog("Delete machine \(machine.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteMachine(machine) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the Linux machine and its disk. This cannot be undone.")
        }
    }

    private var distroBadge: some View {
        Group {
            if let logo = logoName(for: machine.distro) {
                Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 30, height: 30)
            } else {
                Text(machine.letter)
                    .font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(machine.badgeColor, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(width: 44, height: 44)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border))
    }

    private var overflowMenu: some View {
        Menu {
            Button { store.takeSnapshot(machine, note: "") } label: {
                Label("Snapshot", systemImage: "camera.aperture")
            }
            Button { store.openSnapshots(machine) } label: {
                Label("Snapshots…", systemImage: "clock.arrow.circlepath")
            }
            Divider()
            Button { store.openSnapshots(machine) } label: {
                Label("Clone…", systemImage: "doc.on.doc")
            }
            Button { store.openSnapshots(machine) } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Button { store.openMachineEdit(machine) } label: {
                Label("Edit…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .fixedSize()
        .disabled(store.machineBusy)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(machine.status.dotColor(p)).frame(width: 6, height: 6)
            Text(machine.status.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(machine.status.dotColor(p))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(machine.status.badgeBackground(p), in: Capsule())
        .fixedSize()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
            Text(value).font(.system(size: 14.5, weight: .bold)).monospacedDigit().foregroundStyle(p.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(_ systemImage: String, _ title: String, prominent: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? p.accentText : p.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(prominent ? p.accentSoft : p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? p.accentWeak : p.border))
        }
        .buttonStyle(.plain)
        .disabled(store.machineBusy || !enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func iconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.red)
                .frame(width: 34, height: 30)
                .background(p.redWeak, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .disabled(store.machineBusy)
        .help("Delete machine")
    }
}

private func logoName(for distro: String) -> String? {
    let lower = distro.lowercased()
    for family in ["ubuntu", "debian", "fedora", "alpine", "rocky", "alma", "opensuse", "oracle", "amazon", "kali", "centos", "arch"] {
        if lower.contains(family) { return "logo-\(family)" }
    }
    return nil
}

private struct MachineTerminalSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let logo = logoName(for: machine.distro) {
                    Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text("\(machine.distro) \(machine.version) · \(machine.ip)").font(.system(size: 11)).foregroundStyle(p.text3)
                }
                Spacer()
                Button { store.openMachineTerminalApp(machine) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                        Text("Terminal.app").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(p.accentText)
                }
                .buttonStyle(.plain)
                Button { store.machineTerminal = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(p.text2)
                        .frame(width: 26, height: 26)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(p.bgElevated)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            ContainerTerminalView(socketPath: store.shimSocketPath, containerID: machine.containerID,
                                  user: machine.username, shell: machine.loginShell, home: machine.username == "root" ? "/root" : "/Users/\(machine.username)")
                .frame(minWidth: 720, minHeight: 420)
        }
        .frame(width: 760, height: 480)
        .background(p.bgWindow)
    }
}

private struct MachineEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    @State private var cpus = 4
    @State private var memoryGB = 4

    private struct MountRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
    }

    private struct PortRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
    }

    @State private var mountRows: [MountRow] = []
    @State private var portRows: [PortRow] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    warning
                    resourceRow
                    mountsBlock
                    portsBlock
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 540, height: 520)
        .background(p.bgWindow)
        .task { await load() }
    }

    private func load() async {
        let settings = await store.machineSettings(machine.name)
        cpus = max(1, min(8, settings.cpus ?? 4))
        memoryGB = max(1, min(16, settings.memoryMB.map { $0 / 1024 } ?? 4))
        mountRows = settings.mounts.map { MountRow(host: $0.host, guest: $0.guest) }
        portRows = settings.ports.map { PortRow(host: String($0.host), guest: String($0.guest)) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit \(machine.name)").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text("Apply new resources, mounts and ports").font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var warning: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle.fill").font(.system(size: 13)).foregroundStyle(p.accent)
            Text("Applying snapshots the machine, then recreates it with these settings. Your data is preserved.")
                .font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private var resourceRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("CPUS")
                Stepper(value: $cpus, in: 1...8) {
                    Text("\(cpus) \(cpus == 1 ? "core" : "cores")")
                        .font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .frame(width: 180)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("MEMORY")
                Stepper(value: $memoryGB, in: 1...16) {
                    Text("\(memoryGB) GB").font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .frame(width: 180)
            }
            Spacer(minLength: 0)
        }
    }

    private var mountsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("MOUNTED FOLDERS")
                Spacer(minLength: 0)
                addButton { mountRows.append(MountRow()) }
            }
            ForEach($mountRows) { $row in
                HStack(spacing: 8) {
                    Button { chooseMountHost(for: row.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(p.text3)
                            Text(row.host.isEmpty ? "Host folder…" : row.host)
                                .font(.mono(11.5)).foregroundStyle(row.host.isEmpty ? p.text3 : p.text)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(p.text3)
                    fieldInput("/guest/path", text: $row.guest, width: 150)
                    removeButton { mountRows.removeAll { $0.id == row.id } }
                }
            }
            if mountRows.isEmpty {
                Text("Share host folders into the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var portsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("EXPOSED PORTS")
                Spacer(minLength: 0)
                addButton { portRows.append(PortRow()) }
            }
            ForEach($portRows) { $row in
                HStack(spacing: 8) {
                    fieldInput("8080", text: $row.host, width: 90)
                    Text("host").font(.system(size: 10.5)).foregroundStyle(p.text3)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(p.text3)
                    fieldInput("80", text: $row.guest, width: 90)
                    Text("guest").font(.system(size: 10.5)).foregroundStyle(p.text3)
                    Spacer(minLength: 0)
                    removeButton { portRows.removeAll { $0.id == row.id } }
                }
            }
            if portRows.isEmpty {
                Text("Publish machine ports to localhost.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)
            Button("Cancel") { store.editMachineTarget = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            Button(action: apply) {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Apply").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(p.accent.opacity(store.machineBusy ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.machineBusy)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
    }

    private func fieldInput(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.mono(11.5)).foregroundStyle(p.text)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width)
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accent)
                .frame(width: 22, height: 22)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(p.text3)
        }
        .buttonStyle(.plain)
    }

    private func chooseMountHost(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a host folder to mount into the machine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = mountRows.firstIndex(where: { $0.id == id }) else { return }
        mountRows[index].host = url.path
        if mountRows[index].guest.isEmpty {
            mountRows[index].guest = "/mnt/\(url.lastPathComponent)"
        }
    }

    private func apply() {
        let mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest)
        }
        let ports = portRows.compactMap { row -> PortPair? in
            guard let host = Int(row.host.trimmingCharacters(in: .whitespaces)),
                  let guest = Int(row.guest.trimmingCharacters(in: .whitespaces)),
                  host > 0, guest > 0 else { return nil }
            return PortPair(host: host, guest: guest)
        }
        let settings = MachineSettings(cpus: cpus, memoryMB: memoryGB * 1024, mounts: mounts, ports: ports)
        let target = machine
        store.editMachineTarget = nil
        Task { _ = await store.editMachine(target, settings: settings) }
    }
}
