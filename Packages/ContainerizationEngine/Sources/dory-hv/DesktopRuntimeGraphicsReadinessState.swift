import DoryHV
import DorydKit
import Foundation

final class DesktopRuntimeGraphicsReadinessState: @unchecked Sendable {
    typealias Sender = @Sendable (VmmReadyMessage) throws -> Void
    typealias RenewalFailureHandler = @Sendable (Error) -> Void

    private let condition = NSCondition()
    /// Enqueue under `condition` so daemon renewals preserve the state-transition order. The
    /// sender runs on this lane after releasing the state lock; a verified generation must never
    /// overtake its provisional admission when callbacks arrive on different renderer threads.
    private let renewalQueue = DispatchQueue(label: "dev.dory.desktop-graphics-readiness-renewal")
    private let sender: Sender
    private let renewalFailureHandler: RenewalFailureHandler
    private var selection: DoryRuntimeGraphicsSelection?
    private var publishedReady: VmmReadyMessage?
    private var guestMachinePresentationSuspended = false
    private var rendererPresentationSuspended = false
    private var rendererRecoveryPending = false
    private var workloadReadyBeforeRendererLoss = false
    private var guestMachineEpoch: UInt64 = 1

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

    var currentGuestMachineEpoch: UInt64 {
        condition.withLock { guestMachineEpoch }
    }

    var requiresRendererSynchronizedPublication: Bool {
        condition.withLock {
            selection?.accelerationLevel != .software
                && selection?.rendererGeneration != nil
        }
    }

    var hasCompletedRendererPresentation: Bool {
        condition.withLock {
            selection?.accelerationLevel != .software
                && selection?.rendererGeneration != nil
                && selection?.firstPresentationCompletedAtUnixMilliseconds != nil
        }
    }

    /// Allows a caller to observe all renewals admitted before this call. Never call from the
    /// sender or its failure callback.
    func waitForPendingRenewals() {
        renewalQueue.sync { }
    }

    func publish(
        _ ready: VmmReadyMessage,
        expectedGuestMachineEpoch: UInt64? = nil
    ) throws {
        condition.lock()
        if let expectedGuestMachineEpoch, expectedGuestMachineEpoch != guestMachineEpoch {
            condition.unlock()
            throw VMError.bootFailure("stale guest boot cannot publish desktop readiness")
        }
        var current = ready
        current.graphicsSelection = selection
        let previousReady = publishedReady
        publishedReady = current
        let receipt = ReadinessSendReceipt()
        let outgoing = current
        renewalQueue.async { [sender] in
            receipt.complete(Result { try sender(outgoing) })
        }
        condition.unlock()
        do {
            try receipt.wait()
        } catch {
            condition.withLock {
                if publishedReady == outgoing { publishedReady = previousReady }
            }
            throw error
        }
    }

