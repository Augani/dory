import SwiftUI

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    @State private var selectedFamily: MachineFamily
    @State private var selectedVersion: MachineDistro
    @State private var selectedArch: MachineArch
    @State private var name: String
    @State private var lastAutoName: String
    @State private var nameEdited = false
    @State private var selectedRecipe: DevRecipe?

    @State private var advancedExpanded = false
    @State private var cpus = 2
    @State private var memoryGB = 2
    @State private var mountRows: [MountRow] = []
    @State private var portRows: [PortRow] = []
    @State private var envRows: [EnvRow] = []
    @State private var shareHome = true
    @State private var shell = "/bin/bash"
    @State private var username = NSUserName()

    private struct EnvRow: Identifiable, Hashable { let id = UUID(); var key = ""; var value = "" }

    private struct MountRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
    }

    private struct PortRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 8)]

    init() {
        let family = MachineDistro.families[0]
        let auto = NewMachineSheet.defaultName(family)
        _selectedFamily = State(initialValue: family)
        _selectedVersion = State(initialValue: family.defaultVersion)
        _selectedArch = State(initialValue: family.defaultVersion.defaultArch())
        _name = State(initialValue: auto)
        _lastAutoName = State(initialValue: auto)
    }

    private var engineReady: Bool { store.runtimeKind.isDockerCompatible }

    private var recipesAvailable: Bool { selectedVersion.pkg == .apt }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !engineReady { engineNotice }
                    distroSection
                    devEnvironmentSection
                    identitySection
                    optionsRow
                    advancedSection
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 580, height: 560)
        .background(p.bgWindow)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("New Linux machine").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text("Pick a distribution and version").font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var engineNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(p.amber)
            Text(AppStore.dockerCompatibleEngineRequired("Linux machines"))
                .font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.amberWeak, in: RoundedRectangle(cornerRadius: 9))
    }

    private var distroSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("DISTRIBUTION")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MachineDistro.families) { family in
                    familyCard(family)
                }
            }
        }
    }

    private var devEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("DEV ENVIRONMENT")
            Picker("", selection: $selectedRecipe) {
                Text("Plain OS").tag(DevRecipe?.none)
                ForEach(DevRecipe.all) { recipe in Text(recipe.display).tag(DevRecipe?.some(recipe)) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 220, alignment: .leading)
            .disabled(!recipesAvailable)
            if !recipesAvailable {
                Text("Dev recipes currently require an apt-based distro (Ubuntu, Debian, Kali).")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("IDENTITY & SHARING")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("USER").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
                    TextField("username", text: $username)
                        .textFieldStyle(.plain)
                        .font(.mono(12.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: 180, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(usernameInvalid ? p.red : p.border))
                        .disabled(!shareHome)
                        .opacity(shareHome ? 1 : 0.5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("LOGIN SHELL").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
                    Picker("", selection: $shell) {
                        Text("bash").tag("/bin/bash")
                        Text("zsh").tag("/bin/zsh")
                        Text("fish").tag("/usr/bin/fish")
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 160, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            if shareHome && usernameInvalid {
                Text("Lowercase letters, digits, _ or -, starting with a letter or _ (max 32).")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
            Toggle("Share my Mac home (read-write)", isOn: $shareHome)
                .toggleStyle(.switch).tint(p.accent)
                .font(.system(size: 12.5)).foregroundStyle(p.text)
            Text("Your home, git config, and SSH keys are shared into this machine.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
            envBlock
        }
    }

    private var envBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("ENVIRONMENT")
                Spacer(minLength: 0)
                addButton { envRows.append(EnvRow()) }
            }
            ForEach($envRows) { $row in
                HStack(spacing: 8) {
                    fieldInput("KEY", text: $row.key, width: 150)
                    Text("=").font(.system(size: 12)).foregroundStyle(p.text3)
                    fieldInput("VALUE", text: $row.value, width: 180)
                    Spacer(minLength: 0)
                    removeButton { envRows.removeAll { $0.id == row.id } }
                }
            }
            if envRows.isEmpty {
                Text("Set environment variables for the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    sectionLabel("VERSION")
                    Picker("", selection: $selectedVersion) {
                        ForEach(selectedFamily.versions) { version in
                            Text(version.version).tag(version)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(width: 180, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 9) {
                    sectionLabel("ARCHITECTURE")
                    Picker("", selection: $selectedArch) {
                        ForEach(selectedFamily.arches) { arch in
                            Text(arch.label()).tag(arch)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(width: 240, alignment: .leading)
                    .disabled(selectedFamily.arches.count < 2)
                    if !selectedArch.isNative {
                        Text("Emulated via binfmt — slower than \(MachineArch.host.display). Fine for builds and testing.")
                            .font(.system(size: 11)).foregroundStyle(p.text3)
                            .frame(width: 240, alignment: .leading)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("NAME")
                TextField("machine-name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.mono(12.5)).foregroundStyle(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(nameInvalid ? p.red : p.border))
                    .onChange(of: name) { _, newValue in nameEdited = (newValue != lastAutoName) }
                    .frame(maxWidth: .infinity)
                if nameInvalid {
                    Text("Use letters, numbers, dots, dashes or underscores.")
                        .font(.system(size: 11)).foregroundStyle(p.red)
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                resourceRow
                mountsBlock
                portsBlock
            }
            .padding(.top, 12)
        } label: {
            Text("ADVANCED")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
        }
        .tint(p.accent)
    }

    private var resourceRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("CPUS")
                Stepper(value: $cpus, in: 1...8) {
                    Text("\(cpus) \(cpus == 1 ? "core" : "cores")")
                        .font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .frame(width: 180)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("MEMORY")
                Stepper(value: $memoryGB, in: 1...16) {
                    Text("\(memoryGB) GB")
                        .font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .frame(width: 180)
            }
            Spacer(minLength: 0)
        }
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

    private var portsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("EXPOSED PORTS")
                Spacer(minLength: 0)
                addButton { portRows.append(PortRow()) }
            }
            ForEach($portRows) { $row in
                HStack(spacing: 8) {
                    fieldInput("8080", text: $row.host, width: 90)
                    Text("host").font(.system(size: 10.5)).foregroundStyle(p.text3)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(p.text3)
                    fieldInput("80", text: $row.guest, width: 90)
                    Text("guest").font(.system(size: 10.5)).foregroundStyle(p.text3)
                    Spacer(minLength: 0)
                    removeButton { portRows.removeAll { $0.id == row.id } }
                }
            }
            if portRows.isEmpty {
                Text("Publish machine ports to localhost.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
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
                Image(systemName: selectedVersion.boot == .systemd ? "gearshape.2" : "terminal")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
                Text("\(selectedVersion.baseImage) · \(selectedArch.shortLabel) · \(selectedVersion.boot == .systemd ? "systemd" : "shell")")
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

    private func familyCard(_ family: MachineFamily) -> some View {
        let selected = family.id == selectedFamily.id
        return Button { select(family) } label: {
            HStack(spacing: 10) {
                badge(for: family)
                Text(family.display).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(p.accent)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? p.accentSoft : p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? p.accent : p.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badge(for family: MachineFamily) -> some View {
        if let logo = MachineDistro.logoAsset(family: family.id) {
            Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
        } else {
            Text(family.letter)
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: family.badgeHex), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var nameInvalid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !nameValid
    }

    private var createDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || !nameValid || store.machineBusy || !engineReady || mountsOutsideHome || (shareHome && !usernameValid)
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
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    private var usernameValid: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }
        return trimmed.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    private var usernameInvalid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !usernameValid
    }

    private func select(_ family: MachineFamily) {
        selectedFamily = family
        selectedVersion = family.defaultVersion
        if family.defaultVersion.pkg != .apt { selectedRecipe = nil }
        if !family.arches.contains(selectedArch) { selectedArch = family.defaultVersion.defaultArch() }
        guard !nameEdited else { return }
        let auto = NewMachineSheet.defaultName(family)
        lastAutoName = auto
        name = auto
    }

    private func create() {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let identity = shareHome
            ? MacIdentity.make(username: trimmedUser, uid: Int(getuid()), homePath: NSHomeDirectory(),
                               shell: shell, sshDir: NSHomeDirectory() + "/.ssh")
            : nil
        let settings = collectedSettings()
        let machineName = name
        let image = selectedVersion.baseImage
        let arch = selectedArch
        let recipe = selectedRecipe
        store.activeSheet = nil
        Task { _ = await store.createMachine(image: image, name: machineName, arch: arch, recipe: recipe, settings: settings, identity: identity) }
    }

    static func buildSettings(cpus: Int, memoryGB: Int, mounts: [MountPair], ports: [PortPair], env: [String: String]) -> MachineSettings {
        MachineSettings(cpus: cpus, memoryMB: memoryGB * 1024, mounts: mounts, ports: ports, env: env)
    }

    private func collectedSettings() -> MachineSettings {
        let mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest)
        }
        let ports = portRows.compactMap { row -> PortPair? in
            guard let host = Int(row.host.trimmingCharacters(in: .whitespaces)),
                  let guest = Int(row.guest.trimmingCharacters(in: .whitespaces)),
                  host > 0, guest > 0 else { return nil }
            return PortPair(host: host, guest: guest)
        }
        let env = Dictionary(envRows.compactMap { row -> (String, String)? in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, row.value)
        }, uniquingKeysWith: { _, latest in latest })
        return Self.buildSettings(cpus: cpus, memoryGB: memoryGB, mounts: mounts, ports: ports, env: env)
    }

    static func defaultName(_ family: MachineFamily) -> String {
        "\(family.id)-\(String(UUID().uuidString.prefix(4).lowercased()))"
    }
}
