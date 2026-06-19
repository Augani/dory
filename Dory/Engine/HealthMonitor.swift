import Foundation

enum Health: String, Sendable, Equatable {
    case starting, healthy, unhealthy, none
}

struct HealthcheckConfig: Sendable, Equatable {
    var interval: TimeInterval = 30
    var timeout: TimeInterval = 30
    var retries: Int = 3
    var startPeriod: TimeInterval = 0
}

/// Pure state machine implementing Docker healthcheck semantics. `record` is driven by probe
/// results; the actual exec probing is performed by the engine and fed in.
struct HealthMonitor: Sendable, Equatable {
    let config: HealthcheckConfig
    private(set) var state: Health = .starting
    private(set) var failingStreak: Int = 0

    init(config: HealthcheckConfig) { self.config = config }

    mutating func record(success: Bool, elapsed: TimeInterval) {
        if success {
            state = .healthy
            failingStreak = 0
            return
        }
        // Failures during the start period never mark the container unhealthy.
        if elapsed < config.startPeriod { return }
        failingStreak += 1
        if failingStreak >= max(1, config.retries) {
            state = .unhealthy
        }
    }
}
