import SwiftUI

struct NetworksView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var pendingDeleteNetwork: DoryNetwork?
    @State private var confirmingPruneNetworks = false

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("NAME", sort: "name"), .init("DRIVER", 110, sort: "driver"), .init("SCOPE", 100, sort: "scope"),
                .init("SUBNET", 170), .init("CONTAINERS", 110, sort: "containers"),
            ], sort: store.networksSort, onSort: { store.toggleSort(.networks, $0) })
            if store.filteredNetworks.isEmpty {
                TableEmptyState(
                    glyph: .networks,
                    title: store.networks.isEmpty ? "No networks yet" : "No matches",
                    message: store.networks.isEmpty
                        ? "Networks created by your containers and Compose projects appear here."
                        : "No networks match \u{201C}\(store.filter)\u{201D}."
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
                            Button("Delete Network", role: .destructive) { pendingDeleteNetwork = network }
                                .disabled(["bridge", "host", "none"].contains(network.name))
                            Button("Prune unused networks") { confirmingPruneNetworks = true }
                        }
                    }
                }
            }
            }
        }
        .confirmationDialog(
            pendingDeleteNetwork.map { "Delete network \($0.name)?" } ?? "Delete network?",
            isPresented: Binding(get: { pendingDeleteNetwork != nil }, set: { if !$0 { pendingDeleteNetwork = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let network = pendingDeleteNetwork { store.deleteNetwork(network) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the network. This cannot be undone.")
        }
        .confirmationDialog("Prune unused networks?", isPresented: $confirmingPruneNetworks, titleVisibility: .visible) {
            Button("Prune", role: .destructive) { store.pruneNetworks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes networks not used by any container. This cannot be undone.")
        }
    }
}
