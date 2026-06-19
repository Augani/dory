import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            list
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 300)
        .environment(\.palette, store.palette)
        .background(store.palette.bgWindow)
    }

    private var header: some View {
        HStack(spacing: 10) {
            DoryLogo(size: 28, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dory").font(.system(size: 13, weight: .bold)).foregroundStyle(store.palette.text)
                Text("\(store.runningCount) running · \(store.totalCPUDisplay) CPU")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(store.palette.green)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.containers) { container in
                    HStack(spacing: 9) {
                        StatusDot(color: container.status.dotColor(store.palette), size: 7)
                        Text(container.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(container.cpuPercent, specifier: "%.1f")%").font(.system(size: 11)).monospacedDigit().foregroundStyle(store.palette.text3)
                        Glyph(glyph: container.isRunning ? .pause : .play, size: 11, color: store.palette.text2)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { store.toggle(container) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 260)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { NSApp.activate(ignoringOtherApps: true) } label: {
                Text("Open Dory").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.accentText)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { Rectangle().fill(store.palette.border).frame(width: 1) }
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Dory").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
    }
}
