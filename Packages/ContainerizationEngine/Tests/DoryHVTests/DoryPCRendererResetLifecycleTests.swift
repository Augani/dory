import Foundation
import Testing
@testable import dory_hv

@Suite(.serialized)
struct DoryPCRendererResetLifecycleTests {
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
        ) { generation in
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
        ) { generation in
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
}

private final class FakeRendererGenerationLaunch: DoryPCRendererGenerationLaunch, @unchecked Sendable {
    let doryPCWorkerGeneration: UInt64
    private let lock = NSLock()
    private var successes = 0
    private var failures = 0
    init(_ generation: UInt64) {
        doryPCWorkerGeneration = generation
    }

    var successCount: Int { lock.withLock { successes } }
    var failureCount: Int { lock.withLock { failures } }
    func recordSuccess() {
        lock.withLock { successes += 1 }
    }

    func recordFailure() {
        lock.withLock { failures += 1 }
    }

    func teardown(reason _: String) {}
}

private final class PublishedRendererGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [UInt64?]()

    var values: [UInt64?] { lock.withLock { stored } }

    func append(_ generation: UInt64?) {
        lock.withLock { stored.append(generation) }
    }
}
