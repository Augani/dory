import SwiftUI

struct MachineComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let onBack: () -> Void

    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var name: String
    @State private var cpus = 2
    @State private var memoryGB = 4
    @State private var address = ""
    @State private var scanning = false
    @State private var matchNote: String?

    private let chipColumns = [GridItem(.adaptive(minimum: 168, maximum: .infinity), spacing: 8)]

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
        _name = State(initialValue: "dev-" + String(UUID().uuidString.prefix(4).lowercased()))
    }

    private var engineReady: Bool { store.dorydRuntimeActive }
    private var selectedItems: [ProvisionItem] { ProvisionCatalog.all.filter { selected.contains($0.id) } }

    private var filteredPackages: [ProvisionItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return ProvisionCatalog.packages }
        return ProvisionCatalog.packages.filter {
            $0.display.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.aptNames.contains { $0.contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !engineReady { engineNotice }
                    matchMyMac
                    chipSection("RUNTIMES", ProvisionCatalog.runtimes)
                    chipSection("TOOLS", ProvisionCatalog.tools)
                    packagesSection
                    machineSection
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).foregroundStyle(p.text2)
                    .frame(width: 28, height: 28)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("back-to-use-cases")
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Build your machine").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text("Pick what to install — baked in at create time.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
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

    private var matchMyMac: some View {
        HStack(spacing: 10) {
            Button(action: runMatch) {
                HStack(spacing: 6) {
                    if scanning { ProgressView().controlSize(.small) }
                    Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 11, weight: .semibold))
                    Text("Match my Mac").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(p.accentText)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(scanning)
            .accessibilityIdentifier("match-my-mac")
            Text(matchNote ?? "Detect your Mac's runtimes & Homebrew tools and pre-check them.")
                .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func chipSection(_ title: String, _ items: [ProvisionItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(title)
            LazyVGrid(columns: chipColumns, alignment: .leading, spacing: 8) {
                ForEach(items) { chip($0) }
            }
        }
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionLabel("PACKAGES")
                Spacer(minLength: 0)
                Text("\(selected.count) selected").font(.system(size: 10.5)).foregroundStyle(p.text3)
            }
            TextField("Search packages…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                .accessibilityIdentifier("package-search")
            if filteredPackages.isEmpty {
                Text("No packages match “\(search)”.").font(.system(size: 11)).foregroundStyle(p.text3)
            } else {
                LazyVGrid(columns: chipColumns, alignment: .leading, spacing: 8) {
                    ForEach(filteredPackages) { chip($0) }
                }
            }
        }
    }

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("MACHINE")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("NAME")
                    TextField("machine-name", text: $name)
                        .textFieldStyle(.plain).font(.mono(12.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: 200)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(nameInvalid ? p.red : p.border))
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("CPUS")
                    Stepper(value: $cpus, in: 1...8) {
                        Text("\(cpus) \(cpus == 1 ? "core" : "cores")").font(.system(size: 12.5)).foregroundStyle(p.text)
                    }.frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("MEMORY")
                    Stepper(value: $memoryGB, in: 1...16) {
                        Text("\(memoryGB) GB").font(.system(size: 12.5)).foregroundStyle(p.text)
                    }.frame(width: 140)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("ADDRESS")
                TextField(defaultAddress, text: $address)
                    .textFieldStyle(.plain).font(.mono(12.5)).foregroundStyle(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 260)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                Text("Leave blank to use \(defaultAddress).")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
            if nameInvalid {
                Text("Use letters, numbers, dots, dashes or underscores.")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
            Text("Shares your Mac home (git config + SSH keys), Ubuntu 24.04, native architecture.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(selected.isEmpty ? "Nothing picked — you'll get a plain Ubuntu 24.04 box."
                                  : "\(selected.count) selected")
                .font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
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
            .accessibilityIdentifier("composer-create")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func chip(_ item: ProvisionItem) -> some View {
        let on = selected.contains(item.id)
        return Button {
            if on { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundStyle(on ? p.accent : p.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.display).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(item.summary).font(.system(size: 10)).foregroundStyle(p.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? p.accentSoft : p.bgElevated, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? p.accent : p.border, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("provision-\(item.id)")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
    }

    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    private var nameInvalid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !nameValid
    }

    private var createDisabled: Bool {
        !nameValid || store.machineBusy || !engineReady
    }

    private func runMatch() {
        scanning = true
        Task {
            let found = await HostToolScan.detect()
            selected.formUnion(found)
            matchNote = found.isEmpty
                ? "No matching tools found on your Mac."
                : "Matched \(found.count) tool\(found.count == 1 ? "" : "s") from your Mac."
            scanning = false
        }
    }

    private static func linuxUsername() -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        let filtered = String(NSUserName().lowercased().filter { allowed.contains($0) }.prefix(32))
        guard let first = filtered.first, first.isLetter || first == "_" else { return "dev" }
        return filtered
    }

    private func create() {
        let recipe = ProvisionComposer.composedRecipe(selectedItems)
        let identity = MacIdentity.make(username: Self.linuxUsername(), uid: Int(getuid()),
                                        homePath: NSHomeDirectory(), shell: "/bin/bash",
                                        sshDir: NSHomeDirectory() + "/.ssh")
        let settings = NewMachineSheet.buildSettings(cpus: cpus, memoryGB: memoryGB, mounts: [], address: trimmedAddress)
        let machineName = name
        Task { _ = await store.createMachine(image: "ubuntu:24.04", name: machineName, arch: .host, recipe: recipe, settings: settings, identity: identity) }
    }

    private var defaultAddress: String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return AppStore.defaultMachineAddress(name: trimmedName.isEmpty ? "machine" : trimmedName, suffix: store.domainSuffix)
    }

    private var trimmedAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
