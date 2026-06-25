import Foundation

enum AppleLogParse {
    static func parse(_ raw: String) -> [LogLine] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map { line(String($0)) }
    }

    static func line(_ raw: String) -> LogLine {
        let parts = raw.split(separator: " ", maxSplits: 1)
        var timestamp = ""
        var message = raw
        if parts.count == 2, parts[0].contains("T"), parts[0].contains(":") {
            timestamp = shortTime(String(parts[0]))
            message = String(parts[1])
        }
        return LogLine(timestamp: timestamp, level: level(for: message), message: message)
    }

    static func level(for message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") { return .error }
        if upper.contains("WARN") { return .warn }
        if upper.contains("DEBUG") { return .debug }
        return .info
    }

    private static func shortTime(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let after = iso[iso.index(after: tIndex)...]
        return String(after.prefix(12))
    }
}
