import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct ChildProcessTerminatorTests {
    @Test func gracefulChildIsTerminatedAndReaped() throws {
        let process = try launchReadyShell(#"trap 'exit 0' TERM; printf READY; while :; do :; done"#)
        defer { forceCleanup(process) }
        let pid = process.processIdentifier

        let outcome = ChildProcessTerminator.terminateAndReap(process, gracePeriod: 0.5, pollInterval: 0.005)

        #expect(outcome == .terminated)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(childWasReaped(pid))
    }

    @Test func stubbornChildIsKilledWithinBoundAndReaped() throws {
        let process = try launchReadyShell(#"trap '' TERM; printf READY; while :; do :; done"#)
        defer { forceCleanup(process) }
        let pid = process.processIdentifier
        let start = ProcessInfo.processInfo.systemUptime

        let outcome = ChildProcessTerminator.terminateAndReap(process, gracePeriod: 0.05, pollInterval: 0.005)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(outcome == .killed)
        #expect(elapsed < 1)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(childWasReaped(pid))
    }

    @Test func alreadyExitedChildCanBeCleanedAgain() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let outcome = ChildProcessTerminator.terminateAndReap(process, gracePeriod: 0.01)

        #expect(outcome == .alreadyExited)
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)
        #expect(childWasReaped(pid))
    }

    private func launchReadyShell(_ script: String) throws -> Process {
        let ready = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        let marker = ready.fileHandleForReading.readData(ofLength: 5)
        #expect(String(decoding: marker, as: UTF8.self) == "READY")
        return process
    }

    private func forceCleanup(_ process: Process) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func childWasReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        errno = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }
}
