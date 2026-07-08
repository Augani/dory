@testable import DorydKit
import XCTest

final class DorySocketTests: XCTestCase {
    func testBindCreatesSocketAt0600() throws {
        let home = NSTemporaryDirectory() + "dory-sock-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }

        let socket = DorySocket(home: home)
        let fd = try socket.bind()
        defer { close(fd) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path), "socket file created")
        let attrs = try FileManager.default.attributesOfItem(atPath: socket.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "socket is owner-only")
    }

    func testBindRefusesToUnlinkLiveSocket() throws {
        let home = NSTemporaryDirectory() + "dory-sock-live-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }

        let socket = DorySocket(home: home)
        let fd = try socket.bind()
        defer { close(fd) }

        XCTAssertThrowsError(try socket.bind()) { error in
            guard case DorySocket.SocketError.alreadyInUse(socket.path) = error else {
                return XCTFail("expected alreadyInUse, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
    }

    func testBindRemovesStaleSocketPath() throws {
        let home = NSTemporaryDirectory() + "dory-sock-stale-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }

        let socket = DorySocket(home: home)
        let stale = try socket.bind()
        close(stale)

        let fresh = try socket.bind()
        defer { close(fresh) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
    }
}
