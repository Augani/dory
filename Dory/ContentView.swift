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
        .background(MainWindowMarker())
        .environment(\.palette, store.palette)
        .tint(store.palette.accent)
        .preferredColorScheme(store.appearance.colorScheme)
        .overlay {
            if store.onboarding {
                OnboardingView()
                    .environment(\.palette, store.palette)
            }
        }
        .overlay {
            if !store.launchSplashComplete {
                LaunchSplashView {
                    withAnimation(.easeInOut(duration: 0.55)) { store.launchSplashComplete = true }
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let conflict = store.dockerHostConflict, !store.dockerHostConflictDismissed,
               !store.dockerHostCleaned, !store.onboarding, store.activeSheet == nil {
                dockerHostBanner(conflict)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 14)
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
        .overlay(alignment: .bottom) {
            if let notice = store.settingsNotice,
               notice.kind == .success,
               store.actionError == nil,
               store.activeSheet == nil {
                settingsToast(notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        if store.settingsNotice?.id == notice.id {
                            store.clearSettingsNotice()
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: store.actionError)
        .animation(.spring(duration: 0.3), value: store.settingsNotice)
        .animation(.spring(duration: 0.3), value: store.dockerHostConflict)
        .animation(.spring(duration: 0.3), value: store.dockerHostCleaned)
        .task { store.startBackendIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshIfIdle() }
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
                case .kubeResourceDetail: KubeResourceDetailSheet()
                case .newMachine: NewMachineSheet()
                case .creatingMachine: MachineCreationSheet()
                case .machineSnapshots: SnapshotsSheet()
                }
            }
            .environment(store)
            .environment(\.palette, store.palette)
            .preferredColorScheme(store.appearance.colorScheme)
        }
    }

    private func dockerHostBanner(_ conflict: DockerHostConflict.Conflict) -> some View {
        let p = store.palette
        return HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("A pinned DOCKER_HOST is overriding Dory")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Text("New terminals reach \(shortHost(conflict.effectiveHost)) instead of Dory.")
                    .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if conflict.isFixable {
                Button { Task { await store.resolveDockerHostConflict() } } label: {
                    Text("Make Dory default").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("docker-host-banner-fix")
            } else {
                Button {
                    store.section = .settings
                    store.settingsTab = .general
                    store.dismissDockerHostConflict()
                } label: {
                    Text("How to fix").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Button { store.dismissDockerHostConflict() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(p.text3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("docker-host-banner-dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: 580)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.amber.opacity(0.5)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private func shortHost(_ host: String) -> String {
        host.hasPrefix("unix://") ? String(host.dropFirst("unix://".count)) : host
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

    private func settingsToast(_ notice: SettingsNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(store.palette.green)
            Text(notice.message).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.text).lineLimit(2)
            Spacer(minLength: 8)
            Button { store.clearSettingsNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(store.palette.text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(store.palette.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(store.palette.green.opacity(0.5)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(.bottom, 20)
    }
}

private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        markWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        markWindow(for: nsView)
    }

    private func markWindow(for view: NSView) {
        DispatchQueue.main.async {
            if let window = view.window {
                DoryAppDelegate.markMainWindow(window)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppStore())
        .frame(width: 1180, height: 766)
}
