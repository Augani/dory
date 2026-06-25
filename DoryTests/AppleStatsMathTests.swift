import Foundation
import Testing
@testable import Dory

struct AppleStatsMathTests {
    @Test func cpuPercentNormalizesByCpuCount() {
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 1) == 100)
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 4) == 25)
    }

    @Test func cpuPercentClampsInvalidAndOverloadedSamples() {
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 0, elapsedUsec: 800_000, cpus: 1) == 0)
        #expect(AppleStatsMath.cpuPercent(deltaUsec: -1, elapsedUsec: 800_000, cpus: 1) == 0)
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 0, cpus: 1) == 0)
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 1_600_000, elapsedUsec: 800_000, cpus: 1) == 100)
    }

    @Test func cpuPercentTreatsInvalidCpuCountAsOne() {
        #expect(AppleStatsMath.cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 0) == 100)
    }

    @Test func statsDecodeFlexibleCpuCountersAndCounts() throws {
        let json = Data(#"{"id":"c1","cpuUsageUsec":"1600000","memoryUsageBytes":"1024","memoryLimitBytes":2048,"online_cpus":"4"}"#.utf8)
        let stats = try JSONDecoder().decode(ACStats.self, from: json)
        #expect(stats.id == "c1")
        #expect(stats.cpuUsageUsec == 1_600_000)
        #expect(stats.memoryUsageBytes == 1_024)
        #expect(stats.memoryLimitBytes == 2_048)
        #expect(stats.cpus == 4)
    }
}
