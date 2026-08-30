import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacUSBMassStorageTests: XCTestCase {
    func testNoUSBPreservesThePreUSBConfigurationFingerprint() throws {
        let hasXHCI = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(
            try DoryVZMacConfigurationBuilder.fingerprint(),
            hasXHCI
                ? "c2a0604de611f227075125e822434283bbe418ff7cc663421dde2cafc325bd1f"
                : "2f3024611af8d685e0de857cd3f92b143f7f894a1d246c80ff01f733ffd14ee9"
        )
    }

    func testAcceptsDirectNonEmptyImageAndBindsFingerprint() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("removable.img")
        try Data([0x44, 0x4f, 0x52, 0x59]).write(to: image)

        let readOnly = try DoryVZMacUSBMassStorage(url: image, readOnly: true)
        let readWrite = try DoryVZMacUSBMassStorage(url: image, readOnly: false)

        XCTAssertEqual(readOnly.byteCount, 4)
        XCTAssertEqual(readOnly.url, image.standardizedFileURL)
        XCTAssertNotEqual(
            try DoryVZMacConfigurationBuilder.fingerprint(),
            try DoryVZMacConfigurationBuilder.fingerprint(usbMassStorage: readOnly)
        )
        XCTAssertNotEqual(
            try DoryVZMacConfigurationBuilder.fingerprint(usbMassStorage: readOnly),
            try DoryVZMacConfigurationBuilder.fingerprint(usbMassStorage: readWrite)
        )
    }

    func testRejectsEmptyImageAndDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))

        XCTAssertThrowsError(try DoryVZMacUSBMassStorage(url: empty, readOnly: true))
        XCTAssertThrowsError(try DoryVZMacUSBMassStorage(url: directory, readOnly: true))
    }

    func testRejectsSymbolicLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("storage.img")
        let link = directory.appendingPathComponent("storage-link.img")
        try Data([0x01]).write(to: image)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)

        XCTAssertThrowsError(try DoryVZMacUSBMassStorage(url: link, readOnly: true))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoryVZMacUSBMassStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}
