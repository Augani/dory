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
    }

    func testRejectsDirectoriesSymlinksAndDuplicateNames() throws {
        let fixture = try StagerFixture(tag: "shapes")
        defer { fixture.cleanup() }
        let directory = fixture.source.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [directory],
            stagingDirectory: fixture.staging
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferStagingError,
                .unsupportedFile("folder")
            )
        }

        let regular = fixture.source.appendingPathComponent("regular")
        let symlinkURL = fixture.source.appendingPathComponent("link")
        try Data("x".utf8).write(to: regular)
        XCTAssertEqual(Darwin.symlink(regular.path, symlinkURL.path), 0)
        XCTAssertThrowsError(try DoryMachineFileTransferStager.stage(
            fileURLs: [symlinkURL],
            stagingDirectory: fixture.staging
        ))

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

    private func permissions(_ path: String) throws -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw DoryMachineFileTransferStagingError.io("test stat", errno)
        }
        return info.st_mode
    }
}

private struct StagerFixture {
    var root: URL
    var source: URL
    var staging: URL

    init(tag: String) throws {
        root = URL(fileURLWithPath: "/tmp/dory-transfer-stager-\(tag)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))")
        source = root.appendingPathComponent("source", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
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
