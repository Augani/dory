import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Durable machine flight recorder", .serialized)
struct DoryMachineFlightRecorderTests {
    @Test("events are bounded path-free and monotonic across restart")
    func persistenceAndBounds() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineFlightRecorderStore(root: root.path, now: { 1_000 })
        let operationID = "01234567-89ab-4cde-8fab-0123456789ab"
        for index in 0..<(DoryMachineFlightRecorderStore.maximumEventsPerWorkspace + 2) {
            _ = try store.append(
                machineID: "dev",
                operationID: operationID,
                operationKind: "starting",
                kind: .operationPhase,
                phase: index.isMultiple(of: 2) ? "staging" : "verifying",
                machineState: "starting",
                backend: .doryHypervisor,
                virtualHardwareABIVersion: 1,
                planSHA256: String(repeating: "a", count: 64),
                evidenceReferences: [
                    .init(kind: .operation, identifier: operationID),
                ]
            )
        }
        let restarted = DoryMachineFlightRecorderStore(root: root.path)
        let batch = try restarted.batch(machineID: "dev", afterSequence: 0)
        #expect(batch.snapshotRequired)
        #expect(batch.headSequence == 258)
        #expect(batch.events.count == 256)
        #expect(batch.events.first?.sequence == 3)
        #expect(batch.events.last?.sequence == 258)

        let persisted = try String(
            contentsOf: root.appendingPathComponent(
                DoryMachineFlightRecorderStore.recordFileName
            ),
            encoding: .utf8
        )
        #expect(!persisted.contains("/Users/"))
        #expect(!persisted.contains("opaque-secret"))
    }

    @Test("stale and future cursors receive the complete retained snapshot")
    func cursorRecovery() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineFlightRecorderStore(root: root.path, now: { 2_000 })
        for _ in 0...DoryMachineFlightRecorderStore.maximumEventsPerWorkspace {
            _ = try store.append(machineID: "dev", kind: .workspaceCreated)
        }
        let stale = try store.batch(machineID: "dev", afterSequence: 0)
        #expect(stale.snapshotRequired)
        #expect(stale.events.count == 256)
        let future = try store.batch(machineID: "dev", afterSequence: 999)
        #expect(future.snapshotRequired)
        #expect(future.events == stale.events)
        let current = try store.batch(
            machineID: "dev",
            afterSequence: stale.headSequence
        )
        #expect(!current.snapshotRequired)
        #expect(current.events.isEmpty)
    }

    @Test("two daemon instances serialize one workspace sequence")
    func crossInstanceSerialization() async throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DoryMachineFlightRecorderStore(root: root.path, now: { 3_000 })
        let second = DoryMachineFlightRecorderStore(root: root.path, now: { 3_001 })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try first.append(machineID: "dev", kind: .backendSpawned)
            }
            group.addTask {
                _ = try second.append(machineID: "dev", kind: .readinessAccepted)
            }
            try await group.waitForAll()
        }
        let batch = try first.batch(machineID: "dev", afterSequence: 0)
        #expect(batch.headSequence == 2)
        #expect(batch.events.map(\.sequence) == [1, 2])
        #expect(Set(batch.events.map(\.kind)) == [.backendSpawned, .readinessAccepted])
    }

    @Test("invalid path evidence and corrupt filesystem authority fail closed")
    func validationAndFilesystemAuthority() throws {
        let invalid = DoryMachineFlightEvent(
            sequence: 1,
            occurredAtUnixMilliseconds: 1,
            machineID: "dev",
            kind: .failureRecorded,
            failureCode: .helperExited,
            recoveryDisposition: .retry,
            evidenceReferences: [
                .init(kind: .journal, identifier: "/private/journal"),
            ]
        )
        #expect(!invalid.isValid)

        for variant in ["corrupt", "symlink", "hardlink"] {
            let root = try privateTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DoryMachineFlightRecorderStore(root: root.path)
            _ = try store.append(machineID: "dev", kind: .workspaceCreated)
            let record = root.appendingPathComponent(
                DoryMachineFlightRecorderStore.recordFileName
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
            #expect(throws: DoryMachineFlightRecorderStoreError.self) {
                _ = try store.batch(machineID: "dev", afterSequence: 0)
            }
        }
    }

    @Test("deleted workspace history is the only capacity-eviction candidate")
    func deletedWorkspaceEviction() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineFlightRecorderStore(root: root.path, now: { 10_000 })
        for index in 0..<DoryMachineFlightRecorderStore.maximumWorkspaceCount {
            _ = try store.append(machineID: "vm-\(index)", kind: .workspaceCreated)
        }
        #expect(throws: DoryMachineFlightRecorderStoreError.self) {
            _ = try store.append(machineID: "overflow", kind: .workspaceCreated)
        }
        _ = try store.append(machineID: "vm-0", kind: .workspaceDeleted)
        _ = try store.append(machineID: "replacement", kind: .workspaceCreated)
        #expect(try store.batch(machineID: "vm-0", afterSequence: 0).headSequence == 0)
        #expect(try store.batch(machineID: "replacement", afterSequence: 0).headSequence == 1)
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-flight-recorder-\(UUID().uuidString.lowercased())",
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
