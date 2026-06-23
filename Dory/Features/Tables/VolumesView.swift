import SwiftUI

struct VolumesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var pendingDeleteVolume: Volume?
    @State private var confirmingPruneVolumes = false

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("NAME", sort: "name"), .init("SIZE", 110), .init("DRIVER", 120, sort: "driver"),
                .init("USED BY", 150), .init("CREATED", 120),
            ], sort: store.volumesSort, onSort: { store.toggleSort(.volumes, $0) })
            if store.filteredVolumes.isEmpty {
                TableEmptyState(
                    glyph: .volumes,
                    title: store.volumes.isEmpty ? "No volumes yet" : "No matches",
                    message: store.volumes.isEmpty
                        ? "Volumes keep data alive across container restarts. Create one to get started."
                        : "No volumes match \u{201C}\(store.filter)\u{201D}.",
                    actionLabel: store.volumes.isEmpty ? "New Volume" : nil,
                    action: store.volumes.isEmpty ? { store.activeSheet = .newVolume } : nil
                )
            } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.filteredVolumes) { volume in
                        Button { store.openVolumeBrowser(volume.name) } label: {
                            HStack(spacing: 0) {
                                HStack(spacing: 11) {
                                    IconTile(glyph: .volumes, tint: p.green, background: p.greenWeak)
                                    Text(volume.name).font(.mono(13, weight: .semibold)).foregroundStyle(p.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(volume.size).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                                Text(volume.driver).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
                                Text(volume.usedBy).font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 150, alignment: .leading)
                                Text(volume.created).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .tableRow()
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(p.bgHover)
                        .contextMenu {
                            Button("Browse Files") { store.openVolumeBrowser(volume.name) }
                            Divider()
                            Button("Delete Volume", role: .destructive) { pendingDeleteVolume = volume }
                            Button("Prune unused volumes") { confirmingPruneVolumes = true }
                        }
                    }
                }
            }
            }
        }
        .confirmationDialog(
            pendingDeleteVolume.map { "Delete volume \($0.name)?" } ?? "Delete volume?",
            isPresented: Binding(get: { pendingDeleteVolume != nil }, set: { if !$0 { pendingDeleteVolume = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let volume = pendingDeleteVolume { store.deleteVolume(volume) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the volume and its data. This cannot be undone.")
        }
        .confirmationDialog("Prune unused volumes?", isPresented: $confirmingPruneVolumes, titleVisibility: .visible) {
            Button("Prune", role: .destructive) { store.pruneVolumes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes volumes not used by any container. This cannot be undone.")
        }
    }
}
