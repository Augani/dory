@testable import DoryCore
import XCTest

final class DoryDesktopRuntimeContractTests: XCTestCase {
    func testDesktopVMMPreferenceDefaultsAndValidates() throws {
        XCTAssertEqual(try DoryDesktopVMMPreference(environment: [:]), .automatic)
        XCTAssertEqual(
            try DoryDesktopVMMPreference(environment: [
                DoryDesktopVMMPreference.environmentKey: "compatible",
            ]),
            .compatible
        )
        XCTAssertThrowsError(try DoryDesktopVMMPreference(environment: [
            DoryDesktopVMMPreference.environmentKey: "fastest",
        ]))
    }

    func testGraphicsPreferencePreservesLegacyMachinesButPrefersNewContract() throws {
        XCTAssertEqual(try DoryDesktopGraphicsPreference(environment: [:]), .automatic)
        XCTAssertEqual(
            try DoryDesktopGraphicsPreference(environment: [
                DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey: "1",
            ]),
            .virgl
        )
        XCTAssertEqual(
            try DoryDesktopGraphicsPreference(environment: [
                DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey: "1",
                DoryDesktopGraphicsPreference.environmentKey: "virgl-venus",
            ]),
            .virglVenus
        )
        XCTAssertThrowsError(try DoryDesktopGraphicsPreference(environment: [
            DoryDesktopGraphicsPreference.environmentKey: "metal",
        ]))
    }

    func testResolvedGraphicsBackendsPublishTruthfulKernelTokens() {
        XCTAssertEqual(DoryDesktopGraphicsBackend.virgl.kernelArgument, "dory.graphics=virgl")
        XCTAssertEqual(
            DoryDesktopGraphicsBackend.virglVenus.kernelArgument,
            "dory.graphics=virgl-venus"
        )
        XCTAssertEqual(DoryDesktopGraphicsBackend.software.kernelArgument, "dory.graphics=software")
        XCTAssertNotNil(DoryDesktopGraphicsBackend.virgl.legacyKernelArgument)
        XCTAssertNil(DoryDesktopGraphicsBackend.software.legacyKernelArgument)
    }

    func testAutomaticGraphicsRequiresVulkanAccelerationWithoutSilentFallback() {
        XCTAssertEqual(
            DoryDesktopGraphicsPreference.automatic.requiredBackend,
            .virglVenus
        )
        XCTAssertEqual(DoryDesktopGraphicsPreference.virglVenus.requiredBackend, .virglVenus)
        XCTAssertEqual(DoryDesktopGraphicsPreference.virgl.requiredBackend, .virgl)
        XCTAssertEqual(DoryDesktopGraphicsPreference.software.requiredBackend, .software)
    }
}
