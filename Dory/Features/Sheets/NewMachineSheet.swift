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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !engineReady { engineNotice }
                    distroSection
                    optionsRow
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
            Text("Linux machines need Dory's shared VM. Switch engines in Settings → Docker Engine.")
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
        name.trimmingCharacters(in: .whitespaces).isEmpty || !nameValid || store.machineBusy || !engineReady
    }

    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    private func select(_ family: MachineFamily) {
        selectedFamily = family
        selectedVersion = family.defaultVersion
        if !family.arches.contains(selectedArch) { selectedArch = family.defaultVersion.defaultArch() }
        guard !nameEdited else { return }
        let auto = NewMachineSheet.defaultName(family)
        lastAutoName = auto
        name = auto
    }

    private func create() {
        let image = selectedVersion.baseImage
        let machineName = name
        let arch = selectedArch
        store.activeSheet = nil
        Task { _ = await store.createMachine(image: image, name: machineName, arch: arch) }
    }

    static func defaultName(_ family: MachineFamily) -> String {
        "\(family.id)-\(String(UUID().uuidString.prefix(4).lowercased()))"
    }
}
