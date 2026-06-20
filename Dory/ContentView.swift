import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            MainColumnView()
        }
        .frame(minWidth: 1000, minHeight: 660)
        .background(store.palette.bgWindow)
        .environment(\.palette, store.palette)
        .tint(store.palette.accent)
        .preferredColorScheme(store.appearance.colorScheme)
        .overlay {
            if store.onboarding {
                OnboardingView()
                    .environment(\.palette, store.palette)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.actionError, store.activeSheet == nil {
                errorToast(error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: error) {
                        try? await Task.sleep(for: .seconds(6))
                        if store.activeSheet == nil { store.actionError = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: store.actionError)
        .task { await store.connectBackend() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            DockerContext.deactivateSync()
        }
        .sheet(item: Binding(get: { store.activeSheet }, set: { store.activeSheet = $0 })) { sheet in
            Group {
                switch sheet {
                case .newContainer: NewContainerSheet()
                case .pullImage: PullImageSheet()
                case .volumeBrowser: VolumeBrowserSheet()
                case .newVolume: NewVolumeSheet()
                case .newNetwork: NewNetworkSheet()
                case .buildImage: BuildImageSheet()
                case .registryLogin: RegistryLoginSheet()
                case .applyYAML: ApplyYAMLSheet()
                case .inspectImage: ImageDetailSheet()
                case .inspectNetwork: NetworkDetailSheet()
                }
            }
            .environment(store)
            .environment(\.palette, store.palette)
            .preferredColorScheme(store.appearance.colorScheme)
        }
    }

    private func errorToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(store.palette.red)
            Text(message).font(.system(size: 12.5)).foregroundStyle(store.palette.text).lineLimit(2)
            Spacer(minLength: 8)
            Button { store.actionError = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(store.palette.text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(store.palette.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(store.palette.red.opacity(0.5)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(.bottom, 20)
    }
}

#Preview {
    RootView()
        .environment(AppStore())
        .frame(width: 1180, height: 766)
}
