@testable import DoryHV
import Testing

struct GVProxyDatapathGuardTests {
    @Test func requiresConsecutiveDifferentialFailuresBeforeRestart() {
        var guardState = GVProxyDatapathGuard(failureThreshold: 3)

        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .healthy)

        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 2))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .restartRequired(consecutiveFailures: 3))
        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .restartAlreadyRequested)
    }

    @Test func hostOrGuestOutageCannotAccumulateRestartSuspicion() {
        var guardState = GVProxyDatapathGuard(failureThreshold: 3)

        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .healthy)

        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: false) == .inconclusive)
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
    }

    @Test func successfulCanaryRecoversAndResetsTheFailureRun() {
        var guardState = GVProxyDatapathGuard(failureThreshold: 3)

        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .healthy)

        _ = guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true)
        _ = guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true)
        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .recovered(previousFailures: 2))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
    }

    @Test func thresholdCannotBeConfiguredToSingleSample() {
        var guardState = GVProxyDatapathGuard(failureThreshold: 1)

        #expect(guardState.failureThreshold == 2)
        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .healthy)
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .restartRequired(consecutiveFailures: 2))
    }

    @Test func missingStartupCanaryCannotRestartAHealthyVM() {
        var guardState = GVProxyDatapathGuard(failureThreshold: 2)

        for _ in 0..<10 {
            #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .awaitingReadiness)
        }
        #expect(guardState.observe(gvproxyCanaryReachable: true, dockerAPIReachable: true) == .healthy)
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .suspected(consecutiveFailures: 1))
        #expect(guardState.observe(gvproxyCanaryReachable: false, dockerAPIReachable: true) == .restartRequired(consecutiveFailures: 2))
    }
}
