import SwiftUI

private struct InspectSection<Content: View>: View {
    @Environment(\.palette) private var p
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                .padding(.bottom, 8)
            content
        }
    }
}

private struct InspectRow: View {
    @Environment(\.palette) private var p
    let key: String
    let value: String
    var mono = true

    var body: some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(p.text3)
            Spacer(minLength: 0)
            Text(value).font(mono ? .mono(12.5) : .system(size: 12.5)).foregroundStyle(p.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

private struct InspectChrome<Content: View>: View {
    @Environment(\.palette) private var p
    @Environment(AppStore.self) private var store
    let title: String
    let subtitle: String
    let badge: String?
    let copyValue: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.mono(11.5)).foregroundStyle(p.text3).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.accentText)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(p.accentWeak, in: Capsule())
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.bottom, 18)
            }
            .frame(maxHeight: 420)

            Divider().overlay(p.border)
            HStack(spacing: 8) {
                if let copyValue {
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyValue, forType: .string)
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                Spacer()
                Button("Close") { store.activeSheet = nil }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(p.bgWindow)
    }
}

private struct KeyValueList: View {
    @Environment(\.palette) private var p
    let pairs: [LabelPair]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pairs) { pair in
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.key).font(.mono(11, weight: .bold)).foregroundStyle(p.accentText)
                    Text(pair.value.isEmpty ? "—" : pair.value).font(.mono(12)).foregroundStyle(p.text2).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
        }
    }
}

struct ImageDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var detail: ImageDetail?

    var body: some View {
        Group {
            if let image = store.inspectedImage {
                InspectChrome(
                    title: detail?.reference ?? "\(image.repository):\(image.tag)",
                    subtitle: detail?.id ?? image.imageID,
                    badge: image.isUsed ? image.usedLabel : nil,
                    copyValue: detail?.id ?? image.imageID
                ) {
                    if let detail {
                        InspectSection(title: "DETAILS") {
                            InspectRow(key: "Image ID", value: detail.id)
                            InspectRow(key: "Size", value: detail.size)
                            InspectRow(key: "Created", value: detail.created, mono: false)
                            InspectRow(key: "Platform", value: "\(detail.os)/\(detail.architecture)")
                            InspectRow(key: "Working Dir", value: detail.workingDir)
                            if let digest = detail.digest {
                                InspectRow(key: "Digest", value: digest)
                            }
                        }
                        if detail.tags.count > 1 {
                            InspectSection(title: "TAGS") {
                                ForEach(detail.tags, id: \.self) { tag in
                                    Text(tag).font(.mono(12)).foregroundStyle(p.text2).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }
                            }
                        }
                        if !detail.exposedPorts.isEmpty {
                            InspectSection(title: "EXPOSED PORTS") {
                                portFlow(detail.exposedPorts)
                            }
                        }
                        if !detail.entrypoint.isEmpty || !detail.command.isEmpty {
                            InspectSection(title: "PROCESS") {
                                if !detail.entrypoint.isEmpty { InspectRow(key: "Entrypoint", value: detail.entrypoint) }
                                if !detail.command.isEmpty { InspectRow(key: "Command", value: detail.command) }
                            }
                        }
                        if !detail.env.isEmpty {
                            InspectSection(title: "ENVIRONMENT") {
                                KeyValueList(pairs: detail.env.map { LabelPair(key: $0.key, value: $0.value) })
                            }
                        }
                        if !detail.labels.isEmpty {
                            InspectSection(title: "LABELS") { KeyValueList(pairs: detail.labels) }
                        }
                    } else {
                        loading
                    }
                }
                .task(id: image.id) { detail = await store.fetchImageDetail(image) }
            }
        }
    }

    private func portFlow(_ ports: [String]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 76), spacing: 6, alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(ports, id: \.self) { port in
                Text(port).font(.mono(11.5)).foregroundStyle(p.text)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(p.pill, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading details…").font(.system(size: 12.5)).foregroundStyle(p.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
    }
}

