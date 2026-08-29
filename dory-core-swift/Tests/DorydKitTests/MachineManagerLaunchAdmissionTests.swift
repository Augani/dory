import Foundation
@testable import DorydKit
import XCTest

final class MachineManagerLaunchAdmissionTests: XCTestCase {
    func testOtherMachineCreateStartAndStopRemainResponsiveWhileAdmissionIsBlocked() throws {
        let fixture = try makeFixture("cross-machine-mutations")
        defer { fixture.cleanup() }
        let admissionEntered = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let blockedLaunchFinished = DispatchSemaphore(value: 0)
        fixture.manager.installMachineAwareShareAuthorityPreSpawnHookForTesting { machineID in
            guard machineID == "dev" else { return }
            admissionEntered.signal()
            guard releaseAdmission.wait(timeout: .now() + 5) == .success else {
                throw MachineManagerError.persistence("test admission gate timed out")
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? fixture.manager.start(id: "dev")
            blockedLaunchFinished.signal()
        }
        XCTAssertEqual(admissionEntered.wait(timeout: .now() + 2), .success)
        defer { releaseAdmission.signal() }

        let otherMutationsFinished = DispatchSemaphore(value: 0)
        let otherMutationResult = LaunchAdmissionLockedBox<Result<Void, Error>>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try fixture.manager.create(DoryMachineConfiguration(
                    id: "third",
                    kernelPath: doryTestKernelPath,
                    rootfsPath: doryTestRootfsPath
                ))
                _ = try fixture.manager.start(id: "other")
                _ = try fixture.manager.stop(id: "other")
                otherMutationResult.set(.success(()))
            } catch {
                otherMutationResult.set(.failure(error))
            }
            otherMutationsFinished.signal()
        }
        let otherCompletion = otherMutationsFinished.wait(timeout: .now() + 2)
        XCTAssertEqual(
            otherCompletion,
            .success,
            "unrelated create/start/stop waited on another workspace's admission"
        )
        if otherCompletion == .success {
            switch try XCTUnwrap(otherMutationResult.value) {
            case .success:
                XCTAssertEqual(fixture.manager.status(id: "third")?.state, .created)
                XCTAssertEqual(fixture.manager.status(id: "other")?.state, .stopped)
            case let .failure(error):
                XCTFail("unrelated mutations failed: \(error)")
            }
        }

        releaseAdmission.signal()
        XCTAssertEqual(blockedLaunchFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(fixture.starter.value, 2)
        XCTAssertEqual(
            fixture.manager.retainedWorkspaceMutationCoordinatorEntriesForTesting(),
            0
        )
    }

