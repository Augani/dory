import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let distros: [(label: String, image: String)] = [
        ("Ubuntu 24.04", "ubuntu:24.04"), ("Debian 12", "debian:12"),
        ("Fedora 40", "fedora:40"), ("Alpine 3.20", "alpine:3.20"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.filteredMachines) { machine in
                        MachineCard(machine: machine)
                    }
                }
                .padding(18)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Full Linux machines with systemd & SSH").font(.system(size: 12.5)).foregroundStyle(p.text3)
            Spacer()
            Menu {
                ForEach(distros, id: \.image) { distro in
                    Button(distro.label) {
                        Task { _ = await store.createMachine(image: distro.image, name: Self.autoName(distro.label)) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Text(store.machineBusy ? "Creating…" : "New Machine").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.machineBusy)
            .accessibilityIdentifier("new-machine")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private static func autoName(_ label: String) -> String {
        let base = label.split(separator: " ").first.map { $0.lowercased() } ?? "linux"
        return "\(base)-\(abs(label.hashValue) % 1000)"
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
                Text(machine.letter)
                    .font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(machine.badgeColor, in: RoundedRectangle(cornerRadius: 11))
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
