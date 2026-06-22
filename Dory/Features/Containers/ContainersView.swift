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
                listColumn
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

    @ViewBuilder private var listColumn: some View {
        VStack(spacing: 0) {
            filterBar
            if store.loadState == .connecting && store.containers.isEmpty {
                SkeletonRows()
                Spacer(minLength: 0)
            } else if store.loadState == .engineOff {
                TableEmptyState(glyph: .containers, title: "Engine not running",
                                message: "Dory's container engine isn't running yet. It starts automatically when Dory connects.")
            } else if store.containers.isEmpty {
                TableEmptyState(glyph: .containers, title: "No containers yet",
                                message: "Run a container from an image, or start one with `docker run`.",
                                actionLabel: "New Container", action: { store.activeSheet = .newContainer })
            } else if store.filteredContainers.isEmpty {
                TableEmptyState(glyph: .search, title: "No matches",
                                message: "No containers match the current filter.")
            } else {
                listHeader
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(store.groupedContainers) { group in
                            if let project = group.project {
                                groupHeader(project, count: group.containers.count)
                            }
                            ForEach(group.containers) { ContainerRow(container: $0) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            if store.selectedContainer == nil { Rectangle().fill(p.border).frame(width: 1) }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            filterControl
            Spacer()
            if store.runningCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(p.green).frame(width: 6, height: 6)
                    Text("\(store.runningCount) running").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(p.green)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(p.greenWeak, in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var filterControl: some View {
        HStack(spacing: 2) {
            ForEach(ContainerFilter.allCases, id: \.self) { f in
                let selected = store.containerFilter == f
                Button { store.containerFilter = f } label: {
                    Text(f.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? .white : p.text2)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(selected ? p.accent : Color.clear, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filter-\(f.rawValue)")
            }
        }
        .padding(2)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
    }

    private func groupHeader(_ project: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(p.text3)
            Text(project).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text)
            Text("compose · \(count) service\(count == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(p.text3)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(p.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var listHeader: some View {
        HStack(spacing: 0) {
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 92, alignment: .leading)
            Text("MEMORY").frame(width: 70, alignment: .leading)
            Spacer().frame(width: 96)
        }
        .font(.system(size: 10.5, weight: .bold)).tracking(0.5)
        .foregroundStyle(p.text3)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(p.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
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
}

private struct ContainerRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let container: Container
    @State private var hover = false

    private var selected: Bool { store.selectedContainerID == container.id }
    private var pending: Bool { store.pendingContainerIDs.contains(container.id) }
    private var ports: [PublishedPort] { parsePublishedPorts(container.ports) }
    private var spark: [Double] { (store.cpuHistory[container.id] ?? []).map { min(100, max(0, $0 * 7)) } }

    var body: some View {
        HStack(spacing: 0) {
            StatusPill(container.status).padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name).font(DoryType.body.font(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    ForEach(ports.prefix(3)) { port in
                        PortChip(label: port.label) { store.openPort(store.portURL(for: container, port: port)) }
                    }
                }
                Text(container.image).font(.mono(11)).foregroundStyle(p.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if container.isRunning && !spark.isEmpty {
                    SparkBars(heights: spark, tint: p.accent).frame(width: 30, height: 14)
                }
                Text(container.isRunning ? String(format: "%.1f%%", container.cpuPercent) : "—")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
            }
            .frame(width: 92, alignment: .leading)

            Text(container.isRunning ? container.memoryDisplay : "—")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
                .frame(width: 70, alignment: .leading)

            rowActions.frame(width: 96, alignment: .trailing)
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

    @ViewBuilder private var rowActions: some View {
        HStack(spacing: 2) {
            if pending {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else if hover || selected {
                IconButton(systemImage: container.isRunning ? "stop.fill" : "play.fill",
                           label: container.isRunning ? "Stop \(container.name)" : "Start \(container.name)") {
                    store.toggle(container)
                }
                IconButton(systemImage: "terminal", label: "Open terminal for \(container.name)") {
                    store.openContainerTerminal(container)
                }
            } else {
                Image(systemName: container.isRunning ? "circle.fill" : "circle")
                    .font(.system(size: 7)).foregroundStyle(container.isRunning ? p.green : p.text3)
                    .frame(width: 28, height: 28)
            }
        }
    }

    private var rowBackground: Color {
        if selected { return p.accentWeak }
        return hover ? p.bgRowHover : Color.clear
    }
}