    func testSameMachineStartsExcludeEachOtherAndCoordinatorEntryIsReclaimed() throws {
        let fixture = try makeFixture("same-machine-exclusion")
        defer { fixture.cleanup() }
        let admissionEntered = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let hookCalls = LaunchAdmissionLockedCounter()
        let firstResult = LaunchAdmissionLockedBox<Result<DoryMachineStatus, Error>>()
        let secondResult = LaunchAdmissionLockedBox<Result<DoryMachineStatus, Error>>()
        fixture.manager.installMachineAwareShareAuthorityPreSpawnHookForTesting { machineID in
            guard machineID == "dev" else { return }
            hookCalls.increment()
            admissionEntered.signal()
            guard releaseAdmission.wait(timeout: .now() + 5) == .success else {
                throw MachineManagerError.persistence("test admission gate timed out")
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            firstResult.set(Result { try fixture.manager.start(id: "dev") })
            firstFinished.signal()
        }
        XCTAssertEqual(admissionEntered.wait(timeout: .now() + 2), .success)
        defer { releaseAdmission.signal() }

        DispatchQueue.global(qos: .userInitiated).async {
            secondResult.set(Result { try fixture.manager.start(id: "dev") })
            secondFinished.signal()
        }
        XCTAssertEqual(
            secondFinished.wait(timeout: .now() + 0.2),
            .timedOut,
            "conflicting same-workspace start was not serialized"
        )
        XCTAssertEqual(hookCalls.value, 1)
        XCTAssertEqual(fixture.starter.value, 0)

        releaseAdmission.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 5), .success)
        switch try XCTUnwrap(firstResult.value) {
        case let .success(status): XCTAssertEqual(status.state, .running)
        case let .failure(error): XCTFail("first start failed: \(error)")
        }
        switch try XCTUnwrap(secondResult.value) {
        case .success: XCTFail("second start unexpectedly succeeded")
        case let .failure(error):
            guard case MachineManagerError.alreadyRunning("dev") = error else {
                return XCTFail("unexpected second-start error: \(error)")
            }
        }
        XCTAssertEqual(hookCalls.value, 1)
        XCTAssertEqual(fixture.starter.value, 1)
        XCTAssertEqual(
            fixture.manager.retainedWorkspaceMutationCoordinatorEntriesForTesting(),
            0
        )
    }

    func testOtherMachineQueriesRemainResponsiveWhileAdmissionIsBlocked() throws {
        let fixture = try makeFixture("responsive")
        defer { fixture.cleanup() }
        let admissionEntered = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let launchFinished = DispatchSemaphore(value: 0)
        let launchResult = LaunchAdmissionLockedBox<Result<DoryMachineStatus, Error>>()
        fixture.manager.installShareAuthorityPreSpawnHookForTesting {
            admissionEntered.signal()
            guard releaseAdmission.wait(timeout: .now() + 5) == .success else {
                throw MachineManagerError.persistence("test admission gate timed out")
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                launchResult.set(.success(try fixture.manager.start(id: "dev")))
            } catch {
                launchResult.set(.failure(error))
            }
            launchFinished.signal()
        }
        XCTAssertEqual(admissionEntered.wait(timeout: .now() + 2), .success)
        defer { releaseAdmission.signal() }

        let queryFinished = DispatchSemaphore(value: 0)
        let queryResult = LaunchAdmissionLockedBox<(DoryMachineStatus?, [String])>()
        DispatchQueue.global(qos: .userInitiated).async {
            queryResult.set((
                fixture.manager.status(id: "other"),
                fixture.manager.list().map(\.id)
            ))
            queryFinished.signal()
        }
        let queryCompletion = queryFinished.wait(timeout: .now() + 1)
        XCTAssertEqual(
            queryCompletion,
            .success,
            "status/list for an unrelated machine waited on launch admission"
        )
        if queryCompletion == .success, let query = queryResult.value {
            XCTAssertEqual(query.0?.id, "other")
            XCTAssertEqual(query.1, ["dev", "other"])
        }

        releaseAdmission.signal()
        XCTAssertEqual(launchFinished.wait(timeout: .now() + 5), .success)
        switch try XCTUnwrap(launchResult.value) {
        case let .success(status):
            XCTAssertEqual(status.id, "dev")
        case let .failure(error):
            XCTFail("launch unexpectedly failed: \(error)")
        }
        XCTAssertEqual(fixture.starter.value, 1)
    }

    func testInterveningReservationGenerationFailsClosed() throws {
        try assertInterveningAuthorityChangeFailsClosed(.reservationGeneration)
    }

    func testInterveningConfigurationFailsClosed() throws {
        try assertInterveningAuthorityChangeFailsClosed(.configuration)
    }

    func testInterveningOperationFailsClosed() throws {
        try assertInterveningAuthorityChangeFailsClosed(.operation)
    }

    private func assertInterveningAuthorityChangeFailsClosed(
        _ mutation: MachineLaunchAdmissionMutationForTesting,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try makeFixture("mutation-\(mutation)")
        defer { fixture.cleanup() }
        fixture.manager.installShareAuthorityPreSpawnHookForTesting {
            try fixture.manager.mutateReservedLaunchAuthorityForTesting(
                machineID: "dev",
                mutation: mutation
            )
        }

        XCTAssertThrowsError(
            try fixture.manager.start(id: "dev"),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("machine launch authority changed during unlocked admission"),
                "unexpected error: \(error)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(fixture.starter.value, 0, file: file, line: line)
        XCTAssertNil(fixture.manager.status(id: "dev")?.pid, file: file, line: line)
        if mutation == .reservationGeneration {
            XCTAssertNotNil(
                fixture.manager.activeLaunchReservationGenerationForTesting(machineID: "dev"),
                "cleanup for the old launch erased a newer reservation",
                file: file,
                line: line
            )
        } else {
            XCTAssertNil(
                fixture.manager.activeLaunchReservationGenerationForTesting(machineID: "dev"),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            fixture.manager.retainedWorkspaceMutationCoordinatorEntriesForTesting(),
            0,
            "failed admission retained an idle workspace coordinator entry",
            file: file,
            line: line
        )
    }

    private func makeFixture(_ label: String) throws -> LaunchAdmissionFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-launch-admission-\(label)-\(UUID().uuidString)",
            isDirectory: true
        ).path
        let share = root + "/share"
        try FileManager.default.createDirectory(
            atPath: share,
            withIntermediateDirectories: true
        )
        let starter = LaunchAdmissionProcessStarter()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: root + "/state",
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            processStarter: { process in try starter.start(process) }
        )
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "source",
                hostPath: share,
                guestPath: "/workspace"
            )]
        ))
        _ = try manager.create(DoryMachineConfiguration(
            id: "other",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        return LaunchAdmissionFixture(
            root: root,
            manager: manager,
            starter: starter
        )
    }
}

private final class LaunchAdmissionFixture: @unchecked Sendable {
    let root: String
    let manager: MachineManager
    let starter: LaunchAdmissionProcessStarter

    init(root: String, manager: MachineManager, starter: LaunchAdmissionProcessStarter) {
        self.root = root
        self.manager = manager
        self.starter = starter
    }

    func cleanup() {
        _ = try? manager.stop(id: "dev")
        _ = try? manager.stop(id: "other")
        try? FileManager.default.removeItem(atPath: root)
    }
}

private final class LaunchAdmissionProcessStarter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func start(_ process: HvProcess) throws {
        lock.lock()
        starts += 1
        lock.unlock()
        try process.start()
    }
}

private final class LaunchAdmissionLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class LaunchAdmissionLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
