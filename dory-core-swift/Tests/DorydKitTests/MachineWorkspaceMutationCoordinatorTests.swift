import Foundation
@testable import DorydKit
import XCTest

final class MachineWorkspaceMutationCoordinatorTests: XCTestCase {
    func testDifferentWorkspacesAcquireConcurrently() {
        let coordinator = MachineWorkspaceMutationCoordinator()
        let first = coordinator.acquire(workspaceID: "first")
        defer { first.release() }
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            let second = coordinator.acquire(workspaceID: "second")
            acquired.signal()
            _ = release.wait(timeout: .now() + 2)
            second.release()
            completed.signal()
        }

        XCTAssertEqual(acquired.wait(timeout: .now() + 1), .success)
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    }

    func testSameWorkspaceWaitsForLeaseRelease() {
        let coordinator = MachineWorkspaceMutationCoordinator()
        let first = coordinator.acquire(workspaceID: "same")
        let attempted = DispatchSemaphore(value: 0)
        let acquired = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            attempted.signal()
            let second = coordinator.acquire(workspaceID: "same")
            second.release()
            acquired.signal()
        }

        XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(acquired.wait(timeout: .now() + 0.2), .timedOut)
        first.release()
        XCTAssertEqual(acquired.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(coordinator.retainedEntryCountForTesting, 0)
    }

    func testIdleWorkspaceEntriesAreNotRetained() {
        let coordinator = MachineWorkspaceMutationCoordinator()
        for index in 0..<1_000 {
            coordinator.acquire(workspaceID: "workspace-\(index)").release()
        }
        XCTAssertEqual(coordinator.retainedEntryCountForTesting, 0)
    }
}
