import AVFoundation
@testable import DoryHostCamera
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

    func testSelectedHostCameraIsExclusivelyReservedUntilStop() throws {
        let selectedID = "dory-camera-lease-test-\(UUID().uuidString)"
        let first = DoryMacCameraBackend(
            selectedDeviceUniqueID: selectedID, log: { _ in }
        )
        let second = DoryMacCameraBackend(
            selectedDeviceUniqueID: selectedID, log: { _ in }
        )
        try first.reserveSelectedDevice()
        XCTAssertThrowsError(try second.reserveSelectedDevice()) { error in
            XCTAssertEqual(String(describing: error), DoryMacCameraError.deviceInUse.description)
        }
        first.stop()
        try second.reserveSelectedDevice()
        second.stop()
    }

    func testRevokedPermissionReleasesSelectedCameraLease() throws {
        let selectedID = "dory-camera-revocation-test-\(UUID().uuidString)"
        let authorization = CameraAuthorizationState(.authorized)
        let first = DoryMacCameraBackend(
            selectedDeviceUniqueID: selectedID,
            log: { _ in },
            authorizationStatus: { authorization.value }
        )
        let second = DoryMacCameraBackend(
            selectedDeviceUniqueID: selectedID, log: { _ in }
        )
        try first.reserveSelectedDevice()
        try first.requireCurrentAuthorization()
        XCTAssertThrowsError(try second.reserveSelectedDevice())
        authorization.value = .denied
        XCTAssertThrowsError(try first.requireCurrentAuthorization()) { error in
            XCTAssertEqual(String(describing: error), DoryMacCameraError.permissionDenied.description)
        }
        try second.reserveSelectedDevice()
        second.stop()
    }

    func testRestrictedPermissionFailsClosedWithoutAFrame() {
        let backend = DoryMacCameraBackend(
            selectedDeviceUniqueID: nil,
            log: { _ in },
            authorizationStatus: { .restricted }
        )
        XCTAssertThrowsError(try backend.requireCurrentAuthorization()) { error in
            XCTAssertEqual(String(describing: error), DoryMacCameraError.permissionRestricted.description)
        }
    }
}

private final class CameraAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: AVAuthorizationStatus

    init(_ status: AVAuthorizationStatus) { self.status = status }

    var value: AVAuthorizationStatus {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }
}
