import Foundation
import Testing
@testable import dory_hv

struct EngineRuntimePolicyTests {
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
