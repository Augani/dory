import AppKit
import Darwin
import DoryRendererWorkerWireContracts
import Foundation

enum DoryApplicationProcessLaunchError: Error, CustomStringConvertible {
    case invalidDesktopHelperBundle(String)
    case launchFailed(String)
    case launchTimedOut
    case invalidProcessIdentifier
    case monitorFailed(Int32)

    var description: String {
        switch self {
        case .invalidDesktopHelperBundle(let detail):
            return "invalid Dory desktop helper application bundle: \(detail)"
        case .launchFailed(let detail):
            return "LaunchServices could not start DoryHVRunner: \(detail)"
        case .launchTimedOut:
            return "LaunchServices timed out while starting DoryHVRunner"
        case .invalidProcessIdentifier:
            return "LaunchServices returned an invalid DoryHVRunner process identifier"
        case .monitorFailed(let code):
            return "could not monitor DoryHVRunner: \(String(cString: strerror(code)))"
        }
    }
}

enum DoryDesktopHelperApplicationKind: Equatable, Sendable {
    case rawHVRunner
    case virtualizationVMM

    var signedIdentity: DoryLiveRunnerCodeIdentity {
        switch self {
        case .rawHVRunner: .signedApplication
        case .virtualizationVMM: .signedVirtualizationApplication
        }
    }
}

struct DoryRunnerApplicationBundle: Equatable, Sendable {
    let applicationURL: URL
    let executableURL: URL
    let kind: DoryDesktopHelperApplicationKind

    init(executablePath: String) throws {
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let macOSDirectory = executable.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let application = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              application.pathExtension == "app",
              let bundle = Bundle(url: application),
              bundle.executableURL?.standardizedFileURL == executable else {
            throw DoryApplicationProcessLaunchError.invalidDesktopHelperBundle(executablePath)
        }
        switch bundle.bundleIdentifier {
        case DoryRendererWorkerIdentity.runnerBundleIdentifier:
            kind = .rawHVRunner
        case DoryDesktopApplicationCodeIdentity.vmmBundleIdentifier:
            kind = .virtualizationVMM
        default:
            throw DoryApplicationProcessLaunchError.invalidDesktopHelperBundle(executablePath)
        }
        applicationURL = application
        executableURL = executable
    }
}

protocol DoryApplicationTerminationControlling: Sendable {
    var isTerminated: Bool { get }
    @discardableResult func forceTerminate() -> Bool
}

struct DoryWorkspaceApplicationLaunch: DoryApplicationTerminationControlling, @unchecked Sendable {
    let application: NSRunningApplication

    var processIdentifier: pid_t { application.processIdentifier }
    var isTerminated: Bool {
        application.isTerminated
            || NSRunningApplication(processIdentifier: processIdentifier) == nil
    }

    @discardableResult
    func forceTerminate() -> Bool {
        application.forceTerminate()
    }

    @discardableResult
    func terminate() -> Bool {
        application.terminate()
    }
}

/// Retains an exact LaunchServices application after a bounded daemon-side cleanup attempt could
/// not prove termination. Retries run on a private queue, so a stuck AppKit termination request can
/// neither block doryd's machine lock nor release the only exact-process handle prematurely.
final class DoryApplicationTerminalRetirement: @unchecked Sendable {
    private let application: any DoryApplicationTerminationControlling
    private let retryDelay: TimeInterval
    private let queue: DispatchQueue
    private let onRetired: @Sendable () -> Void
    private let completion = DispatchGroup()

    private init(
        application: any DoryApplicationTerminationControlling,
        retryDelay: TimeInterval,
        onRetired: @escaping @Sendable () -> Void
    ) {
        self.application = application
        self.retryDelay = max(0.001, retryDelay)
        queue = DispatchQueue(label: "dev.dory.application-terminal-retirement", qos: .utility)
        self.onRetired = onRetired
        completion.enter()
    }

