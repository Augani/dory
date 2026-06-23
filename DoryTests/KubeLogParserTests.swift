import Testing
@testable import Dory

struct KubeLogParserTests {
    @Test func timestampSplit() {
        let lines = KubeLogParser.parse("2026-06-23T10:00:00Z hello world")
        #expect(lines.count == 1)
        #expect(lines[0].timestamp == "2026-06-23T10:00:00Z")
        #expect(lines[0].message == "hello world")
    }
    @Test func errorLevelInferred() {
        #expect(KubeLogParser.parse("2026-06-23T10:00:00Z ERROR boom")[0].level == .error)
    }
    @Test func plainLineHasEmptyTimestamp() {
        let lines = KubeLogParser.parse("just a message")
        #expect(lines[0].timestamp == "")
        #expect(lines[0].message == "just a message")
    }
    @Test func emptyInput() {
        #expect(KubeLogParser.parse("").isEmpty)
    }
}
