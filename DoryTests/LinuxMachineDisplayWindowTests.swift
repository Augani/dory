import Testing
import DoryVMDisplayWireContracts
@testable import Dory

struct LinuxMachineDisplayWindowTests {
    @Test func captureTitleIsStableAndMachineScoped() {
        let primary = LinuxMachineDisplayWindow(machineID: "ubuntu-a4")
        let secondary = LinuxMachineDisplayWindow(machineID: "ubuntu-a4", scanoutID: 1)

        #expect(primary.id == "ubuntu-a4:0")
        #expect(primary.windowTitle == "Dory — ubuntu-a4 — Display 1")
        #expect(secondary.id == "ubuntu-a4:1")
        #expect(secondary.windowTitle == "Dory — ubuntu-a4 — Display 2")
    }

    @Test func scanoutCoordinatesKeepTopOriginFramesUpright() {
        let topOrigin = LinuxMachineScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: true
        )
        #expect(topOrigin == SIMD4<Float>(0.1, 0.1, 0.5, 0.5))

        let bottomOrigin = LinuxMachineScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: false
        )
        #expect(bottomOrigin == SIMD4<Float>(0.1, 0.5, 0.5, 0.1))
    }
}
