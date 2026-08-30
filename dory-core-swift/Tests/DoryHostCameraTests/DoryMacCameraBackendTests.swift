import DoryHostCamera
import XCTest

final class DoryMacCameraBackendTests: XCTestCase {
    func testUnsupportedFrameSizeFailsWithoutOpeningTheCamera() {
        let backend = DoryMacCameraBackend(log: { _ in })
        XCTAssertNil(backend.nextJPEGFrame(width: 320, height: 240, timeout: 0))
        backend.stop()
        backend.stop()
    }

    func testPermissionErrorsRemainActionable() {
        XCTAssertTrue(DoryMacCameraError.permissionDenied.description.contains("Camera"))
        XCTAssertTrue(
            DoryMacCameraError.permissionRestricted.description.contains("administrator")
        )
        XCTAssertTrue(DoryMacCameraError.unavailable.description.contains("camera"))
    }
}
