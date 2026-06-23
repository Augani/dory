import SwiftUI

struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var confirmingPrune = false

    var body: some View {
        VStack(spacing: 0) {
            if let reclaim = store.reclaimLabel {
                HStack {
                    Spacer()
                    Button { confirmingPrune = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                            Text(reclaim)
                        }
                    }
                    .buttonStyle(DoryButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("reclaim-images")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
            TableHeader(columns: [
                .init("REPOSITORY", sort: "repository"), .init("IMAGE ID", 120), .init("SIZE", 90, sort: "size"),
                .init("CREATED", 120, sort: "created"), .init("IN USE", 92, sort: "used"), .init("", 84),
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
                        ForEach(store.filteredImages) { image in ImageRow(image: image) }
                    }
                }
            }
        }
        .confirmationDialog("Reclaim unused images?", isPresented: $confirmingPrune, titleVisibility: .visible) {
            Button("Reclaim", role: .destructive) { store.pruneImages() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes images not used by any container. This cannot be undone.")
        }
    }
}

private struct ImageRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let image: DockerImage
    @State private var hover = false
    @State private var pendingDeleteImage: DockerImage?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                IconTile(glyph: .images, tint: p.accentText, background: p.accentWeak)
                HStack(spacing: 0) {
                    Text(image.repository).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(":\(image.tag)").font(.system(size: 13)).foregroundStyle(p.text3).lineLimit(1).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(image.imageID).font(.mono(12)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
            Text(image.size).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
            Text(image.created).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
            StatusPill(inUse: image.isUsed).frame(width: 92, alignment: .leading)
            rowActions.frame(width: 84, alignment: .trailing)
        }
        .tableRow()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.inspect(image) }
        .onHover { hover = $0 }
        .contextMenu { menu }
        .confirmationDialog(
            "Delete \(image.repository):\(image.tag)?",
            isPresented: Binding(get: { pendingDeleteImage != nil }, set: { if !$0 { pendingDeleteImage = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let img = pendingDeleteImage { store.removeImage(img) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the image. This cannot be undone.")
        }
    }

    @ViewBuilder private var rowActions: some View {
        HStack(spacing: 2) {
            if hover {
                IconButton(systemImage: "play.fill", label: "Run \(image.repository)") { runImage() }
                IconButton(systemImage: "info.circle", label: "Inspect \(image.repository)") { store.inspect(image) }
                IconButton(systemImage: "trash", label: "Delete \(image.repository)") { pendingDeleteImage = image }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Inspect") { store.inspect(image) }
        Button("Run") { runImage() }
        Button("Copy Image ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(image.imageID, forType: .string)
        }
        Divider()
        Button("Delete Image", role: .destructive) { pendingDeleteImage = image }
    }

    private func runImage() {
        Task {
            if let err = await store.createContainer(name: "", image: "\(image.repository):\(image.tag)", ports: [], env: [:]) {
                store.actionError = err
            } else { store.section = .containers }
        }
    }
}
