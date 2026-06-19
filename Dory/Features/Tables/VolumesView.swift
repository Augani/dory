import SwiftUI

struct VolumesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("NAME"), .init("SIZE", 110), .init("DRIVER", 120),
                .init("USED BY", 150), .init("CREATED", 120),
            ])
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
                            Button("Delete Volume", role: .destructive) { store.deleteVolume(volume) }
                            Button("Prune unused volumes") { store.pruneVolumes() }
                        }
                    }
                }
            }
        }
    }
}
