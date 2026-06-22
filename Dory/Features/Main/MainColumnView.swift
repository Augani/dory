import SwiftUI

struct MainColumnView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(p.border)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.bgContent)
        .onChange(of: store.filterFocusToken) { _, _ in filterFocused = true }
    }

    private var toolbar: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.section.title).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text(store.subtitle(for: store.section)).font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
            if store.section != .settings {
                filterBox(text: $store.filter)
                if store.section == .images {
                    secondaryButton("Sign In") { store.activeSheet = .registryLogin }
                    secondaryButton("Build") { store.activeSheet = .buildImage }
                }
                if store.section == .machines {
                    secondaryButton("Import") { store.importMachineFile() }
                }
                if let label = store.section.primaryActionLabel {
                    primaryButton(label)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func filterBox(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Glyph(glyph: .search, size: 12, color: p.text3)
            TextField("Filter…", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(p.text)
                .focused($filterFocused)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(width: 170)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("secondary-action")
    }

    private func primaryButton(_ label: String) -> some View {
        Button {
            store.presentPrimary(for: store.section)
        } label: {
            HStack(spacing: 6) {
                Glyph(glyph: .plus, size: 13, color: .white, strokeWidth: 1.8)
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("primary-action")
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }

    @ViewBuilder private var content: some View {
        switch store.section {
        case .containers: ContainersView()
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .compose: ComposeProjectsView()
        case .kubernetes: KubernetesView()
        case .machines: MachinesView()
        case .settings: SettingsView()
        }
    }
}
