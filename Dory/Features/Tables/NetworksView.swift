import SwiftUI

struct NetworksView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("NAME"), .init("DRIVER", 110), .init("SCOPE", 100),
                .init("SUBNET", 170), .init("CONTAINERS", 110),
            ])
            if store.filteredNetworks.isEmpty {
                TableEmptyState(
                    glyph: .networks,
                    title: "No matches",
                    message: "No networks match \u{201C}\(store.filter)\u{201D}."
                )
            } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.filteredNetworks) { network in
                        HStack(spacing: 0) {
                            HStack(spacing: 11) {
                                IconTile(glyph: .networks, tint: p.accentText, background: p.accentWeak)
                                Text(network.name).font(.mono(13, weight: .semibold)).foregroundStyle(p.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(network.driver).font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                            Text(network.scope).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 100, alignment: .leading)
                            Text(network.subnet).font(.mono(12)).foregroundStyle(p.text2).frame(width: 170, alignment: .leading)
                            Text("\(network.containerCount)").font(.system(size: 12.5)).foregroundStyle(p.text2).frame(width: 110, alignment: .leading)
                        }
                        .tableRow()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.inspect(network) }
                        .contextMenu {
                            Button("Inspect") { store.inspect(network) }
                            Button("Delete Network", role: .destructive) { store.deleteNetwork(network) }
                                .disabled(["bridge", "host", "none"].contains(network.name))
                            Button("Prune unused networks") { store.pruneNetworks() }
                        }
                    }
                }
            }
            }
        }
    }
}
