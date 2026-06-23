import SwiftUI

struct KubernetesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var pendingDeletePod: Pod?

    var body: some View {
        if !store.kubernetesReachable && store.pods.isEmpty {
            emptyState
        } else {
            clusterBrowser
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

    private var clusterBrowser: some View {
        VStack(spacing: 0) {
            banner
            resourceTable
        }
        .confirmationDialog(
            "Delete pod \(pendingDeletePod?.name ?? "")?",
            isPresented: Binding(get: { pendingDeletePod != nil }, set: { if !$0 { pendingDeletePod = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let pod = pendingDeletePod { Task { await store.deletePod(pod) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the pod. This cannot be undone.")
        }
    }

    @ViewBuilder private var resourceTable: some View {
        switch store.kubeResource {
        case .pods: podTable
        case .deployments: deploymentTable
        case .services: serviceTable
        }
    }

    private var podTable: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("POD"), .init("NAMESPACE", 110), .init("READY", 90),
                .init("STATUS", 120), .init("RESTARTS", 80), .init("AGE", 70), .init("", 40),
            ])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.pods) { pod in
                        PodRow(pod: pod, onDelete: { pendingDeletePod = pod })
                    }
                }
            }
        }
    }

    private var deploymentTable: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("DEPLOYMENT"), .init("NAMESPACE", 110), .init("READY", 90),
                .init("UP-TO-DATE", 100), .init("AVAILABLE", 90), .init("AGE", 70),
            ])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.deployments) { row in
                        HStack(spacing: 0) {
                            Text(row.name).font(.mono(13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.namespace).font(.system(size: 12)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                            Text(row.ready).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
                            Text("\(row.upToDate)").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 100, alignment: .leading)
                            Text("\(row.available)").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
                            Text(row.age).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 70, alignment: .leading)
                        }
                        .tableRow()
                    }
                }
            }
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("SERVICE"), .init("NAMESPACE", 110), .init("TYPE", 110),
                .init("CLUSTER-IP", 120), .init("PORTS", 120), .init("AGE", 70),
            ])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.kubeServices) { row in
                        HStack(spacing: 0) {
                            Text(row.name).font(.mono(13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.namespace).font(.system(size: 12)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                            Text(row.type).font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                            Text(row.clusterIP).font(.mono(12)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
                            Text(row.ports).font(.mono(12)).foregroundStyle(p.text2).lineLimit(1).frame(width: 120, alignment: .leading)
                            Text(row.age).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 70, alignment: .leading)
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
            Picker("", selection: Binding(get: { store.kubeResource }, set: { store.kubeResource = $0; Task { await store.loadKubeResource() } })) {
                ForEach(KubeResourceKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            .accessibilityIdentifier("kube-resource-picker")
            Picker("", selection: Binding(get: { store.kubeNamespace }, set: { store.kubeNamespace = $0; Task { await store.loadKubeResource() } })) {
                Text("All Namespaces").tag("All Namespaces")
                ForEach(store.kubeNamespaces, id: \.self) { ns in Text(ns).tag(ns) }
            }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .accessibilityIdentifier("kube-namespace-picker")
            Spacer(minLength: 0)
            Button("Apply YAML") { store.activeSheet = .applyYAML }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                .accessibilityIdentifier("apply-yaml")
            Menu {
                Button("Apply YAML…") { store.activeSheet = .applyYAML }
                Divider()
                Button("Copy kubeconfig for kubectl") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.kubeconfigHint, forType: .string)
                }
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

private struct PodRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let pod: Pod
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
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
            HStack(spacing: 2) {
                if hover {
                    IconButton(systemImage: "trash", label: "Delete \(pod.name)") { onDelete() }
                }
            }.frame(width: 40, alignment: .trailing)
        }
        .tableRow()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.selectedPodID = pod.id }
        .onHover { hover = $0 }
    }
}
