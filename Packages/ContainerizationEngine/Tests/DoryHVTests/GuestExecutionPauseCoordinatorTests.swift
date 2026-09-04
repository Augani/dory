import Dispatch
import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized)
struct GuestExecutionPauseCoordinatorTests {
    @Test func pauseWaitsForEveryExecutingCPUAndBlocksNewExecution() throws {
        let gate = GuestExecutionPauseCoordinator()
        #expect(try gate.enter(participant: 0))
        #expect(try gate.enter(participant: 1))
        let interrupted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = PauseOutcome()
        DispatchQueue.global().async {
            do { try gate.pause(timeout: 5) { interrupted.signal() } }
            catch { result.set(error) }
            completed.signal()
        }
        #expect(interrupted.wait(timeout: .now() + 5) == .success)
        gate.leave(participant: 0)
        #expect(completed.wait(timeout: .now() + 0.01) == .timedOut)
        gate.leave(participant: 1)
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(result.error == nil)
        #expect(gate.state == .paused)

        let entering = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entering.signal()
            do {
                if try gate.enter(participant: 2) { gate.leave(participant: 2) }
            } catch { result.set(error) }
            entered.signal()
        }
        #expect(entering.wait(timeout: .now() + 5) == .success)
        #expect(entered.wait(timeout: .now() + 0.01) == .timedOut)
        try gate.resume()
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(result.error == nil)
        #expect(gate.state == .running)
    }

    @Test func timedOutPauseRestoresExecutionInsteadOfLeavingAPartialPause() throws {
        let gate = GuestExecutionPauseCoordinator()
        #expect(try gate.enter(participant: 0))
        #expect(throws: GuestExecutionPauseCoordinator.Failure.timedOut) {
            try gate.pause(timeout: 0.01)
        }
        #expect(gate.state == .running)
        gate.leave(participant: 0)
        #expect(try gate.enter(participant: 1))
        gate.leave(participant: 1)
    }

    @Test func stopWakesParkedExecutionWithoutResumingGuestInstructions() throws {
        let gate = GuestExecutionPauseCoordinator()
        try gate.pause()
        let completed = DispatchSemaphore(value: 0)
        let result = PauseOutcome()
        DispatchQueue.global().async {
            do {
                if try gate.enter(participant: 0) { result.set(UnexpectedExecution()) }
            } catch { result.set(error) }
            completed.signal()
        }
        gate.stop()
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(result.error == nil)
        #expect(gate.state == .stopped)
        #expect(throws: GuestExecutionPauseCoordinator.Failure.stopped) { try gate.resume() }
    }

    @Test func stopAbortsInFlightPauseAndWaitsForExecutionRetirement() throws {
        let gate = GuestExecutionPauseCoordinator()
        #expect(try gate.enter(participant: 0))
        let interrupted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = PauseOutcome()
        DispatchQueue.global().async {
            do { try gate.pause(timeout: 5) { interrupted.signal() } }
            catch { result.set(error) }
            completed.signal()
        }
        #expect(interrupted.wait(timeout: .now() + 5) == .success)
        #expect(throws: GuestExecutionPauseCoordinator.Failure.transitionInProgress) {
            try gate.resume()
        }
        gate.stop()
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(result.error as? GuestExecutionPauseCoordinator.Failure == .stopped)
        #expect(gate.state == .stopping)
        gate.leave(participant: 0)
        #expect(gate.state == .stopped)
    }
}

private struct UnexpectedExecution: Error {}
private final class PauseOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error)?
    var error: (any Error)? { lock.withLock { value } }
    func set(_ error: any Error) { lock.withLock { value = error } }
}
