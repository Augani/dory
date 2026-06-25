import Testing
@testable import Dory

struct ExecArgsTests {
    @Test func rootUsesFallbackShellProbe() {
        let a = TerminalLauncher.execArgs(user: "root", shell: "/bin/sh", home: "/root", container: "c1")
        #expect(a == "exec -it c1 sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func nonRootExecsAsUserWithLoginShell() {
        let a = TerminalLauncher.execArgs(user: "augustusotu", shell: "/bin/bash", home: "/Users/augustusotu", container: "c1")
        #expect(a == "exec -it -u augustusotu -w /Users/augustusotu c1 /bin/bash -l")
    }

    @Test func execArgsQuoteShellSensitiveValues() {
        let a = TerminalLauncher.execArgs(
            user: "dev'user",
            shell: "/opt/homebrew/bin/fish shell",
            home: "/Users/Augustus Otu",
            container: "dory-machine-dev box"
        )
        #expect(a == #"exec -it -u 'dev'\''user' -w '/Users/Augustus Otu' 'dory-machine-dev box' '/opt/homebrew/bin/fish shell' -l"#)
    }

    @Test func dockerCommandQuotesSocketPath() {
        let command = TerminalLauncher.dockerCommand(
            socketPath: "/Users/Augustus Otu/.dory/dory.sock",
            execArgs: TerminalLauncher.execArgs(user: "root", shell: "/bin/sh", home: "/root", container: "c1")
        )
        #expect(command == #"docker -H 'unix:///Users/Augustus Otu/.dory/dory.sock' exec -it c1 sh -c 'command -v bash >/dev/null && exec bash || exec sh'"#)
    }
}
