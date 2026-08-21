import DoryCore
@testable import DorydKit
import Darwin
import Foundation
import XCTest

final class VmmLifecycleReceiptTests: XCTestCase {
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
}
