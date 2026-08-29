import DoryCore
import XCTest

final class DoryCoreTests: XCTestCase {
    func testProtocolVersionComesFromRust() {
        // The Rust PROTO_VERSION is 1; this proves the staticlib is linked and callable.
        XCTAssertEqual(DoryCore.protocolVersion(), 1)
    }

    func testBoundedZstdBootArtifactDecompressionCrossesRustFFIExactly() throws {
        let compressed = Data([
            0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0xd1, 0x00,
            0x00, 0x44, 0x6f, 0x72, 0x79, 0x20, 0x62, 0x6f,
            0x75, 0x6e, 0x64, 0x65, 0x64, 0x20, 0x7a, 0x62,
            0x6f, 0x6f, 0x74, 0x20, 0x66, 0x69, 0x78, 0x74,
            0x75, 0x72, 0x65, 0x2b, 0x80, 0x71, 0x29,
        ])
        let expected = Data("Dory bounded zboot fixture".utf8)

        XCTAssertEqual(
            try DoryCore.decompressZstd(
                compressed,
                maximumOutputBytes: expected.count
            ),
            expected
        )
        XCTAssertThrowsError(
            try DoryCore.decompressZstd(
                compressed,
                maximumOutputBytes: expected.count - 1
            )
        ) { error in
            guard case let .decompressionFailed(message) = error as? DoryCoreArtifactError else {
                return XCTFail("expected bounded decompression failure, got \(error)")
            }
            XCTAssertTrue(message.contains("exceeds"))
        }
    }

    func testConnectAgentControlOverFDRejectsInvalidFD() {
        XCTAssertThrowsError(try DoryCore.connectAgentControlOverFD(-1))
    }

    func testPushControlStartsWithBoundedPreparingProgress() {
        let control = DoryPushControl()

        XCTAssertEqual(
            control.progress(),
            DoryPushProgress(
                phase: .preparing,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            )
        )
        XCTAssertFalse(control.progress().phase.isTerminal)
        XCTAssertEqual(control.progress().fractionCompleted, 0)
    }

    func testPushProgressFractionPrefersBytesAndIsBounded() {
        XCTAssertEqual(
            DoryPushProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 3,
                bytesTotal: 100,
                bytesCompleted: 25,
                currentPath: "src/main.swift"
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            DoryPushProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 5,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
        XCTAssertEqual(
            DoryPushProgress(
                phase: .completed,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
    }

    func testPullControlStartsWithBoundedPreparingProgress() {
        let control = DoryPullControl()

        XCTAssertEqual(
            control.progress(),
            DoryPullProgress(
                phase: .preparing,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            )
        )
        XCTAssertFalse(control.progress().phase.isTerminal)
        XCTAssertEqual(control.progress().fractionCompleted, 0)
    }

    func testPullProgressFractionPrefersBytesAndIsBounded() {
        XCTAssertEqual(
            DoryPullProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 3,
                bytesTotal: 100,
                bytesCompleted: 25,
                currentPath: "src/main.swift"
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            DoryPullProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 5,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
        XCTAssertEqual(
            DoryPullProgress(
                phase: .completed,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
    }
}
