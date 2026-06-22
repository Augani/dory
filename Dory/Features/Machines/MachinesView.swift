import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        content
            .sheet(item: Binding(get: { store.machineTerminal }, set: { store.machineTerminal = $0 })) { machine in
                MachineTerminalSheet(machine: machine)
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !store.machines.isEmpty || !store.filter.isEmpty {
                header
            }
            if store.machines.isEmpty && store.filter.isEmpty {
                emptyGallery
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
    }

    private var header: some View {
        HStack {
            Text("Linux machines").font(.system(size: 12.5)).foregroundStyle(p.text3)
            Spacer()
            Button { store.activeSheet = .newMachine } label: {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Text(store.machineBusy ? "Creating\u{2026}" : "New Machine").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.machineBusy)
            .accessibilityIdentifier("new-machine")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var emptyGallery: some View {
        ScrollView {
            VStack(spacing: 18) {
                Glyph(glyph: .machines, size: 48, color: p.accent)
                    .frame(width: 80, height: 80)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                Text("Linux machines").font(.system(size: 26, weight: .bold)).foregroundStyle(p.text)
                Text("Spin up full Ubuntu, Debian, Fedora, Rocky, openSUSE, and more — each with systemd and an instant root shell. Use them for testing services, running CI locally, or any workload that needs a real Linux environment.")
                    .font(.system(size: 13.5)).foregroundStyle(p.text2).multilineTextAlignment(.center).lineSpacing(4)
                    .frame(maxWidth: 520)
                featurePills
                createFirstButton
                    .padding(.top, 6)
                quickPickChips
            }
            .padding(.top, 36).padding(.bottom, 24)
            .padding(.horizontal, 18)
        }
    }

    private var createFirstButton: some View {
        Button { store.activeSheet = .newMachine } label: {
            Text("Create your first machine")
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(p.accent, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(store.machineBusy)
        .accessibilityIdentifier("create-first-machine")
    }

    private var quickPickChips: some View {
        HStack(spacing: 8) {
            ForEach(MachineDistro.families.prefix(5)) { family in
                Button { store.activeSheet = .newMachine } label: {
                    HStack(spacing: 7) {
                        familyBadge(family)
                        Text(family.display).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                .buttonStyle(.plain)
                .disabled(store.machineBusy)
            }
        }
    }

    private func familyBadge(_ family: MachineFamily) -> some View {
        Group {
            if let logo = logoName(for: family.id) {
                Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            } else {
                Text(family.letter)
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color(hex: family.badgeHex), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            featurePill("systemd")
            featurePill("Root shell")
            featurePill("Persistent disk")
            featurePill("Apple Silicon")
        }
    }

    private func featurePill(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(p.pill, in: RoundedRectangle(cornerRadius: 6))
    }

    private var machineGrid: some View {
        ScrollView {
            VStack(spacing: 24) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.filteredMachines) { machine in
                        MachineCard(machine: machine)
                    }
                }
                if store.filter.isEmpty {
                    addAnotherSection
                }
            }
            .padding(18)
        }
    }

    private var addAnotherSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add another machine").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
            Button { store.activeSheet = .newMachine } label: {
                Text("New machine")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.accentText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            }
            .buttonStyle(.plain)
            .disabled(store.machineBusy)
            .accessibilityIdentifier("add-another-machine")
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct MachineCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let logo = logoName(for: machine.distro) {
                    Image(logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                } else {
                    Text(machine.letter)
                        .font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(machine.badgeColor, in: RoundedRectangle(cornerRadius: 11))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name).font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                    Text("\(machine.distro) \(machine.version)").font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                StatusBadge(label: machine.status.label, color: machine.status.dotColor(p), background: machine.status.badgeBackground(p))
            }

            HStack(alignment: .top, spacing: 18) {
                metric("CPU", String(format: "%.1f%%", machine.cpuPercent))
                metric("MEMORY", machine.memoryDisplay)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ADDRESS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3)
                    Text(machine.ip).font(.mono(12.5, weight: .semibold)).foregroundStyle(p.accentText).lineLimit(1)
                }
            }
            .padding(.vertical, 13)

            HStack(spacing: 7) {
                cardButton(machine.actionLabel) { store.toggleMachine(machine) }
                cardButton("Terminal") { store.openMachineTerminal(machine) }
                cardButton("Delete") { confirmingDelete = true }
            }
            .disabled(store.machineBusy)
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
        }
        .padding(16)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(p.border))
        .confirmationDialog("Delete machine \(machine.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteMachine(machine) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the Linux machine and its disk. This cannot be undone.")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3)
            Text(value).font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(p.text)
        }
    }

    private func cardButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
    }
}

private func logoName(for distro: String) -> String? {
    let lower = distro.lowercased()
    if lower.contains("ubuntu") { return "logo-ubuntu" }
    if lower.contains("debian") { return "logo-debian" }
    if lower.contains("fedora") { return "logo-fedora" }
    if lower.contains("alpine") { return "logo-alpine" }
    return nil
}

private struct MachineTerminalSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(machine.name) — \(machine.distro) \(machine.version)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Button("Open in Terminal.app ↗") { store.openMachineTerminalApp(machine) }
                    .buttonStyle(.plain).foregroundStyle(p.accentText).font(.system(size: 12, weight: .semibold))
                Button("Close") { store.machineTerminal = nil }
                    .buttonStyle(.plain).foregroundStyle(p.text2).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            ContainerTerminalView(socketPath: store.shimSocketPath, containerID: machine.containerID)
                .frame(minWidth: 720, minHeight: 420)
        }
        .frame(width: 760, height: 480)
        .background(p.bgWindow)
    }
}
