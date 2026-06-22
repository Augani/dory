import SwiftUI

struct MachineCreationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private var failed: Bool { store.machineCreationError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.machineCreationTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                    Text(failed ? "Creation failed" : "Setting up your Linux machine…")
                        .font(.system(size: 11.5)).foregroundStyle(failed ? p.red : p.text3)
                }
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.machineCreationLog)
                        .font(.mono(11)).foregroundStyle(p.monoText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("log-bottom")
                }
                .padding(10)
                .frame(height: 180)
                .background(p.monoBg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
                .onChange(of: store.machineCreationLog) { _, _ in
                    withAnimation { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
            }

            if let error = store.machineCreationError {
                Text(error).font(.system(size: 12)).foregroundStyle(p.red).lineLimit(3)
                HStack {
                    Spacer()
                    Button {
                        store.activeSheet = nil
                        store.machineCreationError = nil
                    } label: {
                        Text("Close").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(p.bgWindow)
    }

    @ViewBuilder private var statusIcon: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(p.red)
                .frame(width: 36, height: 36).background(p.redWeak, in: RoundedRectangle(cornerRadius: 10))
        } else {
            ProgressView().controlSize(.small)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
