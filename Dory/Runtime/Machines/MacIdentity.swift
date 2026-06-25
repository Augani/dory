import Foundation

nonisolated struct MacIdentity: Sendable, Hashable {
    let username: String
    let uid: Int
    let homePath: String
    let shell: String
    let publicKeys: [String]

    static func current(shell: String = "/bin/bash") -> MacIdentity {
        make(username: NSUserName(), uid: Int(getuid()), homePath: NSHomeDirectory(),
             shell: shell, sshDir: NSHomeDirectory() + "/.ssh")
    }

    static func make(username: String, uid: Int, homePath: String, shell: String, sshDir: String) -> MacIdentity {
        let keys = (try? FileManager.default.contentsOfDirectory(atPath: sshDir))?
            .filter { $0.hasSuffix(".pub") }
            .compactMap { try? String(contentsOfFile: sshDir + "/" + $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
        return MacIdentity(username: username, uid: uid, homePath: homePath, shell: shell, publicKeys: keys.sorted())
    }
}
