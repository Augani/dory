import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.top, 30)
                .padding(.bottom, 14)
            nav
            resourceMeters
            bottomBar
        }
        .frame(width: 238)
        .background(p.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(p.border).frame(width: 1) }
    }

    private var brand: some View {
        Button {
            store.onboarding = true
        } label: {
            HStack(spacing: 10) {
                DoryLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dory").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                    if store.isConnecting {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Starting engine…").font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.text3)
                        }
                    } else {
                        Text("v\(AppInfo.version) · Engine \(store.engineRunning ? "running" : "stopped")")
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.text3)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("brand")
    }

    private var nav: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                sectionLabel("DOCKER")
                row(.containers, .containers, "Containers", trailing: "\(store.runningCount)")
                row(.images, .images, "Images")
                row(.volumes, .volumes, "Volumes")
                row(.networks, .networks, "Networks")
                row(.compose, .gridView, "Compose")
                sectionLabel("ORCHESTRATION").padding(.top, 6)
                row(.kubernetes, .kubernetes, "Kubernetes")
                sectionLabel("LINUX").padding(.top, 6)
                row(.machines, .machines, "Machines", trailing: "\(store.machines.count)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(p.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(_ section: AppSection, _ glyph: DoryGlyph, _ title: String, trailing: String? = nil) -> some View {
        let selected = store.section == section
        return Button {
            store.section = section
        } label: {
            HStack(spacing: 10) {
                Glyph(glyph: glyph, size: 16, color: selected ? p.text : p.text2)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? p.text : p.text2)
                Spacer(minLength: 0)
                if let trailing { CountPill(text: trailing) }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? p.accentWeak : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nav-\(section.rawValue)")
        .hoverHighlight(selected ? Color.clear : p.bgHover)
    }

    private var resourceMeters: some View {
        VStack(spacing: 9) {
            MiniMeter(label: "CPU", value: store.totalCPUDisplay, fraction: store.cpuMeterFraction, tint: p.accent)
            MiniMeter(label: "Memory", value: store.totalMemoryDisplay, fraction: store.memMeterFraction, tint: p.green)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button { store.section = .settings } label: {
                HStack(spacing: 8) {
                    Glyph(glyph: .settings, size: 15, color: store.section == .settings ? p.text : p.text2)
                    Text("Settings").font(.system(size: 12.5, weight: .medium)).foregroundStyle(store.section == .settings ? p.text : p.text2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(store.section == .settings ? p.accentWeak : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nav-settings")

            Button { store.toggleTheme() } label: {
                Glyph(glyph: .moon, size: 15, color: p.text2).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("theme-toggle")
            .help("Toggle appearance")
            .hoverHighlight(p.bgHover)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }
}
