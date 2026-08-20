import Foundation
import Testing
@testable import Dory

@MainActor
struct AppStoreEnvAllowListTests {
    @Test func hostEnvironmentImportDefaultsToDisabled() {
        let store = AppStore(runtime: MockRuntime())
        #expect(store.machineEnvAllowList.isEmpty)
    }

    @Test func legacyAllowListPreferenceIsClearedAndCannotBeReenabled() {
        defer { UserDefaults.standard.removeObject(forKey: AppStore.machineEnvAllowListKey) }
        UserDefaults.standard.set("ANTHROPIC_API_KEY,GH_TOKEN", forKey: AppStore.machineEnvAllowListKey)
        let store = AppStore(runtime: MockRuntime())
        store.setMachineEnvAllowList(["ANTHROPIC_API_KEY", "GH_TOKEN"])
        #expect(store.machineEnvAllowList.isEmpty)
        #expect(UserDefaults.standard.string(forKey: AppStore.machineEnvAllowListKey) == nil)
    }

    @Test func newMachineEnvironmentKeepsOnlyBoundedDoryMetadata() {
        let result = AppStore.sanitizedNewMachineEnvironment([
            "ANTHROPIC_API_KEY": "sk-ant-host",
            "GH_TOKEN": "gh-host",
            "APP_ENV": "development",
            "DORY_DESKTOP_DISTRO": "ubuntu",
            "DORY_GUEST_USER": "dory",
        ])

        #expect(result == [
            "DORY_DESKTOP_DISTRO": "ubuntu",
            "DORY_GUEST_USER": "dory",
        ])
    }

    @Test func createMachineRejectsPathTraversalName() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(name: "../evil")
        #expect(result == "Invalid machine name")
    }

    @Test func createMachineRejectsSlashInName() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(name: "a/b")
        #expect(result == "Invalid machine name")
    }

    @Test func createMachineRejectsNameLongerThanDaemonLimit() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(name: String(repeating: "a", count: 64))
        #expect(result == "Invalid machine name")
        #expect(store.actionError?.contains("63 characters or fewer") == true)
    }

    @Test func createMachineRequiresDorydMachineRuntime() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(name: "dev")
        #expect(result == AppStore.dorydMachineManagerRequired())
        #expect(store.actionError == AppStore.dorydMachineManagerRequired())
    }

    @Test func loadMachinesClearsRowsWithoutDorydRuntime() {
        let store = AppStore(runtime: MockRuntime())
        store.machines = MockData.machines
        store.loadMachines()
        #expect(store.machines.isEmpty)
    }
}