    func apply(
        _ outcome: VirtioGPUStockFenceVerificationOutcome,
        workerGeneration: UInt64? = nil
    ) {
        mutate { current in
            guard !guestMachinePresentationSuspended, !rendererPresentationSuspended else { return false }
            guard var selection = current else { return false }
            if let workerGeneration,
               selection.rendererGeneration != workerGeneration { return false }
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
        workerGeneration: UInt64? = nil,
        atUnixMilliseconds suppliedTimestamp: UInt64? = nil
    ) {
        let timestamp = suppliedTimestamp ?? Self.nowUnixMilliseconds()
        mutate { current in
            guard !guestMachinePresentationSuspended, !rendererPresentationSuspended,
                  var selection = current,
                  workerGeneration == nil
                    || selection.rendererGeneration == workerGeneration,
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
        workerGeneration: UInt64? = nil,
        atUnixMilliseconds suppliedTimestamp: UInt64? = nil
    ) {
        let timestamp = suppliedTimestamp ?? Self.nowUnixMilliseconds()
        mutate { current in
            guard !guestMachinePresentationSuspended, !rendererPresentationSuspended,
                  var selection = current,
                  workerGeneration == nil
                    || selection.rendererGeneration == workerGeneration,
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
        prepareRendererReplacement(
            workerGeneration: launch.workerGeneration.rawValue,
            rendererWorkerReceiptSHA256: launch.rendererWorkerReceiptSHA256
        )
    }

    /// Device loss revokes observations immediately, before a guest reset or replacement exists.
    /// Keep the signed admission identity and running guest boot; neither is live GPU proof.
    /// Late callbacks from the failed generation cannot restore success while it is suspended.
    func rendererBecameUnavailable(workerGeneration: UInt64, detail: String) {
        condition.lock()
        defer { condition.unlock() }
        guard var lost = selection,
              lost.accelerationLevel == .hardwareAccelerated3D,
              lost.rendererGeneration == workerGeneration else { return }
        lost.verificationState = .provisional
        lost.guestProducerFenceProofSHA256 = nil
        lost.firstShaderCompletedAtUnixMilliseconds = nil
        lost.firstPresentationCompletedAtUnixMilliseconds = nil
        guard lost.isValid else { return }
        rendererPresentationSuspended = true
        selection = lost
        if var ready = publishedReady {
            if !rendererRecoveryPending { workloadReadyBeforeRendererLoss = ready.workloadReady }
            rendererRecoveryPending = true
            ready.graphicsSelection = lost
            ready.desktopVisible = false
            ready.workloadReady = false
            ready.detail = detail
            publishedReady = ready
            enqueueRenewal(ready)
        }
        condition.broadcast()
    }

    /// A full guest reset starts a new boot even if the same pristine renderer worker can be
    /// reused. A fence, shader, or displayed frame from the previous boot must never establish
    /// the new boot's observed graphics state.
    func prepareGuestMachineReset() {
        condition.lock()
        guestMachineEpoch = guestMachineEpoch == .max ? 1 : guestMachineEpoch + 1
        guestMachinePresentationSuspended = true
        rendererRecoveryPending = false
        workloadReadyBeforeRendererLoss = false
        if var reset = selection {
            reset.firstShaderCompletedAtUnixMilliseconds = nil
            reset.firstPresentationCompletedAtUnixMilliseconds = nil
            if reset.accelerationLevel == .hardwareAccelerated3D {
                reset.verificationState = .provisional
                reset.guestProducerFenceProofSHA256 = nil
            }
            if reset.isValid { selection = reset }
        }
        if var ready = publishedReady {
            ready.graphicsSelection = selection
            ready.guestBooted = false
            ready.toolsConnected = false
            ready.desktopVisible = false
            ready.workloadReady = false
            ready.detail = "Guest rebooting; waiting for a new desktop presentation."
            publishedReady = ready
            enqueueRenewal(ready)
        }
        condition.broadcast()
        condition.unlock()
    }

    func resumeGuestMachinePresentation() {
        condition.withLock { guestMachinePresentationSuspended = false }
    }

    func prepareRendererReplacement(
        workerGeneration: UInt64,
        rendererWorkerReceiptSHA256: String
    ) {
        mutate { current in
            guard var selection = current,
                  selection.accelerationLevel == .hardwareAccelerated3D,
                  let previousGeneration = selection.rendererGeneration,
                  workerGeneration > previousGeneration else {
                return false
            }
            selection.rendererGeneration = workerGeneration
            selection.rendererWorkerReceiptSHA256 = rendererWorkerReceiptSHA256
            // A prior worker's guest fence and presentation observations cannot prove this
            // generation. The signed replacement receipt is admission evidence only.
            selection.verificationState = .provisional
            selection.guestProducerFenceProofSHA256 = nil
            selection.firstShaderCompletedAtUnixMilliseconds = nil
            selection.firstPresentationCompletedAtUnixMilliseconds = nil
            guard selection.isValid else { return false }
            rendererPresentationSuspended = false
            current = selection
            return true
        }
    }

    func publishRuntimeDetail(_ detail: String) {
        condition.lock()
        if var ready = publishedReady {
            ready.detail = detail
            ready.graphicsSelection = selection
            publishedReady = ready
            enqueueRenewal(ready)
        }
        condition.unlock()
    }

    func waitForFirstPresentation(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        let expectedEpoch = guestMachineEpoch
        while selection?.firstPresentationCompletedAtUnixMilliseconds == nil {
            guard !rendererPresentationSuspended else { return false }
            guard guestMachineEpoch == expectedEpoch else { return false }
            guard condition.wait(until: deadline) else { return false }
        }
        return guestMachineEpoch == expectedEpoch
    }

    private func mutate(
        _ body: (inout DoryRuntimeGraphicsSelection?) -> Bool
    ) {
        condition.lock()
        let changed = body(&selection)
        if changed, var ready = publishedReady {
            ready.graphicsSelection = selection
            if rendererRecoveryPending {
                ready.desktopVisible = !rendererPresentationSuspended
                    && !guestMachinePresentationSuspended
                    && selection?.firstPresentationCompletedAtUnixMilliseconds != nil
                ready.workloadReady = workloadReadyBeforeRendererLoss && ready.desktopVisible
                    && selection?.firstShaderCompletedAtUnixMilliseconds != nil
                    && selection?.verificationState == .verified
                if ready.workloadReady { rendererRecoveryPending = false }
            }
            publishedReady = ready
            enqueueRenewal(ready)
        }
        if changed { condition.broadcast() }
        condition.unlock()
    }

    /// Must be called while `condition` is held. No network I/O or caller callback executes
    /// under that lock, and all admitted generations reach the daemon in their mutation order.
    private func enqueueRenewal(_ ready: VmmReadyMessage) {
        renewalQueue.async { [sender, renewalFailureHandler] in
            do {
                try sender(ready)
            } catch {
                renewalFailureHandler(error)
            }
        }
    }

    private static func nowUnixMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }
}

private final class ReadinessSendReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func complete(_ result: Result<Void, Error>) {
        lock.withLock { self.result = result }
        completed.signal()
    }

    func wait() throws {
        completed.wait()
        try lock.withLock { try result!.get() }
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
