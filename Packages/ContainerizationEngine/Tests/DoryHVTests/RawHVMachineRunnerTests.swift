import Darwin
import Foundation
import Synchronization
import Testing
@testable import DoryHV

@Suite(.serialized) struct RawHVMachineRunnerTests {
    private struct OwnerObservation: Sendable {
        let differsFromCaller: Bool
        let name: String
        let qualityOfService: QualityOfService
    }

    private enum TestFailure: Error, Equatable {
        case expected
    }

    @Test func operationRunsOnDedicatedNamedOwnerAndNativeJoinIsReplayable() throws {
        let callerIdentity = UInt(bitPattern: pthread_self())
        let observation = Mutex<OwnerObservation?>(nil)
        let owner = RawHVOwnerThread<Int>(name: "dory-hv.owner-test") {
            var bytes = [CChar](repeating: 0, count: 64)
            pthread_getname_np(pthread_self(), &bytes, bytes.count)
            observation.withLock {
                $0 = OwnerObservation(
                    differsFromCaller: callerIdentity != UInt(bitPattern: pthread_self()),
                    name: String(
                        decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    ),
                    qualityOfService: Thread.current.qualityOfService
                )
            }
            return 42
        }

        try owner.start()
        #expect(try owner.wait() == 42)
        // A second observer receives the same operation result without attempting a second join.
        #expect(try owner.wait() == 42)

        let recorded = try #require(observation.withLock { $0 })
        #expect(recorded.differsFromCaller)
        #expect(recorded.name == "dory-hv.owner-test")
        #expect(recorded.qualityOfService == .userInitiated)
    }

    @Test func operationFailureAndCompletionArePublishedExactlyOnce() throws {
        let executions = Atomic<Int>(0)
        let completions = Atomic<Int>(0)
        let owner = RawHVOwnerThread<Int>(name: "dory-hv.error-test") {
            executions.wrappingAdd(1, ordering: .relaxed)
            throw TestFailure.expected
        }

        try owner.start { result in
            if case .failure(let error) = result,
               error as? TestFailure == .expected {
                completions.wrappingAdd(1, ordering: .relaxed)
            }
        }

        #expect(throws: TestFailure.expected) { try owner.wait() }
        #expect(throws: TestFailure.expected) { try owner.wait() }
        #expect(executions.load(ordering: .relaxed) == 1)
        // wait() is a native join, so it cannot return before the owner-thread completion exits.
        #expect(completions.load(ordering: .relaxed) == 1)
    }

    @Test func concurrentWaitersShareOneNativeJoinAndOneResult() throws {
        let release = DispatchSemaphore(value: 0)
        let owner = RawHVOwnerThread<Int>(name: "dory-hv.join-test") {
            release.wait()
            return 0xD012
        }
        try owner.start()

        let waiterCount = 12
        let group = DispatchGroup()
        let values = Mutex<[Int]>([])
        let errors = Mutex<[String]>([])
        for _ in 0..<waiterCount {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                do {
                    let value = try owner.wait()
                    values.withLock { $0.append(value) }
                } catch {
                    errors.withLock { $0.append(String(describing: error)) }
                }
            }
        }

        release.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(errors.withLock { $0 }.isEmpty)
        let observed = values.withLock { $0 }
        #expect(observed.count == waiterCount)
        #expect(observed.allSatisfy { $0 == 0xD012 })
    }

    @Test func lifecycleRejectsWaitBeforeStartAndASecondStart() throws {
        let owner = RawHVOwnerThread<Int>(name: "dory-hv.single-use") { 7 }

        #expect(throws: RawHVMachineRunnerError.notStarted) { try owner.wait() }
        try owner.start()
        #expect(throws: RawHVMachineRunnerError.alreadyStarted) { try owner.start() }
        #expect(try owner.wait() == 7)
    }

    @Test func ownerThreadCannotJoinItself() throws {
        let ownerBox = Mutex<RawHVOwnerThread<Int>?>(nil)
        let observedError = Mutex<RawHVMachineRunnerError?>(nil)
        let owner = RawHVOwnerThread<Int>(name: "dory-hv.self-join") {
            let currentOwner = ownerBox.withLock { $0 }
            do {
                _ = try currentOwner?.wait()
            } catch let error as RawHVMachineRunnerError {
                observedError.withLock { $0 = error }
            }
            return 9
        }
        ownerBox.withLock { $0 = owner }

        try owner.start()
        #expect(try owner.wait() == 9)
        #expect(observedError.withLock { $0 } == .waitFromOwnerThread)
        ownerBox.withLock { $0 = nil }
    }
}
