import Foundation
import Testing
@testable import DoryHV

struct GuestMemoryReclaimBootCommandTests {
    @Test func defaultModeKeepsEstablishedDropCachesPolicy() {
        let command = GuestMemoryReclaimBootCommand.idleLoop(experimentalSenpai: false)

        #expect(command.contains("[ ${c:-0} -gt 327680 ] && echo 1 > /proc/sys/vm/drop_caches"))
        #expect(command.contains("[ $quiet_running_ticks -ge 2 ] || continue"))
        #expect(!command.contains("/proc/pressure/memory"))
        #expect(!command.contains("memory.reclaim"))
        #expect(GuestMemoryReclaimBootCommand.hostPressureListener(experimentalSenpai: false) == "true")
    }

    @Test func experimentalSenpaiCommandUsesFailClosedPSIGate() {
        let command = GuestMemoryReclaimBootCommand.idleLoop(experimentalSenpai: true)

        #expect(command.contains("/proc/pressure/memory"))
        #expect(command.contains("END{if(!found) exit 1}"))
        #expect(command.contains("&& awk -v p=\"$psi\""))
        #expect(command.contains("|| continue; for r in"))
        #expect(!command.contains("${psi:-0}"))
        #expect(GuestMemoryReclaimBootCommand.hostPressureListener(experimentalSenpai: true).contains("nc -l -p 2378"))
    }

    @Test func psiConditionAllowsOnlyWellFormedLowPressure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-psi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pressureFile = directory.appendingPathComponent("memory pressure's value")

        try Data("some avg10=0.42 avg60=0.20 avg300=0.10 total=7\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n".utf8)
            .write(to: pressureFile)
        #expect(runPSICondition(path: pressureFile.path) == 0)

        try Data("some avg10=1.00 avg60=0.20 avg300=0.10 total=7\n".utf8).write(to: pressureFile)
        #expect(runPSICondition(path: pressureFile.path) != 0)

        for malformed in [
            "some avg60=0.20 avg300=0.10 total=7\n",
            "some avg10=not-a-number avg60=0.20 total=7\n",
            "some avg10=-0.25 avg60=0.20 total=7\n",
            "garbage\n",
            "",
        ] {
            try Data(malformed.utf8).write(to: pressureFile)
            #expect(runPSICondition(path: pressureFile.path) != 0)
        }
    }

    @Test func psiConditionFailsForMissingAndUnreadableInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-psi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        #expect(runPSICondition(path: missing.path) != 0)

        // A directory is present but cannot be read by awk as the expected PSI text file. Unlike
        // chmod(000), this remains deterministic even if the test process has elevated privileges.
        let unreadableAsFile = directory.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableAsFile, withIntermediateDirectories: true)
        #expect(runPSICondition(path: unreadableAsFile.path) != 0)
    }

    @Test func generatedCommandsAreValidPOSIXShellSyntax() {
        for experimentalSenpai in [false, true] {
            let script = GuestMemoryReclaimBootCommand.idleLoop(experimentalSenpai: experimentalSenpai)
                + "\n"
                + GuestMemoryReclaimBootCommand.hostPressureListener(experimentalSenpai: experimentalSenpai)
            #expect(runShell(script: script, syntaxOnly: true) == 0)
        }
    }

    private func runPSICondition(path: String) -> Int32 {
        let condition = GuestMemoryReclaimBootCommand.experimentalSenpaiPSIAllowsReclaimCondition(
            pressureMemoryPath: path
        )
        return runShell(script: condition)
    }

    private func runShell(script: String, syntaxOnly: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = syntaxOnly ? ["-n", "-c", script] : ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
