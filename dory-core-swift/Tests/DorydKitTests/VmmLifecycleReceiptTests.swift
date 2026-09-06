import DoryCore
@testable import DorydKit
import Darwin
import Foundation
import XCTest

final class VmmLifecycleReceiptTests: XCTestCase {
    private final class ActionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [DoryLifecycleReceiptAction] = []

        func append(_ action: DoryLifecycleReceiptAction) {
            lock.withLock { actions.append(action) }
        }

        var snapshot: [DoryLifecycleReceiptAction] {
            lock.withLock { actions }
        }
    }

    func testLifecycleHandlerRunsBeforeAcknowledgement() throws {
        let root = "/tmp/dory-vmm-handler-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let recorder = ActionRecorder()
        let server = VmmLifecycleReceiptServer(
            socketPath: socketPath,
            lifecycleHandler: { recorder.append($0) }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }

        try server.start()
        let operationID = UUID()
        let controller = UnixMachineVZLifecycleController()
        try controller.acknowledgeLifecycle(
            socketPath: socketPath,
            action: .prepareStop,
            operationID: operationID
        )

        XCTAssertEqual(recorder.snapshot, [.prepareStop])
    }

    func testRawHelperReceiptServerEchoesExactLifecycleAuthority() throws {
        let root = "/tmp/dory-helper-receipt-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let server = VmmLifecycleReceiptServer(socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try server.start()

        let operationID = try XCTUnwrap(UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        ))
        let controller = UnixMachineVZLifecycleController()
        try controller.acknowledgeLifecycle(
            socketPath: socketPath,
            action: .prepareStop,
            operationID: operationID
        )

        let unsupported = try VmmControlClient.send(
            socketPath: socketPath,
            request: .pauseMachine(operationID: operationID)
        )
        XCTAssertFalse(unsupported.ok)
    }

    func testRawHelperReceiptServerRejectsMalformedAndZeroAuthorities() throws {
        let root = "/tmp/dory-helper-receipt-invalid-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let server = VmmLifecycleReceiptServer(socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try server.start()

        for operationID in [
            "12345678-1234-4234-8234-123456789ABC",
            "00000000-0000-0000-0000-000000000000",
            "not-a-uuid",
        ] {
            let response = try VmmControlClient.send(
                socketPath: socketPath,
                request: VmmControlRequest(
                    command: "acknowledgeLifecycle",
                    lifecycleAction: .preparePause,
                    operationID: operationID
                )
            )
            XCTAssertFalse(response.ok, operationID)
            XCTAssertNil(response.operationID)
        }
    }

    func testStoppingOldReceiptServerDoesNotUnlinkReplacementSocket() throws {
        let root = "/tmp/dory-helper-receipt-replace-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let old = VmmLifecycleReceiptServer(socketPath: socketPath)
        let replacement = VmmLifecycleReceiptServer(socketPath: socketPath)
        defer {
            old.stop()
            replacement.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try old.start()
        XCTAssertThrowsError(try replacement.start())
        try UnixMachineVZLifecycleController().acknowledgeLifecycle(
            socketPath: socketPath, action: .preparePause, operationID: UUID())
        XCTAssertEqual(unlink(socketPath), 0)
        try replacement.start()

        old.stop()

        let operationID = try XCTUnwrap(UUID(
            uuidString: "67896789-6789-4789-8789-678967896789"
        ))
        try UnixMachineVZLifecycleController().acknowledgeLifecycle(
            socketPath: socketPath,
            action: .preparePause,
            operationID: operationID
        )
    }
    func testReceiptServerBoundsConcurrentClientsAndReleasesSlots() throws {
        let root = "/tmp/dory-receipt-limit-" + UUID().uuidString
        let socketPath = root + "/control.sock"
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let server = VmmLifecycleReceiptServer(socketPath: socketPath, lifecycleHandler: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        })
        try server.start()
        defer {
            for _ in 0..<8 { release.signal() }
            _ = completed.wait(timeout: .now() + 6)
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        for _ in 0..<8 {
            completed.enter()
            DispatchQueue.global().async {
                defer { completed.leave() }
                do {
                    try UnixMachineVZLifecycleController().acknowledgeLifecycle(
                        socketPath: socketPath, action: .preparePause, operationID: UUID())
                } catch { XCTFail("admitted receipt client failed: \(error)") }
            }
        }
        for _ in 0..<8 { XCTAssertEqual(entered.wait(timeout: .now() + 2), .success) }
        XCTAssertThrowsError(try UnixMachineVZLifecycleController().acknowledgeLifecycle(
            socketPath: socketPath, action: .preparePause, operationID: UUID()))
        for _ in 0..<8 { release.signal() }
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        release.signal()
        try UnixMachineVZLifecycleController().acknowledgeLifecycle(
            socketPath: socketPath, action: .preparePause, operationID: UUID())
    }

}
