import DorydKit
import Foundation
import XCTest

final class SandboxTTLReconcilerTests: XCTestCase {
    func testReconcileDeletesOnlyExpiredPersistedSandboxes() {
        let machines = SandboxMachineFake(statuses: [
            status("expired", expiration: "99"),
            status("future", expiration: "101"),
            status("permanent", expiration: "0"),
            DoryMachineStatus(id: "ordinary", state: .running, environment: [:]),
        ])
        let events = SandboxEventBox()
        let reconciler = SandboxTTLReconciler(
            machines: machines,
            now: { Date(timeIntervalSince1970: 100) },
            eventHandler: { events.append($0) }
        )

        XCTAssertEqual(reconciler.reconcileNow(), ["expired"])
        XCTAssertEqual(machines.stopped, ["expired"])
        XCTAssertEqual(machines.deleted, ["expired"])
        XCTAssertEqual(events.values, ["deleted expired sandbox expired"])
    }

    func testMalformedExpirationFailsClosedWithoutDeletingUnrelatedMachine() {
        let machines = SandboxMachineFake(statuses: [
            status("malformed", expiration: "tomorrow"),
            DoryMachineStatus(
                id: "marker-only",
                state: .stopped,
                environment: [SandboxTTLReconciler.sandboxMarkerKey: "1"]
            ),
        ])
        let reconciler = SandboxTTLReconciler(
            machines: machines,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        XCTAssertTrue(reconciler.reconcileNow().isEmpty)
        XCTAssertTrue(machines.deleted.isEmpty)
    }

    func testExpiredSandboxManifestIsUpdatedWithoutCredentialMaterial() throws {
        let root = "/tmp/dory-sandbox-manifest-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = "\(root)/expired.json"
        let original: [String: Any] = [
            "schema": "dev.dory.sandbox.manifest",
            "sandbox": "expired",
            "status": "retained",
            "credentials": ["secretEnvironmentNames": ["TOKEN"]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: URL(fileURLWithPath: path))
        let machines = SandboxMachineFake(statuses: [status("expired", expiration: "99")])
        let reconciler = SandboxTTLReconciler(
            machines: machines,
            manifestDirectory: root,
            now: { Date(timeIntervalSince1970: 100) }
        )

        XCTAssertEqual(reconciler.reconcileNow(), ["expired"])
        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        )
        XCTAssertEqual(updated["status"] as? String, "expired")
        XCTAssertEqual((updated["updatedEpoch"] as? NSNumber)?.uint64Value, 100)
        XCTAssertEqual(
            (updated["credentials"] as? [String: Any])?["secretEnvironmentNames"] as? [String],
            ["TOKEN"]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func status(_ id: String, expiration: String) -> DoryMachineStatus {
        DoryMachineStatus(
            id: id,
            state: .running,
            environment: [
                SandboxTTLReconciler.sandboxMarkerKey: "1",
                SandboxTTLReconciler.expiresAtKey: expiration,
            ]
        )
    }
}

private final class SandboxMachineFake: @unchecked Sendable, SandboxMachineManaging {
    private(set) var statuses: [DoryMachineStatus]
    private(set) var stopped: [String] = []
    private(set) var deleted: [String] = []

    init(statuses: [DoryMachineStatus]) {
        self.statuses = statuses
    }

    func list() -> [DoryMachineStatus] {
        statuses
    }

    func stop(id: String) throws -> DoryMachineStatus {
        stopped.append(id)
        return statuses.first(where: { $0.id == id }) ?? DoryMachineStatus(id: id, state: .stopped)
    }

    func delete(id: String) throws {
        deleted.append(id)
        statuses.removeAll(where: { $0.id == id })
    }
}

private final class SandboxEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