struct NetworkDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var detail: NetworkDetail?

    var body: some View {
        Group {
            if let network = store.inspectedNetwork {
                InspectChrome(
                    title: network.name,
                    subtitle: detail?.id ?? network.name,
                    badge: (detail?.driver ?? network.driver),
                    copyValue: detail?.id
                ) {
                    if let detail {
                        InspectSection(title: "DETAILS") {
                            InspectRow(key: "Network ID", value: detail.id)
                            InspectRow(key: "Driver", value: detail.driver, mono: false)
                            InspectRow(key: "Scope", value: detail.scope, mono: false)
                            InspectRow(key: "Subnet", value: detail.subnet)
                            InspectRow(key: "Gateway", value: detail.gateway)
                            InspectRow(key: "Internal", value: detail.isInternal ? "Yes" : "No", mono: false)
                            InspectRow(key: "Attachable", value: detail.attachable ? "Yes" : "No", mono: false)
                        }
                        InspectSection(title: "CONNECTED CONTAINERS") {
                            if detail.containers.isEmpty {
                                Text("No containers connected").font(.system(size: 12.5)).foregroundStyle(p.text3)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(detail.containers) { member in
                                    HStack(spacing: 12) {
                                        Text(member.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.text)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(member.ipv4).font(.mono(12)).foregroundStyle(p.text2).textSelection(.enabled)
                                    }
                                    .padding(.vertical, 7)
                                    .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
                                }
                            }
                        }
                        if !detail.options.isEmpty {
                            InspectSection(title: "OPTIONS") { KeyValueList(pairs: detail.options) }
                        }
                    } else {
                        loading
                    }
                }
                .task(id: network.id) { detail = await store.fetchNetworkDetail(network) }
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading details…").font(.system(size: 12.5)).foregroundStyle(p.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
    }
}

struct KubeResourceDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var revealSecrets = false

    var body: some View {
        Group {
            if let configMap = store.selectedConfigMap {
                InspectChrome(
                    title: configMap.name,
                    subtitle: "ConfigMap / \(configMap.namespace)",
                    badge: "\(configMap.keyCount) key\(configMap.keyCount == 1 ? "" : "s")",
                    copyValue: nil
                ) {
                    InspectSection(title: "DATA") {
                        KeyValueList(pairs: configMap.data.keys.sorted().map { LabelPair(key: $0, value: configMap.data[$0] ?? "") })
                    }
                }
            } else if let secret = store.selectedSecret {
                InspectChrome(
                    title: secret.name,
                    subtitle: "Secret / \(secret.namespace)",
                    badge: secret.type,
                    copyValue: nil
                ) {
                    InspectSection(title: "DATA") {
                        HStack {
                            Text(revealSecrets ? "Values are visible" : "Values are hidden")
                                .font(.system(size: 12.5)).foregroundStyle(p.text3)
                            Spacer()
                            Button(revealSecrets ? "Hide Values" : "Reveal Values") {
                                revealSecrets.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.accentText)
                        }
                        .padding(.bottom, 6)
                        KeyValueList(pairs: secretPairs(secret))
                    }
                }
            } else if let ingress = store.selectedIngress {
                InspectChrome(
                    title: ingress.name,
                    subtitle: "Ingress / \(ingress.namespace)",
                    badge: ingress.hosts,
                    copyValue: nil
                ) {
                    InspectSection(title: "ROUTING") {
                        InspectRow(key: "Hosts", value: ingress.hosts)
                        InspectRow(key: "Address", value: ingress.address)
                        InspectRow(key: "Paths", value: ingress.paths)
                    }
                }
            }
        }
        .onDisappear {
            store.selectedConfigMap = nil
            store.selectedSecret = nil
            store.selectedIngress = nil
        }
    }

    private func secretPairs(_ secret: KubeSecretRow) -> [LabelPair] {
        if revealSecrets { return KubeSecretDecode.decode(secret.data) }
        return secret.keys.map { LabelPair(key: $0, value: "••••••••") }
    }
}
