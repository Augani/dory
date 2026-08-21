import Darwin
@testable import DoryOperations
import Foundation
import XCTest

final class DoryMachineFileTransferStagerTests: XCTestCase {
    func testStagesSelectedFilesIntoPrivateFlatHandoff() throws {
        let fixture = try StagerFixture(tag: "success")
        defer { fixture.cleanup() }
        let first = fixture.source.appendingPathComponent("hello.txt")
        let second = fixture.source.appendingPathComponent("empty.bin")
        try Data("hello".utf8).write(to: first)
        try Data().write(to: second)

        let staged = try DoryMachineFileTransferStager.stage(
            fileURLs: [first, second],
            stagingDirectory: fixture.staging
        )
        defer { try? staged.remove() }

        XCTAssertEqual(staged.fileCount, 2)
        XCTAssertEqual(staged.directoryCount, 0)
        XCTAssertEqual(staged.byteCount, 5)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staged.rootPath + "/hello.txt")),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staged.rootPath + "/empty.bin")),
            Data()
        )
        XCTAssertEqual(try permissions(staged.rootPath) & 0o777, 0o700)
        XCTAssertEqual(try permissions(staged.rootPath + "/hello.txt") & 0o777, 0o600)
        try staged.remove()
        try staged.remove()
    }

    func testStagesNestedFoldersIncludingEmptyDirectories() throws {
        let fixture = try StagerFixture(tag: "shapes")
        defer { fixture.cleanup() }
        let directory = fixture.source.appendingPathComponent("folder", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let empty = directory.appendingPathComponent("empty/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("hello.txt"))
        let topLevel = fixture.source.appendingPathComponent("top-level.txt")
        try Data("top".utf8).write(to: topLevel)

        let staged = try DoryMachineFileTransferStager.stage(
            fileURLs: [topLevel, directory],
            stagingDirectory: fixture.staging
        )
        defer { try? staged.remove() }

        XCTAssertEqual(staged.fileCount, 2)
        XCTAssertEqual(staged.directoryCount, 4)
        XCTAssertEqual(staged.byteCount, 9)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staged.rootPath + "/folder/nested/hello.txt")),
            Data("nested".utf8)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.rootPath + "/folder/empty/deep",
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try permissions(staged.rootPath + "/folder") & 0o777, 0o700)
        XCTAssertEqual(
            try permissions(staged.rootPath + "/folder/nested/hello.txt") & 0o777,
            0o600
        )
    }

    func testRejectsSymlinksSpecialFilesAndDuplicateTopLevelNames() throws {
        let fixture = try StagerFixture(tag: "rejections")
        defer { fixture.cleanup() }

        let regular = fixture.source.appendingPathComponent("regular")
        let symlinkURL = fixture.source.appendingPathComponent("link")
        try Data("x".utf8).write(to: regular)
        XCTAssertEqual(Darwin.symlink(regular.path, symlinkURL.path), 0)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [symlinkURL],
            stagingDirectory: fixture.staging
        ))

        let directory = fixture.source.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let nestedLink = directory.appendingPathComponent("nested-link")
        XCTAssertEqual(Darwin.symlink(regular.path, nestedLink.path), 0)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [directory],
            stagingDirectory: fixture.staging
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .io("source open", ELOOP)
            )
        }

        let fifo = fixture.source.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [fifo],
            stagingDirectory: fixture.staging
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .unsupportedFile("fifo")
            )
        }

        let otherRoot = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let duplicate = otherRoot.appendingPathComponent("regular")
        try Data("y".utf8).write(to: duplicate)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [regular, duplicate],
            stagingDirectory: fixture.staging
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .duplicateFileName("regular")
            )
        }
    }

    func testRejectsPublicExistingStagingDirectory() throws {
        let fixture = try StagerFixture(tag: "public")
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("file")
        try Data("x".utf8).write(to: source)
        XCTAssertEqual(chmod(fixture.staging.path, 0o755), 0)

        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [source],
            stagingDirectory: fixture.staging
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .unsafeStagingDirectory
            )
        }
    }

    func testDaemonExportReservationUsesOnlyThePrivateManagedNamespace() throws {
        let operationID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = try DoryMachineFileTransferStager.reserveDaemonExportRoot(
            operationID: operationID
        )
        defer { try? DoryMachineFileTransferStager.removeManagedStagingRoot(root) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
        XCTAssertTrue(root.hasSuffix("/export-\(getpid())-\(operationID)"))
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: root + "/mode-zero",
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("private".utf8).write(
            to: URL(fileURLWithPath: root + "/mode-zero/file")
        )
        XCTAssertEqual(chmod(root + "/mode-zero", 0o000), 0)
        XCTAssertTrue(DoryMachineFileTransferStager.isDaemonExportRoot(root))
        XCTAssertFalse(DoryMachineFileTransferStager.isDaemonExportRoot(fixtureLikePath(operationID)))

        try DoryMachineFileTransferStager.removeManagedStagingRoot(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    func testMaterializesVerifiedGuestExportWithoutOverwritingDestination() throws {
        let fixture = try StagerFixture(tag: "guest-export-success")
        defer { fixture.cleanup() }
        let exportID = operationID()
        let root = try DoryMachineFileTransferStager.reserveDaemonExportRoot(
            operationID: exportID
        )
        defer { try? DoryMachineFileTransferStager.removeManagedStagingRoot(root) }
        try FileManager.default.createDirectory(
            atPath: root + "/folder",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("guest-export".utf8).write(
            to: URL(fileURLWithPath: root + "/folder/file.txt")
        )
        XCTAssertEqual(chmod(root + "/folder/file.txt", 0o000), 0)
        XCTAssertEqual(chmod(root + "/folder", 0o000), 0)

        let materialized = try DoryMachineFileTransferStager.materializeGuestExport(
            privateStagingRoot: root,
            exportID: exportID,
            expectedFileCount: 1,
            expectedDirectoryCount: 1,
            expectedByteCount: 12,
            destinationDirectory: fixture.destination,
            destinationName: "Documents"
        )

        XCTAssertEqual(materialized.fileCount, 1)
        XCTAssertEqual(materialized.directoryCount, 1)
        XCTAssertEqual(materialized.byteCount, 12)
        XCTAssertEqual(materialized.rootURL, fixture.destination.appendingPathComponent(
            "Documents",
            isDirectory: true
        ))
        XCTAssertEqual(
            try Data(contentsOf: materialized.rootURL.appendingPathComponent("folder/file.txt")),
            Data("guest-export".utf8)
        )
        XCTAssertEqual(try permissions(materialized.rootURL.path) & 0o777, 0o700)
        XCTAssertEqual(try permissions(materialized.rootURL.path + "/folder") & 0o777, 0o700)
        XCTAssertEqual(
            try permissions(materialized.rootURL.path + "/folder/file.txt") & 0o777,
            0o600
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root))
        XCTAssertThrowsError(try DoryMachineFileTransferStager.materializeGuestExport(
            privateStagingRoot: root,
            exportID: exportID,
            expectedFileCount: 1,
            expectedDirectoryCount: 1,
            expectedByteCount: 12,
            destinationDirectory: fixture.destination,
            destinationName: "Documents"
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .destinationExists("Documents")
            )
        }
        XCTAssertTrue(try hiddenExportTemporaryNames(in: fixture.destination).isEmpty)
    }

    func testMaterializationRejectsMismatchedEvidenceAndSymlinksWithoutPublishing() throws {
        let fixture = try StagerFixture(tag: "guest-export-rejection")
        defer { fixture.cleanup() }
        let exportID = operationID()
        let root = try DoryMachineFileTransferStager.reserveDaemonExportRoot(
            operationID: exportID
        )
        defer { try? DoryMachineFileTransferStager.removeManagedStagingRoot(root) }
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let source = root + "/file"
        try Data("verified".utf8).write(to: URL(fileURLWithPath: source))

        XCTAssertThrowsError(try DoryMachineFileTransferStager.materializeGuestExport(
            privateStagingRoot: root,
            exportID: exportID,
            expectedFileCount: 1,
            expectedDirectoryCount: 0,
            expectedByteCount: 9,
            destinationDirectory: fixture.destination,
            destinationName: "Mismatch"
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .exportEvidenceMismatch
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("Mismatch").path
        ))
        XCTAssertTrue(try hiddenExportTemporaryNames(in: fixture.destination).isEmpty)

        XCTAssertEqual(unlink(source), 0)
        XCTAssertEqual(symlink("/tmp", source), 0)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.materializeGuestExport(
            privateStagingRoot: root,
            exportID: exportID,
            expectedFileCount: 1,
            expectedDirectoryCount: 0,
            expectedByteCount: 8,
            destinationDirectory: fixture.destination,
            destinationName: "Symlink"
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("Symlink").path
        ))
        XCTAssertTrue(try hiddenExportTemporaryNames(in: fixture.destination).isEmpty)

        XCTAssertThrowsError(try DoryMachineFileTransferStager.materializeGuestExport(
            privateStagingRoot: fixture.root.appendingPathComponent("arbitrary").path,
            exportID: exportID,
            expectedFileCount: 0,
            expectedDirectoryCount: 0,
            expectedByteCount: 0,
            destinationDirectory: fixture.destination,
            destinationName: "Arbitrary"
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .exportEvidenceMismatch
            )
        }
    }

    private func permissions(_ path: String) throws -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw DoryMachineFileTransferStagingError.io("test stat", errno)
        }
        return info.st_mode
    }

    private func fixtureLikePath(_ operationID: String) -> String {
        "/tmp/export-\(getpid())-\(operationID)"
    }

    private func operationID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func hiddenExportTemporaryNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix(".dory-export-")
        }
    }
}

private struct StagerFixture {
    var root: URL
    var source: URL
    var staging: URL
    var destination: URL

    init(tag: String) throws {
        root = URL(fileURLWithPath: "/tmp/dory-transfer-stager-\(tag)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))")
        source = root.appendingPathComponent("source", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
