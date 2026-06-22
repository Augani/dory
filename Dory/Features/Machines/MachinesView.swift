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
                    Text("\(machine.distro) \(machine.version)").font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
                }
                Spacer(minLength: 8)
                statusPill
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
            ContainerTerminalView(socketPath: store.shimSocketPath, containerID: machine.containerID)
                .frame(minWidth: 720, minHeight: 420)
        }
        .frame(width: 760, height: 480)
        .background(p.bgWindow)
    }
}
