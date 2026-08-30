import DoryHostCamera
import XCTest

final class DoryMacCameraBackendTests: XCTestCase {
    func testUnsupportedFrameSizeFailsWithoutOpeningTheCamera() {
        let backend = DoryMacCameraBackend(log: { _ in })
        XCTAssertNil(backend.nextJPEGFrame(width: 320, height: 240, timeout: 0))
        XCTAssertThrowsError(
            try backend.nextJPEGFrameOrThrow(width: 320, height: 240, timeout: 0)
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "The requested Mac camera frame size is unsupported: 320x240."
            )
        }
        backend.stop()
        backend.stop()
    }

    func testPermissionErrorsRemainActionable() {
        XCTAssertTrue(DoryMacCameraError.permissionDenied.description.contains("Camera"))
        XCTAssertTrue(
            DoryMacCameraError.permissionRestricted.description.contains("administrator")
        )
        XCTAssertTrue(DoryMacCameraError.unavailable.description.contains("camera"))
        XCTAssertTrue(DoryMacCameraError.frameTimedOut.description.contains("deadline"))
    }
}
