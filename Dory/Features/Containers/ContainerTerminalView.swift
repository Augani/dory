import SwiftUI
import SwiftTerm

/// An embedded interactive shell into a running container or pod, backed by SwiftTerm. Runs
/// `docker exec -it <id>` against Dory's socket — or `kubectl exec -it` when a `kubeExec` target
/// is present — through a login shell so the CLI binary resolves from the user's PATH.
struct ContainerTerminalView: NSViewRepresentable {
    let socketPath: String
    let containerID: String
    var user: String = "root"
    var shell: String = "/bin/sh"
    var home: String = "/root"
    var kubeExec: KubeExecTarget? = nil

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let exec: String
        if let kubeExec {
            exec = KubeExecCommand.shell(target: kubeExec)
        } else {
            exec = TerminalLauncher.dockerCommand(
                socketPath: socketPath,
                execArgs: TerminalLauncher.execArgs(user: user, shell: shell, home: home, container: containerID)
            )
        }
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        term.startProcess(executable: "/bin/zsh", args: ["-lc", exec], environment: env)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
