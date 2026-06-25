import SwiftUI

struct TerminalWindowView: View {
    @Environment(\.palette) private var p
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            header
            ContainerTerminalView(socketPath: session.socketPath, containerID: session.containerID,
                                  user: session.user, shell: session.shell, home: session.home,
                                  kubeExec: session.kubeExec)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(p.bgWindow)
        .navigationTitle(session.title)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let logo = session.logo {
                Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(session.subtitle).font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer()
            Button {
                let command = session.kubeExec.map(KubeExecCommand.shell)
                    ?? TerminalLauncher.dockerCommand(
                        socketPath: session.socketPath,
                        execArgs: TerminalLauncher.execArgs(user: session.user, shell: session.shell, home: session.home, container: session.containerID)
                    )
                TerminalLauncher.open(command: command)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    Text("Terminal.app").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(p.accentText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}
