import SwiftUI

struct TableHeaderColumn: Identifiable {
    let title: String
    let width: CGFloat?
    var id: String { title }
    init(_ title: String, _ width: CGFloat? = nil) { self.title = title; self.width = width }
}

struct TableHeader: View {
    @Environment(\.palette) private var p
    let columns: [TableHeaderColumn]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { col in
                if let w = col.width {
                    Text(col.title).frame(width: w, alignment: .leading)
                } else {
                    Text(col.title).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 10.5, weight: .bold)).tracking(0.5)
        .foregroundStyle(p.text3)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

struct TableRowBackground: ViewModifier {
    @Environment(\.palette) private var p
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(hover ? p.bgRowHover : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            .onHover { hover = $0 }
    }
}

extension View {
    func tableRow() -> some View { modifier(TableRowBackground()) }
}

struct IconTile: View {
    @Environment(\.palette) private var p
    let glyph: DoryGlyph
    let tint: Color
    let background: Color
    var body: some View {
        Glyph(glyph: glyph, size: 16, color: tint)
            .frame(width: 30, height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TableEmptyState: View {
    @Environment(\.palette) private var p
    let glyph: DoryGlyph
    let title: String
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Glyph(glyph: glyph, size: 34, color: p.text3)
                .frame(width: 60, height: 60)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(p.border))
            Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(p.text)
            Text(message).font(.system(size: 12.5)).foregroundStyle(p.text3)
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 340)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init("REPOSITORY"), .init("IMAGE ID", 120), .init("SIZE", 90),
                .init("CREATED", 120), .init("IN USE", 80),
            ])
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
