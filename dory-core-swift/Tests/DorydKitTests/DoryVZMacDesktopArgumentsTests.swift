import Darwin
@testable import DorydKit
import Foundation
import XCTest
@testable import DoryVMMKit

final class DoryVZMacDesktopArgumentsTests: XCTestCase {
    func testParsesInstallWithExplicitMachineAndRestoreImage() throws {
        let arguments = try parseDoryVZMacDesktopArguments([
            "install",
            "--machine", "/tmp/test.dorymac",
            "--ipsw", "/tmp/Restore.ipsw",
            "--guest-tools", "/tmp/Dory Guest Tools",
            "--usb-disk", "/tmp/tools.img",
            "--usb-disk-read-only",
        ])

        XCTAssertEqual(arguments.operation, .install)
        XCTAssertEqual(arguments.machineBundleURL.path, "/tmp/test.dorymac")
        XCTAssertEqual(arguments.restoreImageURL?.path, "/tmp/Restore.ipsw")
        XCTAssertEqual(arguments.guestToolsURL?.path, "/tmp/Dory Guest Tools")
        XCTAssertEqual(arguments.usbDiskURL?.path, "/tmp/tools.img")
        XCTAssertTrue(arguments.usbDiskReadOnly)
    }

    func testParsesRunWithoutRestoreImage() throws {
        let arguments = try parseDoryVZMacDesktopArguments([
            "run", "--machine", "/tmp/test.dorymac",
        ])

        XCTAssertEqual(arguments.operation, .run)
        XCTAssertNil(arguments.restoreImageURL)
        XCTAssertTrue(arguments.usbDiskReadOnly)
        XCTAssertFalse(arguments.hasManagedLifecycleContract)
    }

    func testParsesCompleteManagedLifecycleContract() throws {
        let identity = DoryRuntimeReconnectLaunchIdentity(
            machineID: "mac-work",
            operationID: UUID(uuidString: "d1ec76d2-a4a0-42dc-a725-643167a06f52")!,
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            secret: String(repeating: "b", count: 64)
        )
        let authority = try makeRuntimeReconnectIdentityDescriptor(identity)
        defer { authority.close() }
        let target = DoryRuntimeReconnectContract.childFileDescriptor
        let previousFlags = fcntl(target, F_GETFD)
        let previous = dup(target)
        defer {
            if previous >= 0 {
                _ = dup2(previous, target)
                _ = fcntl(target, F_SETFD, previousFlags)
                close(previous)
            } else {
                close(target)
            }
        }
        try authority.withBorrowedDescriptor {
            guard dup2($0, target) == target else { throw POSIXError(.EBADF) }
        }
        let arguments = try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--machine-id", "mac-work",
            "--operation-id", "d1ec76d2-a4a0-42dc-a725-643167a06f52",
            "--state-dir", "/tmp/machines/mac-work",
            "--control-sock", "/tmp/runtime/c.sock",
            "--handoff-sock", "/tmp/runtime/h.sock",
            "--runtime-reconnect-fd", String(target),
        ])

        XCTAssertTrue(arguments.hasManagedLifecycleContract)
        XCTAssertEqual(arguments.machineID, "mac-work")
        XCTAssertEqual(
            arguments.operationID?.uuidString.lowercased(),
            "d1ec76d2-a4a0-42dc-a725-643167a06f52"
        )
        XCTAssertEqual(arguments.stateDirectoryURL?.path, "/tmp/machines/mac-work")
        XCTAssertEqual(arguments.controlSocketPath, "/tmp/runtime/c.sock")
        XCTAssertEqual(arguments.handoffSocketPath, "/tmp/runtime/h.sock")
        XCTAssertEqual(arguments.reconnectIdentity, identity)
    }

    func testRejectsPartialManagedLifecycleContract() {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--machine-id", "mac-work",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .incompleteManagedLifecycleContract
            )
        }
    }

    func testRequiresRestoreImageOnlyForInstall() {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "install", "--machine", "/tmp/test.dorymac",
        ])) { error in
            XCTAssertEqual(error as? DoryVZMacDesktopArgumentError, .restoreImageRequired)
        }
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--ipsw", "/tmp/Restore.ipsw",
        ])) { error in
            XCTAssertEqual(error as? DoryVZMacDesktopArgumentError, .restoreImageUnexpected)
        }
    }

    func testRejectsRelativeAndDuplicatePaths() {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run", "--machine", "test.dorymac",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .pathMustBeAbsolute("--machine")
            )
        }
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/one.dorymac",
            "--machine", "/tmp/two.dorymac",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .duplicateArgument("--machine")
            )
        }
    }

    func testReadOnlyUSBFlagRequiresDisk() {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--usb-disk-read-only",
        ])) { error in
            XCTAssertEqual(error as? DoryVZMacDesktopArgumentError, .usbReadOnlyWithoutDisk)
        }
    }
}
