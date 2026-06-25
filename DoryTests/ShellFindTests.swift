import Foundation
import Testing
@testable import Dory

struct ShellFindTests {
    @Test func candidatePathHasPriorityOverPathEnvironment() throws {
        let root = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("candidate/tool")
        let pathTool = root.appendingPathComponent("bin/tool")
        try makeExecutable(candidate)
        try makeExecutable(pathTool)

        let found = Shell.find("tool", candidates: [candidate.path], environment: ["PATH": pathTool.deletingLastPathComponent().path])

        #expect(found == candidate.path)
    }

    @Test func pathEnvironmentIsSearchedAfterCandidates() throws {
        let root = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathTool = root.appendingPathComponent("custom tools/kubectl")
        try makeExecutable(pathTool)

        let found = Shell.find("kubectl", candidates: ["/missing/kubectl"], environment: ["PATH": pathTool.deletingLastPathComponent().path])

        #expect(found == pathTool.path)
    }

    @Test func missingToolReturnsNil() throws {
        let root = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = Shell.find("missing", candidates: [root.appendingPathComponent("missing").path], environment: ["PATH": root.path])

        #expect(found == nil)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
