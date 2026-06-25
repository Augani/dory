import Testing
@testable import Dory

struct AppleLogParseTests {
    @Test func timestampedLineKeepsTimeAndMessage() {
        let line = AppleLogParse.line("2026-06-18T12:00:00.123456789Z hello world")
        #expect(line.timestamp == "12:00:00.123")
        #expect(line.message == "hello world")
        #expect(line.level == .info)
    }

    @Test func timestampedLineDetectsLevelFromMessage() {
        let line = AppleLogParse.line("2026-06-18T12:00:00.123456789Z ERROR request failed")
        #expect(line.timestamp == "12:00:00.123")
        #expect(line.message == "ERROR request failed")
        #expect(line.level == .error)
    }

    @Test func unstampedLineFallsBackToWholeMessage() {
        let line = AppleLogParse.line("WARN no timestamp")
        #expect(line.timestamp == "")
        #expect(line.message == "WARN no timestamp")
        #expect(line.level == .warn)
    }

    @Test func parseDropsBlankLines() {
        let lines = AppleLogParse.parse("DEBUG one\n\nFATAL two\n")
        #expect(lines.map(\.level) == [.debug, .error])
        #expect(lines.map(\.message) == ["DEBUG one", "FATAL two"])
    }
}
