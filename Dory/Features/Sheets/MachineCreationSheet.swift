import SwiftUI

struct MachineCreationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.openWindow) private var openWindow

    private var failed: Bool { store.machineCreationError != nil }
    private var succeeded: Bool { !failed && !store.machineBusy && store.machineCreated != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.machineCreationTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                    Text(failed ? "Creation failed" : (succeeded ? "Ready" : "Setting up your Linux machine…"))
                        .font(.system(size: 11.5)).foregroundStyle(failed ? p.red : (succeeded ? p.green : p.text3))
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

            if succeeded, let machine = store.machineCreated {
                if let port = machine.sshPort {
                    let sshCommand = "ssh \(machine.username)@localhost -p \(port)"
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.text3)
                        Text(sshCommand).font(.mono(11)).foregroundStyle(p.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sshCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(p.text3)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button { dismissSuccess() } label: {
                        Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }.buttonStyle(.plain)
                    Button {
                        openWindow(value: store.terminalSession(for: machine))
                        dismissSuccess()
                    } label: {
                        Text("Open Terminal").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(p.bgWindow)
    }

    private func dismissSuccess() {
        store.activeSheet = nil
        store.machineCreated = nil
    }

    @ViewBuilder private var statusIcon: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(p.red)
                .frame(width: 36, height: 36).background(p.redWeak, in: RoundedRectangle(cornerRadius: 10))
        } else if succeeded {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(p.green)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        } else {
            ProgressView().controlSize(.small)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
