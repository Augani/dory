import Darwin
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

final class DoryMachineStateBrokerTests: XCTestCase {
    func testMachineIDValidationUsesBoundedDaemonIdentifierGrammar() throws {
        let fixture = try makeFixture("machine-id")
        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )

        for invalid in [
            "",
            ".",
            "..",
            "-machine",
            "_machine",
            ".machine",
            "machine/child",
            "machine child",
            "machine+child",
            "m\0achine",
            "máchine",
            String(repeating: "m", count: 64),
        ] {
            XCTAssertThrowsError(
                try broker.acquireMachineDirectoryLease(machineID: invalid)
            ) { error in
                XCTAssertEqual(
                    error as? DoryMachineStateBrokerError,
                    .invalidMachineID(invalid)
                )
            }
        }

        let valid = "M" + String(repeating: "a", count: 58) + "_.-1"
        XCTAssertEqual(valid.utf8.count, 63)
        try makePrivateDirectory(fixture.root + "/" + valid)
        let lease = try broker.acquireMachineDirectoryLease(machineID: valid)
        XCTAssertEqual(lease.machineID, valid)
        XCTAssertEqual(lease.health, .healthy)
        XCTAssertEqual(try lease.revalidate(), lease.generation)
    }

    func testAcquisitionRejectsChildSymlinkAndNonPrivateMode() throws {
        let fixture = try makeFixture("unsafe-child")
        let target = fixture.root + "/target"
        try makePrivateDirectory(target)
        XCTAssertEqual(symlink(target, fixture.root + "/linked"), 0)

        let loose = fixture.root + "/loose"
        try makePrivateDirectory(loose)
        XCTAssertEqual(chmod(loose, mode_t(0o755)), 0)

        let trustedRoot = try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: fixture.root
        )
        let broker = DoryMachineStateBroker(trustedRoot: trustedRoot)

        XCTAssertThrowsError(
            try broker.acquireMachineDirectoryLease(machineID: "linked")
        ) { error in
            guard case let DoryMachineStateBrokerError.trustedRoot(rootError) = error,
                  case let .cannotOpenChild(component, _) = rootError else {
                return XCTFail("expected a no-follow child-open failure, got \(error)")
            }
            XCTAssertEqual(component, "linked")
        }

        XCTAssertThrowsError(
            try broker.acquireMachineDirectoryLease(machineID: "loose")
        ) { error in
            XCTAssertEqual(
                error as? DoryMachineStateBrokerError,
                .trustedRoot(.unsafeChildDirectory(component: "loose"))
            )
        }
        XCTAssertEqual(broker.rootHealth, .healthy)
    }

    func testMachineDirectoryReplacementQuarantinesLeasePermanently() throws {
        let fixture = try makeFixture("child-replacement")
        let machinePath = fixture.root + "/machine"
        try makePrivateDirectory(machinePath)
        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )
        let lease = try broker.acquireMachineDirectoryLease(machineID: "machine")

        let displaced = fixture.root + "/displaced-machine"
        try FileManager.default.moveItem(atPath: machinePath, toPath: displaced)
        try makePrivateDirectory(machinePath)

        assertLeaseQuarantined(lease, reason: .currentEntryIdentityChanged)
        XCTAssertEqual(broker.rootHealth, .healthy)

        try FileManager.default.removeItem(atPath: machinePath)
        try FileManager.default.moveItem(atPath: displaced, toPath: machinePath)
        assertLeaseQuarantined(lease, reason: .currentEntryIdentityChanged)
    }

    func testMachineDirectoryRenameAwayQuarantinesAsUnavailable() throws {
        let fixture = try makeFixture("child-rename")
        let machinePath = fixture.root + "/machine"
        try makePrivateDirectory(machinePath)
        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )
        let lease = try broker.acquireMachineDirectoryLease(machineID: "machine")

        let displaced = fixture.root + "/displaced-machine"
        try FileManager.default.moveItem(atPath: machinePath, toPath: displaced)

        assertLeaseQuarantined(
            lease,
            reason: .currentEntryUnavailable(errno: ENOENT)
        )
    }

    func testMachineDirectoryModeDriftQuarantinesPermanently() throws {
        let fixture = try makeFixture("child-mode")
        let machinePath = fixture.root + "/machine"
        try makePrivateDirectory(machinePath)
        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )
        let lease = try broker.acquireMachineDirectoryLease(machineID: "machine")

        XCTAssertEqual(chmod(machinePath, mode_t(0o755)), 0)
        assertLeaseQuarantined(lease, reason: .currentEntryMetadataChanged)

        XCTAssertEqual(chmod(machinePath, mode_t(0o700)), 0)
        assertLeaseQuarantined(lease, reason: .currentEntryMetadataChanged)
    }

    func testRootReplacementPropagatesRootQuarantineIntoLease() throws {
        let fixture = try makeFixture("root-replacement")
        try makePrivateDirectory(fixture.root + "/machine")
        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )
        let lease = try broker.acquireMachineDirectoryLease(machineID: "machine")

        let displaced = fixture.container + "/displaced-root"
        try FileManager.default.moveItem(atPath: fixture.root, toPath: displaced)
        try makePrivateDirectory(fixture.root)
        try makePrivateDirectory(fixture.root + "/machine")

        let expected = DoryMachineDirectoryLeaseQuarantineReason.trustedRoot(
            .rootIdentityChanged
        )
        assertLeaseQuarantined(lease, reason: expected)
        XCTAssertEqual(broker.rootHealth, .quarantined(.rootIdentityChanged))

        try FileManager.default.removeItem(atPath: fixture.root)
        try FileManager.default.moveItem(atPath: displaced, toPath: fixture.root)
        assertLeaseQuarantined(lease, reason: expected)
    }

    func testBorrowPinsOldGenerationButNextRevalidationRejectsReplacement() throws {
        let fixture = try makeFixture("borrowed-generation")
        let machinePath = fixture.root + "/machine"
        try makePrivateDirectory(machinePath)
        let oldBytes = Data("old-generation".utf8)
        try writePrivateFile(oldBytes, path: machinePath + "/sentinel")

        let broker = try DoryMachineStateBroker(
            canonicalStateRootPath: fixture.root
        )
        let lease = try broker.acquireMachineDirectoryLease(machineID: "machine")
        let displaced = fixture.root + "/displaced-machine"

        let observed: Data = try lease.withBorrowedDescriptor { machineDescriptor in
            // The namespace can move after admission starts, but every relative open in this
            // closure remains anchored to the already revalidated, pinned generation.
            try FileManager.default.moveItem(atPath: machinePath, toPath: displaced)
            try makePrivateDirectory(machinePath)
            try writePrivateFile(
                Data("replacement-generation".utf8),
                path: machinePath + "/sentinel"
            )
            return try readFile(named: "sentinel", from: machineDescriptor)
        }

        XCTAssertEqual(observed, oldBytes)
        assertLeaseQuarantined(lease, reason: .currentEntryIdentityChanged)
    }

    private func assertLeaseQuarantined(
        _ lease: DoryMachineDirectoryLease,
        reason expected: DoryMachineDirectoryLeaseQuarantineReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try lease.revalidate(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? DoryMachineStateBrokerError,
                .leaseQuarantined(expected),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            lease.health,
            .quarantined(expected),
            file: file,
            line: line
        )
    }

    private func makeFixture(
        _ label: String
    ) throws -> (container: String, root: String) {
        let container = "/private/tmp/dory-machine-state-broker-\(label)-\(getpid())-\(UUID().uuidString)"
        try makePrivateDirectory(container)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: container)
        }
        let root = container + "/state"
        try makePrivateDirectory(root)
        return (container, root)
    }

    private func makePrivateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writePrivateFile(_ data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    private func readFile(named name: String, from directoryDescriptor: Int32) throws -> Data {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= 1_048_576 else {
            throw POSIXError(.EIO)
        }
        var result = Data(count: Int(info.st_size))
        let count = result.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count == result.count else { throw POSIXError(.EIO) }
        return result
    }
}
