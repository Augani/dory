import Foundation

/// Keeps the per-user terminal integration true while doryd is alive. This covers users deleting
/// stale shims or upgrading the app without needing a manual `dory install` repair step.
public final class HostCLIReconciler: @unchecked Sendable {
    private let installer: HostCLIInstaller
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.doryd.host-cli")
    private var timer: DispatchSourceTimer?

    public init(installer: HostCLIInstaller, interval: TimeInterval = 300) {
        self.installer = installer
        self.interval = max(30, interval)
    }

    @discardableResult
    public func reconcileNow() -> HostCLIInstallResult {
        installer.install()
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [installer] in
                _ = installer.install()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        stop()
    }
}
