import Foundation
import Testing
@testable import DorydKit

@Suite("Durable machine event stream")
struct DoryMachineEventStreamTests {
    @Test("ordered status and removal events survive daemon restart without secrets")
    func orderedDurableEvents() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineEventStore(
            root: root.path,
            now: { 1_000 }
        )
        try writeMachineConfiguration(root: root, bytes: Data("first".utf8))
        var status = machineStatus(state: .stopped)

        let initial = try store.reconcile(statuses: [status], afterSequence: 0)
        #expect(initial.snapshotRequired)
        #expect(initial.headSequence == 1)
        #expect(initial.events.isEmpty)

        let unchanged = try store.reconcile(
            statuses: [status],
            afterSequence: initial.headSequence
        )
        #expect(!unchanged.snapshotRequired)
        #expect(unchanged.events.isEmpty)

        status.state = .running
        status.pid = 44
        status.environment = ["TOKEN": "opaque-secret-value"]
        status.shares = [DoryMachineShareConfiguration(
            tag: "project",
            hostPath: "/Users/private/source",
            guestPath: "/workspace",
            readOnly: false
        )]
        let changed = try store.reconcile(statuses: [status], afterSequence: 1)
        #expect(changed.headSequence == 2)
        #expect(changed.events.map(\.sequence) == [2])
        #expect(changed.events.first?.kind == .updated)
        #expect(changed.events.first?.status?.state == "running")
        #expect(changed.events.first?.status?.shareCount == 1)

