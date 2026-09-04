import DoryOperations
import Testing
@testable import Dory

@MainActor
struct MachineStatsSyncTests {
    private func machine(containerID: String, status: DoryVirtualMachineState) -> Machine {
        Machine(name: "m-\(containerID)", distro: "Ubuntu", version: "24.04 LTS", status: status,
                cpuPercent: 0, memoryDisplay: "—", ip: "-", letter: "U", badgeHex: 0, containerID: containerID)
    }

    @Test func runningMachineGetsStatsFromMatchingContainer() {
        let store = AppStore()
        store.containers = MockData.containers
        store.machines = [machine(containerID: "c1", status: .running)]
        store.syncMachineStats()
        #expect(store.machines[0].memoryDisplay == "128 MB")
        #expect(store.machines[0].cpuPercent == 2.4)
    }

    @Test func stoppedMachineIsNotSynced() {
        let store = AppStore()
        store.containers = MockData.containers
        store.machines = [machine(containerID: "c1", status: .stopped)]
        store.syncMachineStats()
        #expect(store.machines[0].memoryDisplay == "—")
    }

    @Test func unmatchedContainerLeavesStatsUntouched() {
        let store = AppStore()
        store.containers = MockData.containers
        store.machines = [machine(containerID: "no-such-id", status: .running)]
        store.syncMachineStats()
        #expect(store.machines[0].memoryDisplay == "—")
        #expect(store.machines[0].cpuPercent == 0)
    }
}
