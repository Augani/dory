import DoryVZMacSDKInventory
import XCTest

final class SDKInventoryTests: XCTestCase {
    func testPhysicalUSBFollowsCompilingSDKBoundary() {
        let maximumAllowed = dory_vzmac_sdk_max_allowed()
        if maximumAllowed >= 270_000 {
            XCTAssertTrue(dory_vzmac_accessory_access_declared())
            XCTAssertTrue(dory_vzmac_physical_usb_declared())
        } else {
            XCTAssertFalse(dory_vzmac_accessory_access_declared())
            XCTAssertFalse(dory_vzmac_physical_usb_declared())
        }
    }

    func testCurrentPublicSDKHasNoVZCameraInjectionDeclaration() {
        XCTAssertFalse(dory_vzmac_camera_injection_declared())
    }
}