        let priorRevision = try #require(
            changed.events.first?.status?.configurationRevision
        )
        try writeMachineConfiguration(root: root, bytes: Data("second".utf8))
        let configurationChanged = try store.reconcile(
            statuses: [status],
            afterSequence: 2
        )
        #expect(configurationChanged.events.map(\.sequence) == [3])
        #expect(
            configurationChanged.events.first?.status?.configurationRevision
                != priorRevision
        )

        status.runtimeAddress = "192.0.2.44"
        let observedChanged = try store.reconcile(
            statuses: [status],
            afterSequence: 3
        )
        #expect(observedChanged.events.map(\.sequence) == [4])
        #expect(!String(describing: observedChanged).contains("192.0.2.44"))

        let persisted = try String(
            contentsOf: root.appendingPathComponent(DoryMachineEventStore.recordFileName),
            encoding: .utf8
        )
        #expect(!persisted.contains("opaque-secret-value"))
        #expect(!persisted.contains("/Users/private/source"))
        #expect(!persisted.contains("192.0.2.44"))
        #expect(!persisted.contains("pid"))

        let restarted = DoryMachineEventStore(root: root.path, now: { 1_001 })
        let removed = try restarted.reconcile(statuses: [], afterSequence: 4)
        #expect(removed.headSequence == 5)
        #expect(removed.events.map(\.kind) == [.removed])
        #expect(removed.events.first?.machineID == "dev")
        #expect(removed.events.first?.status == nil)
    }

    @Test("bounded history explicitly requires a fresh snapshot for stale and future cursors")
    func boundedHistoryReset() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineEventStore(
            root: root.path,
            historyLimit: 2,
            now: { 2_000 }
        )
        try writeMachineConfiguration(root: root, bytes: Data("bounded".utf8))
        var status = machineStatus(state: .created)
        _ = try store.reconcile(statuses: [status], afterSequence: 0)
        for state in [DoryMachineState.starting, .running, .paused] {
            status.state = state
            _ = try store.reconcile(statuses: [status], afterSequence: 1)
        }

        let stale = try store.reconcile(statuses: [status], afterSequence: 1)
        #expect(stale.headSequence == 4)
        #expect(stale.snapshotRequired)
        #expect(stale.events.isEmpty)

        let future = try store.reconcile(statuses: [status], afterSequence: 99)
        #expect(future.snapshotRequired)
        #expect(future.events.isEmpty)

        let replay = try store.reconcile(statuses: [status], afterSequence: 2)
        #expect(!replay.snapshotRequired)
        #expect(replay.events.map(\.sequence) == [3, 4])
    }

    @Test("pre-structured schema-v1 failure events normalize across daemon restart")
    func legacyFailureNormalization() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineEventStore(root: root.path, now: { 1_500 })
        try writeMachineConfiguration(root: root, bytes: Data("legacy-failure".utf8))
        var status = machineStatus(state: .failed)
        status.lastError = "historical free-form failure"
        _ = try store.reconcile(statuses: [status], afterSequence: 0)

        let recordURL = root.appendingPathComponent(DoryMachineEventStore.recordFileName)
        let data = try Data(contentsOf: recordURL)
        let record = try #require(
            try JSONSerialization.jsonObject(
                with: data,
                options: .mutableContainers
            ) as? NSMutableDictionary
        )
        let projections = try #require(record["projections"] as? NSMutableDictionary)
        let projection = try #require(
            (projections["dev"] as? NSDictionary)?.mutableCopy()
                as? NSMutableDictionary
        )
        projection.removeObject(forKey: "failureCode")
        projection.removeObject(forKey: "recoveryDisposition")
        projections["dev"] = projection
        let events = try #require(record["events"] as? [NSDictionary])
        let event = try #require(events.first?.mutableCopy() as? NSMutableDictionary)
        let eventStatus = try #require(
            (event["status"] as? NSDictionary)?.mutableCopy()
                as? NSMutableDictionary
        )
        eventStatus.removeObject(forKey: "failureCode")
        eventStatus.removeObject(forKey: "recoveryDisposition")
        event["status"] = eventStatus
        record["events"] = [event]
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)

        let restarted = DoryMachineEventStore(root: root.path, now: { 1_501 })
        let removed = try restarted.reconcile(statuses: [], afterSequence: 1)
        #expect(removed.events.map(\.kind) == [.removed])
        let normalized = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(normalized.contains("\"failureCode\" : \"unclassified\""))
        #expect(normalized.contains("\"recoveryDisposition\" : \"inspect-diagnostics\""))
        #expect(!normalized.contains("historical free-form failure"))
    }

    @Test("corrupt symlinked and hard-linked event authority fails closed")
    func filesystemAuthorityFailsClosed() throws {
        for variant in ["corrupt", "symlink", "hardlink"] {
            let root = try privateTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DoryMachineEventStore(root: root.path, now: { 3_000 })
            try writeMachineConfiguration(root: root, bytes: Data("authority".utf8))
            _ = try store.reconcile(
                statuses: [machineStatus(state: .stopped)],
                afterSequence: 0
            )
            let record = root.appendingPathComponent(DoryMachineEventStore.recordFileName)
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
                let alias = root.appendingPathComponent("record-alias.json")
                #expect(link(record.path, alias.path) == 0)
            default:
                Issue.record("unexpected variant")
            }
            #expect(throws: DoryMachineEventStoreError.self) {
                _ = try store.reconcile(
                    statuses: [machineStatus(state: .running)],
                    afterSequence: 1
                )
            }
        }
    }

    @Test("two store instances serialize one monotonic event authority")
    func crossInstanceSerialization() async throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DoryMachineEventStore(root: root.path, now: { 4_000 })
        let second = DoryMachineEventStore(root: root.path, now: { 4_001 })
        try writeMachineConfiguration(root: root, bytes: Data("shared".utf8))
        _ = try first.reconcile(
            statuses: [machineStatus(state: .stopped)],
            afterSequence: 0
        )
        let results = try await withThrowingTaskGroup(
            of: DoryMachineEventBatch.self
        ) { group in
            group.addTask {
                try first.reconcile(
                    statuses: [machineStatus(state: .running)],
                    afterSequence: 1
                )
            }
            group.addTask {
                try second.reconcile(
                    statuses: [machineStatus(state: .paused)],
                    afterSequence: 1
                )
            }
            var values: [DoryMachineEventBatch] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 2)
        let final = try DoryMachineEventStore(root: root.path).reconcile(
            statuses: [machineStatus(state: .paused)],
            afterSequence: 1
        )
        #expect(final.headSequence >= 2)
        #expect(final.events.map(\.sequence) == Array(2...final.headSequence))
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-machine-events-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func writeMachineConfiguration(root: URL, bytes: Data) throws {
        let directory = root.appendingPathComponent("dev", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let path = directory.appendingPathComponent("machine.json").path
        let temporary = directory.appendingPathComponent("machine.tmp").path
        #expect(FileManager.default.createFile(
            atPath: temporary,
            contents: bytes,
            attributes: [.posixPermissions: 0o600]
        ))
        if rename(temporary, path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: nil
            )
        }
    }

    private func machineStatus(state: DoryMachineState) -> DoryMachineStatus {
        DoryMachineStatus(
            id: "dev",
            state: state,
            memoryMB: 2_048,
            cpuCount: 2
        )
    }
}
