import Testing
@testable import Dory

struct ContainerStatsFormatTests {
    @Test func emptyHistoryYieldsNoBars() {
        #expect(ContainerStatsFormat.cpuSparkBars([]).isEmpty)
    }

    @Test func idleHistoryHasNoFabricatedFloor() {
        #expect(ContainerStatsFormat.cpuSparkBars([0, 0, 0]) == [0, 0, 0])
    }

    @Test func scalesAndClamps() {
        #expect(ContainerStatsFormat.cpuSparkBars([10, 20]) == [50, 100])
        #expect(ContainerStatsFormat.cpuSparkBars([50]) == [100])
    }

    @Test func logsPlainTextJoinsLines() {
        let lines = [
            LogLine(timestamp: "12:00", level: .info, message: "started"),
            LogLine(timestamp: "12:01", level: .error, message: "boom"),
        ]
        #expect(ContainerStatsFormat.logsPlainText(lines) == "12:00 INFO started\n12:01 ERROR boom")
    }

    @Test func logsPlainTextEmpty() {
        #expect(ContainerStatsFormat.logsPlainText([]) == "")
    }
}
