import Testing
@testable import Dory

struct RuntimeStatsMathTests {
    @Test func cpuPercentNormalizesByCpuCount() {
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 1) == 100)
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 4) == 25)
    }

    @Test func cpuPercentClampsInvalidAndOverloadedSamples() {
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 0, elapsedUsec: 800_000, cpus: 1) == 0)
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: -1, elapsedUsec: 800_000, cpus: 1) == 0)
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 0, cpus: 1) == 0)
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 1_600_000, elapsedUsec: 800_000, cpus: 1) == 100)
    }

    @Test func cpuPercentTreatsInvalidCpuCountAsOne() {
        #expect(RuntimeStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 0) == 100)
    }
}