    @discardableResult
    static func begin(
        application: any DoryApplicationTerminationControlling,
        retryDelay: TimeInterval = 1,
        onRetired: @escaping @Sendable () -> Void = {}
    ) -> DoryApplicationTerminalRetirement {
        let retirement = DoryApplicationTerminalRetirement(
            application: application,
            retryDelay: retryDelay,
            onRetired: onRetired
        )
        retirement.queue.async { retirement.attempt() }
        return retirement
    }

    func waitForTermination(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func waitForTermination() {
        completion.wait()
    }

    private func attempt() {
        guard !application.isTerminated else {
            onRetired()
            completion.leave()
            return
        }
        _ = application.forceTerminate()
        queue.asyncAfter(deadline: .now() + retryDelay) { [self] in
            attempt()
        }
    }
}

/// Uses LaunchServices rather than making a desktop helper a daemon child. That gives TCC the
/// signed DoryHVRunner or DoryVMM bundle as the responsible Camera/Microphone identity. The helper
/// still receives no runtime object authority until the authenticated descriptor gate completes.
final class DoryWorkspaceApplicationLauncher: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<DoryWorkspaceApplicationLaunch, Error>?
        private var timedOut = false

        func finish(application: NSRunningApplication?, error: Error?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if timedOut {
                // The caller has already torn down the one-shot authority socket. A late
                // LaunchServices completion must not leave a runner blocked forever with no
                // supervisor. Retain the exact application while non-cooperative termination is
                // retried asynchronously; this callback must remain bounded because it runs on
                // LaunchServices' completion path.
                if let application {
                    DoryApplicationTerminalRetirement.begin(
                        application: DoryWorkspaceApplicationLaunch(application: application)
                    )
                }
                return false
            }
            if let error {
                result = .failure(error)
            } else if let application {
                result = .success(DoryWorkspaceApplicationLaunch(application: application))
            } else {
                result = .failure(DoryApplicationProcessLaunchError.launchFailed(
                    "completion returned neither an application nor an error"
                ))
            }
            return true
        }

