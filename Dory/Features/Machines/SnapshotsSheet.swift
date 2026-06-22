import SwiftUI

struct SnapshotsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    @State private var note = ""
    @State private var pendingDelete: MachineSnapshot?

    private var machine: Machine? { store.snapshotMachine }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            takeSnapshotBar
            Divider().overlay(p.border)
            list
        }
        .frame(width: 560, height: 540)
        .background(p.bgWindow)
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let snapshot = pendingDelete { store.deleteSnapshot(snapshot) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the saved snapshot image. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Snapshots").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text(machine?.name ?? "Machine").font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
            Button { store.activeSheet = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(p.text2)
                    .frame(width: 26, height: 26)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var takeSnapshotBar: some View {
        HStack(spacing: 10) {
            TextField("Optional note…", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5)).foregroundStyle(p.text)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            Button(action: takeSnapshot) {
                HStack(spacing: 6) {
                    if store.machineBusy { ProgressView().controlSize(.small) }
                    Image(systemName: "camera.aperture").font(.system(size: 11, weight: .semibold))
                    Text("Take snapshot").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(p.accent.opacity(takeDisabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(takeDisabled)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var list: some View {
        if store.machineSnapshots.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "camera.aperture").font(.system(size: 30)).foregroundStyle(p.text3)
                Text("No snapshots yet").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.text2)
                Text("Take a snapshot to save the machine's current disk state.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.machineSnapshots) { snapshot in
                        snapshotRow(snapshot)
                    }
                }
                .padding(16)
            }
        }
    }

    private func snapshotRow(_ snapshot: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.note.isEmpty ? "Snapshot" : snapshot.note)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(relativeTime(snapshot.createdISO)).font(.system(size: 11)).foregroundStyle(p.text3)
                        Text("·").font(.system(size: 11)).foregroundStyle(p.text3)
                        Text(DockerFormat.bytes(snapshot.sizeBytes)).font(.mono(11)).foregroundStyle(p.text3)
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                rowAction("arrow.uturn.backward", "Restore") { store.restoreSnapshot(snapshot) }
                rowAction("doc.on.doc", "Clone") { store.cloneSnapshot(snapshot) }
                rowAction("square.and.arrow.up", "Export") { store.exportSnapshot(snapshot) }
                Spacer(minLength: 0)
                Button { pendingDelete = snapshot } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.red)
                        .frame(width: 30, height: 28)
                        .background(p.redWeak, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
                }
                .buttonStyle(.plain)
                .disabled(store.machineBusy)
                .help("Delete snapshot")
            }
        }
        .padding(12)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }

    private func rowAction(_ systemImage: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .disabled(store.machineBusy)
    }

    private var takeDisabled: Bool {
        machine == nil || store.machineBusy || !store.runtimeKind.isDockerCompatible
    }

    private func takeSnapshot() {
        guard let machine else { return }
        store.takeSnapshot(machine, note: note)
        note = ""
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
