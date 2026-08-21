import DoryHV
import DoryOperations
import Testing
@testable import dory_hv

@Suite struct DesktopDisplayPlanTests {
    @Test func legacyLaunchRetainsTheEstablishedRetinaGeometry() throws {
        let plan = try DesktopMode.DisplayPlan(resolvedDevices: nil)

        #expect(plan.widthPixels == 2_560)
        #expect(plan.heightPixels == 1_600)
        #expect(plan.windowSize.width == 1_280)
        #expect(plan.windowSize.height == 800)
    }

    @Test func resolvedLaunchUsesTheExactInitialPixelGeometry() throws {
        let plan = try DesktopMode.DisplayPlan(resolvedDevices: .init(
            display: .init(widthPixels: 1_920, heightPixels: 1_080)
        ))

        #expect(plan.widthPixels == 1_920)
        #expect(plan.heightPixels == 1_080)
        #expect(plan.windowSize.width == 960)
        #expect(plan.windowSize.height == 540)
    }

    @Test func invalidResolvedGeometryFailsClosed() {
        for display in [
            DoryVirtualMachineDisplayCapabilityRequest(widthPixels: 0, heightPixels: 1_080),
            DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels + 1,
                heightPixels: 1_080
            ),
        ] {
            #expect(throws: VMError.self) {
                _ = try DesktopMode.DisplayPlan(resolvedDevices: .init(display: display))
            }
        }
    }
}
