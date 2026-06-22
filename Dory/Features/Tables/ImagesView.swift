import SwiftUI

struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("REPOSITORY", sort: "repository"), .init("IMAGE ID", 120), .init("SIZE", 90, sort: "size"),
                .init("CREATED", 120, sort: "created"), .init("IN USE", 80, sort: "used"),
            ], sort: store.imagesSort, onSort: { store.toggleSort(.images, $0) })
            if store.filteredImages.isEmpty {
                TableEmptyState(
                    glyph: .images,
                    title: store.images.isEmpty ? "No images yet" : "No matches",
                    message: store.images.isEmpty
                        ? "Pull an image from a registry, or build one from a Dockerfile."
                        : "No images match \u{201C}\(store.filter)\u{201D}.",
                    actionLabel: store.images.isEmpty ? "Pull Image" : nil,
                    action: store.images.isEmpty ? { store.activeSheet = .pullImage } : nil
                )
            } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.filteredImages) { image in
                        HStack(spacing: 0) {
                            HStack(spacing: 11) {
                                IconTile(glyph: .images, tint: p.accentText, background: p.accentWeak)
                                HStack(spacing: 0) {
                                    Text(image.repository).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(":\(image.tag)").font(.system(size: 13)).foregroundStyle(p.text3)
                                        .lineLimit(1).fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(image.imageID).font(.mono(12)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
                            Text(image.size).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
                            Text(image.created).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
                            HStack {
                                StatusBadge(label: image.usedLabel,
                                            color: image.isUsed ? p.green : p.text3,
                                            background: image.isUsed ? p.greenWeak : p.pill)
                            }.frame(width: 80, alignment: .leading)
                        }
                        .tableRow()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.inspect(image) }
                        .contextMenu {
                            Button("Inspect") { store.inspect(image) }
                            Button("Run") {
                                Task {
                                    if let err = await store.createContainer(name: "", image: "\(image.repository):\(image.tag)", ports: [], env: [:]) {
                                        store.actionError = err
                                    } else { store.section = .containers }
                                }
                            }
                            Button("Copy Image ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(image.imageID, forType: .string)
                            }
                            Divider()
                            Button("Delete Image", role: .destructive) { store.removeImage(image) }
                            Button("Prune unused images") { store.pruneImages() }
                        }
                    }
                }
            }
            }
        }
    }
}
