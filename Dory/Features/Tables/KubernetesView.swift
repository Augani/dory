import SwiftUI

struct KubernetesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        if store.pods.isEmpty {
            emptyState
        } else {
            podList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Glyph(glyph: .kubernetes, size: 40, color: p.text3)
                .frame(width: 64, height: 64)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.border))
            Text("Kubernetes is not running").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
            Text(store.kubernetesBusy ? store.kubernetesInfo : (store.runtimeKind == .sharedVM
                ? "Run a one-click local k3s cluster inside Dory's shared VM.\nBuilt images are usable in Pods immediately — no registry push."
                : "Kubernetes runs inside Dory's shared VM. Switch to it in Settings → Docker Engine to enable Kubernetes."))
                .font(.system(size: 12.5)).foregroundStyle(p.text3).multilineTextAlignment(.center).lineSpacing(3)
            Button {
                Task { await store.enableKubernetes() }
            } label: {
                HStack(spacing: 7) {
                    if store.kubernetesBusy { ProgressView().controlSize(.small) }
                    Text(store.kubernetesBusy ? "Starting…" : "Enable Kubernetes")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(p.accent.opacity(store.runtimeKind == .sharedVM ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.kubernetesBusy || store.runtimeKind != .sharedVM)
            .accessibilityIdentifier("enable-kubernetes")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var podList: some View {
        VStack(spacing: 0) {
            banner
            TableHeader(columns: [
                .init("POD"), .init("NAMESPACE", 110), .init("READY", 90),
                .init("STATUS", 120), .init("RESTARTS", 80), .init("AGE", 70),
            ])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.pods) { pod in
                        HStack(spacing: 0) {
                            Text(pod.name).font(.mono(13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(pod.namespace).font(.system(size: 12)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                            Text(pod.ready).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
                            HStack {
                                StatusBadge(label: pod.phase.rawValue, color: pod.phase.color(p), background: pod.phase.background(p))
                            }.frame(width: 120, alignment: .leading)
                            Text("\(pod.restarts)").font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 80, alignment: .leading)
                            Text(pod.age).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 70, alignment: .leading)
                        }
                        .tableRow()
                    }
                }
            }
        }
    }

    private var bannerInfo: String {
        if store.kubernetesReachable { return store.kubernetesInfo }
        let namespaces = Set(store.pods.map(\.namespace)).count
        return "\(store.pods.count) pods · \(namespaces) namespace\(namespaces == 1 ? "" : "s")"
    }

    private var banner: some View {
        let healthy = store.kubernetesReachable
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                StatusDot(color: healthy ? p.green : p.amber)
                Text(healthy ? "Cluster Healthy" : "Cluster Unreachable")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(healthy ? p.green : p.amber)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(healthy ? p.greenWeak : p.amberWeak, in: RoundedRectangle(cornerRadius: 8))
            Text(bannerInfo).font(.system(size: 12.5)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
            Button("Apply YAML") { store.activeSheet = .applyYAML }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                .accessibilityIdentifier("apply-yaml")
            Menu {
                Button("Apply YAML…") { store.activeSheet = .applyYAML }
                Divider()
                Button("Disable Kubernetes", role: .destructive) { Task { await store.disableKubernetes() } }
            } label: {
                Text("⋯").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text2)
                    .frame(width: 28, height: 26)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}