        func takeResult() -> Result<DoryWorkspaceApplicationLaunch, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func markTimedOutIfPending() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return false }
            timedOut = true
            return true
        }
    }

    func launch(
        bundle: DoryRunnerApplicationBundle,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 30
    ) throws -> DoryWorkspaceApplicationLaunch {
        let completion = Completion()
        let completed = DispatchSemaphore(value: 0)
        let invoke: @MainActor @Sendable () -> Void = {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.environment = environment
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(
                at: bundle.applicationURL,
                configuration: configuration
            ) { application, error in
                if completion.finish(application: application, error: error) {
                    completed.signal()
                }
            }
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        if Thread.isMainThread {
            MainActor.assumeIsolated { invoke() }
            while completion.takeResult() == nil, Date() < deadline {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
        } else {
            DispatchQueue.main.async { invoke() }
            _ = completed.wait(timeout: .now() + max(1, timeout))
        }
        if completion.markTimedOutIfPending() {
            throw DoryApplicationProcessLaunchError.launchTimedOut
        }
        let launch = try completion.takeResult()!.get()
        guard launch.processIdentifier > 0 else {
            throw DoryApplicationProcessLaunchError.invalidProcessIdentifier
        }
        return launch
    }
}

/// EVFILT_PROC observes the exact non-child process object selected by LaunchServices. Darwin's
/// NOTE_EXITSTATUS is available when the observer may signal the target (doryd and the runner are
/// the same user), preserving the existing restart/error-status behavior without pretending the
/// runner is a waitpid-owned child.
final class DoryApplicationProcessMonitor: @unchecked Sendable {
    let pid: pid_t
    private let queueDescriptor: Int32
    private let terminationObservedBeforeWait: Bool
    private let terminationObserved: @Sendable () -> Bool

    init(
        pid: pid_t,
        terminationObservedAfterRegistration: @escaping @Sendable () -> Bool = { false }
    ) throws {
        self.pid = pid
        terminationObserved = terminationObservedAfterRegistration
        queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            throw DoryApplicationProcessLaunchError.monitorFailed(errno)
        }
        var registration = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: NOTE_EXIT | UInt32(bitPattern: NOTE_EXITSTATUS),
            data: 0,
            udata: nil
        )
        let result = kevent(
            queueDescriptor,
            &registration,
            1,
            nil,
            0,
            nil
        )
        guard result == 0 else {
            let code = errno
            Darwin.close(queueDescriptor)
            throw DoryApplicationProcessLaunchError.monitorFailed(code)
        }
        // EVFILT_PROC observes exits after attachment. LaunchServices can report a very short-lived
        // application just before it exits, so close the completion-to-registration race by
        // checking the retained NSRunningApplication immediately after the knote is installed.
        // If the exit preceded registration there is no truthful wait status to decode.
        terminationObservedBeforeWait = terminationObservedAfterRegistration()
    }

    func waitForTermination() -> HvProcessTermination {
        waitForTermination(timeout: nil)!
    }

    /// A bounded wait is used only by launch-failure cleanup. Normal supervision keeps its
    /// indefinite wait on a utility queue. A timeout consumes no knote, so the same exact-process
    /// monitor remains valid for the terminal retirement path or a later supervised wait.
    func waitForTermination(timeout: TimeInterval) -> HvProcessTermination? {
        waitForTermination(timeout: Optional(max(0, timeout)))
    }

    private func waitForTermination(timeout: TimeInterval?) -> HvProcessTermination? {
        if terminationObservedBeforeWait {
            return HvProcessTermination(
                status: 0,
                wasUncaughtSignal: false,
                statusIsKnown: false
            )
        }
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var event = kevent()
        while true {
            var timeoutValue: timespec?
            if let deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    return terminationObserved()
                        ? HvProcessTermination(
                            status: 0,
                            wasUncaughtSignal: false,
                            statusIsKnown: false
                        )
                        : nil
                }
                let wholeSeconds = floor(remaining)
                timeoutValue = timespec(
                    tv_sec: Int(wholeSeconds),
                    tv_nsec: Int((remaining - wholeSeconds) * 1_000_000_000)
                )
            }
            let result: Int32
            if var timeoutValue {
                result = withUnsafePointer(to: &timeoutValue) { timeoutPointer in
                    kevent(queueDescriptor, nil, 0, &event, 1, timeoutPointer)
                }
            } else {
                result = kevent(queueDescriptor, nil, 0, &event, 1, nil)
            }
            if result > 0 {
                let rawStatus = Int32(truncatingIfNeeded: event.data)
                return Self.decode(rawStatus: rawStatus)
            }
            if result == 0 {
                return terminationObserved()
                    ? HvProcessTermination(
                        status: 0,
                        wasUncaughtSignal: false,
                        statusIsKnown: false
                    )
                    : nil
            }
            if errno == EINTR { continue }

            // A monitor error is not proof that the application exited. Fall back to the retained
            // exact-process observation instead of publishing errno as an exit status and freeing
            // VM authority while the runner may still be alive. Bounded callers still return at
            // their deadline; normal supervision polls only on this exceptional path.
            while !terminationObserved() {
                if let deadline,
                   ProcessInfo.processInfo.systemUptime >= deadline {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return HvProcessTermination(
                status: 0,
                wasUncaughtSignal: false,
                statusIsKnown: false
            )
        }
    }

    private static func decode(rawStatus: Int32) -> HvProcessTermination {
        let signal = rawStatus & 0x7f
        if signal == 0 {
            return HvProcessTermination(
                status: (rawStatus >> 8) & 0xff,
                wasUncaughtSignal: false
            )
        }
        return HvProcessTermination(status: signal, wasUncaughtSignal: true)
    }

    deinit { Darwin.close(queueDescriptor) }
}
