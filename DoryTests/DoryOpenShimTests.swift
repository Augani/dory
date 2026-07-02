import Foundation
import Testing
@testable import Dory

struct DoryOpenShimTests {
    @Test func scriptTargetsBridgeDirAndForwardFirst() {
        let s = DoryOpenShim.script
        #expect(s.contains("/opt/dory/bridge"))
        #expect(s.contains("forward/"))
        #expect(s.contains("open/"))
        let forwardIdx = s.range(of: "forward/")!.lowerBound
        let openIdx = s.range(of: "\"$BRIDGE/open")!.lowerBound
        #expect(forwardIdx < openIdx)
    }

    @Test func scriptScansProcNetTcp() {
        let s = DoryOpenShim.script
        #expect(s.contains("/proc/net/tcp"))
        #expect(s.contains("/proc/net/tcp6"))
        #expect(s.contains("0100007F"))
    }

    @Test func scriptWritesAtomicallyViaRename() {
        let s = DoryOpenShim.script
        #expect(s.contains(".tmp"))
        #expect(s.contains("mv "))
    }

    @Test func installCommandsSymlinkBrowsers() {
        let cmds = DoryOpenShim.installCommands().joined(separator: "\n")
        #expect(cmds.contains("/usr/local/bin/dory-open"))
        #expect(cmds.contains("chmod +x /usr/local/bin/dory-open"))
        #expect(cmds.contains("ln -sf /usr/local/bin/dory-open"))
        #expect(cmds.contains("xdg-open"))
        #expect(cmds.contains("sensible-browser"))
        #expect(cmds.contains("www-browser"))
        #expect(cmds.contains("/usr/local/bin/gio"))
    }

    @Test func scriptDropsLeadingOpenArg() {
        #expect(DoryOpenShim.script.contains(#"[ "$1" = "open" ] && shift"#))
    }

    @Test func installEnsuresSocat() {
        let cmds = DoryOpenShim.installCommands().joined(separator: "\n")
        #expect(cmds.contains("socat"))
    }
}
