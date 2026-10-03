import DoryHV
import DoryOperations
import DorydKit
import Foundation
import Testing
@testable import dory_hv

@Suite struct DesktopRuntimeGraphicsReadinessStateTests {
    @Test func verificationAndPresentationRenewPublishedReadinessTruthfully() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        #expect(!state.hasCompletedRendererPresentation)
        try state.publish(readyMessage())
        state.recordFirstShaderCompletion(atUnixMilliseconds: 10)
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)))
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 11)
        state.waitForPendingRenewals()

        let selection = try #require(state.snapshot)
        #expect(selection.verificationState == .verified)
        #expect(selection.guestProducerFenceProofSHA256 == String(repeating: "c", count: 64))
        #expect(selection.firstShaderCompletedAtUnixMilliseconds == 10)
        #expect(selection.firstPresentationCompletedAtUnixMilliseconds == 11)
        #expect(state.hasCompletedRendererPresentation)
        #expect(selection.isValid)
        #expect(recorder.values.last?.graphicsSelection == selection)
        #expect(recorder.values.count == 4)
    }

    @Test func violationDowngradesReceiptAndNoLongerRequiresMetalPublication() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        try state.publish(readyMessage())
        state.apply(.violated)
        state.recordFirstShaderCompletion(atUnixMilliseconds: 20)
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 21)
        state.waitForPendingRenewals()

        let selection = try #require(state.snapshot)
        #expect(selection.accelerationLevel == .software)
        #expect(selection.backend == .software)
        #expect(selection.verificationState == .downgraded(.guestKernelLacksPrepareFB))
        #expect(selection.guestDriver == .software)
        #expect(selection.rendererGeneration == nil)
        #expect(selection.rendererWorkerReceiptSHA256 == nil)
        #expect(selection.firstShaderCompletedAtUnixMilliseconds == 20)
        #expect(selection.firstPresentationCompletedAtUnixMilliseconds == 21)
        #expect(selection.isValid)
        #expect(!state.requiresRendererSynchronizedPublication)
        #expect(recorder.values.last?.graphicsSelection == selection)
    }

    @Test func rendererFailureDetailRenewsPublishedRuntimeStatus() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        try state.publish(readyMessage())

        state.publishRuntimeDetail(
            "Graphics renderer stopped; the VM is still running. worker exited"
        )
        state.waitForPendingRenewals()

        #expect(recorder.values.count == 2)
        #expect(
            recorder.values.last?.detail
                == "Graphics renderer stopped; the VM is still running. worker exited"
        )
        #expect(recorder.values.last?.graphicsSelection == state.snapshot)
    }

    @Test func workerLossRevokesLiveProofBeforeResetAndOnlyFreshGenerationCanRecover() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(), sender: { recorder.record($0) }
        )
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)), workerGeneration: 9)
        state.recordFirstShaderCompletion(workerGeneration: 9, atUnixMilliseconds: 10)
        state.recordFirstPresentationCompletion(workerGeneration: 9, atUnixMilliseconds: 11)
        try state.publish(readyMessage())
        let bootEpoch = state.currentGuestMachineEpoch
        let original = state.snapshot
        state.rendererBecameUnavailable(workerGeneration: 8, detail: "stale loss")
        #expect(state.snapshot == original)
        state.rendererBecameUnavailable(workerGeneration: 9, detail: "worker exited; guest still running")
        state.waitForPendingRenewals()
        let lost = try #require(state.snapshot)
        #expect(lost.isValid)
        #expect(lost.rendererGeneration == 9)
        #expect(lost.verificationState == .provisional)
        #expect(lost.guestProducerFenceProofSHA256 == nil)
        #expect(lost.firstShaderCompletedAtUnixMilliseconds == nil)
        #expect(lost.firstPresentationCompletedAtUnixMilliseconds == nil)
        #expect(state.currentGuestMachineEpoch == bootEpoch)
        #expect(recorder.values.last?.guestBooted == true)
        #expect(recorder.values.last?.desktopVisible == false)
        #expect(recorder.values.last?.workloadReady == false)
        #expect(!state.waitForFirstPresentation(timeout: 0.01))
        state.resumeGuestMachinePresentation()
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)), workerGeneration: 9)
        state.recordFirstShaderCompletion(workerGeneration: 9, atUnixMilliseconds: 12)
        state.recordFirstPresentationCompletion(workerGeneration: 9, atUnixMilliseconds: 13)
        #expect(state.snapshot == lost)
        state.prepareRendererReplacement(workerGeneration: 10, rendererWorkerReceiptSHA256: String(repeating: "d", count: 64))
        state.rendererBecameUnavailable(workerGeneration: 9, detail: "late retired loss")
        state.recordFirstShaderCompletion(workerGeneration: 10, atUnixMilliseconds: 14)
        state.recordFirstPresentationCompletion(workerGeneration: 10, atUnixMilliseconds: 15)
        state.waitForPendingRenewals()
        #expect(recorder.values.last?.desktopVisible == true)
        #expect(recorder.values.last?.workloadReady == false)
        state.apply(.verified(proofSHA256: String(repeating: "e", count: 64)), workerGeneration: 10)
        state.waitForPendingRenewals()
        #expect(recorder.values.last?.workloadReady == true)
        #expect(state.currentGuestMachineEpoch == bootEpoch)
    }

    @Test func guestRebootDuringRendererLossCannotReuseOldWorkloadReadiness() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(), sender: { recorder.record($0) }
        )
        try state.publish(readyMessage())
        state.rendererBecameUnavailable(workerGeneration: 9, detail: "worker lost")
        state.prepareGuestMachineReset()
        state.prepareRendererReplacement(workerGeneration: 10, rendererWorkerReceiptSHA256: String(repeating: "d", count: 64))
        state.resumeGuestMachinePresentation()
        state.recordFirstShaderCompletion(workerGeneration: 10, atUnixMilliseconds: 14)
        state.recordFirstPresentationCompletion(workerGeneration: 10, atUnixMilliseconds: 15)
        state.apply(.verified(proofSHA256: String(repeating: "e", count: 64)), workerGeneration: 10)
        state.waitForPendingRenewals()
        #expect(recorder.values.last?.guestBooted == false)
        #expect(recorder.values.last?.workloadReady == false)
    }

    @Test func replacementRevokesTheOldWorkersLiveProofAndFrameObservations() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)))
        state.recordFirstShaderCompletion(atUnixMilliseconds: 10)
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 11)
        try state.publish(readyMessage())
        state.prepareRendererReplacement(
            workerGeneration: 10,
            rendererWorkerReceiptSHA256: String(repeating: "d", count: 64)
        )
        state.waitForPendingRenewals()

        let replacement = try #require(state.snapshot)
        #expect(replacement.isValid)
        #expect(replacement.rendererGeneration == 10)
        #expect(replacement.rendererWorkerReceiptSHA256 == String(repeating: "d", count: 64))
        #expect(replacement.verificationState == .provisional)
        #expect(replacement.guestProducerFenceProofSHA256 == nil)
        #expect(replacement.firstShaderCompletedAtUnixMilliseconds == nil)
        #expect(replacement.firstPresentationCompletedAtUnixMilliseconds == nil)
        #expect(!state.hasCompletedRendererPresentation)
        #expect(recorder.values.last?.graphicsSelection == replacement)

        state.apply(
            .verified(proofSHA256: String(repeating: "e", count: 64)),
            workerGeneration: 9
        )
        state.recordFirstShaderCompletion(
            workerGeneration: 9,
            atUnixMilliseconds: 12
        )
        state.recordFirstPresentationCompletion(
            workerGeneration: 9,
            atUnixMilliseconds: 13
        )
        #expect(state.snapshot == replacement)

        state.prepareRendererReplacement(
            workerGeneration: 9,
            rendererWorkerReceiptSHA256: String(repeating: "e", count: 64)
        )
        #expect(state.snapshot == replacement)
        state.apply(
            .verified(proofSHA256: String(repeating: "f", count: 64)),
            workerGeneration: 10
        )
        #expect(state.snapshot?.guestProducerFenceProofSHA256
                == String(repeating: "f", count: 64))
    }

    @Test func fullGuestResetRevokesOldBootProofWithoutChangingAdmittedWorker() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)))
        state.recordFirstShaderCompletion(atUnixMilliseconds: 10)
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 11)
        try state.publish(readyMessage())

        state.prepareGuestMachineReset()
        state.waitForPendingRenewals()

        let reset = try #require(state.snapshot)
        #expect(reset.isValid)
        #expect(reset.rendererGeneration == 9)
        #expect(reset.verificationState == .provisional)
        #expect(reset.guestProducerFenceProofSHA256 == nil)
        #expect(reset.firstShaderCompletedAtUnixMilliseconds == nil)
        #expect(reset.firstPresentationCompletedAtUnixMilliseconds == nil)
        #expect(!state.hasCompletedRendererPresentation)
        #expect(recorder.values.last?.graphicsSelection == reset)
        #expect(recorder.values.last?.guestBooted == false)
        #expect(recorder.values.last?.desktopVisible == false)
        #expect(recorder.values.last?.workloadReady == false)

        state.apply(
            .verified(proofSHA256: String(repeating: "d", count: 64)),
            workerGeneration: 9
        )
        state.recordFirstShaderCompletion(workerGeneration: 9, atUnixMilliseconds: 12)
        state.recordFirstPresentationCompletion(workerGeneration: 9, atUnixMilliseconds: 13)
        #expect(state.snapshot == reset)

        state.resumeGuestMachinePresentation()
        state.recordFirstPresentationCompletion(workerGeneration: 9, atUnixMilliseconds: 14)
        #expect(state.snapshot?.firstPresentationCompletedAtUnixMilliseconds == 14)
    }

    @Test func softwareGuestResetClearsOldPresentationOnly() throws {
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: .resolvedSoftware(
                operationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                resolvedPlanSHA256: String(repeating: "a", count: 64),
                planRevision: 7
            ),
            sender: { _ in }
        )
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 11)

        state.prepareGuestMachineReset()

        let reset = try #require(state.snapshot)
        #expect(reset.isValid)
        #expect(reset.verificationState == .notRequired)
        #expect(reset.firstPresentationCompletedAtUnixMilliseconds == nil)
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 12)
        #expect(state.snapshot == reset)
        state.resumeGuestMachinePresentation()
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 13)
        #expect(state.snapshot?.firstPresentationCompletedAtUnixMilliseconds == 13)
    }

    @Test func retiredGuestBootCannotPublishReadinessForReplacementBoot() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { recorder.record($0) }
        )
        let retiredEpoch = state.currentGuestMachineEpoch
        state.prepareGuestMachineReset()
        let replacementEpoch = state.currentGuestMachineEpoch

        #expect(replacementEpoch != retiredEpoch)
        #expect(throws: VMError.self) {
            try state.publish(
                readyMessage(),
                expectedGuestMachineEpoch: retiredEpoch
            )
        }
        #expect(recorder.values.isEmpty)

        try state.publish(
            readyMessage(),
            expectedGuestMachineEpoch: replacementEpoch
        )
        #expect(recorder.values.count == 1)
    }

    @Test func fullGuestResetClearsLatchedFirstFrameGate() {
        let gate = FirstFrameGate()
        gate.signal()
        #expect(gate.wait(timeout: 0))

        gate.resetForNewGuestMachine()
        #expect(!gate.wait(timeout: 0))

        gate.signal()
        #expect(gate.wait(timeout: 0))
    }

    @Test func replacementAdmissionCannotBeOvertakenByItsVerification() throws {
        let recorder = DesktopGraphicsReadyRecorder()
        let provisionalSendStarted = DispatchSemaphore(value: 0)
        let releaseProvisionalSend = DispatchSemaphore(value: 0)
        let state = DesktopRuntimeGraphicsReadinessState(
            selection: provisionalGraphicsSelection(),
            sender: { ready in
                if ready.graphicsSelection?.rendererGeneration == 10,
                   ready.graphicsSelection?.verificationState == .provisional {
                    provisionalSendStarted.signal()
                    _ = releaseProvisionalSend.wait(timeout: .now() + 3)
                }
                recorder.record(ready)
            }
        )
        try state.publish(readyMessage())
        state.prepareRendererReplacement(
            workerGeneration: 10,
            rendererWorkerReceiptSHA256: String(repeating: "d", count: 64)
        )
        #expect(provisionalSendStarted.wait(timeout: .now() + 3) == .success)
        state.apply(
            .verified(proofSHA256: String(repeating: "e", count: 64)),
            workerGeneration: 10
        )
        releaseProvisionalSend.signal()
        state.waitForPendingRenewals()

        let selections = recorder.values.compactMap(\.graphicsSelection)
        #expect(selections.map(\.rendererGeneration) == [9, 10, 10])
        #expect(selections.map(\.verificationState) == [
            .provisional, .provisional, .verified,
        ])
        #expect(selections[1].guestProducerFenceProofSHA256 == nil)
        #expect(selections[2].guestProducerFenceProofSHA256 == String(repeating: "e", count: 64))
    }

    private func provisionalGraphicsSelection() -> DoryRuntimeGraphicsSelection {
        DoryRuntimeGraphicsSelection(
            operationID: "11111111-2222-3333-4444-555555555555",
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 7,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 9,
            rendererWorkerReceiptSHA256: String(repeating: "b", count: 64),
            requestedGraphics: .hardwareAccelerated3D,
            admittedGraphics: .hardwareAccelerated3D,
            verificationState: .provisional,
            guestDriver: .venus
        )
    }

    private func readyMessage() -> VmmReadyMessage {
        VmmReadyMessage(
            machineID: "desktop",
            operationID: "11111111-2222-3333-4444-555555555555",
            guestBooted: true,
            desktopVisible: true,
            workloadReady: true
        )
    }
}

private final class DesktopGraphicsReadyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [VmmReadyMessage]()

    var values: [VmmReadyMessage] { lock.withLock { recorded } }

    func record(_ ready: VmmReadyMessage) {
        lock.withLock { recorded.append(ready) }
    }
}
