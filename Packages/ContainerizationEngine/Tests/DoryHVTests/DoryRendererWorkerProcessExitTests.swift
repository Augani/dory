import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct DoryRendererWorkerProcessExitTests {
    @Test func armedExactChildExitPublishesOnceAndSurvivesRepeatedWaits() throws {
        let child = try RendererExitTestChild()
        defer { child.stop() }
        let registered = DispatchSemaphore(value: 0)
        let proof = DispatchGroup()
        proof.enter()
        let counter = RendererExitProofCounter()
        let observed: DoryRendererWorkerProcessExitMonitor? = DoryRendererWorkerProcessExitMonitor(
            processIdentifier: child.process.processIdentifier,
            queue: DispatchQueue(label: "dev.dory.tests.renderer-exit"),
            exited: { counter.increment(); proof.leave() })
        let monitor = try #require(observed)
        monitor.start { registered.signal() }
        try #require(registered.wait(timeout: .now() + 2) == .success)
        #expect(counter.value == 0)
        child.closeInput()
        try #require(proof.wait(timeout: .now() + 2) == .success)
        #expect(proof.wait(timeout: .now()) == .success)
        #expect(proof.wait(timeout: .now()) == .success)
        monitor.cancel()
        monitor.start { registered.signal() }
        #expect(counter.value == 1)
        #expect(registered.wait(timeout: .now()) == .timedOut)
    }

    @Test func cancellingExactChildWatchNeverSynthesizesExitProof() throws {
        let child = try RendererExitTestChild()
        defer { child.stop() }
        let registered = DispatchSemaphore(value: 0)
        let counter = RendererExitProofCounter()
        let queue = DispatchQueue(label: "dev.dory.tests.renderer-exit-cancel")
        let observed: DoryRendererWorkerProcessExitMonitor? = DoryRendererWorkerProcessExitMonitor(
            processIdentifier: child.process.processIdentifier,
            queue: queue, exited: { counter.increment() })
        let monitor = try #require(observed)
        monitor.start { registered.signal() }
        try #require(registered.wait(timeout: .now() + 2) == .success)
        monitor.cancel()
        monitor.cancel()
        #expect(counter.value == 0)
        child.closeInput()
        try #require(child.join(timeout: 2))
        queue.sync {}
        #expect(counter.value == 0)
        let invalid: DoryRendererWorkerProcessExitMonitor? = DoryRendererWorkerProcessExitMonitor(
            processIdentifier: 0, queue: queue, exited: { counter.increment() })
        #expect(invalid == nil)
    }
}

/// Only this fixture's child can be terminated. The open pipe gates /bin/cat until its exact
/// kernel observer is registered, with bounded joins on every assertion-failure cleanup path.
private final class RendererExitTestChild {
    let process = Process()
    private let input = Pipe()
    private let termination = DispatchGroup()

    init() throws {
        termination.enter()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let termination = self.termination
        process.terminationHandler = { _ in termination.leave() }
        try process.run()
    }

    func closeInput() { try? input.fileHandleForWriting.close() }
    func join(timeout: TimeInterval) -> Bool {
        termination.wait(timeout: .now() + timeout) == .success
    }
    func stop() {
        closeInput()
        if !join(timeout: 2), process.isRunning {
            process.terminate()
            _ = join(timeout: 2)
        }
    }
}

private final class RendererExitProofCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
