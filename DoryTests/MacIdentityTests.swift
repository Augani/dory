import Testing
import Foundation
@testable import Dory

struct MacIdentityTests {
    private func tempSSH(_ pubs: [String: String]) -> String {
        let dir = NSTemporaryDirectory() + "ssh-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in pubs { try? body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        return dir
    }

    @Test func readsPublicKeysFromSSHDir() {
        let dir = tempSSH(["id_ed25519.pub": "ssh-ed25519 AAAA me\n", "id_rsa.pub": "ssh-rsa BBBB me\n", "config": "Host x\n"])
        let id = MacIdentity.make(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", sshDir: dir)
        #expect(id.username == "augustusotu")
        #expect(id.uid == 501)
        #expect(id.homePath == "/Users/augustusotu")
        #expect(Set(id.publicKeys) == ["ssh-ed25519 AAAA me", "ssh-rsa BBBB me"])
    }

    @Test func emptySSHDirYieldsNoKeys() {
        let id = MacIdentity.make(username: "u", uid: 501, homePath: "/Users/u", shell: "/bin/bash", sshDir: tempSSH([:]))
        #expect(id.publicKeys.isEmpty)
    }

    @Test func currentPopulatesFromMac() {
        let id = MacIdentity.current()
        #expect(!id.username.isEmpty)
        #expect(id.homePath == NSHomeDirectory())
        #expect(id.shell == "/bin/bash")
    }
}
