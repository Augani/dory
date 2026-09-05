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
            "--network", "disconnected",
            "--audio-input", "false",
            "--audio-output", "true",
            "--clipboard", "false",
            "--directory-sharing", "true",
        ])

        XCTAssertEqual(arguments.operation, .install)
        XCTAssertEqual(arguments.machineBundleURL.path, "/tmp/test.dorymac")
        XCTAssertEqual(arguments.restoreImageURL?.path, "/tmp/Restore.ipsw")
        XCTAssertEqual(arguments.guestToolsURL?.path, "/tmp/Dory Guest Tools")
        XCTAssertEqual(arguments.usbDiskURL?.path, "/tmp/tools.img")
        XCTAssertTrue(arguments.usbDiskReadOnly)
        XCTAssertEqual(arguments.devicePolicy.network, .disconnected)
        XCTAssertFalse(arguments.devicePolicy.audio.inputEnabled)
        XCTAssertTrue(arguments.devicePolicy.audio.outputEnabled)
        XCTAssertFalse(arguments.devicePolicy.clipboardEnabled)
        XCTAssertTrue(arguments.devicePolicy.directorySharingEnabled)
    }

    func testParsesRunWithoutRestoreImage() throws {
        let arguments = try parseDoryVZMacDesktopArguments([
            "run", "--machine", "/tmp/test.dorymac",
        ])

        XCTAssertEqual(arguments.operation, .run)
        XCTAssertNil(arguments.restoreImageURL)
        XCTAssertTrue(arguments.usbDiskReadOnly)
        XCTAssertEqual(arguments.devicePolicy, .legacyDefault)
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


    func testManagedResumeRequiresAndParsesDaemonSavedStatePath() throws {
        let stateDirectory = try makeManagedSavedStateFixture()
        defer { try? FileManager.default.removeItem(atPath: (stateDirectory as NSString).deletingLastPathComponent) }
        let restoreStatePath = stateDirectory + "/"
            + DoryMachineSavedStateStore.directoryName + "/"
            + DoryMachineSavedStateManifest.stateFileName
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
            "resume",
            "--machine", "/tmp/test.dorymac",
            "--machine-id", "mac-work",
            "--operation-id", "d1ec76d2-a4a0-42dc-a725-643167a06f52",
            "--state-dir", stateDirectory,
            "--control-sock", "/tmp/runtime/c.sock",
            "--handoff-sock", "/tmp/runtime/h.sock",
            "--runtime-reconnect-fd", String(target),
            "--restore-state", restoreStatePath,
        ])

        XCTAssertTrue(arguments.hasManagedLifecycleContract)
        XCTAssertEqual(
            arguments.restoreStateURL?.path,
            restoreStatePath
        )
    }

    func testRejectsUnmanagedOrWrongShapeRestoreStatePath() throws {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "resume",
            "--machine", "/tmp/test.dorymac",
            "--restore-state", "/tmp/machines/mac-work/saved-state-v1/state.bin",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .incompleteManagedLifecycleContract
            )
        }

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

        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "resume",
            "--machine", "/tmp/test.dorymac",
            "--machine-id", "mac-work",
            "--operation-id", "d1ec76d2-a4a0-42dc-a725-643167a06f52",
            "--state-dir", "/tmp/machines/mac-work",
            "--control-sock", "/tmp/runtime/c.sock",
            "--handoff-sock", "/tmp/runtime/h.sock",
            "--runtime-reconnect-fd", String(target),
            "--restore-state", "/tmp/machines/mac-work/state.bin",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .pathMustBeAbsolute("--restore-state")
            )
        }
    }


    private func makeManagedSavedStateFixture() throws -> String {
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let root = homeRoot
            .appendingPathComponent(".dory-vzmac-desktop-arguments-\(UUID().uuidString)", isDirectory: true)
            .path
        let stateDirectory = root + "/mac-work"
        let savedStateDirectory = stateDirectory + "/" + DoryMachineSavedStateStore.directoryName
        try FileManager.default.createDirectory(
            atPath: savedStateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root, 0o700)
        _ = chmod(stateDirectory, 0o700)
        _ = chmod(savedStateDirectory, 0o700)
        let statePath = savedStateDirectory + "/" + DoryMachineSavedStateManifest.stateFileName
        let descriptor = open(statePath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let data = Data("apple-state".utf8)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard write(descriptor, base, raw.count) == raw.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        close(descriptor)
        return stateDirectory
    }

    func testRejectsInvalidDevicePolicyArguments() {
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--network", "bridged",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .invalidNetworkPolicy("bridged")
            )
        }
        XCTAssertThrowsError(try parseDoryVZMacDesktopArguments([
            "run",
            "--machine", "/tmp/test.dorymac",
            "--clipboard", "yes",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVZMacDesktopArgumentError,
                .invalidBoolean("--clipboard", "yes")
            )
        }
    }
}
