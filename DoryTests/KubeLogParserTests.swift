import Foundation
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

    @Test func streamBufferHoldsPartialLinesUntilComplete() {
        let buffer = KubeLogStreamBuffer()

        #expect(buffer.append(Data("2026-06-23T10:00:00Z partial".utf8)).isEmpty)
        let completed = buffer.append(Data(" line\nnext".utf8))

        #expect(completed.count == 1)
        #expect(completed[0].timestamp == "2026-06-23T10:00:00Z")
        #expect(completed[0].message == "partial line")
    }

    @Test func streamBufferFlushesFinalLineWithoutNewline() {
        let buffer = KubeLogStreamBuffer()

        _ = buffer.append(Data("2026-06-23T10:00:00Z final line".utf8))
        let flushed = buffer.flush()

        #expect(flushed.count == 1)
        #expect(flushed[0].timestamp == "2026-06-23T10:00:00Z")
        #expect(flushed[0].message == "final line")
        #expect(buffer.flush().isEmpty)
    }
}
