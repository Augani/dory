import Darwin
import Foundation

public struct HvRestartPolicy: Sendable, Equatable {
    public var maxRestarts: Int
    public var delaySeconds: TimeInterval

    public init(maxRestarts: Int = 0, delaySeconds: TimeInterval = 0.25) {
        self.maxRestarts = max(0, maxRestarts)
        self.delaySeconds = max(0, delaySeconds)
    }

    public static let none = HvRestartPolicy()
}

public struct HvProcessConfiguration: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var logPath: String?
    public var restartPolicy: HvRestartPolicy

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        logPath: String? = nil,
        restartPolicy: HvRestartPolicy = .none
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.logPath = logPath
        self.restartPolicy = restartPolicy
    }
}

public final class HvProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-hv is already running"
            case .executableMissing(let path):
                return "dory-hv executable missing: \(path)"
            }
        }
    }

    private let configuration: HvProcessConfiguration
    private let lock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false
    private var suspended = false
    private var restartCount = 0
    private var lastTerminationStatus: Int32?
    private var lastLaunchError: String?

    public init(configuration: HvProcessConfiguration) {
        self.configuration = configuration
    }

    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true {
            throw ProcessError.alreadyRunning
        }
        stopping = false
        suspended = false
        restartCount = 0
        lastTerminationStatus = nil
        lastLaunchError = nil
        try launchLocked()
    }

    private func launchLocked() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw ProcessError.executableMissing(configuration.executablePath)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: configuration.executablePath)
        task.arguments = configuration.arguments
        if !configuration.environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        }
        let log = Self.openAppendLog(configuration.logPath)
        task.standardOutput = log ?? FileHandle.standardError
        task.standardError = log ?? FileHandle.standardError
        task.terminationHandler = { [weak self] task in
            self?.handleTermination(task)
        }
        try task.run()
        process = task
        logHandle = log
    }

    private static func openAppendLog(_ path: String?) -> FileHandle? {
        guard let path else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func handleTermination(_ task: Process) {
        let oldLog: FileHandle?
        let shouldRestart: Bool
        let delay: TimeInterval
        lock.lock()
        guard process === task else {
            lock.unlock()
            return
        }
        lastTerminationStatus = task.terminationStatus
        process = nil
        suspended = false
        oldLog = logHandle
        logHandle = nil
        shouldRestart = !stopping && restartCount < configuration.restartPolicy.maxRestarts
        if shouldRestart {
            restartCount += 1
        }
        delay = configuration.restartPolicy.delaySeconds
        lock.unlock()
        try? oldLog?.close()

        guard shouldRestart else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartAfterUnexpectedExit()
        }
    }

    private func restartAfterUnexpectedExit() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, process == nil else { return }
        do {
            try launchLocked()
        } catch {
            lastLaunchError = "\(error)"
        }
    }

    public var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended && process?.isRunning == true
    }

    @discardableResult
    public func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if suspended { return true }
        guard kill(process.processIdentifier, SIGSTOP) == 0 else { return false }
        suspended = true
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if !suspended { return true }
        guard kill(process.processIdentifier, SIGCONT) == 0 else { return false }
        suspended = false
        return true
    }

    public func stop(signal: Int32 = SIGTERM, timeout: TimeInterval = 5) {
        let task: Process?
        let oldLog: FileHandle?
        let wasSuspended: Bool
        lock.lock()
        stopping = true
        task = process
        oldLog = logHandle
        wasSuspended = suspended
        suspended = false
        lock.unlock()

        guard let task, task.isRunning else {
            try? oldLog?.close()
            return
        }
        if wasSuspended {
            kill(task.processIdentifier, SIGCONT)
        }
        kill(task.processIdentifier, signal)

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
        }

        lock.lock()
        if process === task {
            process = nil
            logHandle = nil
            suspended = false
        }
        lock.unlock()
        try? oldLog?.close()
    }

    deinit {
        stop()
    }
}
