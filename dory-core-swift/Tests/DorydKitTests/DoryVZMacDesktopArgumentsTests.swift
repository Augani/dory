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
