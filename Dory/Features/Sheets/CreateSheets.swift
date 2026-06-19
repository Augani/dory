import SwiftUI
import UniformTypeIdentifiers

private struct SheetField: View {
    @Environment(\.palette) private var p
    let label: String
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(mono ? .mono(12.5) : .system(size: 13))
            .foregroundStyle(p.text)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
        }
    }
}

private struct SheetChrome<Content: View>: View {
    @Environment(\.palette) private var p
    @Environment(AppStore.self) private var store
    let title: String
    let primaryLabel: String
    let busy: Bool
    let onSubmit: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
            content
            if let error = store.actionError {
                Text(error).font(.system(size: 12)).foregroundStyle(p.red).lineLimit(3)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.activeSheet = nil; store.actionError = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                Button(action: onSubmit) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(primaryLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sheet-submit")
                .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(p.bgWindow)
    }
}

struct NewContainerSheet: View {
    @Environment(AppStore.self) private var store
    @State private var image = ""
    @State private var name = ""
    @State private var ports = ""
    @State private var volumes = ""
    @State private var env = ""
    @State private var busy = false

    var body: some View {
        SheetChrome(title: "New Container", primaryLabel: "Create", busy: busy, onSubmit: submit) {
            SheetField(label: "IMAGE", placeholder: "nginx:alpine", text: $image, mono: true)
            SheetField(label: "NAME (optional)", placeholder: "my-container", text: $name)
            SheetField(label: "PORTS (host:container, comma-separated)", placeholder: "8080:80", text: $ports, mono: true)
            SheetField(label: "VOLUMES (host:container or name:container, comma-separated)", placeholder: "data:/var/lib/data", text: $volumes, mono: true)
            SheetField(label: "ENVIRONMENT (KEY=value, comma-separated)", placeholder: "LOG_LEVEL=info", text: $env, mono: true)
        }
    }

    private func submit() {
        busy = true
        store.actionError = nil
        let portList = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let volumeList = volumes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var environment: [String: String] = [:]
        for pair in env.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { environment[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        Task {
            let error = await store.createContainer(name: name, image: image, ports: portList, env: environment, volumes: volumeList)
            busy = false
            if let error { store.actionError = error } else { store.activeSheet = nil; store.section = .containers }
        }
    }
}

struct PullImageSheet: View {
    @Environment(AppStore.self) private var store
    @State private var reference = ""
    @State private var busy = false

    var body: some View {
        SheetChrome(title: "Pull Image", primaryLabel: "Pull", busy: busy, onSubmit: submit) {
            SheetField(label: "IMAGE REFERENCE", placeholder: "redis:7-alpine", text: $reference, mono: true)
        }
    }

    private func submit() {
        busy = true
        store.actionError = nil
        Task {
            let error = await store.pullImage(reference)
            busy = false
            if let error { store.actionError = error } else { store.activeSheet = nil; store.section = .images }
        }
    }
}

struct NewVolumeSheet: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        SheetChrome(title: "New Volume", primaryLabel: "Create", busy: busy, onSubmit: submit) {
            SheetField(label: "VOLUME NAME", placeholder: "app-data", text: $name, mono: true)
        }
    }

    private func submit() {
        busy = true
        store.actionError = nil
        Task {
            let error = await store.createVolume(name: name)
            busy = false
            if let error { store.actionError = error } else { store.activeSheet = nil; store.section = .volumes }
        }
    }
}

struct NewNetworkSheet: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        SheetChrome(title: "New Network", primaryLabel: "Create", busy: busy, onSubmit: submit) {
            SheetField(label: "NETWORK NAME", placeholder: "backend", text: $name, mono: true)
        }
    }

    private func submit() {
        busy = true
        store.actionError = nil
        Task {
            let error = await store.createNetwork(name: name)
            busy = false
            if let error { store.actionError = error } else { store.activeSheet = nil; store.section = .networks }
        }
    }
}

struct BuildImageSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var contextDir: URL?
    @State private var tag = ""
    @State private var building = false
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build Image").font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
            VStack(alignment: .leading, spacing: 5) {
                Text("BUILD CONTEXT (folder containing a Dockerfile)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
                HStack(spacing: 8) {
                    Text(contextDir?.path ?? "No folder selected")
                        .font(.mono(12)).foregroundStyle(contextDir == nil ? p.text3 : p.text)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                    Button("Choose…") { chooseContext() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            }
            SheetField(label: "IMAGE TAG", placeholder: "myapp:latest", text: $tag, mono: true)
            if building || !output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output.isEmpty ? "…" : output)
                            .font(.mono(11)).foregroundStyle(p.monoText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled).id("logEnd")
                    }
                    .frame(height: 190)
                    .padding(10)
                    .background(p.monoBg, in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: output) { _, _ in withAnimation { proxy.scrollTo("logEnd", anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Close") { store.activeSheet = nil }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                Button(action: build) {
                    HStack(spacing: 6) {
                        if building { ProgressView().controlSize(.small) }
                        Text(building ? "Building…" : "Build").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(p.accent.opacity(contextDir == nil || building ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(building || contextDir == nil)
                .accessibilityIdentifier("build-submit")
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(p.bgWindow)
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the build context folder (containing a Dockerfile)"
        if panel.runModal() == .OK { contextDir = panel.url }
    }

    private func build() {
        guard let dir = contextDir else { return }
        building = true
        output = ""
        Task {
            for await line in store.buildImage(contextDir: dir, tag: tag) {
                output += line + "\n"
            }
            building = false
        }
    }
}

struct RegistryLoginSheet: View {
    @Environment(AppStore.self) private var store
    @State private var registry = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        SheetChrome(title: "Sign in to a Registry", primaryLabel: "Sign In", busy: busy, onSubmit: submit) {
            SheetField(label: "REGISTRY (leave blank for Docker Hub)", placeholder: "ghcr.io", text: $registry, mono: true)
            SheetField(label: "USERNAME", placeholder: "username", text: $username)
            SheetField(label: "PASSWORD or ACCESS TOKEN", placeholder: "••••••••", text: $password, secure: true)
        }
    }

    private func submit() {
        busy = true
        store.actionError = nil
        Task {
            let error = await store.registryLogin(registry: registry, username: username, password: password)
            busy = false
            if let error { store.actionError = error } else { store.activeSheet = nil }
        }
    }
}

struct ApplyYAMLSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var yaml = ""
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Apply Kubernetes Manifest").font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                Spacer()
                Button("Open File…") { openFile() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
            }
            TextEditor(text: $yaml)
                .font(.mono(12)).foregroundStyle(p.monoText).scrollContentBackground(.hidden)
                .frame(height: 240)
                .padding(8)
                .background(p.monoBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                .overlay(alignment: .topLeading) {
                    if yaml.isEmpty {
                        Text("apiVersion: apps/v1\nkind: Deployment\n…").font(.mono(12)).foregroundStyle(p.text3)
                            .padding(14).allowsHitTesting(false)
                    }
                }
            if let result {
                Text(result).font(.system(size: 12)).foregroundStyle(result.hasPrefix("Applied") ? p.green : p.red).lineLimit(3)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Close") { store.activeSheet = nil }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                Button(action: apply) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Applying…" : "Apply").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(p.accent.opacity(busy ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(busy).accessibilityIdentifier("apply-yaml-submit")
            }
        }
        .padding(22).frame(width: 540).background(p.bgWindow)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            yaml = text
        }
    }

    private func apply() {
        busy = true
        result = nil
        Task {
            let error = await store.applyKubernetesYAML(yaml)
            busy = false
            result = error ?? "Applied successfully"
        }
    }
}
