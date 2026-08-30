import Darwin
import DoryCameraBridgeContracts
@testable import DoryVZMacCameraBridge
import Foundation
import XCTest

final class DoryVZMacCameraSessionTests: XCTestCase {
    func testGuestStartReceivesFrameAndStopEndsSession() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let completed = expectation(description: "host camera session stopped")
        let session = DoryVZMacCameraSession(
            ownedDescriptor: sockets[0],
            frameProvider: { width, height, _ in
                XCTAssertEqual(width, 640)
                XCTAssertEqual(height, 480)
                return Data([0xFF, 0xD8, 0xFF, 0xD9])
            }
        )
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.fulfill() }
            do {
                try session.run()
            } catch {
                XCTFail("camera session failed: \(error)")
            }
        }

        let request = try DoryCameraBridgeV1.StartRequest(
            widthPixels: 640,
            heightPixels: 480,
            maximumFramesPerSecond: 30
        )
        try writeAll(
            DoryCameraBridgeV1.encode(
                try DoryCameraBridgeV1.Message(
                    kind: .start,
                    sequence: 0,
                    payload: request.encode()
                )
            ),
            to: sockets[1]
        )

        var decoder = DoryCameraBridgeV1.Decoder()
        let frameMessage = try readMessage(from: sockets[1], decoder: &decoder)
        XCTAssertEqual(frameMessage.kind, .frame)
        let frame = try DoryCameraBridgeV1.JPEGFrame.decode(frameMessage.payload)
        XCTAssertEqual(frame.widthPixels, 640)
        XCTAssertEqual(frame.heightPixels, 480)
        XCTAssertEqual(frame.jpeg, Data([0xFF, 0xD8, 0xFF, 0xD9]))

        try writeAll(
            DoryCameraBridgeV1.encode(
                try DoryCameraBridgeV1.Message(kind: .stop, sequence: 1)
            ),
            to: sockets[1]
        )
        wait(for: [completed], timeout: 2)
        close(sockets[1])
    }

    private func readMessage(
        from descriptor: Int32,
        decoder: inout DoryCameraBridgeV1.Decoder
    ) throws -> DoryCameraBridgeV1.Message {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            if let message = try decoder.append(Data(bytes.prefix(count))).first {
                return message
            }
        }
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
