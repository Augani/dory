import Foundation

public struct IdleSleepConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var idleAfterSeconds: TimeInterval
    public var checkIntervalSeconds: TimeInterval

    public init(
        enabled: Bool = true,
        idleAfterSeconds: TimeInterval = 300,
        checkIntervalSeconds: TimeInterval = 30
    ) {
        self.enabled = enabled
        self.idleAfterSeconds = max(1, idleAfterSeconds)
        self.checkIntervalSeconds = max(1, checkIntervalSeconds)
    }
}

public final class IdleSleepScheduler: @unchecked Sendable {
    private let dockerTier: DockerTier
    private var configuration: IdleSleepConfiguration
    private let incidentWriter: IncidentWriter?
    private let queue = DispatchQueue(label: "dev.dory.doryd.idle-sleep")
    private var timer: DispatchSourceTimer?

    public init(
        dockerTier: DockerTier,
        configuration: IdleSleepConfiguration,
        incidentWriter: IncidentWriter? = nil
    ) {
        self.dockerTier = dockerTier
        self.configuration = configuration
        self.incidentWriter = incidentWriter
    }

    public var currentConfiguration: IdleSleepConfiguration {
        queue.sync { configuration }
    }

    public func start() {
        queue.sync {
            reconfigureTimer()
        }
    }

    public func update(configuration: IdleSleepConfiguration) {
        queue.sync {
            self.configuration = configuration
            reconfigureTimer()
        }
    }

    private func reconfigureTimer() {
        timer?.cancel()
        timer = nil
        guard configuration.enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + configuration.checkIntervalSeconds,
            repeating: configuration.checkIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.evaluate()
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func evaluate() {
        let configuration = self.configuration
        guard configuration.enabled else { return }
        guard dockerTier.status().state == .running else { return }
        if dockerTier.sleepForIdle(idleAfter: configuration.idleAfterSeconds) {
            incidentWriter?.record(
                type: "engine.idle_sleep",
                detail: "docker tier slept after \(Int(configuration.idleAfterSeconds))s idle"
            )
        }
    }

    deinit {
        stop()
    }
}
