import DoryCore
@testable import DorydKit
import XCTest

final class BalloonControllerTests: XCTestCase {
    func testCriticalHostPressureReclaimsGuestMemory() {
        let controller = BalloonController()
        let host = HostMemorySnapshot(
            totalBytes: 16.gib,
            availableBytes: 512.mib,
            freeBytes: 256.mib,
            pressure: .critical
        )
        let guest = GuestMemorySnapshot(
            id: "docker",
            kind: .docker,
            telemetry: telemetry(totalMB: 4096, availableMB: 2048)
        )

        let plan = controller.plan(host: host, guests: [guest])

        XCTAssertEqual(plan.targets, [
            BalloonTarget(
                id: "docker",
                kind: .docker,
                currentTargetMB: 4096,
                targetMB: 3584,
                reason: .hostCritical
            ),
        ])
        XCTAssertEqual(plan.applicableTargets.map(\.id), ["docker"])
    }

    func testHostPressureDoesNotGrowGuestPastCurrentSetPoint() {
        let controller = BalloonController()
        let host = HostMemorySnapshot(
            totalBytes: 16.gib,
            availableBytes: 512.mib,
            freeBytes: 256.mib,
            pressure: .critical
        )
        let guest = GuestMemorySnapshot(
            id: "builder",
            kind: .virtualMachine,
            telemetry: telemetry(totalMB: 2048, availableMB: 128),
            currentTargetMB: 2048
        )

        let plan = controller.plan(host: host, guests: [guest])

        XCTAssertEqual(plan.targets.first?.targetMB, 2048)
        XCTAssertEqual(plan.targets.first?.reason, .protectedWorkingSet)
        XCTAssertTrue(plan.applicableTargets.isEmpty)
    }

    func testNominalHostGrowsGuestWhenGuestReportsPressure() {
        let controller = BalloonController()
        let host = HostMemorySnapshot(
            totalBytes: 16.gib,
            availableBytes: 8.gib,
            freeBytes: 4.gib
        )
        let guest = GuestMemorySnapshot(
            id: "docker",
            kind: .docker,
            telemetry: telemetry(totalMB: 2048, availableMB: 64, psiSome: 14),
            maximumTargetMB: 2304
        )

        let plan = controller.plan(host: host, guests: [guest])

        XCTAssertEqual(plan.targets.first?.targetMB, 2304)
        XCTAssertEqual(plan.targets.first?.reason, .guestPressure)
    }

    func testRemoteTelemetryIsVisibleButNotApplicable() {
        let controller = BalloonController()
        let host = HostMemorySnapshot(
            totalBytes: 16.gib,
            availableBytes: 256.mib,
            freeBytes: 128.mib,
            pressure: .critical
        )
        let guest = GuestMemorySnapshot(
            id: "remote.prod",
            kind: .remote,
            telemetry: telemetry(totalMB: 8192, availableMB: 4096),
            canBalloon: false
        )

        let plan = controller.plan(host: host, guests: [guest])

        XCTAssertEqual(plan.targets.first?.reason, .notBalloonable)
        XCTAssertEqual(plan.targets.first?.canApply, false)
        XCTAssertTrue(plan.applicableTargets.isEmpty)
    }

    func testReconcileAppliesOnlyChangedApplicableTargets() throws {
        let actuator = CapturingBalloonActuator()
        let controller = BalloonController(
            hostProbe: FixedHostMemoryProbe(snapshot: HostMemorySnapshot(
                totalBytes: 16.gib,
                availableBytes: 512.mib,
                freeBytes: 256.mib,
                pressure: .critical
            )),
            actuator: actuator
        )
        let guests = [
            GuestMemorySnapshot(
                id: "docker",
                kind: .docker,
                telemetry: telemetry(totalMB: 4096, availableMB: 2048)
            ),
            GuestMemorySnapshot(
                id: "remote.prod",
                kind: .remote,
                telemetry: telemetry(totalMB: 4096, availableMB: 2048),
                canBalloon: false
            ),
        ]

        _ = try controller.reconcile(guests: guests)

        XCTAssertEqual(actuator.targets.map(\.id), ["docker"])
        XCTAssertEqual(actuator.targets.first?.targetMB, 3584)
    }

    func testSystemHostMemoryProbeProducesSnapshot() throws {
        let snapshot = try SystemHostMemoryProbe().snapshot()

        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertGreaterThan(snapshot.availableBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }
}

private func telemetry(
    totalMB: UInt64,
    availableMB: UInt64,
    psiSome: Double = 0,
    psiFull: Double = 0
) -> DoryTelemetry {
    DoryTelemetry(
        memTotalKB: totalMB * 1024,
        memAvailableKB: availableMB * 1024,
        psiSomeAvg10: psiSome,
        psiFullAvg10: psiFull
    )
}

private final class FixedHostMemoryProbe: HostMemoryProbing, @unchecked Sendable {
    let snapshotValue: HostMemorySnapshot

    init(snapshot: HostMemorySnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot() throws -> HostMemorySnapshot {
        snapshotValue
    }
}

private final class CapturingBalloonActuator: BalloonActuator, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [BalloonTarget] = []

    var targets: [BalloonTarget] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func apply(targets: [BalloonTarget]) throws {
        lock.lock()
        captured = targets
        lock.unlock()
    }
}

private extension Int {
    var mib: UInt64 { UInt64(self) * 1024 * 1024 }
    var gib: UInt64 { UInt64(self) * 1024 * 1024 * 1024 }
}
