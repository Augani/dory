import AppKit
import DoryOperations
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var domainSuffixDraft = ""
    @State private var dnsPortDraft = ""
    @State private var httpPortDraft = ""
    @State private var httpsPortDraft = ""
    @State private var customSocketDraft = ""
    @State private var machineEnvAllowListDraft = ""
    @State private var detectedEngineSources: [DockerSourceEngine] = []

    var body: some View {
        HStack(spacing: 0) {
            subNav
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = store.settingsNotice {
                        settingsNotice(notice)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .task(id: notice.id) {
                                try? await Task.sleep(for: .seconds(4))
                                if store.settingsNotice?.id == notice.id {
                                    store.clearSettingsNotice()
                                }
                            }
                    }
                    content
                }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.spring(duration: 0.25), value: store.settingsNotice)
    }

    private var subNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = store.settingsTab == tab
                Button { store.settingsTab = tab } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? p.text : p.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(selected ? p.accentWeak : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-\(tab.rawValue)")
            }
            Spacer()
        }
        .frame(width: 178)
        .padding(.horizontal, 10).padding(.vertical, 14)
        .overlay(alignment: .trailing) { Rectangle().fill(p.border).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        switch store.settingsTab {
        case .general: general
        case .resources: resources
        case .machines: machines
        case .engine: engine
        case .autoIdle: AutoIdleView()
        case .network: network
        case .usb: UsbDevicesView()
        case .localTools: localTools
        case .migrate: migrate
        case .managed: managed
        case .about: infoPanel(aboutText)
        }
    }

    private func settingsNotice(_ notice: SettingsNotice) -> some View {
        let color = notice.kind == .success ? p.green : p.red
        return HStack(spacing: 10) {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(notice.message)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(p.text)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button { store.clearSettingsNotice() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(p.text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.35)))
    }

    private var migrate: some View {
        VStack(alignment: .leading, spacing: 22) {
            groupLabel("SWITCH TO DORY")
            VStack(alignment: .leading, spacing: 12) {
                Text("Import images, volumes, networks, and containers from Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, or another Docker-compatible engine onto Dory's engine. Source volume data is mounted read-only while Dory uses temporary helper containers for the copy.")
                    .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.migrationSources.count > 1 {
                    HStack(spacing: 8) {
                        Text("Source").font(.system(size: 11.5)).foregroundStyle(p.text3)
                        Picker("Source", selection: Binding(
                            get: { store.selectedMigrationSourcePath ?? store.migrationSources.first?.socketPath ?? "" },
                            set: { path in Task { await store.selectMigrationSource(path) } }
                        )) {
                            ForEach(store.migrationSources) { engine in
                                Text(engine.pickerLabel).tag(engine.socketPath)
                            }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("migrate-source-picker")
                    }
                }
                if let inv = store.migrationInventory {
                    preflightPanel(inv)
                } else {
                    Text(store.migrationSources.isEmpty
                        ? "No Docker-compatible local engine detected."
                        : "Couldn't read \(store.migrationSources.first(where: { $0.socketPath == store.selectedMigrationSourcePath })?.label ?? "the selected engine") — is it running?")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                Button {
                    if store.migrationBusy {
                        store.cancelMigrationImport()
                    } else {
                        store.beginImportFromDocker()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if store.migrationBusy { ProgressView().controlSize(.small) }
                        Text(store.migrationBusy
                            ? "Cancel Import"
                            : (store.migrationInventory?.isImportBlocked == true
                                ? "Recheck & Import"
                                : "Import from Engine"))
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(p.accent.opacity(store.migrationBusy ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(store.migrationSources.isEmpty || store.runtimeKind != .sharedVM)
                .accessibilityIdentifier("migrate-import")
                if store.migrationInventory != nil && store.runtimeKind != .sharedVM {
                    Text("Switch to Dory's daemon engine (Engine & Daemon tab) to import.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                if !store.migrationStatus.isEmpty {
                    Text(store.migrationStatus).font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                if let failures = store.migrationSummary?.failures, !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(failures.prefix(8), id: \.self) { failure in
                            Text("• \(failure)").font(.system(size: 11)).foregroundStyle(p.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if failures.count > 8 {
                            Text("+ \(failures.count - 8) more").font(.system(size: 11)).foregroundStyle(p.text3)
                        }
                    }
                }
                if let warnings = store.migrationSummary?.warnings, !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(warnings.prefix(8), id: \.self) { warning in
                            Text("• \(warning)").font(.system(size: 11)).foregroundStyle(p.amber)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if warnings.count > 8 {
                            Text("+ \(warnings.count - 8) more").font(.system(size: 11)).foregroundStyle(p.text3)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("HOW DORY COMPARES")
            comparisonTable
            Text("Free and open source — including at work. OrbStack requires a paid license for commercial use; Docker Desktop requires a paid subscription for larger companies.")
                .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.loadMigrationPreflight() }
    }

    private func preflightPanel(_ inv: MigrationInventory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                preflightStat("\(inv.images)", "images")
                preflightStat("\(inv.containers)", "containers")
                preflightStat("\(inv.volumes)", "volumes")
                preflightStat(inv.requiredHostDiskDisplay, "space needed")
            }
            HStack(spacing: 7) {
                Glyph(glyph: .shield, size: 12, color: inv.confidenceLabel == "High confidence" ? p.green : (inv.confidenceLabel == "Blocked" ? p.red : p.amber))
                Text("\(inv.confidenceLabel) from \(inv.sourceName). \(inv.sourceName) is read only until you start the import, and aborting before import writes nothing.")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.text2).lineSpacing(3)
            }
            preflightList("Transfers", inv.transferItems, color: p.text2)
            preflightList("Needs attention", inv.attentionItems, color: inv.confidenceLabel == "High confidence" ? p.text3 : (inv.confidenceLabel == "Blocked" ? p.red : p.amber))
            if !inv.targetCollisionBlockers.isEmpty {
                preflightList(
                    "Target conflicts — resolve all",
                    inv.targetCollisionBlockers,
                    color: p.red,
                    limit: 20
                )
            }
            Text("Images are copied and containers recreated on Dory. Compose labels, ports, and detected networks are preserved where the source engine exposes them.")
                .font(.system(size: 11.5)).foregroundStyle(p.text2).lineSpacing(3)
            if inv.volumes > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Glyph(glyph: .shield, size: 12, color: p.green)
                    Text("Dory copies all \(inv.volumes) named volume\(inv.volumes == 1 ? "" : "s") through read-only source mounts. Keep \(inv.sourceName) installed until you validate the imported data; Dory never deletes the source volumes.")
                        .font(.system(size: 11)).foregroundStyle(p.text3).lineSpacing(3)
                }
                .padding(.top, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 9))
    }

    private func preflightList(
        _ title: String,
        _ items: [String],
        color: Color,
        limit: Int = 5
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold)).foregroundStyle(p.text3).tracking(0.4)
            ForEach(items.prefix(limit), id: \.self) { item in
                Text("• \(item)").font(.system(size: 11)).foregroundStyle(color).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if items.count > limit {
                Text("+ \(items.count - limit) more").font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
        .padding(.top, 2)
    }

    private func preflightStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(p.accentText)
            Text(label).font(.system(size: 10.5)).foregroundStyle(p.text3)
        }
    }

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            comparisonHeader
            comparisonRow("Free for all commercial use", .yes, .no("$8/mo annual"), .no("Paid for large orgs"), divider: true)
            comparisonRow("Open source", .yes, .no(nil), .no(nil), divider: true)
            comparisonRow("One shared VM engine", .yes, .yes, .no(nil), divider: true)
            comparisonRow("Hypervisor-backed virtualization", .yes, .yes, .no(nil), divider: true)
            comparisonRow("*.local domains + HTTPS", .yes, .yes, .no(nil), divider: true)
            comparisonRow("Drop-in docker & kubectl", .yes, .yes, .yes, divider: true)
            comparisonRow("Kubernetes built-in", .yes, .yes, .yes, divider: true)
            comparisonRow("Common x86 / amd64 images", .yes, .yes, .yes, divider: false)
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private var managed: some View {
        let json = store.managedSettingsJSON()
        return VStack(alignment: .leading, spacing: 22) {
            groupLabel("FLEET DEFAULTS")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Managed settings profile")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.text)
                        Text("Config-file and MDM-friendly defaults for engine, DNS, Auto-Idle, sandbox file-sharing, and telemetry. Local features stay free; telemetry is none.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.text3)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy JSON")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("managed-copy-json")
                }
                ScrollView(.horizontal) {
                    Text(json)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.text2)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
        }
    }

    private var localTools: some View {
        VStack(alignment: .leading, spacing: 22) {
            groupLabel("LOCAL DORYD TOOLS")
            VStack(alignment: .leading, spacing: 12) {
                Text("Dory's daemon features are available from any terminal through the bundled `dory` CLI. Stable commands are release-supported; preview rows call out their prerequisites before you rely on them.")
                    .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    ForEach(store.localDorydCapabilities) { capability in
                        localToolRow(capability)
                    }
                }
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("WHAT THIS COVERS")
            VStack(spacing: 0) {
                localToolFact("Daemon-owned state", "The app can close while doryd keeps Docker, machines, Auto-Idle, networking, and durable state on disk.")
                localToolFact("Agent-ready JSON", "Doctor, guide, wait, events, and MCP all expose stable structured output for automation.")
                localToolFact("Isolated sandbox runs", "Preview sandbox commands run in dedicated Linux machines with no host file sharing by default when dorydctl and machine assets are bundled.")
                localToolFact("Visible recovery", "Diagnostics and event history make sleep, wake, memory reclaim, and incidents inspectable before asking users to restart.")
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
        }
    }

    private func localToolRow(_ capability: LocalDorydCapability) -> some View {
        HStack(spacing: 11) {
            Image(systemName: localToolIcon(capability.id))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.accentText)
                .frame(width: 28, height: 28)
                .background(p.accentWeak, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(capability.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(capability.status)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(capability.status == "Preview" ? p.amber : p.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(p.bgElevated, in: Capsule())
                }
                Text(capability.summary)
                    .font(.system(size: 11.2))
                    .foregroundStyle(p.text3)
                    .lineLimit(2)
                Text(capability.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                copy(capability.command)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.text2)
                    .frame(width: 30, height: 28)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            }
            .buttonStyle(.plain)
            .help("Copy command")
            .accessibilityIdentifier("local-tool-copy-\(capability.id)")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func localToolFact(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(p.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func localToolIcon(_ id: String) -> String {
        switch id {
        case "support-bundle": "stethoscope"
        case "agent-guide": "curlybraces.square"
        case "mcp": "point.3.connected.trianglepath.dotted"
        case "sandbox": "shippingbox.and.arrow.backward"
        case "wait": "timer"
        case "events": "waveform.path.ecg"
        default: "terminal"
        }
    }

    private var comparisonHeader: some View {
        HStack(spacing: 0) {
            Text("").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Dory", "OrbStack", "Docker"], id: \.self) { name in
                Text(name).font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(name == "Dory" ? p.accentText : p.text3)
                    .frame(width: 92)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private enum Cell { case yes, no(String?) }

    private func comparisonRow(_ label: String, _ dory: Cell, _ orb: Cell, _ docker: Cell, divider: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(p.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            cellView(dory, highlight: true)
            cellView(orb, highlight: false)
            cellView(docker, highlight: false)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(p.border).frame(height: 1) } }
    }

    @ViewBuilder private func cellView(_ cell: Cell, highlight: Bool) -> some View {
        Group {
            switch cell {
            case .yes:
                Glyph(glyph: .shield, size: 13, color: p.green)
            case .no(let note):
                VStack(spacing: 1) {
                    Text("✕").font(.system(size: 12, weight: .bold)).foregroundStyle(p.text3)
                    if let note { Text(note).font(.system(size: 9)).foregroundStyle(p.text3).multilineTextAlignment(.center) }
                }
            }
        }
        .frame(width: 92)
    }

    private var general: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 0) {
            groupLabel("STARTUP")
            VStack(spacing: 0) {
                toggleRow("Launch Dory at login", "Start the engine automatically when you log in.", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }), divider: true)
                toggleRow("Show menu bar icon", store.isAgentMode ? "Always on — Dory runs in the menu bar in background mode." : "Quick access to containers from the menu bar.", isOn: Binding(get: { store.showMenuBarIcon }, set: { store.setShowMenuBarIcon($0) }), divider: true, disabled: store.isAgentMode)
                toggleRow("Keep doryd running after quit", "Leave the daemon, Docker socket, local domains, and machines available after the Dory app exits. Turn off to stop doryd when you quit Dory.", isOn: Binding(get: { store.keepDorydRunningAfterQuit }, set: { store.setKeepDorydRunningAfterQuit($0) }), divider: true)
                toggleRow("Terminal docker command", "doryd keeps `docker`, `docker compose`, `kubectl`, and Dory support commands ready in `~/.dory/bin` and points them at Dory's engine. No Docker Desktop or admin setup required; turn off to remove.", isOn: Binding(get: { store.routeDockerCLI }, set: { store.setRouteDockerCLI($0) }), divider: false)
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            groupLabel("BROWSER LOGINS")
            VStack(spacing: 0) {
                toggleRow("Open logins on my Mac", "Let CLIs inside a machine open the login page in your Mac browser and complete the localhost callback.", isOn: Binding(get: { store.openLoginsOnMac }, set: { store.setOpenLoginsOnMac($0) }), divider: false)
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            dockerHostCallout

            groupLabel("APPEARANCE")
            HStack(spacing: 10) {
                appearanceCard(.light, "Light", LinearGradient(colors: [Color(hex: 0xDCE9F7), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
                appearanceCard(.dark, "Dark", LinearGradient(colors: [Color(hex: 0x1B1D21), Color(hex: 0x2A2C33)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }

    @ViewBuilder private var dockerHostCallout: some View {
        if store.dockerHostCleaned {
            calloutCard(p.green) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dory is the default `docker`").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text("Removed the conflicting `DOCKER_HOST` from your shell startup files (a `.dory.bak` backup was saved next to each). New terminals now reach Dory through its docker context while it's running, and fall back when it's not.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text2).lineSpacing(3)
                    Button { store.undoDockerHostCleanup() } label: {
                        Text("Undo").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("docker-host-undo")
                }
            }
            .padding(.bottom, 22)
        } else if let conflict = store.dockerHostConflict {
            calloutCard(p.amber) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A pinned `DOCKER_HOST` is overriding Dory").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text("Your shell sets `DOCKER_HOST` to `\(shortHost(conflict.effectiveHost))`, which takes priority over Dory's docker context. New terminals keep using it until it's removed.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text2).lineSpacing(3)
                    if conflict.isFixable {
                        Text("Found in \(conflict.sites.map(\.displayPath).joined(separator: ", ")).")
                            .font(.system(size: 11)).foregroundStyle(p.text3)
                        Button { Task { await store.resolveDockerHostConflict() } } label: {
                            Text("Make Dory the default docker")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("docker-host-fix")
                        Text("Comments the line out and keeps a backup — reversible anytime.")
                            .font(.system(size: 11)).foregroundStyle(p.text3)
                    } else {
                        Text("Remove the `export DOCKER_HOST=…` line from your shell profile, then open a new terminal.")
                            .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                    }
                }
            }
            .padding(.bottom, 22)
        }
    }

    private func calloutCard<Content: View>(_ accent: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Glyph(glyph: .shield, size: 14, color: accent)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.4)))
    }

    private func shortHost(_ host: String) -> String {
        host.hasPrefix("unix://") ? String(host.dropFirst("unix://".count)) : host
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>, divider: Bool, disabled: Bool = false) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
            DoryToggle(isOn: isOn)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .opacity(disabled ? 0.55 : 1)
        .allowsHitTesting(!disabled)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(p.border).frame(height: 1) } }
    }

    private func appearanceCard(_ appearance: DoryAppearance, _ label: String, _ preview: LinearGradient) -> some View {
        let selected = store.appearance == appearance
        return Button { store.setAppearance(appearance) } label: {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 7).fill(preview).frame(height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
            }
            .padding(13)
            .frame(maxWidth: .infinity)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? p.accent : p.border, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance-\(appearance.rawValue)")
    }

    private var resources: some View {
        let cores = ProcessInfo.processInfo.processorCount
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return VStack(alignment: .leading, spacing: 20) {
            groupLabel("DATA DRIVE")
            dataDrivePanel

            groupLabel("DORY PROCESSES")
            processMemoryPanel

            groupLabel("THIS MAC")
            resourceMeter("CPU cores", "\(cores) logical cores available", 1)
            resourceMeter("Memory", String(format: "%.0f GB installed", ramGB), 1)
            infoPanel("Dory tracks the app, doryd, the engine VM, machine VMs, networking helpers, and bundled CLI helpers separately. Auto-Idle is handled by doryd, so the engine VM can sleep when no workload needs it while state remains on disk.")
        }
        .task { await store.refreshProcessMemory() }
    }

    private struct DataDrivePresentation {
        let url: URL
        let title: String
        let isReady: Bool
        let dockerUsage: DockerDataDiskUsage?
        let problem: String?
    }

    private var dataDrivePresentation: DataDrivePresentation {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["DORYD_DATA_DRIVE"] ?? environment["DORY_DATA_DRIVE"]
        do {
            let selectionStore = try DoryDataDriveSelectionStore()
            if let selected = try selectionStore.inspectSelection(requestedRoot: configured) {
                return DataDrivePresentation(
                    url: URL(fileURLWithPath: selected.root),
                    title: "Managed drive ready",
                    isReady: true,
                    dockerUsage: try DockerDataDisk.usage(at: selected.engineDataDiskPath),
                    problem: nil
                )
            }
            let drive = try DoryDataDrive(overrideRoot: configured)
            switch try drive.inspect() {
            case .absent:
                return DataDrivePresentation(
                    url: URL(fileURLWithPath: drive.root),
                    title: "Managed drive initializes on first start",
                    isReady: false,
                    dockerUsage: nil,
                    problem: nil
                )
            case .ready:
                let error = DoryDataDriveSelectionError.unselectedExistingDrive(drive.root)
                return DataDrivePresentation(
                    url: URL(fileURLWithPath: drive.root),
                    title: "Managed drive needs explicit selection",
                    isReady: false,
                    dockerUsage: nil,
                    problem: error.description
                )
            }
        } catch {
            let selectionStore = try? DoryDataDriveSelectionStore()
            let remembered = try? selectionStore?.selectedPath()
            let fallback = configured ?? remembered ?? DoryDataDrive.defaultRoot()
            return DataDrivePresentation(
                url: URL(fileURLWithPath: fallback).standardizedFileURL,
                title: "Managed drive unavailable",
                isReady: false,
                dockerUsage: nil,
                problem: String(describing: error)
            )
        }
    }

    private var dataDrivePanel: some View {
        let presentation = dataDrivePresentation
        let url = presentation.url
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(presentation.isReady ? p.green : p.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(url.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(p.text3)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Reveal in Finder") {
                    if presentation.isReady {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.isReady)
                .accessibilityIdentifier("reveal-data-drive")
            }
            if let problem = presentation.problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.red)
                    .textSelection(.enabled)
            }
            if let usage = presentation.dockerUsage {
                Divider().overlay(p.border)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Docker storage")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(p.text)
                        Text("\(usage.capacityGiB) GiB capacity • \(physicalSize(usage.allocatedBytes)) on this Mac")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.text3)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if growthOptions(after: usage.capacityGiB).isEmpty {
                        Text("Maximum capacity")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(p.text3)
                    } else {
                        Menu("Grow…") {
                            ForEach(growthOptions(after: usage.capacityGiB), id: \.self) { capacityGiB in
                                Button("\(capacityGiB) GiB") {
                                    Task { await store.growDockerDataDisk(toGiB: capacityGiB) }
                                }
                            }
                        }
                        .disabled(store.engineSettingChangeBusy || !store.dorydRuntimeActive)
                        .accessibilityIdentifier("grow-docker-storage")
                    }
                }
                Text("Capacity is a sparse logical ceiling, not reserved Mac storage. Dory allocates physical space only as data is written. Growth is safe and automatic; shrinking is intentionally refused.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.text3)
                    .lineSpacing(3)
            }
            Text("Images, containers, named volumes, machine disks, snapshots, and backups live together here. Runtime sockets and replaceable logs remain in ~/.dory.")
                .font(.system(size: 11.5))
                .foregroundStyle(p.text2)
                .lineSpacing(3)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private func growthOptions(after capacityGiB: Int) -> [Int] {
        [256, 512, 1_024, 2_048].filter { $0 > capacityGiB }
    }

    private func physicalSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func resourceMeter(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Text(value).font(.system(size: 12.5, weight: .bold)).monospacedDigit().foregroundStyle(p.accentText)
            }
            ThinBar(fraction: fraction, tint: p.accent, height: 6)
        }
    }

    private var processMemoryPanel: some View {
        let snapshot = store.processMemorySnapshot
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.totalResidentDisplay)
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(p.accentText)
                    Text("resident across Dory processes")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await store.refreshProcessMemory() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.text2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            if snapshot.groupedRows.isEmpty {
                Text("No Dory processes found.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
            } else {
                ForEach(snapshot.groupedRows) { row in
                    memoryRow(row)
                }
            }
            if snapshot.duplicateAppInstanceCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(p.amber)
                    Text("\(snapshot.duplicateAppInstanceCount) extra Dory app instance\(snapshot.duplicateAppInstanceCount == 1 ? "" : "s") detected.")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.amber)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15).padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
            }
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private func memoryRow(_ row: DoryProcessMemoryRow) -> some View {
        HStack(spacing: 10) {
            Circle().fill(processDot(row.role)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Text(row.subtitle).font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.residentDisplay)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(p.text2)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func processDot(_ role: DoryProcessRole) -> Color {
        switch role {
        case .app: p.accentText
        case .daemon: p.green
        case .dockerVM, .machineVM: p.amber
        case .networking: p.accent
        case .helper: p.text3
        }
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 22) {
            groupLabel("NEW MACHINE DEFAULTS")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Host environment allow-list")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.text)
                        Text("Only named variables are copied when a new machine is created. Empty values are skipped; values are read at creation time.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.text3)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Button(action: commitMachineEnvAllowListDraft) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 26)
                            .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Save environment allow-list")
                    .accessibilityIdentifier("machine-env-save")
                }
                TextField("ANTHROPIC_API_KEY, GH_TOKEN", text: $machineEnvAllowListDraft, onCommit: commitMachineEnvAllowListDraft)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .foregroundStyle(p.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    .accessibilityIdentifier("machine-env-allow-list")
                VStack(spacing: 0) {
                    machineEnvToggleRow("ANTHROPIC_API_KEY", divider: true)
                    ForEach(MachineEnvImport.optionalExtras, id: \.self) { name in
                        machineEnvToggleRow(name, divider: name != (MachineEnvImport.optionalExtras.last ?? ""))
                    }
                }
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
                Text(machineEnvAllowListSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.text3)
                    .lineLimit(2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("AGENT SANDBOXES")
            VStack(spacing: 0) {
                machinePolicyRow("Persistent machines", "No host folders are shared unless the create request includes mounts. Settings above control which host env names may be copied.", divider: true)
                machinePolicyRow("Sandbox runs", "`dory sandbox run` starts a dedicated VM with no host file sharing by default. Add mounts explicitly for scoped workspace access.", divider: true)
                machinePolicyRow("Shell access", "`dory machine shell NAME` and `dory machine exec NAME -- ...` enter the VM boundary; the agent sees machine files, mounted folders, and copied env only.", divider: false)
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
        }
        .onAppear(perform: syncMachineEnvAllowListDraft)
        .onChange(of: store.machineEnvAllowList) { _, _ in syncMachineEnvAllowListDraft() }
    }

    private func machineEnvToggleRow(_ name: String, divider: Bool) -> some View {
        toggleRow(
            name,
            machineEnvDraftNames.contains(name) ? "Copied when present" : "Not copied",
            isOn: Binding(
                get: { machineEnvDraftNames.contains(name) },
                set: { enabled in setMachineEnvDraft(name, enabled: enabled) }
            ),
            divider: divider
        )
    }

    private func machinePolicyRow(_ title: String, _ subtitle: String, divider: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(p.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(p.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.text3)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(p.border).frame(height: 1) } }
    }

    private var machineEnvDraftNames: [String] {
        MachineEnvImport.parse(machineEnvAllowListDraft)
    }

    private var machineEnvAllowListSummary: String {
        let names = MachineEnvImport.normalize(store.machineEnvAllowList)
        guard !names.isEmpty else { return "No host environment variables are copied to new machines." }
        return "Saved: \(names.joined(separator: ", "))"
    }

    private func syncMachineEnvAllowListDraft() {
        machineEnvAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList)
    }

    private func commitMachineEnvAllowListDraft() {
        let names = MachineEnvImport.parse(machineEnvAllowListDraft)
        store.setMachineEnvAllowList(names)
        machineEnvAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList)
    }

    private func setMachineEnvDraft(_ name: String, enabled: Bool) {
        var names = machineEnvDraftNames
        if enabled {
            names.append(name)
        } else {
            names.removeAll { $0 == name }
        }
        machineEnvAllowListDraft = MachineEnvImport.serialize(names)
        store.setMachineEnvAllowList(names)
        machineEnvAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList)
    }

    private var engine: some View {
        let kind = store.runtimeKind
        let onShared = kind == .sharedVM
        let sharedSupport = store.sharedVMSupport
        return VStack(alignment: .leading, spacing: 20) {
            groupLabel("ACTIVE ENGINE")
            HStack(spacing: 12) {
                Circle().fill(store.engineRunning ? p.green : p.text3).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text(engineDescription(for: kind)).font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("v\(store.engineVersion)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(p.accentText)
                    Text(store.runtimeAuthorityDisplay).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("ENGINE BACKEND")
            engineBackendCard
                .padding(.bottom, 22)

            groupLabel("DORY DAEMON ENGINE")
            VStack(alignment: .leading, spacing: 12) {
                Text("Run containers in Dory's daemon-managed Linux engine VM. The app talks to doryd over launchd/XPC; doryd owns the Docker socket, local networking, wake/sleep, Auto-Idle, and durable engine state. Linux Machines are separate VM machines with their own assigned addresses, not containers inside this engine.")
                    .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        Task { await store.useSharedVM() }
                    } label: {
                        Text(onShared ? (store.dorydRuntimeActive ? "Managed by doryd" : "Running on Dory's engine") : "Use Dory's daemon")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(onShared ? p.text2 : .white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(onShared ? p.bgInput : p.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(onShared || !sharedSupport.isSupported)
                    .accessibilityIdentifier("use-shared-vm")
                    if onShared {
                        Button {
                            Task { await store.restartEngine() }
                        } label: {
                            Label(store.isConnecting ? "Restarting…" : "Restart Engine", systemImage: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(p.text2)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isConnecting)
                        .accessibilityIdentifier("restart-engine")
                    }
                }
                if !sharedSupport.isSupported {
                    Text("Unavailable: \(sharedSupport.reason).")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3)
                } else if !store.sharedVMStatus.isEmpty {
                    Text(store.sharedVMStatus).font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            groupLabel("LOCAL DORYD SURFACE")
            dorydCapabilitiesCard
                .padding(.bottom, 22)

            if MacHostPlatform.current().isAppleSilicon {
                groupLabel("X86 / AMD64")
                VStack(spacing: 0) {
                    toggleRow(
                        "Run Intel (x86/amd64) images",
                        "Use Dory's built-in FEX runtime for amd64 images and BuildKit workloads, including nested seccomp sandboxes. Enabled by default on new Apple Silicon installs; native arm64 images remain faster. Restarts the engine.",
                        isOn: Binding(get: { store.rosettaX86Enabled }, set: { on in Task { await store.setRosettaX86(on) } }),
                        divider: false,
                        disabled: !onShared
                    )
                }
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
                if !onShared {
                    Text("Switch to Dory's shared engine above to run x86/amd64 images.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3).padding(.top, 8)
                }
            }

            groupLabel("GPU ACCELERATION (EXPERIMENTAL)")
            gpuAccelerationCard
                .padding(.bottom, 12)
            VStack(spacing: 0) {
                toggleRow(
                    "Enable GPU acceleration for AI & compute",
                    "Attaches a virtio-gpu device (Mesa Venus in the guest, virglrenderer and MoltenVK on your Mac) so Vulkan and GPU compute inside containers reach Apple Metal. Toggling this restarts the engine to apply, then run a container with `--gpus all` on an image that ships Mesa's Venus Vulkan driver.",
                    isOn: Binding(get: { store.gpuVenusEnabled }, set: { on in Task { await store.setGPUVenus(on) } }),
                    divider: false,
                    disabled: !onShared || !store.gpuRuntimeAvailable
                )
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            if onShared, store.gpuRuntimeAvailable {
                Text("Changes apply when the engine restarts (done automatically). Existing containers keep their old settings until recreated.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3).padding(.top, 8)
            }
            if !onShared {
                Text("Switch to Dory's shared engine above to use GPU acceleration.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).padding(.top, 8)
            } else if !store.gpuArchitectureSupported {
                Text("In-guest Venus GPU acceleration is currently supported and release-verified only on Apple silicon. Intel Macs can still reach Metal-backed host services such as Ollama or LM Studio at host.dory.internal.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3).padding(.top, 8)
            } else if !store.gpuRuntimeAvailable {
                Text("Install or bundle the provenance-verified GPU kernel and Venus runtime (virglrenderer plus MoltenVK) to enable this. Until then, run a Metal-backed host service such as Ollama, LM Studio, or MLX and reach it from containers at host.dory.internal on ports 11434, 1234, and 18190.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3).padding(.top, 8)
            }
        }
    }

    /// Colima-style backend picker: Dory's bundled engine, an auto-detected existing engine, or a
    /// custom Docker-compatible socket. Detected engines are listed so the choice is informed.
    private var engineBackendCard: some View {
        VStack(spacing: 0) {
            ForEach(EnginePreference.allCases) { preference in
                engineChoiceRow(preference, detected: detectedEngineSources)
                if preference != EnginePreference.allCases.last {
                    Rectangle().fill(p.border).frame(height: 1)
                }
            }
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
        .task { detectedEngineSources = await Task.detached { DockerEngineSocketDiscovery.availableSources() }.value }
    }

    @ViewBuilder private func engineChoiceRow(_ preference: EnginePreference, detected: [DockerSourceEngine]) -> some View {
        let selected = store.enginePreference == preference
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await store.setEnginePreference(preference) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? p.accent : p.text3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preference.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        Text(preference == .external && !detected.isEmpty
                            ? "Found: \(detected.map(\.label).joined(separator: ", "))"
                            : preference.summary)
                            .font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("engine-backend-\(preference.rawValue)")

            if preference == .custom, selected {
                HStack(spacing: 8) {
                    TextField("/path/to/docker.sock", text: $customSocketDraft)
                        .textFieldStyle(.plain)
                        .font(.mono(12))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                        .onAppear { if customSocketDraft.isEmpty { customSocketDraft = store.customEngineSocket } }
                    Button {
                        Task { await store.setEnginePreference(.custom, customSocket: customSocketDraft) }
                    } label: {
                        Text("Connect").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(customSocketDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 15).padding(.bottom, 12)
            }
        }
    }

    private var dorydCapabilitiesCard: some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(store.dorydRuntimeActive ? p.green : p.amber).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local daemon tools")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text("Stable local tools are ready from the bundled `dory` CLI; sandbox is preview with explicit prerequisites.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    store.settingsTab = .localTools
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.accentText)
                }
                .buttonStyle(.plain)
            }
            Text("These are local-only doryd features: no cloud control plane, no remote dependency, and no external runtime required. They let users diagnose, automate, and observe Dory from any terminal, with sandbox runs gated as a preview machine workflow.")
                .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private var gpuAccelerationCard: some View {
        let available = store.gpuRuntimeAvailable
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(available ? p.green : p.text3).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(available
                        ? "Venus GPU runtime detected"
                        : (store.gpuArchitectureSupported ? "Venus GPU runtime not found" : "Venus GPU requires Apple silicon"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text(available
                        ? "A verified GPU kernel, Venus-capable virglrenderer, and MoltenVK ICD are available to the engine."
                        : (store.gpuArchitectureSupported
                            ? "Needs the GPU kernel plus a Venus-capable libvirglrenderer and MoltenVK ICD, bundled in the app or installed for development."
                            : "Intel Venus is not advertised: no physical Intel result or x86 GPU kernel has been release-verified."))
                        .font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(3)
                }
                Spacer(minLength: 0)
                Text("Experimental")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(p.text3)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.bgInput, in: Capsule())
            }
            Text("Best for running Vulkan or GPU compute (llama.cpp, ComfyUI, ML inference) inside Linux containers against your Mac's GPU. For host-side AI tools like Ollama or LM Studio, containers can already reach them at host.dory.internal on ports 11434, 1234, and 18190 without enabling this.")
                .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private func engineDescription(for kind: RuntimeKind) -> String {
        switch kind {
        case .docker: "Proxying a host Docker-compatible engine"
        case .sharedVM: store.dorydRuntimeActive ? "Daemon-managed Linux engine VM" : "One shared Linux VM on Dory's own engine"
        case .mock: "Demo data"
        case .disconnected: "No engine running"
        }
    }

    private func infoPanel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
            .padding(.bottom, 10)
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel("LOCAL DOMAINS")
            VStack(spacing: 0) {
                toggleRow(
                    "Enable *.\(store.domainSuffix) domains",
                    "Let doryd publish automatic local names with HTTPS for containers and machine addresses. Turn this off if proxy ports conflict or managed DNS cannot be pointed at Dory.",
                    isOn: Binding(get: { store.domainsEnabled }, set: { store.applyNetworkingSettings(domainsEnabled: $0) }),
                    divider: true
                )
                domainSuffixField
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            groupLabel("SYSTEM ACCESS")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Authorize doryd networking")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.text)
                        Text("Applies doryd's current resolver and macOS port-redirect plan for \(store.domainSuffix), including 80/443 and any published low TCP ports.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.text3)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await store.authorizeLocalNetworking() }
                    } label: {
                        Text(store.networkingAuthorizationInFlight ? "Authorizing" : "Authorize")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(store.dorydRuntimeActive ? p.accent : p.text3, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.dorydRuntimeActive || store.networkingAuthorizationInFlight)
                    Button {
                        Task { await store.deauthorizeLocalNetworking() }
                    } label: {
                        Text("Remove")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.text2)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(p.bg, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.dorydRuntimeActive || store.networkingAuthorizationInFlight)
                }
                if let message = store.networkingAuthorizationMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.text3)
                        .lineLimit(4)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            groupLabel("PORTS")
            VStack(alignment: .leading, spacing: 12) {
                portField("DNS resolver", store: $dnsPortDraft, fallback: AppStore.defaultDNSPort) { store.applyNetworkingSettings(dnsPort: $0) }
                portField("HTTP proxy", store: $httpPortDraft, fallback: AppStore.defaultHTTPProxyPort) { store.applyNetworkingSettings(httpProxyPort: $0) }
                portField("HTTPS proxy", store: $httpsPortDraft, fallback: AppStore.defaultHTTPSProxyPort) { store.applyNetworkingSettings(httpsProxyPort: $0) }
                Text("Change these if the defaults (15353 / 8080 / 8443) collide with other software. Saved on Return; doryd local networking restarts to rebind.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .opacity(store.domainsEnabled ? 1 : 0.55)
            .allowsHitTesting(store.domainsEnabled)

            groupLabel("LAN ACCESS").padding(.top, 22)
            VStack(spacing: 0) {
                toggleRow(
                    "Source-preserving LAN access",
                    "Off (default): published ports are reachable only from this Mac. On: authorized packet routing lets LAN and Tailscale clients reach containers without replacing their source IP. Takes effect after the engine restarts.",
                    isOn: Binding(get: { store.lanVisible }, set: { on in Task { await store.setLanVisible(on) } }),
                    divider: false
                )
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            Text("Dory never widens an explicit 127.0.0.1 or ::1 binding. Enabling LAN access requires macOS approval for Dory's signed root networking service; the generic gvproxy hop is not used for remote clients.")
                .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            domainSuffixDraft = store.domainSuffix
            dnsPortDraft = String(store.dnsPort)
            httpPortDraft = String(store.httpProxyPort)
            httpsPortDraft = String(store.httpsProxyPort)
            store.loadLanVisible()
        }
    }

    private var domainSuffixField: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Domain suffix")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                Text("Use a unique suffix per macOS user account, such as augustus.dory.local.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                TextField(AppStore.defaultDomainSuffix, text: $domainSuffixDraft, onCommit: commitDomainSuffixDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 190)
                    .accessibilityIdentifier("domain-suffix")
                Button(action: commitDomainSuffixDraft) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 26)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Save domain suffix")
                .accessibilityIdentifier("domain-suffix-save")
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private func commitDomainSuffixDraft() {
        let raw = domainSuffixDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.applyNetworkingSettings(domainSuffix: raw)
        if let normalized = AppStore.normalizedDomainSuffix(raw) {
            domainSuffixDraft = normalized
        }
    }

    private func portField(_ label: String, store draft: Binding<String>, fallback: UInt16, apply: @escaping (UInt16) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
            TextField(String(fallback), text: draft, onCommit: {
                let port = UInt16(draft.wrappedValue.trimmingCharacters(in: .whitespaces)) ?? fallback
                draft.wrappedValue = String(port)
                apply(port)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 100)
            .accessibilityIdentifier("port-\(label)")
            Spacer(minLength: 0)
        }
    }
    private var aboutText: String {
        "Dory \(AppInfo.version) (build \(AppInfo.build)). A self-contained, memory-efficient alternative to Docker Desktop and OrbStack, built for macOS — free and open source. © 2026 Dory contributors."
    }
}
