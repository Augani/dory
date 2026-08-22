import CryptoKit
import Darwin
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

final class DoryVirtualMachineResourceAdmissionLedgerTests: XCTestCase {
    func testTwoLedgerInstancesAtomicallyAdmitOnlyOneContendingStart() async throws {
        let fixture = try ResourceLedgerFixture("concurrent")
        defer { fixture.cleanup() }
        let first = fixture.ledger
        let second = DoryVirtualMachineResourceAdmissionLedger(root: fixture.ledger.root)
        let host = fixture.host
        let resources = fixture.resources
        let bindings = [fixture.binding("machine-a"), fixture.binding("machine-b")]
        let startGate = ResourceLedgerConcurrentStartGate(participants: 2)

        let results = await withTaskGroup(
            of: Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>.self,
            returning: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>].self
        ) { group in
            for (ledger, binding) in zip([first, second], bindings) {
                group.addTask {
                    await startGate.wait()
                    do {
                        return .success(try ledger.reserveStarting(
                            binding: binding,
                            hostFacts: host,
                            workload: .desktop,
                            resources: resources
                        ))
                    } catch let error as DoryVirtualMachineResourceAdmissionLedgerError {
                        return .failure(error)
                    } catch {
                        return .failure(.filesystem("unexpected test error"))
                    }
                }
            }
            var collected: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        let failures = results.compactMap { result
            -> DoryVirtualMachineResourceAdmissionLedgerError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }
        XCTAssertEqual(failures.count, 1)
        guard case let .capacityUnavailable(issues) = try XCTUnwrap(failures.first) else {
            return XCTFail("expected capacity rejection")
        }
        XCTAssertTrue(issues.contains {
            $0.code == .requestExceedsHostSafeMaximum && $0.resource == .cpu
        })
        let snapshot = try fixture.ledger.snapshot()
        XCTAssertEqual(snapshot.leases.count, 1)
        XCTAssertEqual(snapshot.leases.first?.state, .starting)
    }

    func testStoppedLeaseReleasesRuntimeCommitmentButRetainsStorageReservation() throws {
        try withFixture("stopped-storage") { fixture in
            let first = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let plan = fixture.plan(binding: first.binding, evidence: first.evidence)
            let bound = try fixture.ledger.bind(
                leaseID: first.leaseID,
                to: plan,
                expectedLeaseRevision: first.leaseRevision
            )
            let running = try fixture.ledger.markRunning(
                leaseID: bound.leaseID,
                plan: plan,
                hostFacts: fixture.host,
                expectedLeaseRevision: bound.leaseRevision
            )
            let stopped = try fixture.ledger.markStopped(
                leaseID: running.leaseID,
                expectedLeaseRevision: running.leaseRevision
            )
            XCTAssertEqual(stopped.state, .stopped)

            let second = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-b"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            XCTAssertEqual(second.evidence.existingVirtualCPUCommitment, 0)
            XCTAssertEqual(second.evidence.existingMemoryCommitmentBytes, 0)
            XCTAssertEqual(
                second.evidence.existingStorageReservationBytes,
                fixture.resources.diskBytes
            )
            let states = Dictionary(uniqueKeysWithValues: try fixture.ledger.snapshot().leases.map {
                ($0.binding.machineID, $0.state)
            })
            XCTAssertEqual(states["machine-a"], .stopped)
            XCTAssertEqual(states["machine-b"], .starting)
        }
    }

