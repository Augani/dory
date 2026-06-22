import SwiftUI

struct TableHeaderColumn: Identifiable {
    let title: String
    let width: CGFloat?
    let sortKey: String?
    var id: String { title }
    init(_ title: String, _ width: CGFloat? = nil, sort: String? = nil) {
        self.title = title; self.width = width; self.sortKey = sort
    }
}

struct TableHeader: View {
    @Environment(\.palette) private var p
    let columns: [TableHeaderColumn]
    var sort: TableSort? = nil
    var onSort: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { col in cell(col) }
        }
        .font(.system(size: 10.5, weight: .bold)).tracking(0.5)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    @ViewBuilder private func cell(_ col: TableHeaderColumn) -> some View {
        let active = col.sortKey != nil && sort?.key == col.sortKey
        let label = HStack(spacing: 3) {
            Text(col.title)
            if active {
                Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
        }
        .foregroundStyle(active ? p.text : p.text3)
        if let key = col.sortKey, let onSort {
            Button { onSort(key) } label: {
                framed(label, width: col.width).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            framed(label, width: col.width)
        }
    }

    @ViewBuilder private func framed(_ content: some View, width: CGFloat?) -> some View {
        if let width { content.frame(width: width, alignment: .leading) }
        else { content.frame(maxWidth: .infinity, alignment: .leading) }
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
