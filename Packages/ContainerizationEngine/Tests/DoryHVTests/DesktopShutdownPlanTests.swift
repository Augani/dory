import DoryOperations
import Testing
@testable import dory_hv

@Suite struct DesktopShutdownPlanTests {
    @Test func legacyAndAuthorizedContractsUseGuestAssistedShutdown() {
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: nil) == .guestAssisted)
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: .init(
            gracefulShutdown: true
        )) == .guestAssisted)
    }

    @Test func resolvedOptOutUsesImmediateHostShutdown() {
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: .init(
            gracefulShutdown: false
        )) == .immediate)
    }
}
