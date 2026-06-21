import SwiftUI
import AppKit

struct ContainersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var dragStartWidth: Double?
    private let resizeHandleWidth: Double = 9

    var body: some View {
        GeometryReader { geo in
            let maxDetail = max(320, geo.size.width - 360 - resizeHandleWidth)
            let detailWidth = min(max(store.containerDetailWidth, 320), maxDetail)
            HStack(alignment: .top, spacing: 0) {
                list
                if let selected = store.selectedContainer {
                    resizeHandle(currentWidth: detailWidth, maxDetail: maxDetail)
                    ContainerDetailView(container: selected)
                        .frame(width: detailWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(p.bgContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func resizeHandle(currentWidth: Double, maxDetail: Double) -> some View {
        Rectangle()
            .fill(p.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(p.bgContent)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = currentWidth }
                        let start = dragStartWidth ?? currentWidth
                        store.containerDetailWidth = min(max(start - value.translation.width, 320), maxDetail)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        store.setContainerDetailWidth(store.containerDetailWidth)
                    }
            )
            .accessibilityIdentifier("container-detail-resize")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(store.filteredContainers) { container in
                        ContainerRow(container: container)
                    }
                } header: {
                    listHeader
                }
            }
        }
        .defaultScrollAnchor(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if store.selectedContainer == nil { Rectangle().fill(p.border).frame(width: 1) }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 0) {
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 74, alignment: .leading)
            Text("MEMORY").frame(width: 70, alignment: .leading)
            Color.clear.frame(width: 34)
        }
        .font(.system(size: 10.5, weight: .bold)).tracking(0.5)
        .foregroundStyle(p.text3)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(p.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

private struct ContainerRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let container: Container
    @State private var hover = false

    private var selected: Bool { store.selectedContainerID == container.id }

    var body: some View {
        HStack(spacing: 0) {
            StatusDot(color: container.status.dotColor(p)).padding(.trailing, 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(container.image).font(.mono(11)).foregroundStyle(p.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(container.cpuPercent, specifier: "%.1f")%").font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
                ThinBar(fraction: container.cpuFraction, tint: p.accent, height: 3).frame(width: 44)
            }
            .frame(width: 74, alignment: .leading)

            Text(container.memoryDisplay).font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
                .frame(width: 70, alignment: .leading)

            toggleButton.frame(width: 34)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(p.accent).frame(width: 2.5).padding(.vertical, 6) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.selectedContainerID = container.id }
        .onHover { hover = $0 }
        .accessibilityIdentifier("container-\(container.id)")
    }

    private var rowBackground: Color {
        if selected { return p.accentWeak }
        return hover ? p.bgRowHover : Color.clear
    }

    private var toggleButton: some View {
        Glyph(glyph: container.isRunning ? .pause : .play, size: 12, color: p.text2)
            .frame(width: 30, height: 24)
            .hoverHighlight(p.bgHover, radius: 6)
            .contentShape(Rectangle())
            .onTapGesture { store.toggle(container) }
    }
}
