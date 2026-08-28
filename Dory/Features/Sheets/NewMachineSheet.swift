import Darwin
import DoryOperations
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    @State private var name: String
    @State private var address = ""
    @State private var selectedRecipe: DevRecipe?
    @State private var displayMode: MachineDisplayMode
    @State private var desktopDistro: DesktopMachineDistro = .debian
    @State private var guestUsername = NewMachineSheet.defaultGuestUsername()
    @State private var customISOInstall = false
    @State private var installerISOPath = ""
    @State private var installerISOCheck: InstallerISOCheck = .none
    @State private var diskSizeGB = 64
    @State private var networkMode = DoryVMNetworkMode.sharedNAT
    @State private var portForwardRows: [MachinePortForwardDraft] = []
    @State private var audioInputEnabled = true
    @State private var audioOutputEnabled = true
    @State private var cameraEnabled = true
    @State private var gpuAccelerationEnabled = true
    @State private var hostDisplays: [HostDisplayChoice] = []
    @State private var dedicatedHostDisplayUUID: String?

    private enum InstallerISOCheck: Equatable {
        case none
        case checking
        case compatible(
            DoryInstallerISOArchitecture,
            DoryInstallerISORuntimeQualification
        )
        case unknown(DoryInstallerISOMediaIdentity)
        case unstable(String)
        case incompatible(String)
        case failed(String)
    }

    enum Stage: Hashable { case useCase, form }
    @State private var stage: Stage
    @State private var activeUseCaseID: String?

    @State private var advancedExpanded = false
    @State private var cpus = 4
    @State private var memoryGB = 4
    @State private var mountRows: [MountRow] = []
    @State private var shareHome = false

    private struct MountRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
    }

    init(displayMode: MachineDisplayMode) {
        let resources = Self.recommendedDesktopResources()
        _displayMode = State(initialValue: displayMode)
        _stage = State(initialValue: displayMode == .desktop ? .form : .useCase)
        _name = State(initialValue: NewMachineSheet.defaultName())
        if displayMode == .desktop {
            _cpus = State(initialValue: resources.cpus)
            _memoryGB = State(initialValue: resources.memoryGB)
        }
        if let installedDistro = DesktopMachineDistro.allCases.first(where: {
            AppInfo.componentAvailable($0.componentID)
        }) {
            _desktopDistro = State(initialValue: installedDistro)
        }
    }

    private var engineReady: Bool { store.dorydRuntimeActive }

    var body: some View {
        Group {
            if stage == .useCase {
                useCaseScreen
            } else {
                formScreen
            }
        }
        .frame(width: 600, height: 600)
        .background(p.bgWindow)
        .onAppear { hostDisplays = HostDisplayChoice.connectedDisplays() }
    }

    private var formScreen: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !engineReady { engineNotice }
                        machineKindSection
                        devEnvironmentSection
                        identitySection
                        networkBlock
                        MachinePortForwardEditor(
                            rows: $portForwardRows,
                            networkMode: networkMode,
                            accessibilityPrefix: "new-machine"
                        )
                        desktopGraphicsBlock
                        audioBlock
                        displayAssignmentBlock
                        optionsRow
                        advancedSection
                    }
                    .padding(20)
                }
                .onChange(of: advancedExpanded) { _, isExpanded in
                    guard isExpanded else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("new-machine-resource-controls", anchor: .center)
                    }
                }
            }
            Divider().overlay(p.border)
            footer
        }
    }

    private var useCaseScreen: some View {
        VStack(spacing: 0) {
            useCaseHeader
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !engineReady { engineNotice }
                    LazyVGrid(columns: useCaseColumns, alignment: .leading, spacing: 10) {
                        ForEach(MachineUseCase.all) { useCase in
                            useCaseCard(useCase)
                        }
                    }
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            useCaseFooter
        }
    }

    private var useCaseHeader: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("What will you use it for?").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text("Pick a starting toolset — you can customize resources and sharing next.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var useCaseColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private func useCaseCard(_ useCase: MachineUseCase) -> some View {
        Button { applyUseCase(useCase) } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: useCase.icon)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 38, height: 38)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(useCase.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(useCase.subtitle).font(.system(size: 11)).foregroundStyle(p.text3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("use-case-\(useCase.id)")
    }

    private var useCaseFooter: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)
            Button("Cancel") { store.activeSheet = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            Button { activeUseCaseID = nil; stage = .form } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                    Text("Customize").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(p.accentText)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("customize-machine")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func applyUseCase(_ useCase: MachineUseCase) {
        selectedRecipe = useCase.recipe
        cpus = useCase.cpus
        memoryGB = useCase.memoryGB
        activeUseCaseID = useCase.id
        portForwardRows = useCase.recipe?.ports.map {
            MachinePortForwardDraft(
                name: "port-\($0)",
                hostPort: String($0),
                guestPort: String($0)
            )
        } ?? []
        stage = .form
    }

    private var header: some View {
        HStack(spacing: 12) {
            if displayMode == .headless {
                Button { stage = .useCase } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).foregroundStyle(p.text2)
                        .frame(width: 28, height: 28)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("back-to-use-cases")
            }
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayMode == .desktop ? "New Linux desktop" : "New Linux server")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text(headerSubtitle).font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        if let id = activeUseCaseID, let useCase = MachineUseCase.forID(id) {
            return "\(useCase.title) — tweak anything below"
        }
        if displayMode == .desktop {
            return customISOInstall
                ? "Install an arm64 Linux distribution from ISO · Apple EFI"
                : "\(desktopDistro.displayName) \(desktopDistro.version) · \(desktopDistro.desktopName) · Apple Silicon"
        }
        return "Headless Linux · native Apple Silicon"
    }

    private var engineNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(p.amber)
            Text(AppStore.dorydMachineManagerRequired())
                .font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.amberWeak, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var machineKindSection: some View {
        if displayMode == .desktop {
            desktopDistroSection
        } else {
            serverTypeSection
        }
    }

    private var desktopDistroSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("INSTALLATION SOURCE")
            Picker("", selection: $customISOInstall) {
                Text("Dory desktop").tag(false)
                Text("Custom ISO").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: customISOInstall) { _, custom in
                if custom {
                    selectedRecipe = nil
                    cpus = DoryInstallerMachinePolicy.defaultCPUCount
                }
            }

            if customISOInstall {
                customISOSection
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                    ForEach(installedDesktopDistros) { distro in
                        desktopDistroButton(distro)
                    }
                }
                Text("Only installed distributions are shown. Add or remove Debian, Ubuntu, and Kali independently in Components.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var customISOSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: chooseInstallerISO) {
                HStack(spacing: 8) {
                    Image(systemName: "opticaldiscdrive").foregroundStyle(p.accent)
                    Text(installerISOPath.isEmpty ? "Choose Linux installer ISO…" : installerISOPath)
                        .font(.mono(11.5)).foregroundStyle(installerISOPath.isEmpty ? p.text3 : p.text)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                    Text("Choose").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.accent)
                }
                .padding(11)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("custom-linux-iso-picker")

            installerISOStatus

            HStack(spacing: 16) {
                sectionLabel("VIRTUAL DISK")
                boundedResourceControl(
                    value: $diskSizeGB,
                    range: 16...512,
                    display: { "\($0) GB" },
                    valueIdentifier: "custom-linux-disk-size",
                    decrementIdentifier: "custom-linux-disk-decrement",
                    incrementIdentifier: "custom-linux-disk-increment"
                )
            }
            Text("Dory stores a private copy of the ISO, a thin-provisioned disk, a stable VM identity, and persistent EFI NVRAM. Choose an arm64 ISO on Apple Silicon.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
            Label(
                "Dory starts installers with a balanced 4-vCPU default. EFI architecture and exact-media runtime qualification are checked separately.",
                systemImage: "cpu"
            )
            .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    @ViewBuilder private var installerISOStatus: some View {
        switch installerISOCheck {
        case .none:
            EmptyView()
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Checking EFI architecture before import…")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(p.text2)
        case let .compatible(architecture, qualification):
            switch qualification {
            case let .qualified(message):
                isoStatusRow(icon: "checkmark.circle.fill", color: p.green, text: message)
            case .unqualified:
                isoStatusRow(
                    icon: "questionmark.circle.fill",
                    color: p.amber,
                    text: architecture == .multiArchitecture
                        ? "Universal EFI architecture confirmed — this exact media is not yet runtime-qualified by Dory."
                        : "ARM64 EFI architecture confirmed — this exact media is not yet runtime-qualified by Dory."
                )
            case let .knownUnstable(message):
                isoStatusRow(icon: "exclamationmark.octagon.fill", color: p.red, text: message)
            }
        case .unknown:
            isoStatusRow(
                icon: "xmark.octagon.fill",
                color: p.red,
                text: "Dory could not prove a portable ARM64 EFI loader in this ISO. Choose different media."
            )
        case let .unstable(message):
            isoStatusRow(icon: "exclamationmark.octagon.fill", color: p.red, text: message)
        case let .incompatible(message):
            isoStatusRow(icon: "xmark.octagon.fill", color: p.red, text: message)
        case let .failed(message):
            isoStatusRow(icon: "exclamationmark.triangle.fill", color: p.red, text: message)
        }
    }

    private func isoStatusRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(p.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("custom-linux-iso-compatibility")
    }

    private var installedDesktopDistros: [DesktopMachineDistro] {
        DesktopMachineDistro.allCases.filter { AppInfo.componentAvailable($0.componentID) }
    }

    private func desktopDistroButton(_ distro: DesktopMachineDistro) -> some View {
        let selected = desktopDistro == distro
        return Button { desktopDistro = distro } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(distro.logoName).resizable().aspectRatio(contentMode: .fit).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(distro.displayName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                        Text(distro.version).font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.text3)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(p.accent)
                    }
                }
                Text(distro.summary).font(.system(size: 10.5)).foregroundStyle(p.text3)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? p.accent : p.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desktop-distro-\(distro.rawValue)")
    }

    private var serverTypeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("SERVER IMAGE")
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 34, height: 34)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dory Linux Server").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Text("User-managed headless VM for terminals, tools, and local services — Agent Sandboxes are created from the Dory CLI or MCP")
                        .font(.system(size: 10.5)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
        }
    }

    private var devEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("DEV ENVIRONMENT")
            if customISOInstall {
                Text("Choose packages and applications inside the Linux installer.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text2)
            } else {
            Picker("", selection: Binding(
                get: { selectedRecipe?.id ?? "" },
                set: { selectedRecipe = $0.isEmpty ? nil : DevRecipe.forID($0) }
            )) {
                Text(displayMode == .desktop ? "Plain \(desktopDistro.displayName) Desktop" : "Plain Dory Linux").tag("")
                ForEach(DevRecipe.all) { recipe in Text(recipe.display).tag(recipe.id) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 220, alignment: .leading)
            Text(displayMode == .desktop
                 ? "Recipes install verified apt packages after the desktop starts."
                 : "Recipes install verified Alpine packages after the VM starts.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ACCESS & SHARING")
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 14)).foregroundStyle(p.accent)
                if displayMode == .desktop, !customISOInstall {
                    Text("Linux user").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Spacer(minLength: 0)
                    TextField("dory", text: $guestUsername)
                        .textFieldStyle(.plain)
                        .font(.mono(11.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(width: 170)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(guestUsernameInvalid ? p.red : p.border))
                        .accessibilityIdentifier("new-machine-guest-user")
                } else {
                    Text(customISOInstall ? "Linux account" : "Administrator shell")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Spacer(minLength: 0)
                    Text(customISOInstall ? "Created in the installer" : "root · /bin/sh")
                        .font(.mono(11.5)).foregroundStyle(p.text3)
                }
            }
            if guestUsernameInvalid {
                Text("Use 1–32 lowercase letters, numbers, underscores or dashes; start with a letter or underscore.")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
            Toggle(
                customISOInstall
                    ? "Expose my Mac home to this VM (read-write)"
                    : "Share my Mac home (read-write)",
                isOn: $shareHome
            )
                .toggleStyle(.switch).tint(p.accent)
                .font(.system(size: 12.5)).foregroundStyle(p.text)
            Text(shareHome ? sharedHomeDescription : "No Mac home folder is shared unless you turn this on or add scoped mounts.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("NAME")
                TextField("machine-name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.mono(12.5)).foregroundStyle(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(nameInvalid ? p.red : p.border))
                    .frame(maxWidth: .infinity)
                if nameInvalid {
                    Text("Use up to 63 letters, numbers, dots, dashes or underscores.")
                        .font(.system(size: 11)).foregroundStyle(p.red)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("DNS TARGET OVERRIDE")
                fieldInput("192.168.215.42", text: $address, width: 260)
                Text("Advanced: route \(dnsName) to this IPv4 instead of the address reported by the guest.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var networkBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NETWORK")
            Picker("Network", selection: $networkMode) {
                Text("Shared NAT").tag(DoryVMNetworkMode.sharedNAT)
                Text("Host-only").tag(DoryVMNetworkMode.isolated)
                Text("Disconnected").tag(DoryVMNetworkMode.disconnected)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("new-machine-network-mode")
            Text(networkMode == .disconnected
                 ? "Disconnected keeps the virtual adapter present with its link down."
                 : networkMode == .isolated
                    ? "Host-only allows private Mac-to-machine connectivity with no external route."
                    : "Shared NAT provides outbound access through your Mac without exposing the machine directly.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    @ViewBuilder private var audioBlock: some View {
        if displayMode == .desktop {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("AUDIO & VIDEO")
                HStack(spacing: 24) {
                    Toggle("Microphone", isOn: $audioInputEnabled)
                        .toggleStyle(.switch)
                        .tint(p.accent)
                        .accessibilityIdentifier("new-machine-audio-input")
                    Toggle("Speakers", isOn: $audioOutputEnabled)
                        .toggleStyle(.switch)
                        .tint(p.accent)
                        .accessibilityIdentifier("new-machine-audio-output")
                    Toggle("Camera", isOn: $cameraEnabled)
                        .toggleStyle(.switch)
                        .tint(p.accent)
                        .accessibilityIdentifier("new-machine-camera")
                        .disabled(customISOInstall)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(p.text)
                Text(customISOInstall
                     ? "Speakers and microphone use standard VirtIO audio. Camera sharing is currently available on Dory-managed accelerated desktops, not custom ISO compatibility guests."
                     : "Enabled devices are attached explicitly. Camera sharing appears in Linux as a standard UVC webcam and follows macOS camera permission.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.text3)
            }
        }
    }

    @ViewBuilder private var desktopGraphicsBlock: some View {
        if displayMode == .desktop, !customISOInstall {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("GRAPHICS")
                Toggle("GPU acceleration", isOn: $gpuAccelerationEnabled)
                    .toggleStyle(.switch)
                    .tint(p.accent)
                    .accessibilityIdentifier("new-machine-gpu-acceleration")
                Text(gpuAccelerationEnabled
                     ? "Require Dory's Metal-backed VirGL + Venus runtime for accelerated OpenGL and Vulkan. Creation fails instead of silently falling back to software graphics."
                     : "Use Apple's compatibility display with software 3D. You can enable GPU acceleration later from the desktop's settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.text3)
            }
        }
    }

    @ViewBuilder private var displayAssignmentBlock: some View {
        if displayMode == .desktop {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("MAC DISPLAY")
                Picker("Guest presentation", selection: $dedicatedHostDisplayUUID) {
                    Text("Windowed").tag(String?.none)
                    ForEach(hostDisplays) { display in
                        Text("Dedicated — \(display.name)").tag(Optional(display.id))
                    }
                }
                .accessibilityIdentifier("new-machine-host-display")
                Text(dedicatedHostDisplayUUID == nil
                     ? "Open the Linux desktop as a normal Mac window."
                     : "Give the guest a native full-screen Space on this monitor. Command-Control-F returns to a window.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.text3)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                advancedExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("ADVANCED")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(p.text3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-machine-advanced-toggle")
            .accessibilityLabel("Advanced")
            .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    resourceRow
                    mountsBlock
                }
                .padding(.top, 12)
            }
        }
    }

    private var resourceRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("CPUS")
                boundedResourceControl(
                    value: $cpus,
                    range: 1...8,
                    display: { "\($0) \($0 == 1 ? "core" : "cores")" },
                    valueIdentifier: "new-machine-cpus-value",
                    decrementIdentifier: "new-machine-cpus-decrement",
                    incrementIdentifier: "new-machine-cpus-increment"
                )
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("MEMORY")
                boundedResourceControl(
                    value: $memoryGB,
                    range: 1...16,
                    display: { "\($0) GB" },
                    valueIdentifier: "new-machine-memory-value",
                    decrementIdentifier: "new-machine-memory-decrement",
                    incrementIdentifier: "new-machine-memory-increment"
                )
            }
            Spacer(minLength: 0)
        }
        .id("new-machine-resource-controls")
    }

    private func boundedResourceControl(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        display: @escaping (Int) -> String,
        valueIdentifier: String,
        decrementIdentifier: String,
        incrementIdentifier: String
    ) -> some View {
        let current = value.wrappedValue
        let renderedValue = display(current)
        let canDecrement = current > range.lowerBound
        let canIncrement = current < range.upperBound
        return HStack(spacing: 8) {
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canDecrement ? p.text2 : p.text3.opacity(0.45))
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            .disabled(!canDecrement)
            .accessibilityIdentifier(decrementIdentifier)
            .accessibilityLabel("Decrease \(renderedValue)")

            Text(renderedValue)
                .font(.system(size: 12.5))
                .foregroundStyle(p.text)
                .frame(minWidth: 74)
                .accessibilityIdentifier(valueIdentifier)

            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canIncrement ? p.text2 : p.text3.opacity(0.45))
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            .disabled(!canIncrement)
            .accessibilityIdentifier(incrementIdentifier)
            .accessibilityLabel("Increase \(renderedValue)")
        }
        .frame(width: 180, alignment: .leading)
    }

    private var mountsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("MOUNTED FOLDERS")
                Spacer(minLength: 0)
                addButton { mountRows.append(MountRow()) }
            }
            ForEach($mountRows) { $row in
                HStack(spacing: 8) {
                    Button { chooseMountHost(for: row.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(p.text3)
                            Text(row.host.isEmpty ? "Host folder…" : row.host)
                                .font(.mono(11.5)).foregroundStyle(row.host.isEmpty ? p.text3 : p.text)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(p.text3)
                    fieldInput("/guest/path", text: $row.guest, width: 150)
                    removeButton { mountRows.removeAll { $0.id == row.id } }
                }
            }
            if mountRows.isEmpty {
                Text("Share host folders into the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
            if mountsOutsideHome {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(p.red)
                    Text("Mounted folders must be under your home (\(NSHomeDirectory())).")
                        .font(.system(size: 11)).foregroundStyle(p.red)
                }
            }
        }
    }

    private func fieldInput(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.mono(11.5)).foregroundStyle(p.text)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width)
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accent)
                .frame(width: 22, height: 22)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(p.text3)
        }
        .buttonStyle(.plain)
    }

    private func chooseMountHost(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a host folder to mount into the machine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = mountRows.firstIndex(where: { $0.id == id }) else { return }
        mountRows[index].host = url.path
        if mountRows[index].guest.isEmpty {
            mountRows[index].guest = "/mnt/\(url.lastPathComponent)"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
                Text(displayMode == .desktop
                     ? (customISOInstall
                        ? customISOFooterDescription
                        : "\(desktopDistro.displayName) \(desktopDistro.version) · arm64 · \(normalizedGuestUsername)")
                     : "Dory Linux · arm64 · root shell")
                    .font(.mono(11.5)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel") { store.activeSheet = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            Button(action: create) {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Create machine").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(p.accent.opacity(createDisabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(createDisabled)
            .accessibilityIdentifier("new-machine-submit")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
    }

    private var nameInvalid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !nameValid
    }

    private var createDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
            || !nameValid
            || (!customISOInstall && guestUsernameInvalid)
            || (customISOInstall && installerISOPath.isEmpty)
            || (customISOInstall && installerISOCheckBlocksCreate)
            || store.machineBusy
            || !engineReady
            || mountsOutsideHome
            || resolvedPortForwards == nil
    }

    private var mountsOutsideHome: Bool {
        let home = NSHomeDirectory()
        return mountRows.contains { row in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return false }
            return host != home && !host.hasPrefix(home + "/")
        }
    }

    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 63 else { return false }
        return trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    private func create() {
        var settings = collectedSettings()
        let homeMount = Self.sharedHomeMount(
            home: NSHomeDirectory(),
            displayMode: displayMode,
            customISOInstall: customISOInstall,
            guestUsername: normalizedGuestUsername
        )
        if shareHome, !settings.mounts.contains(where: { $0.guest == homeMount.guest }) {
            settings.mounts.append(homeMount)
        }
        let machineName = name
        let recipe = customISOInstall ? nil : selectedRecipe
        Task { _ = await store.createMachine(name: machineName, recipe: recipe, settings: settings) }
    }

    private func chooseInstallerISO() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = "Choose an arm64 Linux installer ISO"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installerISOPath = url.path
        installerISOCheck = .checking
        let selectedPath = url.path
        Task {
            let result: (DoryInstallerISOMediaIdentity?, String?) = await Task.detached(
                priority: .userInitiated
            ) {
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    return (
                        try DoryInstallerISOInspector.portableEFIMediaIdentity(
                            atPath: selectedPath
                        ),
                        nil
                    )
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard installerISOPath == selectedPath else { return }
            guard let identity = result.0 else {
                installerISOCheck = .failed(result.1 ?? "Dory could not inspect this ISO.")
                return
            }
            switch DoryInstallerISOInspector.compatibility(
                of: identity.architecture,
                hostArchitecture: DoryInstallerISOInspector.currentHostArchitecture
            ) {
            case .compatible:
                let qualification = DoryInstallerISORuntimeCatalog.qualification(of: identity)
                if case let .knownUnstable(message) = qualification {
                    installerISOCheck = .unstable(message)
                } else {
                    installerISOCheck = .compatible(identity.architecture, qualification)
                }
            case .unknown:
                installerISOCheck = .unknown(identity)
            case let .incompatible(message):
                installerISOCheck = .incompatible(message)
            }
        }
    }

    private var installerISOCheckBlocksCreate: Bool {
        switch installerISOCheck {
        case .compatible:
            false
        case .none, .checking, .unknown, .unstable, .incompatible, .failed:
            true
        }
    }

    private var customISOFooterDescription: String {
        switch installerISOCheck {
        case .compatible(.multiArchitecture, _): "Custom universal Linux · EFI · \(diskSizeGB) GB"
        case .compatible(.arm64, _): "Custom arm64 Linux · EFI · \(diskSizeGB) GB"
        case .compatible(.x86_64, _): "Custom x86_64 Linux · EFI · \(diskSizeGB) GB"
        case .compatible(.unknown, _), .unknown: "Custom Linux · EFI architecture unknown · \(diskSizeGB) GB"
        case .incompatible: "Intel x86_64 ISO · incompatible"
        case .unstable: "Known-unstable installer · choose different media"
        case .none, .checking, .failed: "Custom Linux · EFI · \(diskSizeGB) GB"
        }
    }

    static func buildSettings(
        cpus: Int,
        memoryGB: Int,
        mounts: [MountPair],
        address: String? = nil,
        displayMode: MachineDisplayMode = .desktop,
        desktopDistro: DesktopMachineDistro = .debian,
        guestUsername: String = "dory",
        guestUID: uid_t = getuid(),
        networkMode: DoryVMNetworkMode = .sharedNAT,
        portForwards: [DoryVMPortForward] = [],
        audioInputEnabled: Bool = true,
        audioOutputEnabled: Bool = true,
        cameraEnabled: Bool = true,
        gpuAccelerationEnabled: Bool = true
    ) -> MachineSettings {
        let typedSettings: DorydMachineTypedSettings
        if displayMode == .desktop {
            typedSettings = DorydMachineTypedSettings(
                guestIdentityIntent: DoryVMGuestIdentityIntent(
                    account: DoryVMGuestAccountIntent(
                        username: guestUsername,
                        numericUserID: UInt32(guestUID)
                    ),
                    desktop: DoryVMDesktopIdentityIntent(
                        distributionIdentifier: desktopDistro.rawValue,
                        displayName: desktopDistro.displayName,
                        version: desktopDistro.version,
                        desktopEnvironment: desktopDistro.desktopName
                    )
                ),
                // Text and image clipboard are supported by both the compatibility runtime and
                // resolved workspace plans. File transfer uses Dory's separately authorized
                // machine transfer channel; advertising it as clipboard intent makes a clean
                // install unrepresentable before a schema-v2 qualification catalog is active.
                clipboardPolicy: .legacyDesktop(.bidirectional),
                runtimePreference: gpuAccelerationEnabled ? .accelerated : .compatible,
                graphicsPreference: gpuAccelerationEnabled ? .virglVenus : .software,
                networkMode: networkMode,
                portForwards: portForwards,
                audioConfiguration: DoryVMAudioConfiguration(
                    inputEnabled: audioInputEnabled,
                    outputEnabled: audioOutputEnabled
                ),
                cameraConfiguration: DoryVMCameraConfiguration(enabled: cameraEnabled)
            )
        } else {
            typedSettings = DorydMachineTypedSettings(
                networkMode: networkMode,
                portForwards: portForwards
            )
        }
        return MachineSettings(
            cpus: cpus,
            memoryMB: memoryGB * 1024,
            mounts: mounts,
            env: [:],
            virtualMachineSettings: typedSettings,
            address: address,
            displayMode: displayMode
        )
    }

    static func recommendedDesktopResources(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> (cpus: Int, memoryGB: Int) {
        let cpus = max(4, min(8, activeProcessorCount / 2))
        let hostMemoryGB = Int(physicalMemory / 1_073_741_824)
        let memoryGB: Int
        if hostMemoryGB >= 24 {
            memoryGB = 8
        } else if hostMemoryGB >= 16 {
            memoryGB = 6
        } else {
            memoryGB = 4
        }
        return (cpus, memoryGB)
    }

    private func collectedSettings() -> MachineSettings {
        let mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest)
        }
        var settings = Self.buildSettings(
            cpus: cpus,
            memoryGB: memoryGB,
            mounts: mounts,
            address: trimmedAddress,
            displayMode: displayMode,
            desktopDistro: desktopDistro,
            guestUsername: normalizedGuestUsername,
            networkMode: networkMode,
            portForwards: resolvedPortForwards ?? [],
            audioInputEnabled: audioInputEnabled,
            audioOutputEnabled: audioOutputEnabled,
            cameraEnabled: cameraEnabled && !customISOInstall,
            gpuAccelerationEnabled: gpuAccelerationEnabled
        )
        if customISOInstall {
            settings.bootMode = .efi
            settings.installerISOPath = installerISOPath
            settings.diskSizeGB = diskSizeGB
            // EFI boot/media authority is explicit. It must never be inferred from a reserved
            // environment marker or carry managed-desktop provisioning intent.
            settings.env = [:]
            settings.virtualMachineSettings = DorydMachineTypedSettings(
                networkMode: networkMode,
                portForwards: resolvedPortForwards ?? [],
                audioConfiguration: DoryVMAudioConfiguration(
                    inputEnabled: audioInputEnabled,
                    outputEnabled: audioOutputEnabled
                ),
                cameraConfiguration: DoryVMCameraConfiguration(enabled: false)
            )
        }
        settings.displayPresentation = DoryMachineDisplayPresentation(
            assignments: dedicatedHostDisplayUUID.map {
                [DoryGuestDisplayPresentationAssignment(
                    guestDisplayID: "display-0",
                    mode: .dedicatedFullscreen,
                    hostDisplayUUID: $0
                )]
            } ?? []
        )
        return settings
    }

    private var resolvedPortForwards: [DoryVMPortForward]? {
        MachinePortForwardDraft.resolved(portForwardRows, networkMode: networkMode)
    }

    static func defaultName() -> String {
        "dory-\(AppStore.generatedMachineToken())"
    }

    static func sharedHomeMount(
        home: String,
        displayMode: MachineDisplayMode,
        customISOInstall: Bool,
        guestUsername: String
    ) -> MountPair {
        if displayMode == .desktop, customISOInstall {
            return MountPair(
                host: home,
                guest: "/mnt/dory-mac-home",
                shareTag: "mac-home"
            )
        }
        return MountPair(
            host: home,
            guest: displayMode == .desktop ? "/home/\(guestUsername)/Mac" : home
        )
    }

    static func defaultGuestUsername() -> String {
        let normalized = NSUserName().lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "-"
        }
        let candidate = String(normalized.prefix(32))
        guard candidate.range(
            of: "^[a-z_][a-z0-9_-]{0,31}$",
            options: .regularExpression
        ) != nil else { return "dory" }
        return candidate
    }

    private var normalizedGuestUsername: String {
        guestUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var guestUsernameInvalid: Bool {
        guard displayMode == .desktop else { return false }
        return normalizedGuestUsername.range(
            of: "^[a-z_][a-z0-9_-]{0,31}$",
            options: .regularExpression
        ) == nil
    }

    private var sharedHomeDescription: String {
        if displayMode == .desktop, customISOInstall {
            return "Dory exposes the virtiofs tag mac-home. After installation, mount it where you want (for example /mnt/dory-mac-home); an arbitrary distro is not configured automatically."
        }
        return displayMode == .desktop
            ? "Your Mac home is available in the Dory-managed desktop at ~/Mac with your Mac user ID."
            : "Your Mac home is mounted at its native path inside the machine."
    }

    private var dnsName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return AppStore.machineDNSName(name: trimmedName.isEmpty ? "machine" : trimmedName, suffix: store.domainSuffix)
    }

    private var trimmedAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum IntelApplicationTranslationHostAvailability: Sendable, Equatable {
    case installed
    case notInstalled
    case unsupported
}

