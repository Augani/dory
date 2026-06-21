import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let templates: [MachineTemplate] = [
        MachineTemplate(image: "ubuntu:24.04", logo: "logo-ubuntu", name: "Ubuntu", version: "24.04 LTS", isKnownSupported: false,
                        description: "Long-term support release. Great for development, servers, and everyday Linux workloads."),
        MachineTemplate(image: "debian:12", logo: "logo-debian", name: "Debian", version: "12", isKnownSupported: false,
                        description: "Stable and lightweight. Ideal for testing and production-like environments."),
        MachineTemplate(image: "fedora:40", logo: "logo-fedora", name: "Fedora", version: "40", isKnownSupported: false,
                        description: "Bleeding-edge packages and the latest kernel. Perfect for trying new Linux features."),
        MachineTemplate(image: "alpine:3.20", logo: "logo-alpine", name: "Alpine", version: "3.20", isKnownSupported: true,
                        description: "Minimal and security-focused. Excellent for containers and resource-constrained work."),
    ]

    var body: some View {
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
            Menu {
                ForEach(templates) { template in
                    Button("\(template.name) \(template.version)") {
                        Task { _ = await store.createMachine(image: template.image, name: Self.autoName(template.name)) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Text(store.machineBusy ? "Creating\u{2026}" : "New Machine").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
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

    private var emptyGallery: some View {
        ScrollView {
            VStack(spacing: 18) {
                Glyph(glyph: .machines, size: 48, color: p.accent)
                    .frame(width: 80, height: 80)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                Text("Linux machines").font(.system(size: 26, weight: .bold)).foregroundStyle(p.text)
                Text("Spin up full Ubuntu, Debian, Fedora, or Alpine VMs with systemd and SSH. Use them for testing services, running CI locally, or any workload that needs a real Linux environment.")
                    .font(.system(size: 13.5)).foregroundStyle(p.text2).multilineTextAlignment(.center).lineSpacing(4)
                    .frame(maxWidth: 520)
                featurePills
                templateList
                    .padding(.top, 10)
            }
            .padding(.top, 36).padding(.bottom, 24)
            .padding(.horizontal, 18)
        }
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            featurePill("systemd")
            featurePill("SSH")
            featurePill("Persistent disk")
            featurePill("Apple Silicon")
        }
    }

    private func featurePill(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(p.pill, in: RoundedRectangle(cornerRadius: 6))
    }

    private var templateList: some View {
        VStack(spacing: 10) {
            ForEach(templates) { template in
                TemplateCard(template: template)
            }
        }
        .frame(maxWidth: 640)
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
            templateList
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    fileprivate static func autoName(_ label: String) -> String {
        let base = label.split(separator: " ").first.map { $0.lowercased() } ?? "linux"
        return "\(base)-\(abs(label.hashValue) % 1000)"
    }
}

private struct MachineTemplate: Identifiable {
    let image: String
    let logo: String
    let name: String
    let version: String
    let isKnownSupported: Bool
    let description: String
    var id: String { image }
}

private struct TemplateCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let template: MachineTemplate

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(template.logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(template.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                    Text(template.version).font(.system(size: 12)).foregroundStyle(p.text3)
                    Spacer()
                    if !template.isKnownSupported {
                        Text("Container 1.0 issue")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(p.amber)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(p.amberWeak, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(template.description)
                    .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(3).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button {
                Task { _ = await store.createMachine(image: template.image, name: MachinesView.autoName(template.name)) }
            } label: {
                Text("Create")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(store.machineBusy)
        }
        .padding(16)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border))
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
