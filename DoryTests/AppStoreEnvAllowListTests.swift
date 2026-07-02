import Testing
@testable import Dory

@MainActor
struct AppStoreEnvAllowListTests {
    @Test func defaultAllowListIsAnthropicOnly() {
        let store = AppStore(runtime: MockRuntime())
        #expect(store.machineEnvAllowList == ["ANTHROPIC_API_KEY"])
    }

    @Test func setAllowListNormalizesAndKeepsAnthropicFirst() {
        let store = AppStore(runtime: MockRuntime())
        store.setMachineEnvAllowList(["gh_token", "  ", "gh_token"])
        #expect(store.machineEnvAllowList == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
    }
}
