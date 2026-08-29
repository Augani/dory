@testable import DorydKit
import Darwin
import Foundation
import XCTest

final class InheritedDescriptorSpawnerTests: XCTestCase {
    func testMapsBorrowedDescriptorToDeterministicChildSlot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let sourcePath = directory + "/authorized-source"
        let outputPath = directory + "/output"
        try Data("daemon-authorized\n".utf8).write(to: URL(fileURLWithPath: sourcePath))

        let source = open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(source, 0)
        defer { close(source) }

        let child = try InheritedDescriptorSpawner.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", "cat <&19 > \"$1\"", "dory-fd-test", outputPath],
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: source, childDescriptor: 19),
            ]
        )

        XCTAssertEqual(try waitForSuccessfulExit(child), 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outputPath)), Data("daemon-authorized\n".utf8))
        XCTAssertGreaterThanOrEqual(fcntl(source, F_GETFD), 0, "spawn must not consume the caller's descriptor")
    }

    func testClosesUnmappedParentDescriptorsEvenWithoutCloseOnExec() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let mappedPath = directory + "/mapped"
        let secretPath = directory + "/secret"
        let outputPath = directory + "/result"
        try Data("mapped".utf8).write(to: URL(fileURLWithPath: mappedPath))
        try Data("secret".utf8).write(to: URL(fileURLWithPath: secretPath))

        let mapped = open(mappedPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(mapped, 0)
        defer { close(mapped) }

        let originalSecret = open(secretPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(originalSecret, 0)
        defer { close(originalSecret) }
        let secret = fcntl(originalSecret, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(secret, 200)
        defer { close(secret) }
        XCTAssertEqual(fcntl(secret, F_SETFD, 0), 0, "test requires an inheritable, unmapped descriptor")

        let script = "if test -e /dev/fd/$1; then printf leaked; else printf closed; fi > \"$2\"; cat <&19 >/dev/null"
        let child = try InheritedDescriptorSpawner.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "dory-fd-test", "\(secret)", outputPath],
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: mapped, childDescriptor: 19),
            ]
        )

        XCTAssertEqual(try waitForSuccessfulExit(child), 0)
        XCTAssertEqual(try String(contentsOfFile: outputPath, encoding: .utf8), "closed")
    }

    func testStartSuspendedPreventsUserCodeAndDescriptorReadsUntilContinued() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let sourcePath = directory + "/authorized-source"
        let outputPath = directory + "/output"
        try Data("unread-before-admission\n".utf8).write(
            to: URL(fileURLWithPath: sourcePath)
        )

        let source = open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(source, 0)
        defer { close(source) }

        let child = try InheritedDescriptorSpawner.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", "cat <&19 > \"$1\"", "dory-suspended-fd-test", outputPath],
            startSuspended: true,
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: source, childDescriptor: 19),
            ]
        )
        var admitted = false
        defer {
            if !admitted {
                _ = kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
            }
        }

        usleep(50_000)
        XCTAssertEqual(kill(child, 0), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputPath),
            "a suspended child must not execute user code or consume inherited authority"
        )

        XCTAssertEqual(kill(child, SIGCONT), 0)
        admitted = true
        XCTAssertEqual(try waitForSuccessfulExit(child), 0)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: outputPath)),
            Data("unread-before-admission\n".utf8)
        )
    }

    func testRejectsDuplicateChildSlotsBeforeSpawning() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        XCTAssertThrowsError(try InheritedDescriptorSpawner.spawn(
            executablePath: "/usr/bin/true",
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: descriptor, childDescriptor: 9),
                InheritedDescriptorMapping(parentDescriptor: descriptor, childDescriptor: 9),
            ]
        )) { error in
            XCTAssertEqual(error as? InheritedDescriptorSpawnError, .duplicateChildDescriptor(9))
        }
    }

    func testRejectsStdioAsAResourceSlot() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        XCTAssertThrowsError(try InheritedDescriptorSpawner.spawn(
            executablePath: "/usr/bin/true",
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: descriptor, childDescriptor: STDIN_FILENO),
            ]
        )) { error in
            XCTAssertEqual(error as? InheritedDescriptorSpawnError, .invalidChildDescriptor(STDIN_FILENO))
        }
    }

    func testRejectsUnboundedResourceSlot() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        let slot = InheritedDescriptorSpawner.maximumChildDescriptor + 1
        XCTAssertThrowsError(try InheritedDescriptorSpawner.spawn(
            executablePath: "/usr/bin/true",
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: descriptor, childDescriptor: slot),
            ]
        )) { error in
            XCTAssertEqual(error as? InheritedDescriptorSpawnError, .invalidChildDescriptor(slot))
        }
    }

    func testRejectsClosedParentDescriptor() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(close(descriptor), 0)

        XCTAssertThrowsError(try InheritedDescriptorSpawner.spawn(
            executablePath: "/usr/bin/true",
            descriptorMappings: [
                InheritedDescriptorMapping(parentDescriptor: descriptor, childDescriptor: 9),
            ]
        )) { error in
            XCTAssertEqual(error as? InheritedDescriptorSpawnError, .invalidParentDescriptor(descriptor))
        }
    }

    private func makeTemporaryDirectory() throws -> String {
        let path = "/tmp/dory-descriptor-spawn-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    private func waitForSuccessfulExit(_ pid: pid_t) throws -> Int32 {
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }
}
