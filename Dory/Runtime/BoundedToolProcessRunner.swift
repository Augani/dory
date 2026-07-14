import Foundation
import Darwin

nonisolated enum ToolProcessStream: Sendable {
    case stdout
    case stderr
}

nonisolated struct ToolCommandRequest: Sendable {
    enum OutputPolicy: Sendable, Equatable {
        case complete(maxBytes: Int)
        case tail(maxBytes: Int)
    }

    var executableURL: URL
    var arguments: [String]
    var workingDirectoryURL: URL
    var environment: [String: String]
    var timeout: TimeInterval
    var outputPolicy: OutputPolicy
    /// Called from the process-reader queues. Keep handlers nonblocking.
    var outputHandler: (@Sendable (ToolProcessStream, Data) -> Void)? = nil
}

nonisolated struct ToolCommandResult: Sendable, Equatable {
    var terminationStatus: Int32
    var stdout: String
    var stderr: String
    var outputTruncated: Bool
}

nonisolated protocol ToolCommandRunning: Sendable {
    func run(_ request: ToolCommandRequest) async throws -> ToolCommandResult
}

nonisolated enum ToolProcessError: Error, LocalizedError, Sendable, Equatable {
    case launch(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launch(let message): "Could not start helper process: \(message)"
        case .timedOut(let seconds): "Helper process timed out after \(Int(seconds)) seconds"
        }
    }
}

/// Executes a tool without a shell, drains both output streams concurrently, bounds retained
/// output, and terminates commands that are cancelled or exceed their operation deadline.
nonisolated final class BoundedToolProcessRunner: ToolCommandRunning, @unchecked Sendable {
    func run(_ request: ToolCommandRequest) async throws -> ToolCommandResult {
        let execution = ToolProcessExecution(request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

nonisolated private final class ToolProcessExecution: @unchecked Sendable {
    private let request: ToolCommandRequest
    private let lock = NSLock()
    private var process: Process?
    private var completion: ((Result<ToolCommandResult, Error>) -> Void)?
    private var completed = false
    private var cancelled = false
    private var timedOut = false
    private var watchdog: DispatchWorkItem?
    private var forcedKill: DispatchWorkItem?

    init(request: ToolCommandRequest) {
        self.request = request
    }

    func start(completion: @escaping (Result<ToolCommandResult, Error>) -> Void) {
        lock.lock()
        self.completion = completion
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled {
            finish(.failure(CancellationError()))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in launch() }
    }

    func cancel() {
        let running: Process?
        lock.lock()
        guard !completed else { lock.unlock(); return }
        cancelled = true
        running = process
        lock.unlock()
        if let running { terminate(running) }
    }

    private func launch() {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = BoundedProcessOutput(policy: request.outputPolicy)
        let stderr = BoundedProcessOutput(policy: request.outputPolicy)
        let outputHandler = request.outputHandler
        let readers = DispatchGroup()

        lock.lock()
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            finish(.failure(ToolProcessError.launch(error.localizedDescription)))
            return
        }

        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()

        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(
                stdoutPipe.fileHandleForReading,
                stream: .stdout,
                into: stdout,
                handler: outputHandler
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(
                stderrPipe.fileHandleForReading,
                stream: .stderr,
                into: stderr,
                handler: outputHandler
            )
            readers.leave()
        }

        if shouldCancel { terminate(process) }
        installWatchdog(for: process)
        process.waitUntilExit()
        cancelWatchdog()
        readers.wait()

        lock.lock()
        let didCancel = cancelled
        let didTimeOut = timedOut
        lock.unlock()

        if didCancel {
            finish(.failure(CancellationError()))
        } else if didTimeOut {
            finish(.failure(ToolProcessError.timedOut(request.timeout)))
        } else {
            finish(.success(ToolCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: stdout.string,
                stderr: stderr.string,
                outputTruncated: stdout.truncated || stderr.truncated
            )))
        }
    }

    private func installWatchdog(for process: Process) {
        let item = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process else { return }
            lock.lock()
            guard !completed, process.isRunning else { lock.unlock(); return }
            timedOut = true
            lock.unlock()
            terminate(process)
        }
        lock.lock()
        watchdog = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + request.timeout, execute: item)
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let item = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
        lock.lock()
        forcedKill?.cancel()
        forcedKill = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func cancelWatchdog() {
        lock.lock()
        watchdog?.cancel()
        forcedKill?.cancel()
        lock.unlock()
    }

    private func finish(_ result: Result<ToolCommandResult, Error>) {
        let callback: ((Result<ToolCommandResult, Error>) -> Void)?
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        watchdog?.cancel()
        forcedKill?.cancel()
        callback = completion
        completion = nil
        process = nil
        lock.unlock()
        callback?(result)
    }

    private static func drain(
        _ handle: FileHandle,
        stream: ToolProcessStream,
        into output: BoundedProcessOutput,
        handler: (@Sendable (ToolProcessStream, Data) -> Void)?
    ) {
        while true {
            let data = handle.readData(ofLength: 64 * 1024)
            if data.isEmpty { return }
            output.append(data)
            handler?(stream, data)
        }
    }
}

nonisolated private final class BoundedProcessOutput: @unchecked Sendable {
    private let policy: ToolCommandRequest.OutputPolicy
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false

    init(policy: ToolCommandRequest.OutputPolicy) {
        self.policy = policy
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch policy {
        case .complete(let maxBytes):
            let remaining = max(0, maxBytes - data.count)
            if chunk.count > remaining { didTruncate = true }
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
        case .tail(let maxBytes):
            if chunk.count >= maxBytes {
                data = Data(chunk.suffix(maxBytes))
                didTruncate = true
                return
            }
            data.append(chunk)
            if data.count > maxBytes {
                data.removeFirst(data.count - maxBytes)
                didTruncate = true
            }
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTruncate
    }
}
