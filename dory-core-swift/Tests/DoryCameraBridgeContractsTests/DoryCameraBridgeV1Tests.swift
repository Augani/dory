import DoryCameraBridgeContracts
import Foundation
import XCTest

final class DoryCameraBridgeV1Tests: XCTestCase {
    func testFragmentedMessagesDecodeInSequence() throws {
        let start = try DoryCameraBridgeV1.StartRequest(
            widthPixels: 1_280,
            heightPixels: 720,
            maximumFramesPerSecond: 30
        )
        let first = try DoryCameraBridgeV1.Message(
            kind: .start,
            sequence: 0,
            payload: start.encode()
        )
        let second = try DoryCameraBridgeV1.Message(kind: .stop, sequence: 1)
        let bytes = DoryCameraBridgeV1.encode(first) + DoryCameraBridgeV1.encode(second)
        var decoder = DoryCameraBridgeV1.Decoder()
        var decoded: [DoryCameraBridgeV1.Message] = []
        for byte in bytes {
            decoded += try decoder.append(Data([byte]))
        }
        XCTAssertEqual(decoded, [first, second])
        XCTAssertEqual(try DoryCameraBridgeV1.StartRequest.decode(decoded[0].payload), start)
    }

    func testJPEGFrameRoundTrips() throws {
        let frame = try DoryCameraBridgeV1.JPEGFrame(
            widthPixels: 640,
            heightPixels: 480,
            hostPresentationTimeNanoseconds: 42,
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        XCTAssertEqual(try DoryCameraBridgeV1.JPEGFrame.decode(frame.encode()), frame)
    }

    func testOversizedPayloadIsRejectedFromHeader() throws {
        var bytes = DoryCameraBridgeV1.encode(
            try DoryCameraBridgeV1.Message(kind: .stop, sequence: 0)
        )
        let oversized = UInt32(DoryCameraBridgeV1.maximumPayloadBytes + 1).bigEndian
        Swift.withUnsafeBytes(of: oversized) { bytes.replaceSubrange(8..<12, with: $0) }
        var decoder = DoryCameraBridgeV1.Decoder()
        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(
                error as? DoryCameraBridgeV1.ProtocolError,
                .payloadTooLarge(DoryCameraBridgeV1.maximumPayloadBytes + 1)
            )
        }
    }

    func testOutOfOrderMessageIsRejected() throws {
        let bytes = DoryCameraBridgeV1.encode(
            try DoryCameraBridgeV1.Message(kind: .stop, sequence: 9)
        )
        var decoder = DoryCameraBridgeV1.Decoder()
        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(
                error as? DoryCameraBridgeV1.ProtocolError,
                .unexpectedSequence(expected: 0, actual: 9)
            )
        }
    }

    func testFormatLimitsRejectInvalidRequests() {
        XCTAssertThrowsError(
            try DoryCameraBridgeV1.StartRequest(
                widthPixels: 1_920,
                heightPixels: 1_080,
                maximumFramesPerSecond: 30
            )
        )
        XCTAssertThrowsError(
            try DoryCameraBridgeV1.StartRequest(
                widthPixels: 640,
                heightPixels: 480,
                maximumFramesPerSecond: 0
            )
        )
    }
}
