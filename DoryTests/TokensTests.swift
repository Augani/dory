import Testing
import SwiftUI
@testable import Dory

struct TokensTests {
    @Test func typeScaleSizes() {
        #expect(DoryType.label.rawValue == 11)
        #expect(DoryType.body.rawValue == 13)
        #expect(DoryType.display.rawValue == 22)
    }

    @Test func spacingScale() {
        #expect(DorySpace.xs.rawValue == 4)
        #expect(DorySpace.md.rawValue == 12)
        #expect(DorySpace.xl.rawValue == 24)
    }

    @Test func radiusScale() {
        #expect(DoryRadius.sm.rawValue == 6)
        #expect(DoryRadius.lg.rawValue == 12)
    }
}
