import SwiftUI

struct ComposeProjectsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private var projects: [(name: String, services: [Container])] {
        let grouped = Dictionary(grouping: store.containers.filter { $0.composeProject != nil }, by: { $0.composeProject ?? "" })
        return grouped.keys.sorted().map { name in
            (name: name, services: grouped[name]!.sorted { ($0.composeService ?? $0.name) < ($1.composeService ?? $1.name) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.composeBusy || !store.composeStatus.isEmpty {
                HStack(spacing: 8) {
                    if store.composeBusy { ProgressView().controlSize(.small) }
                    Text(store.composeStatus).font(.system(size: 12)).foregroundStyle(p.text2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(p.bgElevated)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
            if projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(projects, id: \.name) { project in
                            ProjectCard(name: project.name, services: project.services)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Glyph(glyph: .gridView, size: 38, color: p.text3)
                .frame(width: 64, height: 64)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.border))
            Text("No Compose projects").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
            Text("Open a compose.yaml to bring the whole stack up at once —\nservices start in dependency order and appear here.")
                .font(.system(size: 12.5)).foregroundStyle(p.text3).multilineTextAlignment(.center).lineSpacing(3)
            Button { store.openComposeFile() } label: {
                Text("Open Compose File…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.composeBusy)
            .padding(.top, 4)
            .accessibilityIdentifier("open-compose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let name: String
    let services: [Container]

    private var running: Int { services.filter(\.isRunning).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Glyph(glyph: .gridView, size: 16, color: p.accentText)
                    .frame(width: 30, height: 30)
                    .background(p.accentWeak, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                    Text("\(services.count) service\(services.count == 1 ? "" : "s") · \(running) running")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                actionButton(running > 0 ? "Stop" : "Start") { toggleAll(start: running == 0) }
                Menu {
                    Button("Down — stop & remove", role: .destructive) { Task { await store.composeDown(name) } }
                } label: {
                    Text("⋯").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text2)
                        .frame(width: 30, height: 28)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(services) { service in
                    HStack(spacing: 11) {
                        StatusDot(color: service.status.dotColor(p), size: 7)
                        Text(service.composeService ?? service.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        Text(service.image).font(.mono(11)).foregroundStyle(p.text3).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(service.memoryDisplay).font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
                        Button { store.toggle(service) } label: {
                            Glyph(glyph: service.isRunning ? .pause : .play, size: 11, color: p.text2)
                                .frame(width: 26, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(service.isRunning ? "Stop service" : "Start service")
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
                }
            }
        }
        .padding(16)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(p.border))
    }

    private func toggleAll(start: Bool) {
        for service in services where service.isRunning != start { store.toggle(service) }
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
    }
}
