import DoryVZMacCompatibility
import XCTest

final class VZMacHostCapabilitiesTests: XCTestCase {
    private let sdk26 = DoryVZMacSDKCapabilities(
        maximumAllowed: 260_500,
        accessoryAccessDeclared: false,
        physicalUSBDeclared: false,
        xhciControllerDeclared: true,
        virtualUSBMassStorageDeclared: true,
        virtioSocketDeclared: true,
        customVirtioDeclared: false,
        cameraInjectionDeclared: false
    )
    private let sdk27 = DoryVZMacSDKCapabilities(
        maximumAllowed: 270_000,
        accessoryAccessDeclared: true,
        physicalUSBDeclared: true,
        xhciControllerDeclared: true,
        virtualUSBMassStorageDeclared: true,
        virtioSocketDeclared: true,
        customVirtioDeclared: true,
        cameraInjectionDeclared: false
    )

    func testMacOS26WithOlderSDKUsesOnlyTheVirtualStoragePath() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 26,
            sdk: sdk26
        )
        XCTAssertEqual(result.physicalUSB, .unavailable)
        XCTAssertEqual(result.removableStorage, .virtualUSBMassStorageAttachment)
        XCTAssertEqual(result.cameraInjection, .unavailable)
        XCTAssertTrue(result.blockers.contains(.physicalUSBRequiresMacOS27))
    }

    func testMacOS26WithNewSDKStillRejectsPhysicalUSB() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 26,
            sdk: sdk27
        )
        XCTAssertEqual(result.physicalUSB, .unavailable)
        XCTAssertEqual(result.removableStorage, .virtualUSBMassStorageAttachment)
        XCTAssertEqual(result.cameraInjection, .unavailable)
        XCTAssertTrue(result.blockers.contains(.physicalUSBRequiresMacOS27))
    }

    func testMacOS14DisablesBothPhysicalUSBAndVirtualMassStorage() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 14,
            sdk: sdk26
        )
        XCTAssertEqual(result.physicalUSB, .unavailable)
        XCTAssertEqual(result.removableStorage, .unavailable)
        XCTAssertEqual(result.cameraInjection, .unavailable)
        XCTAssertTrue(result.blockers.contains(.physicalUSBRequiresMacOS27))
        XCTAssertTrue(result.blockers.contains(.virtualUSBMassStorageRequiresMacOS15))
    }

    func testMacOS27UsesAccessoryAccessPhysicalPassthrough() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 27,
            sdk: sdk27
        )
        XCTAssertEqual(result.physicalUSB, .accessoryAccessPassthrough)
        XCTAssertEqual(result.removableStorage, .accessoryAccessPhysicalPassthrough)
        XCTAssertEqual(result.cameraInjection, .unavailable)
        XCTAssertFalse(result.blockers.contains(.compilingSDKLacksPhysicalUSB))
    }

    func testQualifiedGuestCameraBridgeBecomesTheCameraPath() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 26,
            sdk: sdk26,
            cameraBridgeQualification: .init(
                guestMajorVersion: 12,
                guestMinorVersion: 3,
                guestExtensionInstalledAndAuthorized: true,
                releaseQualificationPassed: true
            )
        )
        XCTAssertEqual(result.cameraInjection, .guestCoreMediaIOBridge)
        XCTAssertFalse(result.blockers.contains(.guestCameraBridgeQualificationPending))
    }

    func testUnqualifiedGuestCameraBridgeRemainsUnavailable() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 27,
            sdk: sdk27,
            cameraBridgeQualification: .init(
                guestMajorVersion: 12,
                guestMinorVersion: 2,
                guestExtensionInstalledAndAuthorized: true,
                releaseQualificationPassed: true
            )
        )
        XCTAssertEqual(result.cameraInjection, .unavailable)
        XCTAssertTrue(result.blockers.contains(.guestCameraBridgeQualificationPending))
    }

    func testOlderBuildRemainsSafeWhenRunOnMacOS27() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "arm64",
            hostMajorVersion: 27,
            sdk: sdk26
        )
        XCTAssertEqual(result.physicalUSB, .unavailable)
        XCTAssertEqual(result.removableStorage, .virtualUSBMassStorageAttachment)
        XCTAssertTrue(result.blockers.contains(.compilingSDKLacksPhysicalUSB))
    }

    func testIntelHostRejectsBeforeAnyDevicePath() {
        let result = DoryVZMacHostCapabilities.resolve(
            hostArchitecture: "x86_64",
            hostMajorVersion: 27,
            sdk: sdk27
        )
        XCTAssertEqual(result.physicalUSB, .unavailable)
        XCTAssertEqual(result.removableStorage, .unavailable)
        XCTAssertEqual(result.blockers, [.unsupportedHostArchitecture])
    }
}
