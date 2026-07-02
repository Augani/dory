import Testing
@testable import Dory

@MainActor
struct OpenLoginsOnMacTests {
    @Test func defaultsToTrue() {
        let store = AppStore()
        #expect(store.openLoginsOnMac == true)
    }

    @Test func setterTogglesState() {
        let store = AppStore()
        store.setOpenLoginsOnMac(false)
        #expect(store.openLoginsOnMac == false)
        store.setOpenLoginsOnMac(true)
        #expect(store.openLoginsOnMac == true)
    }
}
