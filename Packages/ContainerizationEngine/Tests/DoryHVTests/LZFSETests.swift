import Foundation
import XCTest
@testable import DoryHV

final class LZFSETests: XCTestCase {
    func testRoundTripAcrossMultipleStreamChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.bin")
        let compressed = directory.appendingPathComponent("input.bin.lzfse")
        let restored = directory.appendingPathComponent("restored.bin")
        let bytes = Data((0..<(3 * 1_048_576 + 257)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: input)

        try LZFSE.compress(source: input.path, destination: compressed.path)
        try LZFSE.decompress(source: compressed.path, destination: restored.path)

        XCTAssertEqual(try Data(contentsOf: restored), bytes)
    }

    func testMissingInputReportsItsPath() {
        let missing = "/tmp/dory-lzfse-missing-\(UUID().uuidString)"
        XCTAssertThrowsError(
            try LZFSE.compress(source: missing, destination: "\(missing).lzfse")
        ) { error in
            guard case .openInput(let path) = error as? LZFSEError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing)
        }
    }
}
