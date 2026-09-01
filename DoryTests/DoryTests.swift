import Foundation
import Testing
@testable import Dory

@MainActor
struct DoryTests {
    @Test func componentSelectionLinkOpensComponentsWithCanonicalSelection() throws {
        let store = AppStore(runtime: MockRuntime())
        let url = try #require(URL(
            string: "dory://components/install?ids=linux-machines,kubernetes"
        ))

        #expect(store.handleComponentSelectionURL(url))
        #expect(store.section == .components)
        #expect(store.requestedComponentIDs.map(\.rawValue) == [
            "kubernetes",
            "linux-machines",
        ])
        #expect(store.windowOpenRequested)
    }

    @Test func retiredDesktopPayloadSelectionLinkIsRejected() throws {
        let store = AppStore(runtime: MockRuntime())
        let url = try #require(URL(
            string: "dory://components/install?ids=desktop-ubuntu,linux-desktop"
        ))

        #expect(!store.handleComponentSelectionURL(url))
        #expect(store.requestedComponentIDs.isEmpty)
    }

    @Test func malformedComponentSelectionLinkDoesNotChangeNavigation() throws {
        let store = AppStore(runtime: MockRuntime())
        store.section = .images
        let url = try #require(URL(
            string: "dory://components/install?ids=kubernetes,kubernetes"
        ))

        #expect(!store.handleComponentSelectionURL(url))
        #expect(store.section == .images)
        #expect(store.requestedComponentIDs.isEmpty)
        #expect(!store.windowOpenRequested)
    }
}
