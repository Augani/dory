import Darwin
import DoryOperations
import SwiftUI

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    @State private var name: String
    @State private var address = ""
    @State private var selectedRecipe: DevRecipe?
    @State private var displayMode: MachineDisplayMode
    @State private var desktopDistro: DesktopMachineDistro = .debian
    @State private var guestUsername = NewMachineSheet.defaultGuestUsername()

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
        _displayMode = State(initialValue: displayMode)
        _stage = State(initialValue: displayMode == .desktop ? .form : .useCase)
        _name = State(initialValue: NewMachineSheet.defaultName())
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
            return "\(desktopDistro.displayName) \(desktopDistro.version) · \(desktopDistro.desktopName) · Apple Silicon"
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
            sectionLabel("DESKTOP DISTRIBUTION")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(installedDesktopDistros) { distro in
                    desktopDistroButton(distro)
                }
            }
            Text("Only installed distributions are shown. Add or remove Debian, Ubuntu, and Kali independently in Components.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
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
                    Text("Lightweight headless Linux for terminals, tools, and local services")
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

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ACCESS & SHARING")
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 14)).foregroundStyle(p.accent)
                if displayMode == .desktop {
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
                    Text("Administrator shell").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Spacer(minLength: 0)
                    Text("root · /bin/sh").font(.mono(11.5)).foregroundStyle(p.text3)
                }
            }
            if guestUsernameInvalid {
                Text("Use 1–32 lowercase letters, numbers, underscores or dashes; start with a letter or underscore.")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
            Toggle("Share my Mac home (read-write)", isOn: $shareHome)
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
                     ? "\(desktopDistro.displayName) \(desktopDistro.version) · arm64 · \(normalizedGuestUsername)"
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
            || guestUsernameInvalid
            || store.machineBusy
            || !engineReady
            || mountsOutsideHome
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
        let sharedHomeGuestPath = displayMode == .desktop
            ? "/home/\(normalizedGuestUsername)/Mac"
            : NSHomeDirectory()
        if shareHome, !settings.mounts.contains(where: { $0.guest == sharedHomeGuestPath }) {
            settings.mounts.append(MountPair(host: NSHomeDirectory(), guest: sharedHomeGuestPath))
        }
        let machineName = name
        let recipe = selectedRecipe
        Task { _ = await store.createMachine(name: machineName, recipe: recipe, settings: settings) }
    }

    static func buildSettings(
        cpus: Int,
        memoryGB: Int,
        mounts: [MountPair],
        address: String? = nil,
        displayMode: MachineDisplayMode = .desktop,
        desktopDistro: DesktopMachineDistro = .debian,
        guestUsername: String = "dory",
        guestUID: uid_t = getuid()
    ) -> MachineSettings {
        var environment: [String: String] = [:]
        if displayMode == .desktop {
            environment["DORY_GUEST_USER"] = guestUsername
            environment["DORY_GUEST_UID"] = String(guestUID)
            environment["DORY_DESKTOP_DISTRO"] = desktopDistro.rawValue
            environment["DORY_DESKTOP_NAME"] = desktopDistro.displayName
            environment["DORY_DESKTOP_VERSION"] = desktopDistro.version
            environment["DORY_DESKTOP_ENVIRONMENT"] = desktopDistro.desktopName
        }
        return MachineSettings(
            cpus: cpus,
            memoryMB: memoryGB * 1024,
            mounts: mounts,
            env: environment,
            address: address,
            displayMode: displayMode
        )
    }

    private func collectedSettings() -> MachineSettings {
        let mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest)
        }
        return Self.buildSettings(
            cpus: cpus,
            memoryGB: memoryGB,
            mounts: mounts,
            address: trimmedAddress,
            displayMode: displayMode,
            desktopDistro: desktopDistro,
            guestUsername: normalizedGuestUsername
        )
    }

    static func defaultName() -> String {
        "dory-\(AppStore.generatedMachineToken())"
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
        displayMode == .desktop
            ? "Your Mac home is available in the desktop at ~/Mac with your Mac user ID."
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
