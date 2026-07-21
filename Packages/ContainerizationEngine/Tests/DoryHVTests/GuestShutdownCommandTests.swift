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

    @Test func periodicStorageReclaimTrimsOnlyTheMountedDockerFilesystem() throws {
        let command = GuestStorageReclaimCommand.periodicLoop(intervalSeconds: 90)

        #expect(command.contains("sleep 90"))
        #expect(command.contains("mountpoint -q /var/lib/docker"))
        #expect(command.contains("fstrim -v /var/lib/docker"))
        #expect(command.contains("/mnt/dory-logs/data-trim.log"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func dockerRestartHelperPreservesItsRuntimeArguments() {
        let command = GuestDockerRestartCommand.installerLines(
            dockerdArguments: "dockerd $DORY_RUNTIME_ARGS"
        ).joined(separator: "\n")

        #expect(command.contains("set -- dockerd $DORY_RUNTIME_ARGS"))
        #expect(command.contains("[ -z \"\\$DORY_DOCKERD_ARG\" ]"))
        #expect(command.contains("set -- \"\\$@\" \"\\$DORY_DOCKERD_ARG\""))
        #expect(command.contains("exec \"\\$@\""))
        #expect(!command.contains("exec \"$@\""))
    }

    @Test func buildCacheGCKeepsAUsefulBoundedCache() throws {
        let command = GuestBuildCacheGCCommand.configureDaemon()

        #expect(command.contains("/etc/docker/daemon.json"))
        #expect(command.contains("\"enabled\":true"))
        #expect(command.contains("\"defaultKeepStorage\":\"2GB\""))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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