@MainActor
enum IntelApplicationTranslationHost {
    static var availability: IntelApplicationTranslationHostAvailability {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            .installed
        case .notInstalled:
            .notInstalled
        case .notSupported:
            .unsupported
        @unknown default:
            .unsupported
        }
    }

    static func install() async throws {
        try await VZLinuxRosettaDirectoryShare.installRosetta()
    }
}

struct MachineIntelApplicationTranslationControl: View {
    @Environment(\.palette) private var p
    @Binding var isEnabled: Bool
    let editable: Bool
    let runtimeCompatible: Bool
    let accessibilityPrefix: String

    @State private var availability = IntelApplicationTranslationHost.availability
    @State private var installing = false
    @State private var installationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTEL APPLICATIONS")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(p.text3)
                .tracking(0.5)
            HStack(spacing: 12) {
                Toggle("Run Intel Linux applications", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .tint(p.accent)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.text)
                    .disabled(!editable || (availability != .installed && !isEnabled))
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-intel-application-translation"
                    )
                Spacer(minLength: 0)
                if availability == .notInstalled {
                    Button {
                        Task { await installRosetta() }
                    } label: {
                        HStack(spacing: 6) {
                            if installing { ProgressView().controlSize(.mini) }
                            Text(installing ? "Installing…" : "Install Rosetta")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(installing || !editable)
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-install-intel-application-translation"
                    )
                }
            }
            Text(statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusMessage: String {
        if let installationError {
            return "Rosetta could not be installed: \(installationError)"
        }
        guard runtimeCompatible else {
            return "Intel application translation requires Automatic or Compatibility runtime selection."
        }
        guard editable else {
            return "Replan this compatibility machine into the resolved runtime before changing Intel application translation."
        }
        switch availability {
        case .installed:
            return "Uses Apple's Rosetta runtime inside this ARM64 Linux desktop. The runtime is attached only when the resolved plan qualifies it."
        case .notInstalled:
            return "Rosetta is not installed on this Mac. Installation is an explicit Apple system action."
        case .unsupported:
            return "This Mac does not support Rosetta for Linux virtual machines."
        }
    }

    private var statusColor: Color {
        installationError == nil && availability == .installed && runtimeCompatible
            ? p.text3 : p.amber
    }

    private func installRosetta() async {
        installationError = nil
        installing = true
        defer { installing = false }
        do {
            try await IntelApplicationTranslationHost.install()
            availability = IntelApplicationTranslationHost.availability
            if availability != .installed {
                installationError = "macOS did not report the runtime as installed."
            }
        } catch {
            installationError = error.localizedDescription
            availability = IntelApplicationTranslationHost.availability
        }
    }
}
