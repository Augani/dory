import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Structured machine failure authority", .serialized)
struct DoryMachineFailureTests {
    @Test("failure contract is bounded and excludes path-shaped evidence")
    func validation() {
        let valid = failure(operationID: "12345678-1234-1234-1234-123456789abc")
        #expect(valid.isValid)

        var changed = valid
        changed.causalChain = []
        #expect(!changed.isValid)
        changed = valid
        changed.operationID = "not-an-operation"
        #expect(!changed.isValid)
        changed = valid
        changed.evidenceReferences = [
            .init(kind: .media, identifier: "/Users/private/image.iso"),
        ]
        #expect(!changed.isValid)
    }

    @Test("failure survives restart and clearing is durable")
    func persistenceAndClear() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineFailureStore(root: root.path)
        let expected = failure()
        try store.set(expected, for: "dev")

        let restarted = DoryMachineFailureStore(root: root.path)
        #expect(try restarted.failures()["dev"] == expected)
        let persisted = try String(
            contentsOf: root.appendingPathComponent(
                DoryMachineFailureStore.recordFileName
            ),
            encoding: .utf8
        )
        #expect(!persisted.contains("/Users/"))
        #expect(!persisted.contains("opaque-secret"))

        try restarted.clear("dev")
        #expect(try DoryMachineFailureStore(root: root.path).failures().isEmpty)
    }

    @Test("two daemon instances serialize independent machine failures")
    func crossInstanceSerialization() async throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DoryMachineFailureStore(root: root.path)
        let second = DoryMachineFailureStore(root: root.path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try first.set(self.failure(), for: "first") }
            group.addTask {
                try second.set(
                    self.failure(code: .helperExited),
                    for: "second"
                )
            }
            try await group.waitForAll()
        }
        let failures = try first.failures()
        #expect(failures.keys.sorted() == ["first", "second"])
        #expect(failures["second"]?.code == .helperExited)
    }

    @Test("corrupt symlinked and hard-linked failure records fail closed")
    func filesystemAuthority() throws {
        for variant in ["corrupt", "symlink", "hardlink"] {
            let root = try privateTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DoryMachineFailureStore(root: root.path)
            try store.set(failure(), for: "dev")
            let record = root.appendingPathComponent(
                DoryMachineFailureStore.recordFileName
            )
            switch variant {
            case "corrupt":
                try Data("{}".utf8).write(to: record)
            case "symlink":
                let target = root.appendingPathComponent("foreign.json")
                try Data("{}".utf8).write(to: target)
                try FileManager.default.removeItem(at: record)
                try FileManager.default.createSymbolicLink(
                    atPath: record.path,
                    withDestinationPath: target.path
                )
            case "hardlink":
                #expect(link(
                    record.path,
                    root.appendingPathComponent("alias.json").path
                ) == 0)
            default:
                Issue.record("unexpected fixture")
            }
            #expect(throws: DoryMachineFailureStoreError.self) {
                _ = try store.failures()
            }
        }
    }

    private func failure(
        code: DoryMachineFailureCode = .readinessTimedOut,
        operationID: String? = nil
    ) -> DoryMachineFailure {
        DoryMachineFailure(
            code: code,
            occurredAtUnixMilliseconds: 1_000,
            operationID: operationID,
            causalChain: code == .helperExited ? [.processExit] : [.readinessGate],
            recoveryDisposition: .retry,
            evidenceReferences: [
                .init(kind: .plan, identifier: String(repeating: "a", count: 64)),
            ]
        )
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-machine-failures-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
