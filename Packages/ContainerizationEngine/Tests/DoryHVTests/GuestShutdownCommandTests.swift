import DoryCore
@testable import DoryHV
import Foundation
import Testing

struct GuestShutdownCommandTests {
    @Test func stopsDockerBeforeSyncingAndPoweringOff() throws {
        let command = GuestShutdownCommand.listener()

        #expect(command.contains("nc -l -p 2377"))
        #expect(command.contains("cat /var/run/docker.pid"))
        #expect(command.contains("pidof dockerd"))
        #expect(command.contains("kill -TERM $DORY_DOCKERD_PID"))
        #expect(command.contains("while kill -0 $DORY_DOCKERD_PID"))
        #expect(command.contains("\"$DORY_DOCKERD_WAIT\" -lt \(DoryEngineShutdownTiming.dockerdPollAttempts)"))
        #expect(command.contains("kill -KILL $DORY_DOCKERD_PID"))
        #expect(command.contains("fstrim -v /var/lib/docker"))
        #expect(command.contains("/mnt/dory-logs/data-trim.log"))

        let terminate = try #require(command.range(of: "kill -TERM")).lowerBound
        let trim = try #require(command.range(of: "fstrim -v /var/lib/docker")).lowerBound
        let firstSync = try #require(command.range(of: "sync;")).lowerBound
        let unmount = try #require(command.range(of: "umount /var/lib/docker")).lowerBound
        let poweroff = try #require(command.range(of: "poweroff -f")).lowerBound
        #expect(terminate < firstSync)
        #expect(terminate < trim)
        #expect(trim < firstSync)
        #expect(firstSync < unmount)
        #expect(unmount < poweroff)
    }

    @Test func customShutdownPortIsRendered() {
        #expect(GuestShutdownCommand.listener(port: 4242).contains("nc -l -p 4242"))
    }

    @Test func generatedListenerIsValidPOSIXShellSyntax() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", GuestShutdownCommand.listener()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test func detachedAgentRequestReturnsBeforePoweroffAndIsValidShell() throws {
        let command = GuestShutdownCommand.detachedAgentRequest()
        #expect(command.contains("sleep 0.1"))
        #expect(command.contains("kill -TERM $DORY_DOCKERD_PID"))
        #expect(command.contains("poweroff -f"))
        #expect(command.hasSuffix("2>&1 </dev/null &"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }
}
