import DoryOperations
import SwiftUI

struct ComponentsView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var p
    let embedded: Bool

    @State private var catalog: DoryComponentCatalog?
    @State private var catalogData = Data()
    @State private var statuses: [DoryComponentStatus] = []
    @State private var progress: [DoryComponentID: DoryComponentProgress] = [:]
    @State private var busy: Set<DoryComponentID> = []
    @State private var pendingRemoval: DoryComponentID?
    @State private var errorMessage: String?
    @State private var usingCachedCatalog = false

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView { content.padding(.horizontal, 24).padding(.vertical, 20) }
            }
        }
        .task { await refresh(preferRemote: true) }
        .confirmationDialog(
            "Remove \(pendingRemoval.map(displayName) ?? "component")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRemoval {
                Button("Remove \(displayName(pendingRemoval))", role: .destructive) {
                    self.pendingRemoval = nil
                    Task { await remove(pendingRemoval) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Only the component payload is removed. Your containers, Kubernetes state, machines, disks, snapshots, and exports stay on the selected Dory data drive.")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let errorMessage {
                errorPanel(errorMessage)
            }
            if statuses.isEmpty, errorMessage == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading signed component catalog…")
                        .font(.system(size: 12.5)).foregroundStyle(p.text2)
                }
                .padding(.vertical, 20)
            } else {
                componentGrid
            }
            dataSafetyPanel
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Components")
                    .font(.system(size: embedded ? 18 : 22, weight: .bold))
                    .foregroundStyle(p.text)
                if usingCachedCatalog {
                    Text("Offline catalog")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(p.amber)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(p.amber.opacity(0.12), in: Capsule())
                }
            }
            Text("Start with Docker Core. Add only the Kubernetes, Linux machine, and desktop payloads you use. Each component updates and removes independently.")
                .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let catalog {
                Text("Catalog \(catalog.releaseVersion) · Apple silicon · sizes shown before download")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var componentGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: embedded ? 300 : 340, maximum: 410), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(statuses) { status in
                componentCard(status)
            }
        }
    }

    private func componentCard(_ status: DoryComponentStatus) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon(status.id))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(status.id == .dockerCore ? p.green : p.accent)
                    .frame(width: 38, height: 38)
                    .background((status.id == .dockerCore ? p.green : p.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.displayName)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                    Text(status.summary)
                        .font(.system(size: 11.5)).foregroundStyle(p.text2)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                statePill(status.state)
            }

            HStack(spacing: 14) {
                sizeFact("Download", status.downloadBytes)
                sizeFact("Installed", status.installedBytes)
                if !status.dependencies.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("REQUIRES").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                        Text(status.dependencies.map(displayName).joined(separator: ", "))
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.text2).lineLimit(1)
                    }
                }
            }

            if let currentProgress = progress[status.id], busy.contains(status.id) {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(
                        value: Double(currentProgress.completedBytes),
                        total: Double(max(1, currentProgress.totalBytes))
                    )
                    .tint(p.accent)
                    Text("\(currentProgress.phase.rawValue.capitalized) · \(formatted(currentProgress.completedBytes)) of \(formatted(currentProgress.totalBytes))")
                        .font(.system(size: 10.5)).foregroundStyle(p.text3)
                }
            }

            actions(status)
        }
        .padding(15)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(status.state == .invalid ? p.red.opacity(0.55) : p.border))
        .accessibilityIdentifier("component-\(status.id.rawValue)")
    }

    @ViewBuilder private func actions(_ status: DoryComponentStatus) -> some View {
        HStack(spacing: 8) {
            switch status.state {
            case .bundled:
                Label("Included in Dory", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.green)
            case .notInstalled:
                actionButton("Install", primary: true, disabled: isBusy(status.id)) {
                    Task { await install(status.id) }
                }
            case .updateAvailable:
                actionButton("Update", primary: true, disabled: isBusy(status.id)) {
                    Task { await install(status.id) }
                }
                removeButton(status.id)
            case .invalid:
                actionButton("Repair", primary: true, disabled: isBusy(status.id)) {
                    Task { await install(status.id) }
                }
                removeButton(status.id)
            case .installed:
                actionButton("Verify", primary: false, disabled: isBusy(status.id)) {
                    Task { await verify(status.id) }
                }
                removeButton(status.id)
            }
            Spacer(minLength: 0)
            Text(status.installedVersion.map { "v\($0)" } ?? "v\(status.availableVersion)")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.text3)
        }
    }

    private func actionButton(
        _ label: String,
        primary: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary ? Color.white : p.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(primary ? p.accent : p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if !primary { RoundedRectangle(cornerRadius: 7).strokeBorder(p.border) }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func removeButton(_ id: DoryComponentID) -> some View {
        actionButton("Remove", primary: false, disabled: isBusy(id)) {
            pendingRemoval = id
        }
    }

    private func statePill(_ state: DoryComponentState) -> some View {
        let color: Color = switch state {
        case .bundled, .installed: p.green
        case .updateAvailable: p.accent
        case .invalid: p.red
        case .notInstalled: p.text3
        }
        let label: String = switch state {
        case .bundled: "Core"
        case .installed: "Installed"
        case .updateAvailable: "Update"
        case .invalid: "Repair"
        case .notInstalled: "Optional"
        }
        return Text(label)
            .font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
    }

    private func sizeFact(_ label: String, _ bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
            Text(formatted(bytes)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.text)
        }
    }

    private var dataSafetyPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(p.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Removing a component never removes your work")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Text("Only the installed payload is reclaimed. Containers, images, volumes, Kubernetes state, machine disks, snapshots, and backups stay on your selected Dory data drive.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text2).lineSpacing(3)
            }
        }
        .padding(13)
        .background(p.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.green.opacity(0.25)))
    }

    private func errorPanel(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Components are unavailable").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Text(message).font(.system(size: 11.5)).foregroundStyle(p.text2).textSelection(.enabled)
            }
            Spacer()
            Button("Retry") { Task { await refresh(preferRemote: true) } }
                .buttonStyle(.borderless).font(.system(size: 11.5, weight: .semibold))
        }
        .padding(13)
        .background(p.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.red.opacity(0.28)))
    }

    @MainActor private func refresh(preferRemote: Bool) async {
        do {
            let store = try DoryComponentStore.selected()
            try store.prepare()
            var loadedCatalog: DoryComponentCatalog
            var loadedData: Data
            var cached = true
            if preferRemote {
                do {
                    let client = DoryComponentCatalogClient(
                        catalogURL: AppInfo.componentCatalogURL,
                        publicKey: DoryComponentDefaults.publicKey,
                        expectedArchitecture: DoryComponentDefaults.architecture,
                        appVersion: AppInfo.version
                    )
                    let fetched = try await client.fetch()
                    loadedCatalog = try store.cacheCatalog(
                        data: fetched.data,
                        signature: fetched.signature,
                        publicKey: DoryComponentDefaults.publicKey,
                        expectedArchitecture: DoryComponentDefaults.architecture,
                        appVersion: AppInfo.version
                    )
                    loadedData = fetched.data
                    cached = false
                } catch {
                    guard let local = try store.cachedCatalog(
                        publicKey: DoryComponentDefaults.publicKey,
                        expectedArchitecture: DoryComponentDefaults.architecture,
                        appVersion: AppInfo.version
                    ) else { throw error }
                    loadedCatalog = local.catalog
                    loadedData = local.data
                }
            } else if let local = try store.cachedCatalog(
                publicKey: DoryComponentDefaults.publicKey,
                expectedArchitecture: DoryComponentDefaults.architecture,
                appVersion: AppInfo.version
            ) {
                loadedCatalog = local.catalog
                loadedData = local.data
            } else {
                throw DoryComponentError.invalidCatalog("no verified component catalog is available")
            }
            catalog = loadedCatalog
            catalogData = loadedData
            statuses = store.list(
                catalog: loadedCatalog,
                catalogDigest: DoryComponentCatalogVerifier.digest(loadedData)
            )
            usingCachedCatalog = cached
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor private func install(_ id: DoryComponentID) async {
        guard let catalog, !catalogData.isEmpty else { return }
        var operationIDs: Set<DoryComponentID> = [id]
        busy.insert(id)
        errorMessage = nil
        defer {
            for operationID in operationIDs {
                busy.remove(operationID)
                progress[operationID] = nil
            }
        }
        do {
            let store = try DoryComponentStore.selected()
            let installer = DoryComponentInstaller(store: store)
            let digest = DoryComponentCatalogVerifier.digest(catalogData)
            for release in try installationOrder(id, catalog: catalog) {
                if let current = try store.installedComponent(release.id),
                   current.version == release.version,
                   current.catalogDigest == digest,
                   (try? store.verify(release.id)) != nil {
                    continue
                }
                operationIDs.insert(release.id)
                busy.insert(release.id)
                _ = try await installer.install(release, catalogData: catalogData) { update in
                    Task { @MainActor in self.progress[release.id] = update }
                }
                busy.remove(release.id)
            }
            statuses = store.list(catalog: catalog, catalogDigest: digest)
            HostDockerCLI.reconcileOptionalTools(enabled: appStore.routeDockerCLI)
            appStore.showSettingsSuccess("\(displayName(id)) is installed and verified.")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor private func verify(_ id: DoryComponentID) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let store = try DoryComponentStore.selected()
            _ = try store.verify(id)
            if let catalog {
                statuses = store.list(
                    catalog: catalog,
                    catalogDigest: DoryComponentCatalogVerifier.digest(catalogData)
                )
            }
            appStore.showSettingsSuccess("\(displayName(id)) passed verification.")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor private func remove(_ id: DoryComponentID) async {
        guard let catalog else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let store = try DoryComponentStore.selected()
            try store.remove(id, catalog: catalog)
            statuses = store.list(
                catalog: catalog,
                catalogDigest: DoryComponentCatalogVerifier.digest(catalogData)
            )
            HostDockerCLI.reconcileOptionalTools(enabled: appStore.routeDockerCLI)
            appStore.showSettingsSuccess("Removed \(displayName(id)). Your workload data was preserved.")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func installationOrder(
        _ id: DoryComponentID,
        catalog: DoryComponentCatalog
    ) throws -> [DoryComponentRelease] {
        var visited: Set<DoryComponentID> = []
        var ordered: [DoryComponentRelease] = []
        func append(_ current: DoryComponentID) throws {
            guard current != .dockerCore, !visited.contains(current) else { return }
            guard let release = catalog.component(current) else {
                throw DoryComponentError.unknownComponent(current.rawValue)
            }
            for dependency in release.dependencies { try append(dependency) }
            visited.insert(current)
            ordered.append(release)
        }
        try append(id)
        return ordered
    }

    private func isBusy(_ id: DoryComponentID) -> Bool { busy.contains(id) }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func displayName(_ id: DoryComponentID) -> String {
        catalog?.component(id)?.displayName ?? id.rawValue
    }

    private func icon(_ id: DoryComponentID) -> String {
        switch id {
        case .dockerCore: "shippingbox.fill"
        case .kubernetes: "square.3.layers.3d"
        case .linuxMachines: "server.rack"
        case .linuxDesktop: "display"
        case .desktopDebian, .desktopUbuntu, .desktopKali: "desktopcomputer"
        }
    }
}

struct MissingComponentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let component: DoryComponentID
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "square.stack.3d.up.badge.a")
                .font(.system(size: 34, weight: .semibold)).foregroundStyle(p.accent)
                .frame(width: 72, height: 72)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 19))
            Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(p.text)
            Text(message)
                .font(.system(size: 13)).foregroundStyle(p.text2).multilineTextAlignment(.center)
                .lineSpacing(4).frame(maxWidth: 460)
            Button {
                store.section = .components
            } label: {
                Text("Choose components")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 17).padding(.vertical, 9)
                    .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("install-\(component.rawValue)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
