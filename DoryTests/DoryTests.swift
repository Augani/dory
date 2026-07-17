import Foundation
import Testing
@testable import Dory

@MainActor
struct DoryTests {
    @Test func componentSelectionLinkOpensComponentsWithCanonicalSelection() throws {
        let store = AppStore(runtime: MockRuntime())
        let url = try #require(URL(
            string: "dory://components/install?ids=desktop-ubuntu,linux-desktop,kubernetes"
        ))

        #expect(store.handleComponentSelectionURL(url))
        #expect(store.section == .components)
        #expect(store.requestedComponentIDs.map(\.rawValue) == [
            "kubernetes",
            "linux-desktop",
            "desktop-ubuntu",
        ])
        #expect(store.windowOpenRequested)
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
