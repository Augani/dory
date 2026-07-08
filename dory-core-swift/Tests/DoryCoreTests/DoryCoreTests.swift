import DoryCore
import XCTest

final class DoryCoreTests: XCTestCase {
    func testProtocolVersionComesFromRust() {
        // The Rust PROTO_VERSION is 1; this proves the staticlib is linked and callable.
        XCTAssertEqual(DoryCore.protocolVersion(), 1)
    }

    func testConnectAgentControlOverFDRejectsInvalidFD() {
        XCTAssertThrowsError(try DoryCore.connectAgentControlOverFD(-1))
    }
}
