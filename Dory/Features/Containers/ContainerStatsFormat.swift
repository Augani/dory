import Foundation

enum ContainerStatsFormat {
    static func cpuSparkBars(_ history: [Double]) -> [Double] {
        history.map { min(100, max(0, $0 * 5)) }
    }

    static func logsPlainText(_ lines: [LogLine]) -> String {
        lines.map { "\($0.timestamp) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
    }
}
