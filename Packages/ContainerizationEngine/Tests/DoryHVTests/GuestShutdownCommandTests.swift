@testable import DoryCore
@testable import DoryHV
import Foundation
import Darwin
import Testing

struct GuestShutdownCommandTests {
    @Test func fallbackInitUsesTheSameShutdownAndReclaimShell() throws {
        let root = ProcessInfo.processInfo.environment["DORY_TEST_REPO_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("guest/initfs/init"), encoding: .utf8)
        #expect(script.contains(GuestShutdownCommand.listener()))
        #expect(script.contains(GuestStorageReclaimCommand.periodicLoop()))
        #expect(script.contains("exec /usr/bin/dory-agent >/dev/console 2>&1"))
        let mounts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: mounts) }
        try "/dev/vdb /var/lib/docker ext4 rw 0 0\n".write(to: mounts, atomically: true, encoding: .utf8)
        let prefix = try #require(script.components(separatedBy: "\nmkdir -p /proc").first)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", prefix.replacingOccurrences(of: "/proc/mounts", with: mounts.path)
            + "\nmountpoint /var/lib/docker && mountpoint -q /var/lib/docker && ! mountpoint -q /missing"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func stopsDaemonsAndUnmountsBeforePoweroff() throws {
        let result = try runShutdown()
        #expect(result.status == 0)
        #expect(result.events == [
            "validate", "reload 101", "info", "stop 101", "stop 102", "stop 103", "trim", "sync", "unmount", "sync", "root-ro", "poweroff",
        ])
    }

    @Test(arguments: ["config-missing", "config-symlink", "config-malformed", "config-unchanged", "validate-timeout", "hup-fail", "info-fail", "info-hang", "reload-unchanged", "dockerd", "dockerd-timeout", "unmount", "root-ro"])
    func failedSafetyStageNeverPowersOff(failure: String) throws {
        let result = try runShutdown(failure: failure)
        #expect(result.status != 0)
        #expect(!result.events.contains("poweroff"))
        if !["dockerd", "dockerd-timeout", "unmount", "root-ro"].contains(failure) {
            #expect(!result.events.contains("stop 101"))
            #expect(!result.events.contains("unmount"))
        }
        if failure.hasPrefix("dockerd") {
            #expect(!result.events.contains("stop 102"))
            #expect(!result.events.contains("unmount"))
        }
        if failure == "unmount" { #expect(!result.events.contains("root-ro")) }
    }

    @Test func reloadPreservesOtherSettingsAndConfigPermissions() throws {
        let result = try runShutdown()
        let config = try #require(JSONSerialization.jsonObject(with: result.configuration) as? [String: Any])
        #expect(config["live-restore"] as? Bool == false)
        #expect((config["builder"] as? [String: Any])?["sentinel"] as? String == "unchanged")
        #expect(result.permissions == 0o640)
    }

    @Test func absentDaemonSkipsReloadAndStillUnmountsCleanly() throws {
        let result = try runShutdown(failure: "no-daemon")
        #expect(result.status == 0)
        #expect(!result.events.contains("validate"))
        #expect(!result.events.contains("reload 101"))
        #expect(!result.events.contains("info"))
        #expect(!result.events.contains("stop 101"))
        #expect(result.events.contains("unmount"))
        #expect(result.events.contains("poweroff"))
    }

    @Test func waitsForEffectiveReloadOnTheLocalSocket() throws {
        let result = try runShutdown(failure: "reload-delayed")
        #expect(result.status == 0)
        #expect(result.events.filter { $0 == "info" }.count == 3)
        let stopped = try #require(result.events.firstIndex(of: "stop 101"))
        #expect(result.events[..<stopped].filter { $0 == "info" }.count == 3)
    }

    @Test func unavailableSocketCanRecoverAfterTheFormerThreeAttempts() throws {
        let result = try runShutdown(failure: "socket-delayed")
        #expect(result.status == 0)
        #expect(result.events.filter { $0 == "info" }.count == 17)
        #expect(result.elapsedCentiseconds == 400)
        #expect(result.events.contains("poweroff"))
    }

    @Test(arguments: [850, 950])
    func socketRecoveryInTheLastTwoSecondsStillConfirmsReload(centiseconds: Int) throws {
        let result = try runShutdown(failure: "socket-delayed-\(centiseconds)")
        #expect(result.status == 0)
        #expect(result.elapsedCentiseconds == centiseconds)
        #expect(!result.events.contains("probe-budget-overrun"))
        #expect(result.events.contains("poweroff"))
    }

    @Test(arguments: ["info-fail", "info-hang", "reload-unchanged", "validation-delayed"])
    func reloadUsesOneTenSecondDeadlineAndRefusesCleanPoweroff(failure: String) throws {
        let result = try runShutdown(failure: failure)
        #expect(result.status != 0)
        #expect(result.elapsedCentiseconds == 1_000)
        #expect(!result.events.contains("stop 101"))
        #expect(!result.events.contains("unmount"))
        #expect(!result.events.contains("root-ro"))
        #expect(!result.events.contains("poweroff"))
    }

    @Test func disappearedDaemonDoesNotProveItsTasksDrained() throws {
        let result = try runShutdown(failure: "daemon-disappears")
        #expect(result.status != 0)
        #expect(result.events.filter { $0 == "info" }.count == 1)
        #expect(!result.events.contains("stop 102"))
        #expect(!result.events.contains("unmount"))
        #expect(!result.events.contains("poweroff"))
    }

    @Test(arguments: ["pid1", "pid1-and-agent"])
    func neverSignalsOrWaitsForPID1(scenario: String) throws {
        let result = try runShutdown(failure: scenario)
        #expect(result.status == 0)
        #expect(!result.events.contains("stop 1"))
        #expect(result.events.contains("poweroff"))
        #expect(result.events.contains("stop 103") == (scenario == "pid1-and-agent"))
    }

    @Test func detachedShutdownReadsReclaimPIDFileWithoutInheritedVariable() throws {
        let result = try runShutdown(detached: true)
        #expect(result.status == 0)
        let reclaim = try #require(result.events.firstIndex(of: "stop 104"))
        let trim = try #require(result.events.firstIndex(of: "trim"))
        #expect(reclaim < trim)
        #expect(result.events.contains("poweroff"))
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

    @Test(arguments: ["sleep", "fstrim"])
    func reclaimTerminationReapsItsActiveChild(active: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for tool in ["sleep", "fstrim", "mountpoint"] {
            let file = directory.appendingPathComponent(tool)
            let script = tool == active
                ? "#!/bin/sh\necho $$ > \"$CHILD_PID_FILE\"\nexec /bin/sleep 60\n"
                : "#!/bin/sh\nexit 0\n"
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let pidFile = directory.appendingPathComponent("loop.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", GuestStorageReclaimCommand.periodicLoop()
            .replacingOccurrences(of: "/run/dory-storage-reclaim.pid", with: pidFile.path)
            .replacingOccurrences(of: "/var/log/dory-data-trim.log", with: directory.appendingPathComponent("trim.log").path)
            .replacingOccurrences(of: "/mnt/dory-logs/data-trim.log", with: directory.appendingPathComponent("trim-copy.log").path) + "\nwait"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":/usr/bin:/bin"
        environment["CHILD_PID_FILE"] = childFile.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var ownedPIDs: [Int32] = []
        defer {
            for pid in ownedPIDs where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: childFile.path) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let loopPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childPID = try #require(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        ownedPIDs = [loopPID, childPID]
        #expect(kill(loopPID, SIGTERM) == 0)
        for _ in 0..<100 {
            if kill(childPID, 0) != 0 && kill(loopPID, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(kill(childPID, 0) != 0)
        #expect(kill(loopPID, 0) != 0)
    }

    @Test func dockerRestartHelperPreservesItsRuntimeArguments() throws {
        let command = GuestDockerRestartCommand.installerLines(
            dockerdArguments: "dockerd $DORY_RUNTIME_ARGS"
        ).joined(separator: "\n")

        #expect(command.contains("set -- dockerd $DORY_RUNTIME_ARGS"))
        #expect(command.contains("[ -z \"\\$DORY_DOCKERD_ARG\" ]"))
        #expect(command.contains("set -- \"\\$@\" \"\\$DORY_DOCKERD_ARG\""))
        #expect(command.contains("echo +memory >/sys/fs/cgroup/cgroup.subtree_control"))
        #expect(command.contains("mkdir -p /sys/fs/cgroup/dory-dockerd"))
        #expect(command.contains("echo \\$\\$ >/sys/fs/cgroup/dory-dockerd/cgroup.procs"))
        #expect(command.contains("exec \"\\$@\""))
        #expect(!command.contains("exec \"$@\""))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func buildCacheGCKeepsAUsefulBoundedCache() throws {
        let command = GuestBuildCacheGCCommand.configureDaemon()

        #expect(command.contains("/etc/docker/daemon.json"))
        #expect(command.contains("\"live-restore\":true"))
        #expect(command.contains("\"enabled\":true"))
        #expect(command.contains("\"defaultKeepStorage\":\"2GB\""))
        #expect(command.contains("\"default-ulimits\""))
        #expect(command.contains("\"nofile\""))
        #expect(command.contains("\"Hard\":65536"))
        #expect(command.contains("\"Soft\":65536"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func containerCompatibilityRaisesHostWideMapCount() throws {
        let command = GuestContainerCompatibilityCommand.configureKernel()

        #expect(GuestContainerCompatibilityCommand.maximumMapCount == 262_144)
        #expect(GuestContainerCompatibilityCommand.defaultOpenFiles == 65_536)
        #expect(command.contains("/proc/sys/vm/max_map_count"))
        #expect(command.contains("262144"))

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
        #expect(command.contains("dory_stop_service dockerd"))
        #expect(!command.contains(">/var/log/dory-shutdown.log"))
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

    @Test func detachedDesktopRequestUsesGracefulSystemShutdown() throws {
        let command = GuestShutdownCommand.detachedDesktopRequest()

        #expect(command.contains("systemd-run"))
        #expect(command.contains("--on-active=1s"))
        #expect(command.contains("systemctl poweroff"))
        #expect(!command.contains("poweroff -f"))
        #expect(!command.hasSuffix("&"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func runShutdown(failure: String = "", detached: Bool = false) throws -> (status: Int32, events: [String], configuration: Data, permissions: Int, elapsedCentiseconds: Int) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        try Data().write(to: trace)
        let clock = directory.appendingPathComponent("uptime")
        let ticks = directory.appendingPathComponent("ticks")
        try "0.00 0.00\n".write(to: clock, atomically: true, encoding: .utf8)
        try "0\n".write(to: ticks, atomically: true, encoding: .utf8)
        let configFile = directory.appendingPathComponent("daemon.json")
        if failure != "config-missing" {
            let config = failure == "config-malformed" ? #"{"live-restore":true,INVALID}"#
                : failure == "config-unchanged" ? #"{"live-restore":false}"#
                : #"{"live-restore":true,"builder":{"sentinel":"unchanged"}}"#
            try config.write(to: configFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configFile.path)
            if failure == "config-symlink" {
                let target = directory.appendingPathComponent("real-config.json")
                try FileManager.default.moveItem(at: configFile, to: target)
                try FileManager.default.createSymbolicLink(at: configFile, withDestinationURL: target)
            }
        }
        // Shell functions isolate every process, mount and power operation from the host.
        let stubs = #"""
        DOCKER_UP=1; CONTAINERD_UP=1; AGENT_UP=1; RECLAIM_UP=1
        [ "$FAILURE" != no-daemon ] || DOCKER_UP=0
        trace() { printf '%s\n' "$*" >> "$TRACE"; }
        advance_clock() {
          DORY_FAKE_NOW=$(( $(/bin/cat "$TICKS_FILE") + $1 ))
          printf '%s\n' "$DORY_FAKE_NOW" >"$TICKS_FILE"
          printf '%s.%02d 0.00\n' "$((DORY_FAKE_NOW / 100))" "$((DORY_FAKE_NOW % 100))" >"$CLOCK_FILE"
        }
        duration_ticks() { DORY_DURATION=$1; echo $(( ${DORY_DURATION%.*} * 100 + 1${DORY_DURATION#*.} - 100 )); }
        timeout() {
          DORY_TEST_GRACE=$2; DORY_TEST_PROBE=$3; shift 3
          if [ "$1" = docker ]; then
            DORY_TEST_LIMIT=$(( $(duration_ticks "$DORY_TEST_GRACE") + $(duration_ticks "$DORY_TEST_PROBE") ))
            [ "$DORY_TEST_LIMIT" -le "$((1000 - $(/bin/cat "$TICKS_FILE")))" ] || { trace probe-budget-overrun; return 1; }
            [ "$FAILURE" != info-hang ] || { advance_clock "$DORY_TEST_LIMIT"; return 124; }
          fi
          [ "$FAILURE:$1" != validate-timeout:dockerd ] || { advance_clock 300; return 124; }
          "$@"
        }
        sleep() { [ "$1" = 0.1 ] || advance_clock "$(duration_ticks "$1")"; }
        dockerd() { trace validate; [ "$FAILURE" != validation-delayed ] || advance_clock 300; [ "$FAILURE" != config-malformed ]; }
        docker() {
          trace info
          [ "$1 $2 $3 $4 $5" = '-H unix:///var/run/docker.sock info --format {{.LiveRestoreEnabled}}' ] || return 1
          if [ "$FAILURE" = daemon-disappears ]; then : >"$DAEMON_GONE_FILE"; return 1; fi
          if [ "$FAILURE" = socket-delayed ] && [ "$(/bin/cat "$TICKS_FILE")" -lt 400 ]; then return 1; fi
          case "$FAILURE" in socket-delayed-*) [ "$(/bin/cat "$TICKS_FILE")" -ge "${FAILURE##*-}" ] || return 1 ;; esac
          [ "$FAILURE" != info-fail ] && [ "$FAILURE" != validation-delayed ] || return 1
          if [ "$FAILURE" = reload-unchanged ] || { [ "$FAILURE" = reload-delayed ] && [ "$(grep -c '^info$' "$TRACE")" -lt 3 ]; }; then echo true; else echo false; fi
        }
        cat() { [ "$1" = /run/dory-storage-reclaim.pid ] && [ "$DETACHED" = 1 ] && echo 104; }
        pidof() {
          case "$1" in
            dockerd) [ "$DOCKER_UP" = 1 ] && [ ! -f "$DAEMON_GONE_FILE" ] && echo 101 ;;
            containerd) [ "$CONTAINERD_UP" = 1 ] && echo 102 ;;
            dory-agent)
              case "$FAILURE" in pid1) echo 1 ;; pid1-and-agent) echo 1; [ "$AGENT_UP" = 1 ] && echo 103 ;; *) [ "$AGENT_UP" = 1 ] && echo 103 ;; esac ;;
          esac
        }
        kill() {
          if [ "$1" = -HUP ]; then trace "reload $2"; [ "$FAILURE" != hup-fail ]; return; fi
          if [ "$1" = -0 ]; then [ "$2" = 104 ] && [ "$RECLAIM_UP" = 1 ]; return; fi
          trace "stop $2"
          [ "$FAILURE:$2" != dockerd:101 ] || return 1
          [ "$FAILURE:$2" != dockerd-timeout:101 ] || return 0
          case "$2" in 101) DOCKER_UP=0 ;; 102) CONTAINERD_UP=0 ;; 103) AGENT_UP=0 ;; 104) RECLAIM_UP=0 ;; *) return 1 ;; esac
        }
        mountpoint() { return 0; }
        fstrim() { trace trim; }
        sync() { trace sync; }
        umount() { trace unmount; [ "$FAILURE" != unmount ]; }
        mount() { trace root-ro; [ "$FAILURE" != root-ro ]; }
        poweroff() { trace poweroff; }
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = detached
            ? GuestShutdownCommand.detachedAgentRequest()
                .replacingOccurrences(of: "/dev/console", with: directory.appendingPathComponent("console").path) + "\nwait"
            : GuestShutdownCommand.shutdownSequence()
        process.arguments = ["-c", stubs + "\n" + command
            .replacingOccurrences(of: "/etc/docker/daemon.json", with: configFile.path)
            .replacingOccurrences(of: "/proc/uptime", with: clock.path)
            .replacingOccurrences(of: "/usr/local/bin/dockerd", with: "dockerd")
            .replacingOccurrences(of: "/usr/local/bin/docker", with: "docker")]
        var environment = ProcessInfo.processInfo.environment
        environment["TRACE"] = trace.path
        environment["FAILURE"] = failure
        environment["DETACHED"] = detached ? "1" : "0"
        environment["CLOCK_FILE"] = clock.path
        environment["TICKS_FILE"] = ticks.path
        environment["DAEMON_GONE_FILE"] = directory.appendingPathComponent("daemon-gone").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
        let configuration = (try? Data(contentsOf: configFile)) ?? Data()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: configFile.path)[.posixPermissions] as? Int) ?? 0
        let elapsed = try Int(String(contentsOf: ticks, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (process.terminationStatus, events, configuration, permissions, elapsed)
    }
}
