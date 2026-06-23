import Testing
@testable import Dory

struct ExecArgsTests {
    @Test func rootUsesFallbackShellProbe() {
        let a = TerminalLauncher.execArgs(user: "root", shell: "/bin/sh", home: "/root", container: "c1")
        #expect(a == "exec -it c1 sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func nonRootExecsAsUserWithLoginShell() {
        let a = TerminalLauncher.execArgs(user: "augustusotu", shell: "/bin/bash", home: "/Users/augustusotu", container: "c1")
        #expect(a == "exec -it -u 'augustusotu' -w '/Users/augustusotu' c1 '/bin/bash' -l")
    }
}
