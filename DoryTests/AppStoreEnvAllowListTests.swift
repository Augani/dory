import Foundation
import Testing
@testable import Dory

@MainActor
struct AppStoreEnvAllowListTests {
    @Test func defaultAllowListIsAnthropicOnly() {
        let store = AppStore(runtime: MockRuntime())
        #expect(store.machineEnvAllowList == ["ANTHROPIC_API_KEY"])
    }

    @Test func setAllowListNormalizesDedupesAndPersistsUserChoice() {
        defer { UserDefaults.standard.removeObject(forKey: AppStore.machineEnvAllowListKey) }
        let store = AppStore(runtime: MockRuntime())
        store.setMachineEnvAllowList(["gh_token", "  ", "gh_token"])
        #expect(store.machineEnvAllowList == ["GH_TOKEN"])
        #expect(UserDefaults.standard.string(forKey: AppStore.machineEnvAllowListKey) == "GH_TOKEN")
    }

    @Test func setAllowListCanDisableAutomaticEnvTransfer() {
        defer { UserDefaults.standard.removeObject(forKey: AppStore.machineEnvAllowListKey) }
        let store = AppStore(runtime: MockRuntime())
        store.setMachineEnvAllowList([])
        #expect(store.machineEnvAllowList.isEmpty)
        #expect(UserDefaults.standard.string(forKey: AppStore.machineEnvAllowListKey) == "")
    }

    @Test func mergingEnvAddsResolvedButUserKeysWin() {
        var settings = MachineSettings.default
        settings.env = ["ANTHROPIC_API_KEY": "user-set"]
        let merged = AppStore.mergingEnv(settings, resolved: ["ANTHROPIC_API_KEY": "probed", "GH_TOKEN": "gh-123"])
        #expect(merged.env["ANTHROPIC_API_KEY"] == "user-set")
        #expect(merged.env["GH_TOKEN"] == "gh-123")
    }

    @Test func mergingEnvIgnoresEmptyResolved() {
        let merged = AppStore.mergingEnv(.default, resolved: [:])
        #expect(merged.env.isEmpty)
    }

    @Test func createMachineRejectsPathTraversalName() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(image: "ubuntu", name: "../evil")
        #expect(result == "Invalid machine name")
    }

    @Test func createMachineRejectsSlashInName() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(image: "ubuntu", name: "a/b")
        #expect(result == "Invalid machine name")
    }

    @Test func createMachineRequiresDorydMachineRuntime() async {
        let store = AppStore(runtime: MockRuntime())
        let result = await store.createMachine(image: "ubuntu", name: "dev")
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
