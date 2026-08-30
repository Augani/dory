import Darwin
import DoryCameraBridgeContracts
@testable import DoryMacGuestCamera
import Foundation
import XCTest

final class DoryMacGuestCameraClientTests: XCTestCase {
    func testConnectedClientDecodesHostFrameAndSendsStop() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = DoryMacGuestCameraClient(connectedDescriptor: sockets[0])
        let frame = try DoryCameraBridgeV1.JPEGFrame(
            widthPixels: 640,
            heightPixels: 480,
            hostPresentationTimeNanoseconds: 123,
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        try writeAll(
            DoryCameraBridgeV1.encode(
                try DoryCameraBridgeV1.Message(
                    kind: .frame,
                    sequence: 0,
                    payload: frame.encode()
                )
            ),
            to: sockets[1]
        )
        XCTAssertEqual(try client.nextFrame(), frame)
        client.stop()
        close(sockets[1])
    }

    func testRemoteErrorIsBoundedAndActionable() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = DoryMacGuestCameraClient(connectedDescriptor: sockets[0])
        try writeAll(
            DoryCameraBridgeV1.encode(
                try DoryCameraBridgeV1.Message(
                    kind: .error,
                    sequence: 0,
                    payload: Data("permission revoked".utf8)
                )
            ),
            to: sockets[1]
        )
        XCTAssertThrowsError(try client.nextFrame()) { error in
            XCTAssertTrue(String(describing: error).contains("permission revoked"))
        }
        client.stop()
        close(sockets[1])
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
}
