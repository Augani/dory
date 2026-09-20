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
        try state.publish(readyMessage())
        state.recordFirstShaderCompletion(atUnixMilliseconds: 10)
        state.apply(.verified(proofSHA256: String(repeating: "c", count: 64)))
        state.recordFirstPresentationCompletion(atUnixMilliseconds: 11)

        let selection = try #require(state.snapshot)
        #expect(selection.verificationState == .verified)
        #expect(selection.guestProducerFenceProofSHA256 == String(repeating: "c", count: 64))
        #expect(selection.firstShaderCompletedAtUnixMilliseconds == 10)
        #expect(selection.firstPresentationCompletedAtUnixMilliseconds == 11)
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
