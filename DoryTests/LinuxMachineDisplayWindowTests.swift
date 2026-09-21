import Testing
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
}
