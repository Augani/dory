import Darwin
import Foundation
import XCTest
@testable import DoryOperations

final class DockerDataDiskTests: XCTestCase {
    func testDescriptorAdmissionAcceptsPrivateWritableUnallocatedSparseBlank() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/admitted-blank.ext4"
        let descriptor = open(
            path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(fchmod(descriptor, mode_t(0o600)), 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(8 * 1024 * 1024)), 0)

        XCTAssertEqual(
            try DockerDataDisk.admittedState(
                ofFileDescriptor: descriptor,
                description: path,
                minimumBytes: 8 * 1024 * 1024,
                maximumBytes: 8 * 1024 * 1024
            ),
            .sparseBlank
        )
    }

    func testDescriptorAdmissionRejectsAllocatedZeroDataOutsideExt4Superblock() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/allocated-zero.ext4"
        let descriptor = open(
            path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(fchmod(descriptor, mode_t(0o600)), 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(8 * 1024 * 1024)), 0)

        var allocatedZeros = [UInt8](repeating: 0, count: 4_096)
        let written = allocatedZeros.withUnsafeMutableBytes {
            pwrite(descriptor, $0.baseAddress, $0.count, off_t(4_096))
        }
        XCTAssertEqual(written, allocatedZeros.count)
        XCTAssertEqual(fsync(descriptor), 0)
        var status = stat()
        XCTAssertEqual(fstat(descriptor, &status), 0)
        XCTAssertGreaterThan(status.st_blocks, 0, "the fixture must contain an allocated extent")

        XCTAssertThrowsError(
            try DockerDataDisk.admittedState(
                ofFileDescriptor: descriptor,
                description: path,
                minimumBytes: 8 * 1024 * 1024,
                maximumBytes: 8 * 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(error as? DockerDataDiskError, .invalidExistingDisk(path))
        }
    }

    func testDescriptorAdmissionRejectsReadOnlyPublicLinkedUnalignedAndOutOfBoundsFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let readOnlyPath = root + "/read-only.ext4"
        try createSparseFile(at: readOnlyPath, size: 8 * 1024, mode: 0o600)
        let readOnlyDescriptor = open(readOnlyPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(readOnlyDescriptor, 0)
        if readOnlyDescriptor >= 0 {
            defer { close(readOnlyDescriptor) }
            assertDescriptorAdmissionRejectsUnsafe(
                readOnlyDescriptor,
                description: readOnlyPath,
                minimumBytes: 8 * 1024,
                maximumBytes: 8 * 1024
            )
        }

        let publicPath = root + "/public.ext4"
        try createSparseFile(at: publicPath, size: 8 * 1024, mode: 0o644)
        let publicDescriptor = open(publicPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(publicDescriptor, 0)
        if publicDescriptor >= 0 {
            defer { close(publicDescriptor) }
            assertDescriptorAdmissionRejectsUnsafe(
                publicDescriptor,
                description: publicPath,
                minimumBytes: 8 * 1024,
                maximumBytes: 8 * 1024
            )
        }

        let linkedPath = root + "/linked.ext4"
        try createSparseFile(at: linkedPath, size: 8 * 1024, mode: 0o600)
        try FileManager.default.linkItem(
            atPath: linkedPath,
            toPath: root + "/linked-alias.ext4"
        )
        let linkedDescriptor = open(linkedPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(linkedDescriptor, 0)
        if linkedDescriptor >= 0 {
            defer { close(linkedDescriptor) }
            assertDescriptorAdmissionRejectsUnsafe(
                linkedDescriptor,
                description: linkedPath,
                minimumBytes: 8 * 1024,
                maximumBytes: 8 * 1024
            )
        }

        for (name, size, minimum, maximum) in [
            ("unaligned", 4_097, 1, 8 * 1024),
            ("below-minimum", 4 * 1024, 8 * 1024, 16 * 1024),
            ("above-maximum", 16 * 1024, 4 * 1024, 8 * 1024),
        ] {
            let path = root + "/\(name).ext4"
            try createSparseFile(at: path, size: Int64(size), mode: 0o600)
            let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { continue }
            assertDescriptorAdmissionRejectsUnsafe(
                descriptor,
                description: path,
                minimumBytes: Int64(minimum),
                maximumBytes: Int64(maximum)
            )
            close(descriptor)
        }
    }

    func testCreatesSparseBlankDiskOnFirstLaunch() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/state/docker-data.ext4"

        XCTAssertEqual(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 8 * 1024 * 1024
            ),
            .createdBlank
        )
        let size = try FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 8 * 1024 * 1024)
        XCTAssertEqual(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 8 * 1024 * 1024
            ),
            .alreadyPresent
        )
    }

    func testRefusesAllocatedExistingNonExt4DiskInsteadOfFormattingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        let original = Data(repeating: 0xA5, count: 4096)
        try writePrivate(original, to: destination)

        XCTAssertThrowsError(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 8 * 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(
                error as? DockerDataDiskError,
                .invalidExistingDisk(destination)
            )
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), original)
    }

    func testAllowsExistingUnallocatedSparseBlankToReachFirstBootFormatting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        FileManager.default.createFile(atPath: destination, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        let descriptor = open(destination, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024), 0)
        close(descriptor)

        XCTAssertEqual(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 16 * 1024 * 1024
            ),
            .alreadyPresent
        )
        let size = try FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 16 * 1024 * 1024)
    }

    func testRefusesExistingExt4MagicWithInvalidGeometryWithoutGrowingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        let invalid = ext4Fixture(fileBytes: 4096, declaredBlocks: 0, logBlockSize: 0)
        try writePrivate(invalid, to: destination)

        XCTAssertThrowsError(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 16 * 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(error as? DockerDataDiskError, .invalidExistingDisk(destination))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), invalid)
    }

    func testRejectsExistingSparseDiskTruncatedBelowExt4DeclaredLength() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try writePrivate(
            ext4Fixture(fileBytes: 4 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1),
            to: destination
        )

        XCTAssertEqual(try DockerDataDisk.expectedExt4ImageBytes(at: destination), 8 * 1024 * 1024)
        XCTAssertThrowsError(
            try DockerDataDisk.prepare(destination: destination)
        ) { error in
            XCTAssertEqual(
                error as? DockerDataDiskError,
                .truncatedDisk(
                    path: destination,
                    actualBytes: 4 * 1024 * 1024,
                    expectedBytes: 8 * 1024 * 1024
                )
            )
        }
    }

    func testAcceptsSparseDiskAtExt4DeclaredLength() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try writePrivate(
            ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1),
            to: destination
        )

        XCTAssertEqual(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 8 * 1024 * 1024
            ),
            .alreadyPresent
        )
    }

    func testGrowsExistingValidDiskSparselyToRequestedLogicalCapacity() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try writePrivate(
            ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1),
            to: destination
        )

        XCTAssertEqual(
            try DockerDataDisk.prepare(
                destination: destination,
                blankSize: 32 * 1024 * 1024
            ),
            .alreadyPresent
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: destination)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 32 * 1024 * 1024)
        XCTAssertEqual(try DockerDataDisk.expectedExt4ImageBytes(at: destination), 8 * 1024 * 1024)
    }

    func testProductionBlankDiskUsesLargeSparseLogicalCapacity() {
        XCTAssertEqual(DockerDataDisk.blankDiskBytes, 128 * 1024 * 1024 * 1024)
        XCTAssertEqual(DockerDataDisk.minimumCapacityGiB, 128)
        XCTAssertEqual(DockerDataDisk.maximumCapacityGiB, 2_048)
    }

    func testGuestFilesystemUUIDReaderUsesBusyBoxCompatibleDefaultBlkidOutput() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bin = root + "/bin"
        try FileManager.default.createDirectory(
            atPath: bin,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fakeBlkid = bin + "/blkid"
        try Data(#"""
        #!/bin/sh
        if [ "$#" -ne 1 ] || [ "$1" != "/dev/vdb" ]; then
          echo "unsupported blkid arguments" >&2
          exit 64
        fi
        if [ "$DORY_FAKE_BLKID_STATUS" -ne 0 ]; then
          exit "$DORY_FAKE_BLKID_STATUS"
        fi
        printf '%s\n' "$DORY_FAKE_BLKID_OUTPUT"
        """#.utf8).write(to: URL(fileURLWithPath: fakeBlkid), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeBlkid
        )

        func readUUID(
            from output: String,
            blkidStatus: Int32 = 0
        ) throws -> (status: Int32, stdout: String, stderr: String) {
            let standardOutput = Pipe()
            let standardError = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                """
                set -eu
                \(DockerDataDiskLaunchContract.guestFilesystemUUIDShellFunction)
                \(DockerDataDiskLaunchContract.guestFilesystemUUIDShellCommand)
                """,
            ]
            process.environment = [
                "DORY_FAKE_BLKID_OUTPUT": output,
                "DORY_FAKE_BLKID_STATUS": String(blkidStatus),
                "LC_ALL": "C",
                "PATH": "\(bin):/usr/bin:/bin",
            ]
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(
                    decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ),
                String(
                    decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
            )
        }

        let expected = "7bb0bc1b-d4be-456f-afae-6acd18c6e2fc"
        let busyBox = try readUUID(
            from: #"/dev/vdb: LABEL="DORY" UUID="7BB0BC1B-D4BE-456F-AFAE-6ACD18C6E2FC" TYPE="ext4" PARTUUID="ignored""#
        )
        XCTAssertEqual(busyBox.status, 0, busyBox.stderr)
        XCTAssertEqual(busyBox.stdout, expected + "\n")
        XCTAssertEqual(busyBox.stderr, "")

        let invalidRecords = [
            #"/dev/vdb: TYPE="ext4" PARTUUID="7BB0BC1B-D4BE-456F-AFAE-6ACD18C6E2FC""#,
            #"/dev/vdb: UUID="not-a-uuid" TYPE="ext4""#,
            #"/dev/vdb: UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2fc" UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2fc" TYPE="ext4""#,
            #"/dev/vdb: UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2fc TYPE="ext4""#,
            #"/dev/vdb: UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2f" TYPE="ext4""#,
            #"/dev/vdb: UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2fg" TYPE="ext4""#,
            """
            /dev/vdb: UUID="7bb0bc1b-d4be-456f-afae-6acd18c6e2fc" TYPE="ext4"
            /dev/vdc: UUID="11111111-2222-4333-8444-555555555555" TYPE="ext4"
            """,
            "",
        ]
        for record in invalidRecords {
            let invalid = try readUUID(from: record)
            XCTAssertEqual(invalid.status, 1, "\(record)\n\(invalid.stderr)")
            XCTAssertEqual(invalid.stdout, "", record)
            XCTAssertEqual(invalid.stderr, "", record)
        }

        let failedBlkid = try readUUID(from: "", blkidStatus: 7)
        XCTAssertEqual(failedBlkid.status, 1, failedBlkid.stderr)
        XCTAssertEqual(failedBlkid.stdout, "")
        XCTAssertEqual(failedBlkid.stderr, "")
    }

    func testUsageReportsDefaultWithoutCreatingDiskAndExplicitGrowthStaysSparse() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/state/docker-data.ext4"

        XCTAssertEqual(
            try DockerDataDisk.usage(at: destination),
            DockerDataDiskUsage(
                initialized: false,
                logicalBytes: DockerDataDisk.blankDiskBytes,
                allocatedBytes: 0,
                capacityGiB: 128,
                minimumCapacityGiB: 128,
                maximumCapacityGiB: 2_048
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))

        let grown = try DockerDataDisk.grow(destination: destination, capacityGiB: 256)
        XCTAssertTrue(grown.initialized)
        XCTAssertEqual(grown.logicalBytes, 256 * DockerDataDisk.bytesPerGiB)
        XCTAssertEqual(grown.capacityGiB, 256)
        XCTAssertLessThan(grown.allocatedBytes, grown.logicalBytes)
    }

    func testExplicitGrowthRejectsShrinkAndOutOfBoundsCapacityWithoutMutation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        _ = try DockerDataDisk.grow(destination: destination, capacityGiB: 256)

        XCTAssertThrowsError(try DockerDataDisk.grow(destination: destination, capacityGiB: 128)) {
            guard case .shrinkUnsupported = $0 as? DockerDataDiskError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(try DockerDataDisk.grow(destination: destination, capacityGiB: 4_096)) {
            XCTAssertEqual(
                $0 as? DockerDataDiskError,
                .invalidCapacityGiB(requested: 4_096, minimum: 128, maximum: 2_048)
            )
        }
        XCTAssertEqual(try DockerDataDisk.usage(at: destination).capacityGiB, 256)
    }

    func testRejectsSymlinkHardLinkAndPublicDiskFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = root + "/target"
        try writePrivate(Data(), to: target)

        let symlink = root + "/symlink.ext4"
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: target)
        XCTAssertThrowsError(try DockerDataDisk.usage(at: symlink)) {
            XCTAssertEqual($0 as? DockerDataDiskError, .unsafeExistingDisk(symlink))
        }

        let hardLink = root + "/hardlink.ext4"
        try FileManager.default.linkItem(atPath: target, toPath: hardLink)
        XCTAssertThrowsError(try DockerDataDisk.usage(at: hardLink)) {
            XCTAssertEqual($0 as? DockerDataDiskError, .unsafeExistingDisk(hardLink))
        }

        try FileManager.default.removeItem(atPath: hardLink)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target)
        XCTAssertThrowsError(try DockerDataDisk.usage(at: target)) {
            XCTAssertEqual($0 as? DockerDataDiskError, .unsafeExistingDisk(target))
        }
    }

    func testUsageRejectsAllocatedNonExt4AndTruncatedExt4Images() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let invalid = root + "/invalid.ext4"
        try writePrivate(Data(repeating: 0xA5, count: 4096), to: invalid)
        XCTAssertThrowsError(try DockerDataDisk.usage(at: invalid)) {
            XCTAssertEqual($0 as? DockerDataDiskError, .invalidExistingDisk(invalid))
        }

        let truncated = root + "/truncated.ext4"
        try writePrivate(
            ext4Fixture(fileBytes: 4 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1),
            to: truncated
        )
        XCTAssertThrowsError(try DockerDataDisk.usage(at: truncated)) {
            XCTAssertEqual(
                $0 as? DockerDataDiskError,
                .truncatedDisk(
                    path: truncated,
                    actualBytes: 4 * 1024 * 1024,
                    expectedBytes: 8 * 1024 * 1024
                )
            )
        }
    }

    private func ext4Fixture(fileBytes: Int, declaredBlocks: UInt32, logBlockSize: UInt32) -> Data {
        var bytes = Data(repeating: 0, count: fileBytes)
        bytes[1024 + 0x38] = 0x53
        bytes[1024 + 0x39] = 0xEF
        writeLittleEndian(declaredBlocks, into: &bytes, at: 1024 + 0x04)
        writeLittleEndian(logBlockSize, into: &bytes, at: 1024 + 0x18)
        return bytes
    }

    private func writeLittleEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func writePrivate(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func createSparseFile(at path: String, size: Int64, mode: mode_t) throws {
        let descriptor = open(
            path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0,
              ftruncate(descriptor, off_t(size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func assertDescriptorAdmissionRejectsUnsafe(
        _ descriptor: Int32,
        description: String,
        minimumBytes: Int64,
        maximumBytes: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DockerDataDisk.admittedState(
                ofFileDescriptor: descriptor,
                description: description,
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DockerDataDiskError,
                .unsafeExistingDisk(description),
                file: file,
                line: line
            )
        }
    }

    private func temporaryRoot() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-disk-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
