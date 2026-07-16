import Darwin
import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    let displayMode: MachineDisplayMode

    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 14)]

    var body: some View {
        content
            .sheet(item: Binding(get: { store.editMachineTarget }, set: { store.editMachineTarget = $0 })) { machine in
                MachineEditSheet(machine: machine)
            }
    }

    @ViewBuilder private var content: some View {
        if matchingMachines.isEmpty && store.filter.isEmpty {
            emptyState
        } else if matchingFilteredMachines.isEmpty {
            TableEmptyState(
                glyph: .machines,
                title: "No matches",
                message: "No \(displayMode == .desktop ? "desktops" : "servers") match \u{201C}\(store.filter)\u{201D}."
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
                    Text(displayMode == .desktop ? "No Linux desktops yet" : "No Linux servers yet")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(p.text)
                    Text(emptyMessage)
                        .font(.system(size: 13.5)).foregroundStyle(p.text2)
                        .multilineTextAlignment(.center).lineSpacing(4)
                        .frame(maxWidth: 460)
                }
                featurePills.padding(.top, 2)
                Button { store.activeSheet = displayMode == .desktop ? .newDesktop : .newMachine } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text(displayMode == .desktop ? "Create a desktop" : "Create a server")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityIdentifier(displayMode == .desktop ? "create-first-desktop" : "create-first-server")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64).padding(.bottom, 32).padding(.horizontal, 24)
        }
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            featurePill("Isolated VM", "rectangle.stack.badge.person.crop")
            if displayMode == .desktop {
                featurePill("Graphical Linux", "display")
                featurePill("Desktop console", "macwindow")
            } else {
                featurePill("Headless Linux", "terminal")
                featurePill("Service ready", "bolt.horizontal")
            }
            featurePill("Persistent disk", "internaldrive")
        }
    }

    private var emptyMessage: String {
        displayMode == .desktop
            ? "Create a graphical Linux desktop with its own display, terminal, user, resources, folders, snapshots, and persistent disk."
            : "Create a lightweight Linux server for terminals, development tools, services, and VPS-style workflows."
    }

    private var matchingMachines: [Machine] {
        store.machines.filter { $0.displayMode == displayMode }
    }

    private var matchingFilteredMachines: [Machine] {
        let filteredIDs = Set(store.filteredMachines.map(\.id))
        return matchingMachines.filter { filteredIDs.contains($0.id) }
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
                ForEach(matchingFilteredMachines) { machine in
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
    @Environment(\.openWindow) private var openWindow
    let machine: Machine
    @State private var confirmingDelete = false

    private var isRunning: Bool { machine.status == .running }
    private var hasAssignedAddress: Bool { DoryDNS.ipv4Bytes(machine.ip) != nil }

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
                    Text(hasAssignedAddress ? "ADDRESS" : "DNS NAME").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
                    Text(machine.ip).font(.mono(12.5, weight: .semibold)).foregroundStyle(isRunning ? p.accentText : p.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16).padding(.bottom, 14)

            if machine.username != "root" {
                Text("\(machine.username) · \(machine.loginShell)")
                    .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
                    .padding(.bottom, 12)
            }

            if let command = store.machineTerminalCommand(machine) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.text3)
                    Text(command).font(.mono(11)).foregroundStyle(p.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(p.text3)
                    }.buttonStyle(.plain)
                }
                .padding(.bottom, 12)
            }

            if !machine.mounts.isEmpty {
                mountsSummary
                    .padding(.bottom, 12)
            }

            Divider().overlay(p.border)

            HStack(spacing: 8) {
                actionButton(isRunning ? "stop.fill" : "play.fill", isRunning ? "Stop" : "Start", prominent: !isRunning) {
                    store.toggleMachine(machine)
                }
                if machine.displayMode == .desktop {
                    actionButton("display", "Desktop", prominent: false, enabled: store.canOpenMachineDesktop(machine)) {
                        store.openMachineDesktop(machine)
                    }
                }
                actionButton("terminal", "Terminal", prominent: false, enabled: isRunning && store.canOpenMachineTerminal(machine)) {
                    openWindow(value: store.terminalSession(for: machine))
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
            Button { store.cloneMachine(machine) } label: {
                Label("Clone…", systemImage: "doc.on.doc")
            }
            Button { store.exportMachine(machine) } label: {
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
        .disabled(store.isMachineBusy(machine.name) || !store.canUseMachineArtifacts(machine))
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

    private var mountsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(p.text3)
                Text("MOUNTED FOLDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
            }
            ForEach(Array(machine.mounts.prefix(2)).indices, id: \.self) { index in
                let mount = machine.mounts[index]
                HStack(spacing: 6) {
                    Text(mount.host).font(.mono(10.5)).foregroundStyle(p.text2).lineLimit(1).truncationMode(.head)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(p.text3)
                    Text(mount.guest).font(.mono(10.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1).truncationMode(.middle)
                    if mount.readOnly {
                        Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(p.text3)
                    }
                }
            }
            if machine.mounts.count > 2 {
                Text("+ \(machine.mounts.count - 2) more")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(p.text3)
            }
        }
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
        .disabled(store.isMachineBusy(machine.name) || !enabled)
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
        .disabled(store.isMachineBusy(machine.name))
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

private struct MachineEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    @State private var cpus = 4
    @State private var memoryGB = 4
    @State private var address = ""
    @State private var displayMode: MachineDisplayMode = .headless
    @State private var guestUsername = "dory"
    @State private var environment: [String: String] = [:]

    private struct MountRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
        var readOnly = false
    }

    @State private var mountRows: [MountRow] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    warning
                    machineTypeBlock
                    resourceRow
                    addressBlock
                    mountsBlock
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 560, height: 560)
        .background(p.bgWindow)
        .task { await load() }
    }

    private func load() async {
        let settings = await store.machineSettings(machine.name)
        cpus = max(1, min(8, settings.cpus ?? 4))
        memoryGB = max(1, min(16, settings.memoryMB.map { $0 / 1024 } ?? 4))
        address = settings.address ?? ""
        displayMode = settings.displayMode
        environment = settings.env
        guestUsername = settings.env["DORY_GUEST_USER"] ?? "dory"
        mountRows = settings.mounts.map { MountRow(host: $0.host, guest: $0.guest, readOnly: $0.readOnly) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit \(machine.name)").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text("Apply user, resources, address and mounted folders").font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var warning: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle.fill").font(.system(size: 13)).foregroundStyle(p.accent)
            Text("Resource, user and mount changes restart a running machine automatically. The machine type is fixed to protect its existing disk.")
                .font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private var machineTypeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("MACHINE TYPE")
            HStack(spacing: 10) {
                Image(systemName: displayMode == .desktop ? "display" : "terminal.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 34, height: 34)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayMode == .desktop ? "Desktop Linux" : "Headless Linux")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Text(displayMode == .desktop ? "Debian 13 + Xfce" : "Lightweight Dory Linux")
                        .font(.system(size: 11)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                if displayMode == .desktop {
                    TextField("dory", text: $guestUsername)
                        .textFieldStyle(.plain)
                        .font(.mono(11.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(width: 160)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(guestUsernameInvalid ? p.red : p.border))
                        .accessibilityIdentifier("edit-machine-guest-user")
                }
            }
            .padding(11)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
            if guestUsernameInvalid {
                Text("Use 1–32 lowercase letters, numbers, underscores or dashes; start with a letter or underscore.")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
        }
    }

    private var resourceRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("CPUS")
                Stepper(value: $cpus, in: 1...8) {
                    Text("\(cpus) \(cpus == 1 ? "core" : "cores")")
                        .font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("edit-machine-cpus")
                .frame(width: 180)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("MEMORY")
                Stepper(value: $memoryGB, in: 1...16) {
                    Text("\(memoryGB) GB").font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("edit-machine-memory")
                .frame(width: 180)
            }
            Spacer(minLength: 0)
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DNS TARGET OVERRIDE")
            fieldInput("192.168.215.42", text: $address, width: 260)
            Text("Advanced: override the address reported by the guest for \(machine.name).dory.local. Leave blank to clear.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
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
                    modeButton(readOnly: $row.readOnly)
                    removeButton { mountRows.removeAll { $0.id == row.id } }
                }
            }
            if mountRows.isEmpty {
                Text("Share host folders into the machine.")
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
                    if store.isMachineBusy(machine.name) { ProgressView().controlSize(.small) }
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Apply").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(p.accent.opacity(store.isMachineBusy(machine.name) ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.isMachineBusy(machine.name) || guestUsernameInvalid)
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

    private func modeButton(readOnly: Binding<Bool>) -> some View {
        Button {
            readOnly.wrappedValue.toggle()
        } label: {
            Image(systemName: readOnly.wrappedValue ? "lock" : "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(readOnly.wrappedValue ? p.amber : p.text3)
                .frame(width: 26, height: 26)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .help(readOnly.wrappedValue ? "Read-only" : "Read-write")
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
        var mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest, readOnly: row.readOnly)
        }
        if displayMode == .desktop {
            let previousUsername = environment["DORY_GUEST_USER"] ?? "dory"
            if previousUsername != normalizedGuestUsername {
                let previousHome = "/home/\(previousUsername)"
                let updatedHome = "/home/\(normalizedGuestUsername)"
                mounts = mounts.map { mount in
                    guard mount.guest == previousHome || mount.guest.hasPrefix(previousHome + "/") else {
                        return mount
                    }
                    return MountPair(
                        host: mount.host,
                        guest: updatedHome + String(mount.guest.dropFirst(previousHome.count)),
                        readOnly: mount.readOnly
                    )
                }
            }
            environment["DORY_GUEST_USER"] = normalizedGuestUsername
            environment["DORY_GUEST_UID"] = environment["DORY_GUEST_UID"] ?? String(getuid())
        }
        let settings = MachineSettings(
            cpus: cpus,
            memoryMB: memoryGB * 1024,
            mounts: mounts,
            env: environment,
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            displayMode: displayMode
        )
        let target = machine
        store.editMachineTarget = nil
        Task { _ = await store.editMachine(target, settings: settings) }
    }

    private var normalizedGuestUsername: String {
        guestUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var guestUsernameInvalid: Bool {
        guard displayMode == .desktop else { return false }
        return normalizedGuestUsername.range(
            of: "^[a-z_][a-z0-9_-]{0,31}$",
            options: .regularExpression
        ) == nil
    }
}
