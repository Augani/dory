import Darwin
import Foundation
import XCTest
@testable import DoryCore

final class DockerDataDiskTests: XCTestCase {
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
        try original.write(to: URL(fileURLWithPath: destination))

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
        try invalid.write(to: URL(fileURLWithPath: destination))

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
        try ext4Fixture(fileBytes: 4 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

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
        try ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

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
        try ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

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

    private func temporaryRoot() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-disk-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
