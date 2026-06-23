import Foundation

enum KubeLogParser {
    static func parse(_ raw: String) -> [LogLine] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map { slice in
            let line = String(slice)
            if let space = line.firstIndex(of: " ") {
                let prefix = line[line.startIndex..<space]
                if prefix.contains("T") && prefix.contains(":") {
                    let message = String(line[line.index(after: space)...])
                    return LogLine(timestamp: String(prefix), level: level(for: message), message: message)
                }
            }
            return LogLine(timestamp: "", level: level(for: line), message: line)
        }
    }

    static func level(for message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") { return .error }
        if upper.contains("WARN") { return .warn }
        if upper.contains("DEBUG") { return .debug }
        return .info
    }
}
