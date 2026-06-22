import SwiftUI

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    @State private var selectedFamily: MachineFamily
    @State private var selectedVersion: MachineDistro
    @State private var name: String
    @State private var lastAutoName: String
    @State private var nameEdited = false

    init() {
        let family = MachineDistro.families[0]
        let auto = NewMachineSheet.defaultName(family)
        _selectedFamily = State(initialValue: family)
        _selectedVersion = State(initialValue: family.defaultVersion)
        _name = State(initialValue: auto)
        _lastAutoName = State(initialValue: auto)
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Linux machine").font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)

            VStack(alignment: .leading, spacing: 6) {
                Text("DISTRIBUTION").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(MachineDistro.families) { family in
                            familyCard(family)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 230)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VERSION").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
                    Picker("", selection: $selectedVersion) {
                        ForEach(selectedFamily.versions) { version in
                            Text(version.version).tag(version)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text2)
                    TextField("machine-name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.mono(12.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                        .onChange(of: name) { _, newValue in nameEdited = (newValue != lastAutoName) }
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty && !nameValid {
                        Text("Use letters, numbers, dots, dashes or underscores.")
                            .font(.system(size: 11.5)).foregroundStyle(p.red)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                Button(action: create) {
                    HStack(spacing: 6) {
                        if store.machineBusy { ProgressView().controlSize(.small) }
                        Text("Create").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(p.accent.opacity(createDisabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(createDisabled)
                .accessibilityIdentifier("new-machine-submit")
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
        .background(p.bgWindow)
    }

    private var createDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || !nameValid || store.machineBusy
    }

    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    private func familyCard(_ family: MachineFamily) -> some View {
        let isSelected = family.id == selectedFamily.id
        return Button {
            select(family)
        } label: {
            HStack(spacing: 11) {
                badge(for: family)
                Text(family.display).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? p.accentSoft : p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? p.accent : p.border, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badge(for family: MachineFamily) -> some View {
        if let logo = MachineDistro.logoAsset(family: family.id) {
            Image(logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
        } else {
            Text(family.letter)
                .font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(hex: family.badgeHex), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func select(_ family: MachineFamily) {
        selectedFamily = family
        selectedVersion = family.defaultVersion
        guard !nameEdited else { return }
        let auto = NewMachineSheet.defaultName(family)
        lastAutoName = auto
        name = auto
    }

    private func create() {
        let image = selectedVersion.baseImage
        let n = name
        store.activeSheet = nil
        Task { _ = await store.createMachine(image: image, name: n) }
    }

    static func defaultName(_ family: MachineFamily) -> String {
        "\(family.id)-\(String(UUID().uuidString.prefix(4).lowercased()))"
    }
}
