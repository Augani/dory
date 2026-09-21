import DoryHV
import DorydKit
import Foundation

final class DesktopRuntimeGraphicsReadinessState: @unchecked Sendable {
    typealias Sender = @Sendable (VmmReadyMessage) throws -> Void
    typealias RenewalFailureHandler = @Sendable (Error) -> Void

    private let condition = NSCondition()
    private let sender: Sender
    private let renewalFailureHandler: RenewalFailureHandler
    private var selection: DoryRuntimeGraphicsSelection?
    private var publishedReady: VmmReadyMessage?

    init(
        selection: DoryRuntimeGraphicsSelection?,
        sender: @escaping Sender,
        renewalFailureHandler: @escaping RenewalFailureHandler = { _ in }
    ) {
        self.selection = selection
        self.sender = sender
        self.renewalFailureHandler = renewalFailureHandler
    }

    var snapshot: DoryRuntimeGraphicsSelection? {
        condition.withLock { selection }
    }

    var requiresRendererSynchronizedPublication: Bool {
        condition.withLock {
            selection?.accelerationLevel != .software
                && selection?.rendererGeneration != nil
        }
    }

    func publish(_ ready: VmmReadyMessage) throws {
        condition.lock()
        defer { condition.unlock() }
        var current = ready
        current.graphicsSelection = selection
        try sender(current)
        publishedReady = current
    }

    func apply(_ outcome: VirtioGPUStockFenceVerificationOutcome) {
        mutate { current in
            guard var selection = current else { return false }
            switch outcome {
            case .verified(let proofSHA256):
                guard selection.verificationState == .provisional else { return false }
                selection.verificationState = .verified
                selection.guestProducerFenceProofSHA256 = proofSHA256.lowercased()
            case .violated:
                guard selection.verificationState == .provisional else { return false }
                selection.accelerationLevel = .software
                selection.backend = .software
                selection.rendererGeneration = nil
                selection.rendererWorkerReceiptSHA256 = nil
                selection.guestProducerFenceProofSHA256 = nil
                selection.verificationState = .downgraded(.guestKernelLacksPrepareFB)
                selection.guestDriver = .software
            }
            guard selection.isValid else { return false }
            current = selection
            return true
        }
    }

    func recordFirstShaderCompletion(
        atUnixMilliseconds suppliedTimestamp: UInt64? = nil
    ) {
        let timestamp = suppliedTimestamp ?? Self.nowUnixMilliseconds()
        mutate { current in
            guard var selection = current,
                  selection.firstShaderCompletedAtUnixMilliseconds == nil else {
                return false
            }
            selection.firstShaderCompletedAtUnixMilliseconds = timestamp
            guard selection.isValid else { return false }
            current = selection
            return true
        }
    }

    func recordFirstPresentationCompletion(
        atUnixMilliseconds suppliedTimestamp: UInt64? = nil
    ) {
        let timestamp = suppliedTimestamp ?? Self.nowUnixMilliseconds()
        mutate { current in
            guard var selection = current,
                  selection.firstPresentationCompletedAtUnixMilliseconds == nil else {
                return false
            }
            let shader = selection.firstShaderCompletedAtUnixMilliseconds
            selection.firstPresentationCompletedAtUnixMilliseconds = max(
                timestamp,
                shader ?? timestamp
            )
            guard selection.isValid else { return false }
            current = selection
            return true
        }
    }

    func prepareRendererReplacement(_ launch: DesktopRendererWorkerLaunch) {
        mutate { current in
            guard var selection = current,
                  selection.accelerationLevel == .hardwareAccelerated3D else {
                return false
            }
            selection.rendererGeneration = launch.workerGeneration.rawValue
            selection.rendererWorkerReceiptSHA256 = launch.rendererWorkerReceiptSHA256
            selection.guestProducerFenceProofSHA256 = selection.verificationState == .provisional
                ? nil : launch.qualifiedProducerFenceAuthoritySHA256
            selection.firstShaderCompletedAtUnixMilliseconds = nil
            selection.firstPresentationCompletedAtUnixMilliseconds = nil
            guard selection.isValid else { return false }
            current = selection
            return true
        }
    }

    func publishRuntimeDetail(_ detail: String) {
        condition.lock()
        let renewal: VmmReadyMessage?
        if var ready = publishedReady {
            ready.detail = detail
            ready.graphicsSelection = selection
            publishedReady = ready
            renewal = ready
        } else {
            renewal = nil
        }
        condition.unlock()
        guard let renewal else { return }
        do {
            try sender(renewal)
        } catch {
            renewalFailureHandler(error)
        }
    }

    func waitForFirstPresentation(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while selection?.firstPresentationCompletedAtUnixMilliseconds == nil {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    private func mutate(
        _ body: (inout DoryRuntimeGraphicsSelection?) -> Bool
    ) {
        condition.lock()
        let changed = body(&selection)
        let renewal: VmmReadyMessage?
        if changed, var ready = publishedReady {
            ready.graphicsSelection = selection
            publishedReady = ready
            renewal = ready
        } else {
            renewal = nil
        }
        if changed { condition.broadcast() }
        condition.unlock()

        guard let renewal else { return }
        do {
            try sender(renewal)
        } catch {
            renewalFailureHandler(error)
        }
    }

    private static func nowUnixMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