    func testPortBindingsAreAtomicAcrossProcessesAndReleasedOnlyWhenStopped() throws {
        try withFixture("port-binding-lifecycle") { fixture in
            let tcp = fixture.forward("ssh", transport: .tcp, hostPort: 22_220)
            let udp = fixture.forward("dns", transport: .udp, hostPort: 22_220)
            let resources = fixture.lightweightResources
            let first = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .server,
                resources: resources,
                portForwards: [tcp]
            )
            XCTAssertEqual(first.portForwards, [tcp])

            let secondLedger = DoryVirtualMachineResourceAdmissionLedger(
                root: fixture.ledger.root
            )
            XCTAssertThrowsError(try secondLedger.reserveStarting(
                binding: fixture.binding("machine-b"),
                hostFacts: fixture.host,
                workload: .server,
                resources: resources,
                portForwards: [fixture.forward(
                    "web",
                    transport: .tcp,
                    hostPort: 22_220,
                    exposure: .lan
                )]
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .portBindingUnavailable(
                        transport: .tcp,
                        hostPort: 22_220,
                        machineID: "machine-a"
                    )
                )
            }

            let udpLease = try secondLedger.reserveStarting(
                binding: fixture.binding("machine-b"),
                hostFacts: fixture.host,
                workload: .server,
                resources: resources,
                portForwards: [udp]
            )
            XCTAssertEqual(udpLease.portForwards, [udp])

            let plan = fixture.plan(
                binding: first.binding,
                evidence: first.evidence,
                portForwards: [tcp]
            )
            let bound = try fixture.ledger.bind(
                leaseID: first.leaseID,
                to: plan,
                expectedLeaseRevision: first.leaseRevision
            )
            let running = try fixture.ledger.markRunning(
                leaseID: bound.leaseID,
                plan: plan,
                hostFacts: fixture.host,
                expectedLeaseRevision: bound.leaseRevision
            )
            _ = try fixture.ledger.markStopped(
                leaseID: running.leaseID,
                expectedLeaseRevision: running.leaseRevision
            )

            let replacement = try secondLedger.reserveStarting(
                binding: fixture.binding("machine-c"),
                hostFacts: fixture.host,
                workload: .server,
                resources: resources,
                portForwards: [tcp]
            )
            XCTAssertEqual(replacement.portForwards, [tcp])

            let beforeRestart = try fixture.ledger.snapshot()
            XCTAssertThrowsError(try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .server,
                resources: resources,
                portForwards: [tcp]
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .portBindingUnavailable(
                        transport: .tcp,
                        hostPort: 22_220,
                        machineID: "machine-c"
                    )
                )
            }
            XCTAssertEqual(try fixture.ledger.snapshot(), beforeRestart)
        }
    }

    func testTwoLedgerInstancesAtomicallyReserveOnlyOnePortOwner() async throws {
        let fixture = try ResourceLedgerFixture("port-binding-race")
        defer { fixture.cleanup() }
        let ledgers = [
            fixture.ledger,
            DoryVirtualMachineResourceAdmissionLedger(root: fixture.ledger.root),
        ]
        let bindings = [fixture.binding("machine-a"), fixture.binding("machine-b")]
        let host = fixture.host
        let resources = fixture.lightweightResources
        let forward = fixture.forward("service", transport: .tcp, hostPort: 22_223)
        let results = await withTaskGroup(
            of: Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>.self,
            returning: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>].self
        ) { group in
            for (ledger, binding) in zip(ledgers, bindings) {
                group.addTask {
                    do {
                        return .success(try ledger.reserveStarting(
                            binding: binding,
                            hostFacts: host,
                            workload: .server,
                            resources: resources,
                            portForwards: [forward]
                        ))
                    } catch let error as DoryVirtualMachineResourceAdmissionLedgerError {
                        return .failure(error)
                    } catch {
                        return .failure(.filesystem("unexpected test error"))
                    }
                }
            }
            var values: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        let failure = try XCTUnwrap(results.compactMap { result
            -> DoryVirtualMachineResourceAdmissionLedgerError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }.first)
        guard case let .portBindingUnavailable(transport, hostPort, machineID) = failure else {
            return XCTFail("expected port-binding rejection, got \(failure)")
        }
        XCTAssertEqual(transport, .tcp)
        XCTAssertEqual(hostPort, 22_223)
        XCTAssertTrue(["machine-a", "machine-b"].contains(machineID))
        XCTAssertEqual(try fixture.ledger.snapshot().leases.count, 1)
    }

    func testPlanMustMatchExactAdmittedPortForwards() throws {
        try withFixture("port-binding-plan") { fixture in
            let forward = fixture.forward("ssh", transport: .tcp, hostPort: 22_221)
            let reserved = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .server,
                resources: fixture.lightweightResources,
                portForwards: [forward]
            )
            var changed = forward
            changed.guestPort += 1
            let changedPlan = fixture.plan(
                binding: reserved.binding,
                evidence: reserved.evidence,
                portForwards: [changed]
            )
            XCTAssertThrowsError(try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: changedPlan,
                expectedLeaseRevision: reserved.leaseRevision
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .planMismatch
                )
            }

            let exactPlan = fixture.plan(
                binding: reserved.binding,
                evidence: reserved.evidence,
                portForwards: [forward]
            )
            XCTAssertNoThrow(try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: exactPlan,
                expectedLeaseRevision: reserved.leaseRevision
            ))
        }
    }

    func testInvalidPortForwardContractNeverCreatesALease() throws {
        try withFixture("invalid-port-binding") { fixture in
            XCTAssertThrowsError(try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .server,
                resources: fixture.lightweightResources,
                portForwards: [fixture.forward(
                    "ssh",
                    transport: .tcp,
                    hostPort: 22
                )]
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .invalidPortForwardContract
                )
            }
            XCTAssertTrue(try fixture.ledger.snapshot().leases.isEmpty)
        }
    }

    func testSchemaOneLeaseRemainsReadableWithNoPortClaims() throws {
        try withFixture("schema-one-port-migration") { fixture in
            _ = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let path = fixture.ledger.root + "/resource-admissions.json"
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            var envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            var record = try XCTUnwrap(envelope["record"] as? [String: Any])
            var leases = try XCTUnwrap(record["leases"] as? [[String: Any]])
            XCTAssertEqual(leases.count, 1)
            leases[0]["schemaVersion"] = 1
            leases[0].removeValue(forKey: "portForwards")
            record["leases"] = leases
            let recordData = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            envelope["record"] = record
            envelope["recordSHA256"] = SHA256.hash(data: recordData).map {
                String(format: "%02x", $0)
            }.joined()
            let downgraded = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) + Data("\n".utf8)
            try downgraded.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )

            let lease = try XCTUnwrap(fixture.ledger.snapshot().leases.first)
            XCTAssertEqual(lease.schemaVersion, 1)
            XCTAssertEqual(lease.portForwards, [])
        }
    }

    func testRunningLeaseCanBeReopenedOnlyForTheSameRetainedPlan() throws {
        try withFixture("retained-running-restart") { fixture in
            let reserved = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let plan = fixture.plan(binding: reserved.binding, evidence: reserved.evidence)
            let bound = try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: plan,
                expectedLeaseRevision: reserved.leaseRevision
            )
            let running = try fixture.ledger.markRunning(
                leaseID: bound.leaseID,
                plan: plan,
                hostFacts: fixture.host,
                expectedLeaseRevision: bound.leaseRevision
            )

            var changedPlan = plan
            changedPlan.planRevision += 1
            XCTAssertThrowsError(try fixture.ledger.prepareRetainedRunningForRestart(
                leaseID: running.leaseID,
                plan: changedPlan,
                expectedLeaseRevision: running.leaseRevision
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .planMismatch
                )
            }
            XCTAssertEqual(try fixture.ledger.snapshot().leases.first, running)

            let restarting = try fixture.ledger.prepareRetainedRunningForRestart(
                leaseID: running.leaseID,
                plan: plan,
                expectedLeaseRevision: running.leaseRevision
            )
            XCTAssertEqual(restarting.state, .starting)
            XCTAssertEqual(restarting.leaseRevision, running.leaseRevision + 1)
            XCTAssertEqual(restarting.boundPlanSHA256, running.boundPlanSHA256)
            XCTAssertEqual(restarting.evidence, running.evidence)
            XCTAssertThrowsError(try fixture.ledger.prepareRetainedRunningForRestart(
                leaseID: restarting.leaseID,
                plan: plan,
                expectedLeaseRevision: restarting.leaseRevision
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .invalidLeaseState(.starting)
                )
            }
        }
    }

    func testStoppedMachineRestartAtomicallyReplacesItsStorageReservation() throws {
        try withFixture("stopped-restart") { fixture in
            let first = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let firstPlan = fixture.plan(binding: first.binding, evidence: first.evidence)
            let bound = try fixture.ledger.bind(
                leaseID: first.leaseID,
                to: firstPlan,
                expectedLeaseRevision: first.leaseRevision
            )
            let running = try fixture.ledger.markRunning(
                leaseID: bound.leaseID,
                plan: firstPlan,
                hostFacts: fixture.host,
                expectedLeaseRevision: bound.leaseRevision
            )
            let stopped = try fixture.ledger.markStopped(
                leaseID: running.leaseID,
                expectedLeaseRevision: running.leaseRevision
            )

            var nextBinding = fixture.binding("machine-a")
            nextBinding.definitionRevision += 1
            nextBinding.definitionSHA256 = digest("2")
            nextBinding.plannedPlanRevision += 1
            let largerDisk = DoryVMResourceRequest(
                virtualCPUCount: fixture.resources.virtualCPUCount,
                memoryBytes: fixture.resources.memoryBytes,
                diskBytes: fixture.resources.diskBytes + 8 * ResourceLedgerFixture.gibibyte
            )
            let restarted = try fixture.ledger.reserveStarting(
                binding: nextBinding,
                hostFacts: fixture.host,
                workload: .desktop,
                resources: largerDisk
            )

            XCTAssertEqual(restarted.leaseID, stopped.leaseID)
            XCTAssertEqual(restarted.leaseRevision, stopped.leaseRevision + 1)
            XCTAssertEqual(restarted.state, .starting)
            XCTAssertEqual(restarted.binding, nextBinding)
            XCTAssertNil(restarted.boundPlanSHA256)
            XCTAssertEqual(restarted.evidence.existingVirtualCPUCommitment, 0)
            XCTAssertEqual(restarted.evidence.existingMemoryCommitmentBytes, 0)
            XCTAssertEqual(restarted.evidence.existingStorageReservationBytes, 0)
            let snapshot = try fixture.ledger.snapshot()
            XCTAssertEqual(snapshot.leases.count, 1)
            XCTAssertEqual(snapshot.leases.first?.resources, largerDisk)
        }
    }

    func testStoppedMachineRestartRollsBackOnCapacityFailureAndSerializesContention() async throws {
        let fixture = try ResourceLedgerFixture("stopped-restart-contention")
        defer { fixture.cleanup() }
        let first = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        )
        let plan = fixture.plan(binding: first.binding, evidence: first.evidence)
        let bound = try fixture.ledger.bind(
            leaseID: first.leaseID,
            to: plan,
            expectedLeaseRevision: first.leaseRevision
        )
        let running = try fixture.ledger.markRunning(
            leaseID: bound.leaseID,
            plan: plan,
            hostFacts: fixture.host,
            expectedLeaseRevision: bound.leaseRevision
        )
        _ = try fixture.ledger.markStopped(
            leaseID: running.leaseID,
            expectedLeaseRevision: running.leaseRevision
        )
        let beforeFailure = try fixture.ledger.snapshot()
        let smallerDisk = DoryVMResourceRequest(
            virtualCPUCount: fixture.resources.virtualCPUCount,
            memoryBytes: fixture.resources.memoryBytes,
            diskBytes: fixture.resources.diskBytes - ResourceLedgerFixture.gibibyte
        )
        XCTAssertThrowsError(try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: smallerDisk
        )) { error in
            XCTAssertEqual(
                error as? DoryVirtualMachineResourceAdmissionLedgerError,
                .storageReservationCannotShrink(
                    existing: fixture.resources.diskBytes,
                    requested: smallerDisk.diskBytes
                )
            )
        }
        XCTAssertEqual(try fixture.ledger.snapshot(), beforeFailure)

        let oversized = DoryVMResourceRequest(
            virtualCPUCount: fixture.host.logicalCPUCount,
            memoryBytes: fixture.resources.memoryBytes,
            diskBytes: fixture.resources.diskBytes
        )
        XCTAssertThrowsError(try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: oversized
        )) { error in
            guard case .capacityUnavailable =
                    error as? DoryVirtualMachineResourceAdmissionLedgerError else {
                return XCTFail("expected capacity rejection")
            }
        }
        XCTAssertEqual(try fixture.ledger.snapshot(), beforeFailure)

        let ledgers = [
            fixture.ledger,
            DoryVirtualMachineResourceAdmissionLedger(root: fixture.ledger.root),
        ]
        let restartBinding = fixture.binding("machine-a")
        let host = fixture.host
        let resources = fixture.resources
        let results = await withTaskGroup(
            of: Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>.self,
            returning: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>].self
        ) { group in
            for ledger in ledgers {
                group.addTask {
                    do {
                        return .success(try ledger.reserveStarting(
                            binding: restartBinding,
                            hostFacts: host,
                            workload: .desktop,
                            resources: resources
                        ))
                    } catch let error as DoryVirtualMachineResourceAdmissionLedgerError {
                        return .failure(error)
                    } catch {
                        return .failure(.filesystem("unexpected test error"))
                    }
                }
            }
            var values: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(results.compactMap { result -> String? in
            guard case let .failure(.machineAlreadyReserved(machineID)) = result else { return nil }
            return machineID
        }, ["machine-a"])
        let snapshot = try fixture.ledger.snapshot()
        XCTAssertEqual(snapshot.leases.count, 1)
        XCTAssertEqual(snapshot.leases.first?.state, .starting)
        XCTAssertEqual(snapshot.leases.first?.leaseID, first.leaseID)
    }

    func testRestartRecoveryExpiresAbandonedStartAndPreservesBoundDisk() throws {
        let clock = ResourceLedgerClock(now: 10_000)
        let fixture = try ResourceLedgerFixture("recovery", clock: clock)
        defer { fixture.cleanup() }
        _ = try fixture.ledger.reserveStarting(
            binding: fixture.binding("abandoned"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources,
            startingLeaseDurationMilliseconds: 100
        )
        clock.advance(by: 100)
        let restarted = DoryVirtualMachineResourceAdmissionLedger(
            root: fixture.ledger.root,
            now: clock.read
        )
        let abandoned = try XCTUnwrap(restarted.snapshot().leases.first)
        XCTAssertEqual(abandoned.state, .stopped)
        XCTAssertNil(abandoned.boundPlanSHA256)
        try restarted.releaseStorageReservation(
            leaseID: abandoned.leaseID,
            expectedLeaseRevision: abandoned.leaseRevision
        )

        let durable = try restarted.reserveStarting(
            binding: fixture.binding("durable"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources,
            startingLeaseDurationMilliseconds: 100
        )
        let plan = fixture.plan(binding: durable.binding, evidence: durable.evidence)
        let bound = try restarted.bind(
            leaseID: durable.leaseID,
            to: plan,
            expectedLeaseRevision: durable.leaseRevision
        )
        XCTAssertNotNil(bound.boundPlanSHA256)
        clock.advance(by: 100)

        let recoveredAgain = DoryVirtualMachineResourceAdmissionLedger(
            root: fixture.ledger.root,
            now: clock.read
        )
        let recovered = try XCTUnwrap(recoveredAgain.snapshot().leases.first)
        XCTAssertEqual(recovered.state, .recoveryRequired)
        XCTAssertNotNil(recovered.boundPlanSHA256)
        XCTAssertNil(recovered.startingExpiresAtUnixMilliseconds)
        XCTAssertThrowsError(try recoveredAgain.reserveStarting(
            binding: fixture.binding("blocked-until-reconciled"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        )) { error in
            guard case .capacityUnavailable =
                    error as? DoryVirtualMachineResourceAdmissionLedgerError else {
                return XCTFail("expected retained runtime commitment")
            }
        }
        let stopped = try recoveredAgain.reconcileExpiredStart(
            leaseID: recovered.leaseID,
            observedRuntimeState: .stopped,
            expectedLeaseRevision: recovered.leaseRevision
        )
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNoThrow(try recoveredAgain.reserveStarting(
            binding: fixture.binding("allowed-after-reconciliation"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        ))
    }

    func testPlanningCompensationCancelsOnlyUnboundAndRetainsStorage() throws {
        let fixture = try ResourceLedgerFixture("planning-cancel")
        defer { fixture.cleanup() }
        let reserved = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        )
        let stopped = try fixture.ledger.cancelUnboundStarting(
            leaseID: reserved.leaseID,
            expectedLeaseRevision: reserved.leaseRevision
        )
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.boundPlanSHA256)
        XCTAssertEqual(stopped.resources.diskBytes, fixture.resources.diskBytes)

        let restarted = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        )
        let plan = fixture.plan(binding: restarted.binding, evidence: restarted.evidence)
        let bound = try fixture.ledger.bind(
            leaseID: restarted.leaseID,
            to: plan,
            expectedLeaseRevision: restarted.leaseRevision
        )
        XCTAssertThrowsError(try fixture.ledger.cancelUnboundStarting(
            leaseID: bound.leaseID,
            expectedLeaseRevision: bound.leaseRevision
        ))
    }

    func testExpiredBoundPlanningLeaseRequiresExactUnlaunchedAuthorization() throws {
        let clock = ResourceLedgerClock(now: 40_000)
        let fixture = try ResourceLedgerFixture("bound-planning-recovery", clock: clock)
        defer { fixture.cleanup() }
        let reserved = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources,
            startingLeaseDurationMilliseconds: 100
        )
        let plan = fixture.plan(binding: reserved.binding, evidence: reserved.evidence)
        _ = try fixture.ledger.bind(
            leaseID: reserved.leaseID,
            to: plan,
            expectedLeaseRevision: reserved.leaseRevision
        )
        clock.advance(by: 100)
        let expired = try XCTUnwrap(try fixture.ledger.snapshot().leases.first)
        XCTAssertEqual(expired.state, .recoveryRequired)
        XCTAssertThrowsError(try fixture.ledger.recoverBoundPlanningLease(
            leaseID: expired.leaseID,
            plan: plan,
            authorization: DoryVirtualMachineBoundPlanningLeaseRecoveryAuthorization(
                machineID: plan.machineID,
                planSHA256: digest("f")
            ),
            startingLeaseDurationMilliseconds: 100,
            expectedLeaseRevision: expired.leaseRevision
        ))
        let exact = DoryVirtualMachineBoundPlanningLeaseRecoveryAuthorization(
            machineID: plan.machineID,
            planSHA256: DoryDaemonVirtualMachinePlanningCoordinator.planSHA256(plan)
        )
        let recovered = try fixture.ledger.recoverBoundPlanningLease(
            leaseID: expired.leaseID,
            plan: plan,
            authorization: exact,
            startingLeaseDurationMilliseconds: 100,
            expectedLeaseRevision: expired.leaseRevision
        )
        XCTAssertEqual(recovered.state, .starting)
        XCTAssertEqual(recovered.boundPlanSHA256,
                       DoryDaemonVirtualMachinePlanningCoordinator.planSHA256(plan))
    }

    func testBoundPlanAndHostFactsAreExactStartGates() throws {
        try withFixture("exact-binding") { fixture in
            let reserved = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let plan = fixture.plan(binding: reserved.binding, evidence: reserved.evidence)
            XCTAssertThrowsError(try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: plan,
                expectedLeaseRevision: 0
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .staleLeaseRevision(expected: 0, actual: 1)
                )
            }
            let bound = try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: plan,
                expectedLeaseRevision: reserved.leaseRevision
            )
            var alternatePlan = plan
            alternatePlan.updatedAtUnixMilliseconds += 1
            XCTAssertThrowsError(try fixture.ledger.bind(
                leaseID: reserved.leaseID,
                to: alternatePlan,
                expectedLeaseRevision: bound.leaseRevision
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .planAlreadyBound
                )
            }
            XCTAssertEqual(
                try fixture.ledger.revalidateForStart(
                    leaseID: bound.leaseID,
                    plan: plan,
                    hostFacts: fixture.host
                ),
                reserved.evidence
            )

            var changedPlan = plan
            changedPlan.updatedAtUnixMilliseconds += 1
            XCTAssertThrowsError(try fixture.ledger.revalidateForStart(
                leaseID: bound.leaseID,
                plan: changedPlan,
                hostFacts: fixture.host
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .planMismatch
                )
            }
            let changedHost = DoryVMHostResources(
                logicalCPUCount: fixture.host.logicalCPUCount,
                physicalMemoryBytes: fixture.host.physicalMemoryBytes,
                freeStorageBytes: fixture.host.freeStorageBytes + 1
            )
            XCTAssertThrowsError(try fixture.ledger.revalidateForStart(
                leaseID: bound.leaseID,
                plan: plan,
                hostFacts: changedHost
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .hostFactsMismatch
                )
            }
        }
    }

    func testConcurrentPlanBindingIsOneShot() async throws {
        let fixture = try ResourceLedgerFixture("bind-race")
        defer { fixture.cleanup() }
        let reserved = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources
        )
        let firstPlan = fixture.plan(binding: reserved.binding, evidence: reserved.evidence)
        var secondPlan = firstPlan
        secondPlan.updatedAtUnixMilliseconds += 1
        let ledgers = [
            fixture.ledger,
            DoryVirtualMachineResourceAdmissionLedger(root: fixture.ledger.root),
        ]
        let plans = [firstPlan, secondPlan]
        let results = await withTaskGroup(
            of: Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>.self,
            returning: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>].self
        ) { group in
            for (ledger, plan) in zip(ledgers, plans) {
                group.addTask {
                    do {
                        return .success(try ledger.bind(
                            leaseID: reserved.leaseID,
                            to: plan,
                            expectedLeaseRevision: reserved.leaseRevision
                        ))
                    } catch let error as DoryVirtualMachineResourceAdmissionLedgerError {
                        return .failure(error)
                    } catch {
                        return .failure(.filesystem("unexpected test error"))
                    }
                }
            }
            var values: [Result<DoryVirtualMachineResourceAdmissionLease,
                DoryVirtualMachineResourceAdmissionLedgerError>] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(results.compactMap { result
            -> DoryVirtualMachineResourceAdmissionLedgerError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }, [.staleLeaseRevision(expected: 1, actual: 2)])

        let acceptedPlans = plans.filter { candidate in
            (try? fixture.ledger.revalidateForStart(
                leaseID: reserved.leaseID,
                plan: candidate,
                hostFacts: fixture.host
            )) != nil
        }
        XCTAssertEqual(acceptedPlans.count, 1)
    }

    func testRunningLeaseSurvivesExpiryAndStorageReleaseIsExplicit() throws {
        let clock = ResourceLedgerClock(now: 20_000)
        let fixture = try ResourceLedgerFixture("running", clock: clock)
        defer { fixture.cleanup() }
        let reserved = try fixture.ledger.reserveStarting(
            binding: fixture.binding("machine-a"),
            hostFacts: fixture.host,
            workload: .desktop,
            resources: fixture.resources,
            startingLeaseDurationMilliseconds: 100
        )
        let plan = fixture.plan(binding: reserved.binding, evidence: reserved.evidence)
        let bound = try fixture.ledger.bind(
            leaseID: reserved.leaseID,
            to: plan,
            expectedLeaseRevision: reserved.leaseRevision
        )
        let running = try fixture.ledger.markRunning(
            leaseID: bound.leaseID,
            plan: plan,
            hostFacts: fixture.host,
            expectedLeaseRevision: bound.leaseRevision
        )
        clock.advance(by: 1_000)
        let restarted = DoryVirtualMachineResourceAdmissionLedger(
            root: fixture.ledger.root,
            now: clock.read
        )
        XCTAssertEqual(try restarted.snapshot().leases.first?.state, .running)
        let stopped = try restarted.markStopped(
            leaseID: running.leaseID,
            expectedLeaseRevision: running.leaseRevision
        )
        XCTAssertEqual(try restarted.snapshot().leases.count, 1)
        try restarted.releaseStorageReservation(
            leaseID: stopped.leaseID,
            expectedLeaseRevision: stopped.leaseRevision
        )
        XCTAssertTrue(try restarted.snapshot().leases.isEmpty)
    }

    func testTamperedRecordAndUnsafeRecordLinkFailClosed() throws {
        try withFixture("record-safety") { fixture in
            _ = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let path = fixture.ledger.root + "/resource-admissions.json"
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            data.append(0x20)
            try data.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            XCTAssertThrowsError(try fixture.ledger.snapshot()) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .invalidRecord
                )
            }
        }

        try withFixture("record-hardlink") { fixture in
            _ = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources
            )
            let path = fixture.ledger.root + "/resource-admissions.json"
            XCTAssertEqual(link(path, fixture.root + "/record-copy"), 0)
            XCTAssertThrowsError(try fixture.ledger.snapshot()) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .invalidRecord
                )
            }
        }
    }

    func testOptimisticLedgerRevisionAndActiveStorageReleaseFailClosed() throws {
        try withFixture("optimistic") { fixture in
            let reserved = try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-a"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources,
                expectedLedgerRevision: 0
            )
            XCTAssertThrowsError(try fixture.ledger.reserveStarting(
                binding: fixture.binding("machine-b"),
                hostFacts: fixture.host,
                workload: .desktop,
                resources: fixture.resources,
                expectedLedgerRevision: 0
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .staleLedgerRevision(expected: 0, actual: 1)
                )
            }
            XCTAssertThrowsError(try fixture.ledger.releaseStorageReservation(
                leaseID: reserved.leaseID,
                expectedLeaseRevision: reserved.leaseRevision
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineResourceAdmissionLedgerError,
                    .invalidLeaseState(.starting)
                )
            }
            XCTAssertEqual(try fixture.ledger.snapshot().leases.count, 1)
        }
    }

    private func withFixture(
        _ name: String,
        body: (ResourceLedgerFixture) throws -> Void
    ) throws {
        let fixture = try ResourceLedgerFixture(name)
        defer { fixture.cleanup() }
        try body(fixture)
    }
}

