import Foundation

enum AppleStatsMath {
    static func cpuPercent(deltaUsec: Int64, elapsedUsec: Double, cpus: Int) -> Double {
        guard elapsedUsec > 0, deltaUsec > 0 else { return 0 }
        let safeCPUs = max(1, cpus)
        let percent = (Double(deltaUsec) / elapsedUsec / Double(safeCPUs)) * 100
        return min(100, max(0, percent))
    }
}
