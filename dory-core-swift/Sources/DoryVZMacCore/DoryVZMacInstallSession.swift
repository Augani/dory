import Foundation

/// Bridges one Apple installer invocation to Swift cancellation. In particular, cancellation
/// must neither cancel NSProgress before install() is invoked nor return while Apple still owns
/// the VM. Only the installer's completion callback settles the underlying operation.
@MainActor
final class DoryVZMacInstallSession {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    private enum Phase { case ready, starting, installing, finished }

    private let startInstallation: @MainActor (@escaping Completion) -> Void
    private let cancelInstallation: @MainActor () -> Void
    private var phase: Phase = .ready
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancellationError: Error?
    private var underlyingCancellationSent = false

    init(
        start: @escaping @MainActor (@escaping Completion) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        startInstallation = start
        cancelInstallation = cancel
    }

    var isInstalling: Bool {
        switch phase {
        case .starting, .installing: true
        case .ready, .finished: false
        }
    }

    var isFinished: Bool { phase == .finished }

    func run() async throws {
        guard case .ready = phase else {
            throw DoryVZMacInstallJournalError.invalid("installer session is single-use")
        }
        if let cancellationError { throw cancellationError }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                phase = .starting
                startInstallation { [weak self] result in
                    Task { @MainActor in self?.complete(result) }
                }
                // A synchronous start hook can request cancellation reentrantly. Defer the
                // underlying Progress.cancel() until install(completionHandler:) has returned.
                if case .starting = phase { phase = .installing }
                if Task.isCancelled { cancel() }
                sendCancellationIfNeeded()
            }
            // A successful callback and onCancel's actor hop can be queued in either order.
            // The caller's cancellation flag is the final publication fence in both cases.
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Also used when durable progress persistence fails. The original error is preserved even
    /// if Apple subsequently reports success or its generic cancellation error.
    func cancel(error: Error = CancellationError()) {
        guard phase != .finished else { return }
        if cancellationError == nil { cancellationError = error }
        sendCancellationIfNeeded()
    }

    private func sendCancellationIfNeeded() {
        guard case .installing = phase, cancellationError != nil,
              !underlyingCancellationSent else { return }
        underlyingCancellationSent = true
        cancelInstallation()
    }

    private func complete(_ result: Result<Void, Error>) {
        guard let continuation, phase != .finished else { return }
        self.continuation = nil
        phase = .finished
        if let cancellationError {
            continuation.resume(throwing: cancellationError)
        } else {
            continuation.resume(with: result)
        }
    }
}
