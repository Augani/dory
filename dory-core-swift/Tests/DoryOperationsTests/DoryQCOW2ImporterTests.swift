import Foundation
import XCTest
@testable import DoryOperations

final class DoryQCOW2ImporterTests: XCTestCase {
    func testConvertsAllocatedAndSparseClustersIntoRawImage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.qcow2")
        let destination = root.appendingPathComponent("destination.raw")
        try writeFixture(to: source)

        let receipt = try DoryQCOW2Importer.convert(source: source, destination: destination)

        XCTAssertEqual(receipt.virtualDiskBytes, 1_024)
        XCTAssertEqual(receipt.copiedDataBytes, 512)
        let raw = try Data(contentsOf: destination)
        XCTAssertEqual(raw.count, 1_024)
        XCTAssertEqual(raw.prefix(512), Data(repeating: 0xab, count: 512))
        XCTAssertEqual(raw.suffix(512), Data(repeating: 0, count: 512))
    }

    func testRejectsBackingCompressedAndOutOfRangeTablesWithoutPublishingOutput() throws {
        for mutation in [Mutation.backing, .compressed, .outOfRangeL1] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.qcow2")
            let destination = root.appendingPathComponent("destination.raw")
            try writeFixture(to: source, mutation: mutation)
            XCTAssertThrowsError(try DoryQCOW2Importer.convert(source: source, destination: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testRejectsAnExistingDestinationAndLeavesItUnchanged() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.qcow2")
        let destination = root.appendingPathComponent("destination.raw")
        try writeFixture(to: source)
        try Data("do not replace".utf8).write(to: destination)
        XCTAssertThrowsError(try DoryQCOW2Importer.convert(source: source, destination: destination)) {
            XCTAssertEqual($0 as? DoryQCOW2ImportError, .destinationExists(destination.path))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("do not replace".utf8))
    }

    private enum Mutation { case backing, compressed, outOfRangeL1 }

    private func writeFixture(to url: URL, mutation: Mutation? = nil) throws {
        var data = Data(repeating: 0, count: 2_048)
        put(UInt32(0x5146_49fb), in: &data, at: 0)
        put(UInt32(3), in: &data, at: 4)
        put(UInt32(9), in: &data, at: 20)
        put(UInt64(1_024), in: &data, at: 24)
        put(UInt32(1), in: &data, at: 36)
        put(UInt64(512), in: &data, at: 40)
        put(UInt32(104), in: &data, at: 100)
        switch mutation {
        case .backing:
            put(UInt64(104), in: &data, at: 8)
            put(UInt32(5), in: &data, at: 16)
        default:
            break
        }
        put(UInt64(mutation == .outOfRangeL1 ? 8_192 : 1_024), in: &data, at: 512)
        let l2Entry: UInt64 = mutation == .compressed ? (UInt64(1_536) | (1 << 62)) : 1_536
        put(l2Entry, in: &data, at: 1_024)
        data.replaceSubrange(1_536..<2_048, with: Data(repeating: 0xab, count: 512))
        try data.write(to: url)
    }

    private func put<T: FixedWidthInteger>(_ value: T, in data: inout Data, at offset: Int) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-qcow2-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
