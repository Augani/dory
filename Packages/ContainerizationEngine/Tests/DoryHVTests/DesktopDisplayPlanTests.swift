import DoryHV
import DoryOperations
import Testing
@testable import dory_hv

@Suite struct DesktopDisplayPlanTests {
    @Test func legacyLaunchRetainsTheEstablishedRetinaGeometry() throws {
        let plan = try DesktopMode.DisplayPlan(resolvedDevices: nil)

        #expect(plan.widthPixels == 2_560)
        #expect(plan.heightPixels == 1_600)
        #expect(plan.backingScaleFactor == 2)
        #expect(plan.guestUIScaleFactor == 2)
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

    @Test func resolvedBackingScaleIsNotInferredFromHostDensity() throws {
        let plan = try DesktopMode.DisplayPlan(resolvedDevices: .init(
            display: .init(
                widthPixels: 1_920,
                heightPixels: 1_080,
                backingScaleFactor: 1,
                guestUIScaleFactor: 2
            )
        ))

        #expect(plan.windowSize.width == 1_920)
        #expect(plan.windowSize.height == 1_080)
        #expect(plan.backingScaleFactor == 1)
        #expect(plan.guestUIScaleFactor == 2)
    }

    @Test func resolvedTopologyMapsEveryStableDisplayToOneScanout() throws {
        let plans = try DesktopMode.DisplayPlan.resolve(resolvedDevices: .init(displays: [
            .init(
                id: "display-0",
                widthPixels: 2_560,
                heightPixels: 1_600,
                backingScaleFactor: 2,
                guestUIScaleFactor: 2
            ),
            .init(
                id: "display-1",
                widthPixels: 1_920,
                heightPixels: 1_080,
                backingScaleFactor: 1,
                guestUIScaleFactor: 2
            ),
        ]))

        #expect(plans.map(\.id) == ["display-0", "display-1"])
        #expect(plans.map(\.scanoutID) == [0, 1])
        #expect(plans.map(\.windowSize) == [
            .init(width: 1_280, height: 800),
            .init(width: 1_920, height: 1_080),
        ])
    }

    @Test func topologyRejectsDuplicateIDsAndDivergentGuestScale() {
        let primary = DoryVirtualMachineDisplayCapabilityRequest(
            id: "display-0",
            widthPixels: 1_920,
            heightPixels: 1_080,
            guestUIScaleFactor: 2
        )
        let duplicate = primary
        var divergent = primary
        divergent.id = "display-1"
        divergent.guestUIScaleFactor = 1

        #expect(throws: VMError.self) {
            _ = try DesktopMode.DisplayPlan.resolve(resolvedDevices: .init(displays: [
                primary, duplicate,
            ]))
        }
        #expect(throws: VMError.self) {
            _ = try DesktopMode.DisplayPlan.resolve(resolvedDevices: .init(displays: [
                primary, divergent,
            ]))
        }
    }

    @Test func pointerTopologyMapsEachWindowIntoTheWholeGuestDesktop() {
        let topology = DesktopPointerTopology(sizes: [
            .init(width: 1_920, height: 1_080),
            .init(width: 1_280, height: 1_024),
        ])

        #expect(topology.normalizedPoint(
            scanoutID: 0,
            localX: 0,
            localY: 0
        ) == .init(x: 0, y: 0))
        #expect(topology.normalizedPoint(
            scanoutID: 0,
            localX: 1,
            localY: 1
        ) == .init(x: 0.6, y: 1))
        #expect(topology.normalizedPoint(
            scanoutID: 1,
            localX: 0,
            localY: 0
        ) == .init(x: 0.6, y: 0))
        let secondaryBottomRight = topology.normalizedPoint(
            scanoutID: 1,
            localX: 1,
            localY: 1
        )
        #expect(secondaryBottomRight.x == 1)
        #expect(abs(secondaryBottomRight.y - (1_024.0 / 1_080.0)) < 0.000_001)

        topology.update(scanoutID: 1, width: 1_920, height: 1_080)
        #expect(topology.normalizedPoint(
            scanoutID: 1,
            localX: 0,
            localY: 0
        ) == .init(x: 0.5, y: 0))
    }

    @Test func scanoutAndPointerShareTheTopLeftOriginContract() {
        let topOrigin = DesktopScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: true
        )
        #expect(topOrigin == SIMD4<Float>(0.1, 0.1, 0.5, 0.5))

        let bottomOrigin = DesktopScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: false
        )
        #expect(bottomOrigin == SIMD4<Float>(0.1, 0.5, 0.5, 0.1))

        let pointer = DesktopPointerTopology(sizes: [
            .init(width: 1_000, height: 500),
        ]).normalizedPoint(scanoutID: 0, localX: 0.1, localY: 0.1)
        #expect(pointer.x == 0.1)
        #expect(pointer.y == 0.1)
    }

    @Test func invalidResolvedGeometryFailsClosed() {
        for display in [
            DoryVirtualMachineDisplayCapabilityRequest(widthPixels: 0, heightPixels: 1_080),
            DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels + 1,
                heightPixels: 1_080
            ),
            DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: 1_920,
                heightPixels: 1_080,
                backingScaleFactor: 0
            ),
            DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: 1_920,
                heightPixels: 1_080,
                guestUIScaleFactor: 3
            ),
        ] {
            #expect(throws: VMError.self) {
                _ = try DesktopMode.DisplayPlan(resolvedDevices: .init(display: display))
            }
        }
    }
}
