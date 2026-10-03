import Foundation
import Synchronization
import Testing
@testable import dory_hv

@Suite(.serialized)
struct RawHVGuestExecutionRetirementTests {
    private enum TestFailure: Error, Equatable {
        case joinFailed
        case gateTimedOut
    }

    @Test func resetReleasesTheRunnerAndItsCapturedVMBeforeReplacementCreation() throws {
        let destroyed = DestructionState()
        let joins = Atomic<Int>(0)
        let weakOwner = WeakOwner()
        var owner: MockExecutionOwner? = MockExecutionOwner(destroyed: destroyed)
        weakOwner.set(owner)
        let retirement = RawHVGuestExecutionRetirement(owner: owner!) { owner in
            joins.wrappingAdd(1, ordering: .relaxed)
            owner.completeExecution()
        }
        // Mirrors transfer out of DesktopMode.Controller.machineRunner before reset work.
        owner = nil
        #expect(weakOwner.isAlive)
        #expect(!destroyed.isDestroyed)

        try retirement.wait()
        // The boundary remains retained by the worker/controller. It must not retain the VM.
        #expect(!weakOwner.isAlive)
        #expect(destroyed.isDestroyed)
        let replacementCanBeCreated = destroyed.isDestroyed
        #expect(replacementCanBeCreated)
        try retirement.wait()
        #expect(joins.load(ordering: .relaxed) == 1)
    }

    @Test func cancellationObserversJoinOnceAndRetainGuestMemoryUntilExecutionReturns() throws {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let destroyed = DestructionState()
        let joins = Atomic<Int>(0)
        let weakOwner = WeakOwner()
        var owner: MockExecutionOwner? = MockExecutionOwner(destroyed: destroyed)
        weakOwner.set(owner)
        let retirement = RawHVGuestExecutionRetirement(owner: owner!) { _ in
            joins.wrappingAdd(1, ordering: .relaxed)
            entered.signal()
            guard resume.wait(timeout: .now() + 2) == .success else {
                throw TestFailure.gateTimedOut
            }
        }
        owner = nil
        let finished = DispatchGroup()
        let failures = Mutex<[String]>([])
        for _ in 0..<8 {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { try retirement.wait() }
                catch { failures.withLock { $0.append(String(describing: error)) } }
            }
        }
        let didEnter = entered.wait(timeout: .now() + 2) == .success
        #expect(didEnter)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(weakOwner.isAlive)
        #expect(!destroyed.isDestroyed)
        resume.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(joins.load(ordering: .relaxed) == 1)
        #expect(!weakOwner.isAlive)
        #expect(destroyed.isDestroyed)
    }

    @Test func successfulJoinIsNotPublishedWhileRunnerDestructionStillOwnsVM() throws {
        let destroying = DispatchSemaphore(value: 0)
        let resumeDestruction = DispatchSemaphore(value: 0)
        let destroyed = DestructionState()
        let destructorTimedOut = Atomic<Bool>(false)
        var owner: MockExecutionOwner? = MockExecutionOwner(destroyed: destroyed) {
            destroying.signal()
            if resumeDestruction.wait(timeout: .now() + 2) != .success {
                destructorTimedOut.store(true, ordering: .releasing)
            }
        }
        let retirement = RawHVGuestExecutionRetirement(owner: owner!) { _ in }
        owner = nil
        let finished = DispatchGroup()
        let failures = Mutex<[String]>([])
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { try retirement.wait() }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        #expect(destroying.wait(timeout: .now() + 2) == .success)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { try retirement.wait() }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(!destroyed.isDestroyed)
        resumeDestruction.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(failures.withLock { $0 }.isEmpty)
        let didTimeOut = destructorTimedOut.load(ordering: .acquiring)
        #expect(!didTimeOut)
        #expect(destroyed.isDestroyed)
    }

    @Test func failedJoinRetainsExecutionAuthorityAndReplaysTheFailure() {
        let destroyed = DestructionState()
        let joins = Atomic<Int>(0)
        let weakOwner = WeakOwner()
        var owner: MockExecutionOwner? = MockExecutionOwner(destroyed: destroyed)
        weakOwner.set(owner)
        var retirement: RawHVGuestExecutionRetirement<MockExecutionOwner>? =
            RawHVGuestExecutionRetirement(owner: owner!) { _ in
                joins.wrappingAdd(1, ordering: .relaxed)
                throw TestFailure.joinFailed
            }
        owner = nil
        #expect(throws: TestFailure.joinFailed) { try retirement!.wait() }
        #expect(throws: TestFailure.joinFailed) { try retirement!.wait() }
        #expect(joins.load(ordering: .relaxed) == 1)
        #expect(weakOwner.isAlive)
        #expect(!destroyed.isDestroyed)
        // The VM is quarantined for the remaining lifetime of the retirement owner.
        retirement = nil
        #expect(!weakOwner.isAlive)
        #expect(destroyed.isDestroyed)
    }

    private final class DestructionState: @unchecked Sendable {
        private let destroyed = Atomic<Bool>(false)

        var isDestroyed: Bool { destroyed.load(ordering: .acquiring) }
        func markDestroyed() { destroyed.store(true, ordering: .releasing) }
    }

    private final class MockVM: @unchecked Sendable {
        private let destroyed: DestructionState

        init(destroyed: DestructionState) { self.destroyed = destroyed }
        deinit { destroyed.markDestroyed() }
    }

    private final class MockExecutionOwner: @unchecked Sendable {
        private let vm: MockVM
        private let operation: @Sendable () -> Void
        private let onDestruction: @Sendable () -> Void

        init(
            destroyed: DestructionState,
            onDestruction: @escaping @Sendable () -> Void = {}
        ) {
            let vm = MockVM(destroyed: destroyed)
            self.vm = vm
            // RawHVMachineRunner retains Machine both directly and through its operation.
            self.operation = { withExtendedLifetime(vm) {} }
            self.onDestruction = onDestruction
        }

        func completeExecution() { operation() }
        deinit { onDestruction() }
    }

    private final class WeakOwner: @unchecked Sendable {
        private let lock = NSLock()
        private weak var owner: MockExecutionOwner?

        func set(_ owner: MockExecutionOwner?) { lock.withLock { self.owner = owner } }
        var isAlive: Bool { lock.withLock { owner != nil } }
    }
}
