import Foundation
import Testing
@testable import Dory

struct HostToolsTests {
    @Test func userFacingDoryCommandUsesStableUserInstall() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-host-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".dory/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dory = bin.appendingPathComponent("dory")
        try "#!/bin/sh\n".write(to: dory, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dory.path)

        #expect(HostTools.userFacingDoryCommand(
            home: root.path,
            environment: ["PATH": ""]
        ) == dory.path)
    }
}
