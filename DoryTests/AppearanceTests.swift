import Testing
import SwiftUI
@testable import Dory

@MainActor
struct AppearanceTests {
    @Test func systemResolvesToTheOSAppearance() {
        #expect(DoryAppearance.system.resolved(systemIsDark: true) == .dark)
        #expect(DoryAppearance.system.resolved(systemIsDark: false) == .light)
    }

    @Test func explicitAppearancesIgnoreTheOSAppearance() {
        #expect(DoryAppearance.light.resolved(systemIsDark: true) == .light)
        #expect(DoryAppearance.dark.resolved(systemIsDark: false) == .dark)
    }

    @Test func systemLeavesTheColorSchemeToSwiftUI() {
        #expect(DoryAppearance.system.colorScheme == nil)
        #expect(DoryAppearance.light.colorScheme == .light)
        #expect(DoryAppearance.dark.colorScheme == .dark)
    }

    @Test func paletteFollowsTheSystemAppearance() {
        let store = AppStore()
        store.appearance = .system
        #expect(store.palette == (store.systemAppearance.isDark ? .dark : .light))
    }

    @Test func toggleThemeLeavesSystemForAnExplicitOverride() {
        let store = AppStore()
        store.appearance = .system
        let wasDark = store.resolvedAppearance == .dark
        store.toggleTheme()
        #expect(store.appearance == (wasDark ? .light : .dark))
    }
}
