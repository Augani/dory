import Foundation

enum KubeLogParser {
    nonisolated static func parse(_ raw: String) -> [LogLine] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map { parseLine(String($0)) }
    }

    nonisolated static func parseLine(_ line: String) -> LogLine {
        if let space = line.firstIndex(of: " ") {
            let prefix = line[line.startIndex..<space]
            if prefix.contains("T") && prefix.contains(":") {
                let message = String(line[line.index(after: space)...])
                return LogLine(timestamp: String(prefix), level: level(for: message), message: message)
            }
        }
        return LogLine(timestamp: "", level: level(for: line), message: line)
    }

    nonisolated static func level(for message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") { return .error }
        if upper.contains("WARN") { return .warn }
        if upper.contains("DEBUG") { return .debug }
        return .info
    }
}

nonisolated final class KubeLogStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [LogLine] {
        guard !chunk.isEmpty else { return [] }
        lock.lock()
        data.append(chunk)
        let lines = drainCompletedLines()
        lock.unlock()
        return lines
    }

    func flush() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let lineData = data
        data.removeAll(keepingCapacity: true)
        guard let text = String(data: lineData, encoding: .utf8), !text.isEmpty else { return [] }
        return [KubeLogParser.parseLine(text)]
    }

    private func drainCompletedLines() -> [LogLine] {
        var lines: [LogLine] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<newline)
            data.removeSubrange(data.startIndex...newline)
            guard let text = String(data: lineData, encoding: .utf8), !text.isEmpty else { continue }
            lines.append(KubeLogParser.parseLine(text))
        }
        return lines
    }
}
