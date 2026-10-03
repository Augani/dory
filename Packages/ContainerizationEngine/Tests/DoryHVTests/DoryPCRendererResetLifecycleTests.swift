import Foundation
import DoryRendererWorkerContracts
import DorydKit
import Testing
@testable import dory_hv

@Suite(.serialized)
struct DoryPCRendererResetLifecycleTests {
    @Test func readinessBackendMatchesTheAdmittedPCProducerFenceContract() throws {
        #expect(try DoryPCMode.runtimeGraphicsBackend(
            for: .doryPCX8664LinuxVirGL2PrepareFBV1
        ) == .virgl)
        #expect(try DoryPCMode.runtimeGraphicsBackend(
            for: .doryPCX8664LinuxVenusPrepareFBV1
        ) == .virglVenus)
        #expect(throws: (any Error).self) {
            _ = try DoryPCMode.runtimeGraphicsBackend(for: nil)
        }
        #expect(throws: (any Error).self) {
            _ = try DoryPCMode.runtimeGraphicsBackend(
                for: .stockLinux613RuntimeVerifiedV1
            )
        }
    }

    @Test func admittedPCWorkerDoesNotClaimLiveGuestGraphicsProof() throws {
        let operationID = UUID()
        for (contract, backend) in [
            (DoryRendererProducerFenceContract.doryPCX8664LinuxVirGL2PrepareFBV1,
             DoryRuntimeGraphicsBackend.virgl),
            (.doryPCX8664LinuxVenusPrepareFBV1, .virglVenus),
        ] {
            let selection = try DoryPCMode.acceleratedRuntimeGraphicsSelection(
                operationID: operationID,
                resolvedPlanSHA256: String(repeating: "a", count: 64),
                planRevision: 7,
                producerFenceContract: contract,
                workerGeneration: 9,
                rendererWorkerReceiptSHA256: String(repeating: "b", count: 64)
            )
            #expect(selection.isValid)
            #expect(selection.backend == backend)
            #expect(selection.verificationState == .provisional)
            #expect(selection.guestProducerFenceProofSHA256 == nil)
            #expect(selection.rendererGeneration == 9)
        }
        #expect(throws: (any Error).self) {
            _ = try DoryPCMode.acceleratedRuntimeGraphicsSelection(
                operationID: operationID,
                resolvedPlanSHA256: String(repeating: "a", count: 64),
                planRevision: 7,
                producerFenceContract: .doryPCX8664LinuxVenusPrepareFBV1,
                workerGeneration: 0,
                rendererWorkerReceiptSHA256: String(repeating: "b", count: 64)
            )
        }
    }

    @MainActor
    @Test func duplicateResetWhileReplacementProviderAwaitsDoesNotInvalidateAdmittedReset() {
        let oldLaunch = FakeRendererGenerationLaunch(1)
        let store = DoryPCRendererLaunchStore(oldLaunch)
        let coordinator = DoryPCRendererReplacementResetCoordinator<FakeRendererGenerationLaunch>()

        let first = coordinator.beginReset(previousLaunch: oldLaunch, launchStore: store)
        #expect(first != nil)
        #expect(store.current() == nil)

        let duplicate = coordinator.beginReset(previousLaunch: oldLaunch, launchStore: store)
        #expect(duplicate == nil)
        if let first {
            #expect(coordinator.acceptsCompletion(first))
        }
    }

    @MainActor
    @Test func laterAdmittedResetInvalidatesOlderAwaitingReplacement() throws {
        let firstLaunch = FakeRendererGenerationLaunch(1)
        let secondLaunch = FakeRendererGenerationLaunch(2)
        let store = DoryPCRendererLaunchStore(firstLaunch)
        let coordinator = DoryPCRendererReplacementResetCoordinator<FakeRendererGenerationLaunch>()

        let first = try #require(coordinator.beginReset(
            previousLaunch: firstLaunch,
            launchStore: store
        ))
        store.replace(secondLaunch)
        let second = try #require(coordinator.beginReset(
            previousLaunch: secondLaunch,
            launchStore: store
        ))

        #expect(!coordinator.acceptsCompletion(first))
        #expect(coordinator.acceptsCompletion(second))
    }

    @MainActor
    @Test func shutdownInvalidatesAnAwaitingReplacementTicket() throws {
        let launch = FakeRendererGenerationLaunch(7)
        let store = DoryPCRendererLaunchStore(launch)
        let coordinator = DoryPCRendererReplacementResetCoordinator<FakeRendererGenerationLaunch>()
        let ticket = try #require(coordinator.beginReset(previousLaunch: launch, launchStore: store))
        coordinator.invalidate()
        #expect(!coordinator.acceptsCompletion(ticket))
    }

    @MainActor
    @Test func guestRebootCanJoinPendingReplacementWithoutRevivingOldPresentation() throws {
        let old = FakeRendererGenerationLaunch(7)
        let store = DoryPCRendererLaunchStore(old)
        let coordinator = DoryPCRendererReplacementResetCoordinator<FakeRendererGenerationLaunch>()
        let ticket = try #require(coordinator.beginReset(previousLaunch: old, launchStore: store))
        #expect(store.current() == nil)
        #expect(store.current(matchingWorkerGeneration: 7) == nil)
        #expect(store.replacementSource() === old)
        #expect(coordinator.beginReset(previousLaunch: old, launchStore: store) == nil)
        #expect(coordinator.acceptsCompletion(ticket))
        store.teardown(reason: "stopped while handoff awaited")
        #expect(old.teardownCount == 1)
        let successor = FakeRendererGenerationLaunch(8)
        #expect(!store.replace(successor, replacing: old))
        #expect(store.replacementSource() == nil)
        #expect(store.current(matchingWorkerGeneration: 7) == nil)
    }

    @Test func rebootIntentIsVisibleBeforeItsRunLoopCallbackAndConsumedOnlyOnce() {
        let handoff = DoryPCRendererMachineResetHandoff<UInt64>()
        #expect(handoff.take() == nil)
        handoff.begin()
        #expect(handoff.isPending)
        // A GPU completion arriving before reset-device preparation must not lose reboot intent.
        #expect(handoff.take() == nil)
        #expect(handoff.isPending)
        handoff.store(7)
        #expect(handoff.take() == 7)
        #expect(!handoff.isPending)
        // A later full-reset callback must not resume the same machine a second time.
        #expect(handoff.take() == nil)
        handoff.store(8)
        handoff.store(9)
        #expect(handoff.take() == 9)
        #expect(handoff.take() == nil)
        handoff.begin()
        handoff.clear()
        #expect(!handoff.isPending)
    }

    @Test func rendererLossBlocksReadinessUntilAReplacementPresentationArrives() throws {
        let recorder = PublishedRendererGenerations()
        let publisher = DoryPCRendererReadyPublisher(requiresGuestServices: false, requiresRendererPresentation: true) {
            generation, _ in recorder.append(generation)
        }
        try publisher.markPresentationReady()
        try publisher.markRendererPresentationReady(workerGeneration: 7)
        publisher.suspendRendererPresentation(workerGeneration: 7)
        try publisher.markRendererPresentationReady(workerGeneration: 7)
        #expect(recorder.values == [7])
        publisher.prepareRendererPresentation(workerGeneration: 8)
        try publisher.markRendererPresentationReady(workerGeneration: 7)
        #expect(recorder.values == [7])
        try publisher.markRendererPresentationReady(workerGeneration: 8)
        #expect(recorder.values == [7, 8])
    }

    @Test func delayedRetiredWorkerPresentationCallbacksCannotTouchReplacementLaunch() {
        let oldLaunch = FakeRendererGenerationLaunch(1)
        let replacementLaunch = FakeRendererGenerationLaunch(2)
        let store = DoryPCRendererLaunchStore(oldLaunch)

        let retired = store.retire(matchingWorkerGeneration: 1)
        #expect(retired === oldLaunch)
        store.replace(replacementLaunch)

        if let launch = store.current(matchingWorkerGeneration: 1) {
            launch.recordSuccess()
        }
        if let launch = store.current(matchingWorkerGeneration: 1) {
            launch.recordFailure()
        }
        if let launch = store.current(matchingWorkerGeneration: 2) {
            launch.recordSuccess()
        }

        #expect(store.current(matchingWorkerGeneration: 1) == nil)
        #expect(store.current(matchingWorkerGeneration: 2) === replacementLaunch)
        #expect(oldLaunch.successCount == 0)
        #expect(oldLaunch.failureCount == 0)
        #expect(replacementLaunch.successCount == 1)
        #expect(replacementLaunch.failureCount == 0)
    }


    @Test func stalePublicationFailureCannotReopenAlreadyPublishedSuccessorGeneration() throws {
        enum PublicationError: Error { case staleGeneration }

        let recorder = PublishedRendererGenerations()
        let admitted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let publisher = DoryPCRendererReadyPublisher(
            requiresGuestServices: false,
            requiresRendererPresentation: true
        ) { generation, _ in
            recorder.append(generation)
            if generation == 1 {
                admitted.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
                throw PublicationError.staleGeneration
            }
        }

        try publisher.markPresentationReady()
        DispatchQueue.global().async {
            defer { completed.signal() }
            #expect(throws: PublicationError.self) {
                try publisher.markRendererPresentationReady(workerGeneration: 1)
            }
        }
        defer { release.signal() }
        try #require(admitted.wait(timeout: .now() + 5) == .success)
        publisher.prepareRendererPresentation(workerGeneration: 2)
        try publisher.markRendererPresentationReady(workerGeneration: 2)
        release.signal()
        try #require(completed.wait(timeout: .now() + 5) == .success)
        try publisher.markRendererPresentationReady(workerGeneration: 2)

        #expect(recorder.values == [1, 2])
    }

    @Test func readinessPublicationCarriesTheAdmittedWorkerGeneration() throws {
        let recorder = PublishedRendererGenerations()
        let publisher = DoryPCRendererReadyPublisher(
            requiresGuestServices: false,
            requiresRendererPresentation: true
        ) { generation, _ in
            recorder.append(generation)
        }

        try publisher.markPresentationReady()
        try publisher.markRendererPresentationReady(workerGeneration: 1)
        #expect(recorder.values == [1])

        publisher.prepareRendererPresentation(workerGeneration: 2)
        try publisher.markRendererPresentationReady(workerGeneration: 1)
        #expect(recorder.values == [1])
        try publisher.markRendererPresentationReady(workerGeneration: 2)
        #expect(recorder.values == [1, 2])
    }

    @Test func guestMachineResetRequiresFreshPresentationEvenForTheSameWorker() throws {
        let recorder = PublishedRendererGenerations()
        let publisher = DoryPCRendererReadyPublisher(
            requiresGuestServices: false,
            requiresRendererPresentation: true
        ) { generation, _ in
            recorder.append(generation)
        }

        try publisher.markPresentationReady()
        try publisher.markRendererPresentationReady(workerGeneration: 1)
        #expect(recorder.values == [1])

        publisher.prepareGuestMachineReset()
        try publisher.markRendererPresentationReady(workerGeneration: 1)
        #expect(recorder.values == [1])
        publisher.prepareRendererPresentation(workerGeneration: 1)
        try publisher.markRendererPresentationReady(workerGeneration: 1)
        #expect(recorder.values == [1])
        try publisher.markPresentationReady()
        #expect(recorder.values == [1, 1])
    }

    @Test func softwareGuestResetRequiresAFreshExecutionSlice() throws {
        let recorder = PublishedRendererGenerations()
        let publisher = DoryPCRendererReadyPublisher(
            requiresGuestServices: false,
            requiresRendererPresentation: false
        ) { generation, _ in
            recorder.append(generation)
        }

        try publisher.markPresentationReady()
        #expect(recorder.values == [nil])
        publisher.prepareGuestMachineReset()
        #expect(recorder.values == [nil])
        try publisher.markPresentationReady()
        #expect(recorder.values == [nil, nil])
    }

    @Test func retiredBootPublicationFailureCannotReopenReplacementBoot() throws {
        enum PublicationError: Error { case retiredBoot }
        let recorder = PublishedRendererGenerations()
        let admitted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let publisher = DoryPCRendererReadyPublisher(
            requiresGuestServices: false,
            requiresRendererPresentation: false
        ) { _, bootEpoch in
            recorder.append(bootEpoch)
            if bootEpoch == 1 {
                admitted.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
                throw PublicationError.retiredBoot
            }
        }

        DispatchQueue.global().async {
            defer { completed.signal() }
            #expect(throws: PublicationError.self) {
                try publisher.markPresentationReady()
            }
        }
        defer { release.signal() }
        try #require(admitted.wait(timeout: .now() + 5) == .success)
        publisher.prepareGuestMachineReset()
        try publisher.markPresentationReady()
        release.signal()
        try #require(completed.wait(timeout: .now() + 5) == .success)
        try publisher.markPresentationReady()

        #expect(recorder.values == [1, 2])
    }
}

private final class FakeRendererGenerationLaunch: DoryPCRendererGenerationLaunch, @unchecked Sendable {
    let doryPCWorkerGeneration: UInt64
    private let lock = NSLock()
    private var successes = 0
    private var failures = 0
    private var teardowns = 0
    init(_ generation: UInt64) {
        doryPCWorkerGeneration = generation
    }

    var successCount: Int { lock.withLock { successes } }
    var failureCount: Int { lock.withLock { failures } }
    var teardownCount: Int { lock.withLock { teardowns } }
    func recordSuccess() {
        lock.withLock { successes += 1 }
    }

    func recordFailure() {
        lock.withLock { failures += 1 }
    }

    func teardown(reason _: String) { lock.withLock { teardowns += 1 } }
    func waitForRetirement(reason _: String) async throws {}
}

private final class PublishedRendererGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [UInt64?]()

    var values: [UInt64?] { lock.withLock { stored } }

    func append(_ generation: UInt64?) {
        lock.withLock { stored.append(generation) }
    }
}
