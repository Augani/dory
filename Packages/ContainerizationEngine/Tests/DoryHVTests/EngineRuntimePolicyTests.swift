import Darwin
import Foundation
import Testing
@testable import dory_hv

struct EngineRuntimePolicyTests {
    @Test func engineMemoryPolicyRejectsAnUnrepresentableGuestMappingBeforeBoot() throws {
        try EngineMode.validateMemoryMB(62 * 1_024)

        do {
            try EngineMode.validateMemoryMB(64 * 1_024)
            Issue.record("64 GiB must exceed the ARM guest-physical aperture")
        } catch {
            #expect(String(describing: error).contains("must not exceed 63488 MiB"))
            #expect(String(describing: error).contains("64-GiB"))
        }
    }

    @Test func reclaimPolicyHasOnlyExplicitStableWireValues() {
        #expect(EngineMode.ReclaimPolicy(rawValue: "drop-caches") == .dropCaches)
        #expect(EngineMode.ReclaimPolicy(rawValue: "senpai") == .senpai)
        #expect(EngineMode.ReclaimPolicy(rawValue: "dropcaches") == nil)
        #expect(EngineMode.ReclaimPolicy(rawValue: "SENPAI") == nil)
    }

    @Test func fuseQueuePolicyIsBoundedAndDeterministic() throws {
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 0) == 1)
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 4) == 4)
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 64) == 8)
        #expect(
            try EngineMode.FuseRequestQueuePolicy(fixedCount: 3).resolved(cpuCount: 64) == 3
        )
        #expect(throws: (any Error).self) {
            _ = try EngineMode.FuseRequestQueuePolicy(fixedCount: 0)
        }
        #expect(throws: (any Error).self) {
            _ = try EngineMode.FuseRequestQueuePolicy(fixedCount: 9)
        }
    }

    @Test func engineStateDirectoryIsOwnerPrivateAndDoesNotFollowFinalSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-engine-state-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = root.appendingPathComponent("fresh", isDirectory: true).path
        #expect(try EngineMode.prepareStateDirectory(fresh) == fresh)
        var freshStatus = stat()
        #expect(lstat(fresh, &freshStatus) == 0)
        #expect(freshStatus.st_uid == geteuid())
        #expect(freshStatus.st_mode & mode_t(0o7777) == mode_t(0o700))

        let state = root.appendingPathComponent("runtime", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: false)
        #expect(chmod(state, mode_t(0o755)) == 0)

        #expect(try EngineMode.prepareStateDirectory(state) == state)
        var status = stat()
        #expect(lstat(state, &status) == 0)
        #expect(status.st_uid == geteuid())
        #expect(status.st_mode & mode_t(0o7777) == mode_t(0o700))

        let target = root.appendingPathComponent("target", isDirectory: true).path
        let alias = root.appendingPathComponent("alias", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        #expect(symlink(target, alias) == 0)
        #expect(throws: (any Error).self) {
            _ = try EngineMode.prepareStateDirectory(alias)
        }
    }

    @Test func helperSourcesContainNoLegacyAmbientFilesystemPolicy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        let forbidden = ["DORY_FUSE_", "DORY_ENGINE_RECLAIM_MODE"]
        var violations: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                violations.append("\(fileURL.lastPathComponent):\(token)")
            }
        }

        #expect(violations.isEmpty)
    }
}
