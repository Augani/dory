import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var envAllowListDraft = ""
    @State private var dnsPortDraft = ""
    @State private var httpPortDraft = ""
    @State private var httpsPortDraft = ""
    @State private var customSocketDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            subNav
            ScrollView {
                content
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        case .engine: engine
        case .autoIdle: AutoIdleView()
        case .network: network
        case .usb: UsbDevicesView()
        case .migrate: migrate
        case .about: infoPanel(aboutText)
        }
    }

    private var migrate: some View {
        VStack(alignment: .leading, spacing: 22) {
            groupLabel("SWITCH TO DORY")
            VStack(alignment: .leading, spacing: 12) {
                Text("Import your images and containers from Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, or another Docker-compatible engine onto Dory's engine. Your source engine is only read — nothing there is modified, so you can switch back anytime.")
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
                                Text(engine.label).tag(engine.socketPath)
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
                    Task { await store.importFromDocker() }
                } label: {
                    HStack(spacing: 8) {
                        if store.migrationBusy { ProgressView().controlSize(.small) }
                        Text(store.migrationBusy ? "Importing…" : "Import from Engine")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(p.accent.opacity(store.migrationBusy ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(store.migrationBusy || store.migrationInventory == nil || store.runtimeKind != .sharedVM)
                .accessibilityIdentifier("migrate-import")
                if store.migrationInventory != nil && store.runtimeKind != .sharedVM {
                    Text("Switch to Dory's shared VM (Docker Engine tab) to import.")
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
            }
            Text("Found on \(inv.sourceName). Images are copied and containers recreated on Dory — \(inv.sourceName) is left untouched.")
                .font(.system(size: 11.5)).foregroundStyle(p.text2).lineSpacing(3)
            if inv.volumes > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Glyph(glyph: .shield, size: 12, color: p.amber)
                    Text("Volume **data** isn't copied automatically — your \(inv.volumes) named volume\(inv.volumes == 1 ? "" : "s") stay in \(inv.sourceName). Re-mount or re-create them in Dory.")
                        .font(.system(size: 11)).foregroundStyle(p.text3).lineSpacing(3)
                }
                .padding(.top, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 9))
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
            comparisonRow("Free for commercial use", .yes, .no("$8/user/mo"), .no("Paid for business"), divider: true)
            comparisonRow("Open source", .yes, .no(nil), .no(nil), divider: true)
            comparisonRow("Low memory (one shared VM)", .yes, .yes, .no(nil), divider: true)
            comparisonRow("Apple-native virtualization", .yes, .yes, .no(nil), divider: true)
            comparisonRow("*.local domains + HTTPS", .yes, .yes, .no(nil), divider: true)
            comparisonRow("Drop-in docker & kubectl", .yes, .yes, .yes, divider: true)
            comparisonRow("Kubernetes built-in", .yes, .yes, .yes, divider: true)
            comparisonRow("Rosetta-fast x86", .yes, .yes, .partial, divider: false)
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
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

    private enum Cell { case yes, no(String?), partial }

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
            case .partial:
                Text("~").font(.system(size: 15, weight: .bold)).foregroundStyle(p.amber)
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
                toggleRow("Set up the docker command", "Installs `docker` and `docker compose` for your terminal (into `~/.dory/bin`, added to your PATH) and points them at Dory's engine, so `docker` just works with nothing else installed. No admin needed; turn off to remove.", isOn: Binding(get: { store.routeDockerCLI }, set: { store.setRouteDockerCLI($0) }), divider: false)
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

            groupLabel("MACHINE SECRETS")
            VStack(alignment: .leading, spacing: 8) {
                Text("Comma-separated env var names to copy from your shell into new machines. \(MachineEnvImport.defaultNames.joined(separator: ", ")) is always included; common extras: \(MachineEnvImport.optionalExtras.joined(separator: ", ")).")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                TextField("ANTHROPIC_API_KEY, GH_TOKEN", text: $envAllowListDraft, onCommit: {
                    store.setMachineEnvAllowList(MachineEnvImport.parse(envAllowListDraft))
                    envAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityIdentifier("machine-env-allowlist")
                .onChange(of: envAllowListDraft) { _, newValue in
                    store.setMachineEnvAllowList(MachineEnvImport.parse(newValue))
                }
                Text("These secrets are copied into every machine's environment. They are visible to processes inside the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.amber).lineSpacing(3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)
            .onAppear { if envAllowListDraft.isEmpty { envAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList) } }

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
            groupLabel("THIS MAC")
            resourceMeter("CPU cores", "Engine uses up to 4 of \(cores) cores", min(1, 4.0 / Double(max(cores, 1))))
            resourceMeter("Memory", String(format: "%.0f GB installed · grows on demand", ramGB), min(1, 4.0 / max(ramGB, 1)))
            infoPanel("Dory's engine uses up to 4 CPU cores and allocates memory on demand — it reclaims RAM back to macOS when idle instead of holding a fixed reservation, so there are no manual limits to tune.")
        }
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
                Text("v\(store.engineVersion)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(p.accentText)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("ENGINE BACKEND")
            engineBackendCard
                .padding(.bottom, 22)

            groupLabel("DORY SHARED VM")
            VStack(alignment: .leading, spacing: 12) {
                Text("Run every container in one shared Linux VM — like OrbStack — on Dory's own engine. The app bundles the engine, kernel, networking, Docker CLI, Compose, and kubectl, so it needs no Docker, OrbStack, Colima, Homebrew, or Apple container toolchain on the user's Mac. Memory is returned to macOS as workloads idle. Metal-backed AI services on the Mac are reachable from containers at host.dory.internal on ports 11434, 1234, and 18190. Requires macOS 15 or later on Apple silicon or Intel; installs without bundled engine assets can use a Docker-compatible local engine.")
                    .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        Task { await store.useSharedVM() }
                    } label: {
                        Text(onShared ? "Running on Dory's engine" : "Use Dory's engine")
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

            groupLabel("APPLE CONTAINER")
            appleContainerCard
                .padding(.bottom, 22)

            if MacHostPlatform.current().isAppleSilicon {
                groupLabel("X86 / AMD64")
                VStack(spacing: 0) {
                    toggleRow(
                        "Run Intel (x86/amd64) images",
                        "Run amd64 images (SQL Server, Oracle, older x86 builds) on Dory's own engine through QEMU emulation — no separate VM, so the memory advantage stays. Emulated x86 is slower than native arm64; leave off when you don't need it to keep the guest lean. Restarts the engine.",
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
            } else if !store.gpuRuntimeAvailable {
                Text("Install or bundle the Venus runtime (virglrenderer plus MoltenVK) to enable this. Until then, run a Metal-backed host service such as Ollama, LM Studio, or MLX and reach it from containers at host.dory.internal on ports 11434, 1234, and 18190.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3).padding(.top, 8)
            }
        }
    }

    /// Colima-style backend picker: Dory's bundled engine, an auto-detected existing engine, or a
    /// custom Docker-compatible socket. Detected engines are listed so the choice is informed.
    private var engineBackendCard: some View {
        let detected = DockerEngineSocketDiscovery.availableSources()
        return VStack(spacing: 0) {
            ForEach(EnginePreference.allCases) { preference in
                engineChoiceRow(preference, detected: detected)
                if preference != EnginePreference.allCases.last {
                    Rectangle().fill(p.border).frame(height: 1)
                }
            }
        }
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
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

    private var appleContainerCard: some View {
        let path = HostTools.appleContainer()
        let detected = path != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(detected ? p.green : p.text3).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(detected ? "Apple container detected" : "Apple container not found")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text(detected ? (path ?? "") : "Install Apple's container CLI only if you want to benchmark Apple's per-container VM runtime.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("External")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(p.text3)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.bgInput, in: Capsule())
            }
            Text("Dory's bundled shared VM remains the full-feature engine for Docker CLI compatibility, Compose, Kubernetes, Linux machines, port forwarding, and memory reclamation. Apple's container runtime is a useful comparison target, but it is not yet wired as a feature-equivalent selectable backend.")
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
                    Text(available ? "Venus GPU runtime detected" : "Venus GPU runtime not found")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text(available
                        ? "A Venus-capable virglrenderer and a MoltenVK ICD are available to the engine."
                        : "Needs a Venus-capable libvirglrenderer and a MoltenVK ICD, either bundled in the app or installed via the krunkit tap (brew install slp/krunkit/virglrenderer molten-vk libepoxy).")
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
        case .sharedVM: "One shared Linux VM on Dory's own engine"
        case .appleContainer: "Apple container — one micro-VM per container"
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
                    "Enable *.dory.local domains",
                    "Give each container an automatic *.dory.local name with local HTTPS. Turn this off if the proxy ports conflict, or if your DNS is managed (MDM / corporate) and can't be pointed at Dory.",
                    isOn: Binding(get: { store.domainsEnabled }, set: { store.applyNetworkingSettings(domainsEnabled: $0) }),
                    divider: false
                )
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)

            groupLabel("PORTS")
            VStack(alignment: .leading, spacing: 12) {
                portField("DNS resolver", store: $dnsPortDraft, fallback: AppStore.defaultDNSPort) { store.applyNetworkingSettings(dnsPort: $0) }
                portField("HTTP proxy", store: $httpPortDraft, fallback: AppStore.defaultHTTPProxyPort) { store.applyNetworkingSettings(httpProxyPort: $0) }
                portField("HTTPS proxy", store: $httpsPortDraft, fallback: AppStore.defaultHTTPSProxyPort) { store.applyNetworkingSettings(httpsProxyPort: $0) }
                Text("Change these if the defaults (15353 / 8080 / 8443) collide with other software — 8080 is a common one. Saved on Return; local networking restarts to rebind.")
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
                    "Make published ports LAN-visible",
                    "Off (default): published ports are reachable only from this Mac (localhost). On: bind them so other devices on your local network can reach your containers. Takes effect for newly published ports or after an engine restart.",
                    isOn: Binding(get: { store.lanVisible }, set: { on in Task { await store.setLanVisible(on) } }),
                    divider: false
                )
            }
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            Text("With LAN access off, published container ports stay reachable only at localhost on this Mac. Containers use Docker's default bridge network (172.17.0.0/16).")
                .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            dnsPortDraft = String(store.dnsPort)
            httpPortDraft = String(store.httpProxyPort)
            httpsPortDraft = String(store.httpsProxyPort)
            store.loadLanVisible()
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
