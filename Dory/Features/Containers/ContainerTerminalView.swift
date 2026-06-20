import SwiftUI
import SwiftTerm

/// An embedded interactive shell into a running container, backed by SwiftTerm. Runs
/// `docker exec -it <id>` against Dory's socket through a login shell so the `docker` binary
/// resolves from the user's PATH.
struct ContainerTerminalView: NSViewRepresentable {
    let socketPath: String
    let containerID: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let exec = "docker -H unix://\(socketPath) exec -it \(containerID) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        term.startProcess(executable: "/bin/zsh", args: ["-lc", exec], environment: env)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