private actor ResourceLedgerConcurrentStartGate {
    private let participants: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func wait() async {
        if waiters.count + 1 == participants {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class ResourceLedgerFixture {
    static let gibibyte: UInt64 = 1_073_741_824

    let root: String
    let ledger: DoryVirtualMachineResourceAdmissionLedger
    let host = DoryVMHostResources(
        logicalCPUCount: 8,
        physicalMemoryBytes: 16 * gibibyte,
        freeStorageBytes: 256 * gibibyte
    )
    let resources = DoryVMResourceRequest(
        virtualCPUCount: 4,
        memoryBytes: 4 * gibibyte,
        diskBytes: 32 * gibibyte
    )
    let lightweightResources = DoryVMResourceRequest(
        virtualCPUCount: 2,
        memoryBytes: 2 * gibibyte,
        diskBytes: 32 * gibibyte
    )

    init(_ name: String, clock: ResourceLedgerClock? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-resource-ledger-\(name)-\(UUID().uuidString)",
            isDirectory: true
        ).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        if let clock {
            ledger = DoryVirtualMachineResourceAdmissionLedger(
                root: root + "/ledger",
                now: clock.read
            )
        } else {
            ledger = DoryVirtualMachineResourceAdmissionLedger(root: root + "/ledger")
        }
    }

    func binding(_ machineID: String) -> DoryVirtualMachineResourceAdmissionPlanBinding {
        DoryVirtualMachineResourceAdmissionPlanBinding(
            machineID: machineID,
            definitionRevision: 3,
            definitionSHA256: digest("1"),
            plannedPlanRevision: 1
        )
    }

    func plan(
        binding: DoryVirtualMachineResourceAdmissionPlanBinding,
        evidence: DoryResolvedMachineResourceAdmissionEvidence,
        portForwards: [DoryVMPortForward] = []
    ) -> DoryResolvedMachinePlan {
        let provenance = DoryMutableBootMediaProvenanceReference(
            repositoryIdentity: "machine-store",
            mediaIdentity: "\(binding.machineID)-disk",
            revision: 1
        )
        let media = DoryBootMedia(
            kind: .virtualDisk,
            source: .userProvided,
            mutableProvenance: provenance
        )
        var devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        if !portForwards.isEmpty { devices.networkAttachment = .sharedNAT }
        let guest = DoryGuestPlatform(family: .linux, architecture: .arm64)
        return DoryResolvedMachinePlan(
            machineID: binding.machineID,
            definitionRevision: binding.definitionRevision,
            definitionSHA256: binding.definitionSHA256,
            planRevision: binding.plannedPlanRevision,
            createdAtUnixMilliseconds: 1_700_000_000_000,
            updatedAtUnixMilliseconds: 1_700_000_000_000,
            guest: guest,
            backend: .appleVirtualizationFramework,
            backendImplementationIdentifier: "dory.vz-linux.compatibility.v1",
            backendRuntimeBuildIdentifier: "vz-runtime-1",
            virtualHardwareABIVersion: 1,
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: DoryVMResolverReference(
                    namespace: "machine",
                    identifier: "\(binding.machineID)-disk"
                ),
                media: media,
                mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
                    receiptIdentity: "disk-receipt-1",
                    provenance: provenance,
                    receiptSHA256: digest("7"),
                    resolverID: "machine-store",
                    resolverVersion: 1
                )
            ),
            launchArtifacts: resolvedBootLaunchArtifacts(
                reference: DoryVMResolverReference(
                    namespace: "machine",
                    identifier: "\(binding.machineID)-disk"
                ),
                media: media,
                mutableEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
                    receiptIdentity: "disk-receipt-1",
                    provenance: provenance,
                    receiptSHA256: digest("7"),
                    resolverID: "machine-store",
                    resolverVersion: 1
                )
            ),
            components: [DoryResolvedBackendComponentEvidence(
                componentIdentifier: "dory-vmm",
                buildIdentifier: "vz-runtime-1",
                artifactSHA256: digest("d")
            )],
            devices: devices,
            graphics: .software,
            portForwards: portForwards,
            supportTier: .supported,
            selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: DoryVirtualMachineBackendPlanRequest(
                    guest: guest,
                    bootMedia: media,
                    acceptableGraphics: [.software],
                    devices: devices,
                    backendPreferences: [.appleVirtualizationFramework],
                    backendPreferencePolicy: .required
                ),
                selectedEvaluationIndex: 0,
                rejectedCandidates: []
            ),
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                runtime: DoryVirtualMachineRuntimeQualificationEvidence(
                    qualificationIdentity: "runtime-qualification-1",
                    qualificationReportSHA256: digest("c"),
                    signingKeyID: "dory-runtime-1",
                    qualificationFormatVersion: 1,
                    guest: guest,
                    bootMediaKind: media.kind,
                    immutableArtifactSHA256: nil,
                    mutableProvenance: provenance,
                    backend: .appleVirtualizationFramework,
                    backendRuntimeBuildID: "vz-runtime-1",
                    virtualHardwareABIVersion: 1,
                    graphics: .software,
                    devices: devices
                )
            ),
            resourceAdmission: evidence,
            hostQualification: DoryResolvedHostQualificationEvidence(
                qualificationIdentity: "host-qualification-1",
                qualificationReportSHA256: digest("e"),
                hostHardwareModelIdentifier: "Mac16.1",
                hostOperatingSystemBuild: "26A5406c",
                backend: .appleVirtualizationFramework,
                backendRuntimeBuildIdentifier: "vz-runtime-1",
                virtualHardwareABIVersion: 1,
                qualifierIdentifier: "dory-host-qualifier",
                qualifierVersion: 1
            )
        )
    }

    func forward(
        _ id: String,
        transport: DoryVMPortForwardTransport,
        hostPort: UInt16,
        guestPort: UInt16 = 22,
        exposure: DoryVMPortForwardExposure = .loopback
    ) -> DoryVMPortForward {
        DoryVMPortForward(
            id: id,
            transport: transport,
            hostPort: hostPort,
            guestPort: guestPort,
            exposure: exposure
        )
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private final class ResourceLedgerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(now: Int64) { value = now }

    var read: @Sendable () -> Int64 {
        { [self] in lock.withLock { value } }
    }

    func advance(by milliseconds: Int64) {
        lock.withLock { value += milliseconds }
    }
}

private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
