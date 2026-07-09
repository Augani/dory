import DoryCore
@testable import DorydKit
import XCTest

final class MachineManagerTests: XCTestCase {
    func testCreateStartStopDeleteMachineProcess() throws {
        let base = "/tmp/dory-machine-manager-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        let created = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
        ))
        XCTAssertEqual(created.state, .created)

        let running = try manager.start(id: "dev")
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.pid)
        XCTAssertEqual(manager.list().map(\.id), ["dev"])

        let stopped = try manager.stop(id: "dev")
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)

        try manager.delete(id: "dev")
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testRejectsDuplicateAndInvalidMachineIDs() throws {
        let base = "/tmp/dory-machine-manager-invalid-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
            id: "bad/id",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidID("bad/id"))
        }

        _ = try manager.create(DoryMachineConfiguration(id: "dev", kernelPath: "/tmp/kernel", rootfsPath: "/tmp/rootfs"))
        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(id: "dev", kernelPath: "/tmp/kernel", rootfsPath: "/tmp/rootfs"))) { error in
            XCTAssertEqual(error as? MachineManagerError, .duplicateMachine("dev"))
        }
    }

    func testRejectsDotAndDotDotMachineIDsForCreateAndDelete() throws {
        let base = "/tmp/dory-machine-traversal-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: "\(base)/machines", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sentinel = "\(base)/sentinel"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        for id in [".", "..", "..."] {
            XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
                id: id,
                kernelPath: "/tmp/kernel",
                rootfsPath: "/tmp/rootfs"
            ))) { error in
                XCTAssertEqual(error as? MachineManagerError, .invalidID(id))
            }
            XCTAssertThrowsError(try manager.delete(id: id)) { error in
                XCTAssertEqual(error as? MachineManagerError, .invalidID(id))
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/machines"))
    }

    func testImportSnapshotRejectsTraversalMachineID() throws {
        let base = "/tmp/dory-machine-import-traversal-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        let bundlePath = "\(base)/evil.dorymachine"
        try writeMachineBundle(
            toPath: bundlePath,
            snapshot: DoryMachineSnapshot(
                id: "s1",
                machineID: "..",
                note: "",
                createdISO: "2026-07-07T00:00:00Z",
                rootfsPath: "/ignored",
                sizeBytes: 0,
                kernelPath: "/tmp/kernel",
                memoryMB: 2048,
                cpuCount: 2
            ),
            rootfs: Data("evil".utf8)
        )

        XCTAssertThrowsError(try manager.importSnapshot(fromPath: bundlePath)) { error in
            XCTAssertEqual(error as? MachineManagerError, .persistence("invalid snapshot metadata"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/../snapshots"))
    }

    func testRestoreSnapshotLeavesLiveRootfsIntactWhenCopyFails() throws {
        let base = "/tmp/dory-machine-restore-atomic-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(id: "dev", kernelPath: "/tmp/kernel", rootfsPath: sourceRootfs))
        let devRootfs = "\(base)/machines/dev/rootfs.ext4"
        try Data("live-disk-v1".utf8).write(to: URL(fileURLWithPath: devRootfs))
        let snapshot = try manager.snapshot(id: "dev", createdISO: "2026-07-07T00:00:00Z", snapshotID: "s1")

        try FileManager.default.removeItem(atPath: snapshot.rootfsPath)
        try FileManager.default.createDirectory(atPath: snapshot.rootfsPath, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(snapshot.rootfsPath)/inner"))

        try Data("live-disk-v2".utf8).write(to: URL(fileURLWithPath: devRootfs))
        XCTAssertThrowsError(try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1"))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: devRootfs, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(
            String(data: try Data(contentsOf: URL(fileURLWithPath: devRootfs)), encoding: .utf8),
            "live-disk-v2"
        )
    }

    func testMachineDefinitionsPersistAcrossManagerRestart() throws {
        let base = "/tmp/dory-machine-persist-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let share = "\(base)-share"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        defer { try? FileManager.default.removeItem(atPath: share) }
        let config = MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        )

        let manager = MachineManager(configuration: config)
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 4096,
            cpuCount: 4,
            shares: [
                DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src", readOnly: true),
            ],
            environment: ["APP_ENV": "dev"]
        ))

        let configPath = "\(base)/dev/machine.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)

        let reloaded = MachineManager(configuration: config)
        let loaded = reloaded.list()
        XCTAssertEqual(loaded.map(\.id), ["dev"])
        XCTAssertEqual(loaded.first?.state, .stopped)
        XCTAssertEqual(loaded.first?.shares, [
            DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src", readOnly: true),
        ])
        XCTAssertEqual(loaded.first?.environment, ["APP_ENV": "dev"])
        let running = try reloaded.start(id: "dev")
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.pid)
        let stopped = try reloaded.stop(id: "dev")
        XCTAssertEqual(stopped.state, .stopped)
        try reloaded.delete(id: "dev")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/dev"))
    }

    func testStartPassesEnvironmentArgumentsToVMM() throws {
        let base = "/tmp/dory-machine-env-argv-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let argsPath = "\(base)/argv.txt"
        let helperPath = "\(base)/record-vmm.sh"
        try """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argsPath)"
        sleep 30
        """.write(to: URL(fileURLWithPath: helperPath), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)

        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: helperPath,
            stateDirectory: "\(base)/state",
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            environment: ["APP_ENV": "dev"]
        ))
        _ = try manager.start(id: "dev")

        let args = try waitForFileContent(argsPath)
        XCTAssertTrue(args.contains("--env\nAPP_ENV=dev"))
    }

    func testLegacyMachineDefinitionsLoadWithoutShareField() throws {
        let base = "/tmp/dory-machine-legacy-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/dev", withIntermediateDirectories: true)
        let legacyJSON = Data("""
        {
          "id": "dev",
          "kernelPath": "/tmp/kernel",
          "rootfsPath": "/tmp/rootfs",
          "memoryMB": 2048,
          "cpuCount": 2
        }
        """.utf8)
        try legacyJSON.write(to: URL(fileURLWithPath: "\(base)/dev/machine.json"))

        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        let loaded = manager.list()
        XCTAssertEqual(loaded.map(\.id), ["dev"])
        XCTAssertEqual(loaded.first?.shares, [])
        XCTAssertEqual(loaded.first?.environment, [:])
    }

    func testUpdatePersistsMachineResourcesAndRestartsRunningMachine() throws {
        let base = "/tmp/dory-machine-update-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let share = "\(base)-share"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        defer { try? FileManager.default.removeItem(atPath: share) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 2,
            address: "192.168.215.40"
        ))
        _ = try manager.start(id: "dev")

        let updated = try manager.update(
            id: "dev",
            memoryMB: 4096,
            cpuCount: 4,
            address: "192.168.215.41",
            updatesAddress: true,
            shares: [
                DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src"),
            ],
            updatesShares: true,
            environment: ["NODE_ENV": "production"],
            updatesEnvironment: true
        )

        XCTAssertEqual(updated.state, .running)
        XCTAssertEqual(updated.memoryMB, 4096)
        XCTAssertEqual(updated.cpuCount, 4)
        XCTAssertEqual(updated.address, "192.168.215.41")
        XCTAssertEqual(updated.shares, [
            DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src"),
        ])
        XCTAssertEqual(updated.environment, ["NODE_ENV": "production"])
        let stored = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: "\(base)/dev/machine.json"))
        )
        XCTAssertEqual(stored.memoryMB, 4096)
        XCTAssertEqual(stored.cpuCount, 4)
        XCTAssertEqual(stored.address, "192.168.215.41")
        XCTAssertEqual(stored.shares, [
            DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src"),
        ])
        XCTAssertEqual(stored.environment, ["NODE_ENV": "production"])
    }

    func testRejectsNonIPv4MachineAddress() throws {
        let base = "/tmp/dory-machine-address-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            address: "dev.dory.local"
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidAddress("dev.dory.local"))
        }
    }

    func testCreateClonesRootfsIntoPerMachineStateDirectory() throws {
        let base = "/tmp/dory-machine-rootfs-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: sourceRootfs
        ))

        let configPath = "\(base)/machines/dev/machine.json"
        let stored = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: configPath))
        )
        XCTAssertEqual(stored.rootfsPath, "\(base)/machines/dev/rootfs.ext4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.rootfsPath))

        try Data("machine-mutated".utf8).write(to: URL(fileURLWithPath: stored.rootfsPath))
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: sourceRootfs)), encoding: .utf8), "base-rootfs")
    }

    func testSnapshotsCopyRestoreCloneExportImportAndDeleteRootfs() throws {
        let base = "/tmp/dory-machine-snapshots-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? manager.delete(id: "dev-copy")
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: sourceRootfs,
            memoryMB: 4096,
            cpuCount: 4
        ))
        _ = try manager.start(id: "dev")
        let devRootfs = "\(base)/machines/dev/rootfs.ext4"
        try Data("snapshot-v1".utf8).write(to: URL(fileURLWithPath: devRootfs))

        let snapshot = try manager.snapshot(
            id: "dev",
            note: "before upgrade",
            createdISO: "2026-07-07T00:00:00Z",
            snapshotID: "s1"
        )

        XCTAssertEqual(snapshot.id, "s1")
        XCTAssertEqual(snapshot.machineID, "dev")
        XCTAssertEqual(snapshot.note, "before upgrade")
        XCTAssertEqual(snapshot.memoryMB, 4096)
        XCTAssertEqual(snapshot.cpuCount, 4)
        XCTAssertEqual(manager.status(id: "dev")?.state, .running)
        XCTAssertEqual(try manager.listSnapshots(machineID: "dev").map(\.id), ["s1"])
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: snapshot.rootfsPath)), encoding: .utf8), "snapshot-v1")

        try Data("snapshot-v2".utf8).write(to: URL(fileURLWithPath: devRootfs))
        let clone = try manager.cloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-copy")
        XCTAssertEqual(clone.state, .running)
        XCTAssertEqual(
            String(data: try Data(contentsOf: URL(fileURLWithPath: "\(base)/machines/dev-copy/rootfs.ext4")), encoding: .utf8),
            "snapshot-v1"
        )

        let restored = try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1")
        XCTAssertEqual(restored.state, .running)
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: devRootfs)), encoding: .utf8), "snapshot-v1")

        let bundle = "\(base)/dev.dorymachine"
        try manager.exportSnapshot(machineID: "dev", snapshotID: "s1", toPath: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle))

        try manager.deleteSnapshot(machineID: "dev", snapshotID: "s1")
        XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty)

        let imported = try manager.importSnapshot(fromPath: bundle)
        XCTAssertEqual(imported.id, "s1")
        XCTAssertEqual(imported.machineID, "dev")
        XCTAssertEqual(try manager.listSnapshots(machineID: "dev").map(\.id), ["s1"])
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: imported.rootfsPath)), encoding: .utf8), "snapshot-v1")
    }

    func testRequiredHandoffMovesMachineFromStartingToRunning() throws {
        let base = "/tmp/dory-machine-handoff-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: true
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
        ))

        let starting = try manager.start(id: "dev")
        XCTAssertEqual(starting.state, .starting)
        let handoffPath = try XCTUnwrap(starting.handoffSocketPath)

        try sendVmmHandoff(
            path: handoffPath,
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                shellSocketPath: "/run/shell.sock"
            ),
            fileDescriptors: []
        )

        let running = try waitForMachineState(manager, id: "dev", state: .running)
        XCTAssertEqual(running.agentBuild, "dory-agent/test")
        XCTAssertEqual(running.agentSocketPath, "/run/agent.sock")
        XCTAssertEqual(running.dockerdSocketPath, "/run/docker.sock")
        XCTAssertEqual(running.shellSocketPath, "/run/shell.sock")
        XCTAssertEqual(running.handoffFDCount, 0)
    }

    func testWakeClockSyncsRunningMachineAgents() throws {
        let base = "/tmp/dory-machine-clock-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: connector.connect(socketPath:)
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
        ))
        let starting = try manager.start(id: "dev")
        let handoffPath = try XCTUnwrap(starting.handoffSocketPath)
        try sendVmmHandoff(
            path: handoffPath,
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: "dev", state: .running)

        let result = manager.syncAgentClock(now: Date(timeIntervalSince1970: 1_234.5))

        XCTAssertEqual(result, AgentClockSyncResult(name: "machines", attempted: true, synced: true))
        XCTAssertEqual(connector.connectedPaths, ["/run/agent.sock"])
        XCTAssertEqual(connector.clockSyncs, [1_234_500_000_000])
    }

    func testExecRunsThroughRunningMachineAgent() throws {
        let base = "/tmp/dory-machine-exec-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: connector.connect(socketPath:)
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(id: "dev", kernelPath: "/tmp/kernel", rootfsPath: "/tmp/rootfs"))
        let starting = try manager.start(id: "dev")
        let handoffPath = try XCTUnwrap(starting.handoffSocketPath)
        try sendVmmHandoff(
            path: handoffPath,
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: "dev", state: .running)

        let result = try manager.exec(
            id: "dev",
            argv: ["/bin/sh", "-lc", "echo hi"],
            cwd: "/work",
            env: [DoryExecEnvironment(key: "A", value: "B")],
            timeoutMs: 123,
            outputLimitBytes: 456
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "machine-exec-ok\n")
        XCTAssertEqual(connector.execs, [
            RecordingMachineAgentConnector.Exec(
                argv: ["/bin/sh", "-lc", "echo hi"],
                cwd: "/work",
                env: [DoryExecEnvironment(key: "A", value: "B")],
                timeoutMs: 123,
                outputLimitBytes: 456
            ),
        ])
    }

    func testMemorySnapshotsIncludeRunningMachineTelemetry() throws {
        let base = "/tmp/dory-machine-memory-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector(telemetry: DoryTelemetry(
            memTotalKB: 3072 * 1024,
            memAvailableKB: 1536 * 1024,
            psiSomeAvg10: 0.5,
            psiFullAvg10: 0
        ))
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: connector.connect(socketPath:)
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 3072,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: "dev", state: .running)

        let snapshots = manager.memorySnapshots()

        XCTAssertEqual(snapshots.map(\.id), ["machine.dev"])
        XCTAssertEqual(snapshots.first?.kind, .virtualMachine)
        XCTAssertEqual(snapshots.first?.currentTargetMB, 3072)
        XCTAssertEqual(snapshots.first?.maximumTargetMB, 3072)
        XCTAssertEqual(snapshots.first?.telemetry.memTotalKB, 3072 * 1024)
        XCTAssertEqual(snapshots.first?.canBalloon, true)
        XCTAssertEqual(connector.connectedPaths, ["/run/agent.sock"])
    }

    func testMemorySnapshotsMarkMachinesWithoutControlSocketAsNotBalloonable() throws {
        let base = "/tmp/dory-machine-memory-no-balloon-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: { _ in RecordingMachineAgentClient(recorder: RecordingMachineAgentConnector(), telemetry: DoryTelemetry(
                memTotalKB: 2048 * 1024,
                memAvailableKB: 1024 * 1024,
                psiSomeAvg10: 0,
                psiFullAvg10: 0
            )) }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(id: "dev", kernelPath: "/tmp/kernel", rootfsPath: "/tmp/rootfs"))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: "dev", state: .running)

        XCTAssertEqual(manager.memorySnapshots().first?.canBalloon, false)
    }

    func testApplyBalloonTargetUpdatesLiveTargetWithoutShrinkingMaximum() throws {
        let base = "/tmp/dory-machine-balloon-apply-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector(telemetry: DoryTelemetry(
            memTotalKB: 4096 * 1024,
            memAvailableKB: 2048 * 1024,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        ))
        let balloon = RecordingMachineBalloonController()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            balloonController: balloon,
            agentConnector: connector.connect(socketPath:)
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 4096,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: "dev", state: .running)

        try manager.applyBalloonTargets([
            BalloonTarget(
                id: "machine.dev",
                kind: .virtualMachine,
                currentTargetMB: 4096,
                targetMB: 3072,
                reason: .hostWarning
            ),
        ])

        XCTAssertEqual(balloon.applied, [
            RecordingMachineBalloonController.Apply(socketPath: "/run/control.sock", targetMB: 3072),
        ])
        let snapshot = try XCTUnwrap(manager.memorySnapshots().first)
        XCTAssertEqual(snapshot.currentTargetMB, 3072)
        XCTAssertEqual(snapshot.maximumTargetMB, 4096)
    }

    func testHandoffSocketStartFailureReleasesManagerLock() throws {
        let longComponent = String(repeating: "a", count: 120)
        let base = "/tmp/dory-machine-handoff-long-\(longComponent)"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: true
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
        ))

        XCTAssertThrowsError(try manager.start(id: "dev")) { error in
            XCTAssertTrue("\(error)".contains("handoff socket path is too long"))
        }

        let lockReleased = expectation(description: "manager lock released after start failure")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = manager.list()
            lockReleased.fulfill()
        }
        wait(for: [lockReleased], timeout: 1)
        XCTAssertEqual(manager.status(id: "dev")?.state, .created)
    }
}

private final class RecordingMachineAgentConnector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var syncs: [Int64] = []
    private var recordedExecs: [Exec] = []
    private let telemetry: DoryTelemetry

    init(telemetry: DoryTelemetry = DoryTelemetry(memTotalKB: 1, memAvailableKB: 1, psiSomeAvg10: 0, psiFullAvg10: 0)) {
        self.telemetry = telemetry
    }

    struct Exec: Equatable {
        var argv: [String]
        var cwd: String
        var env: [DoryExecEnvironment]
        var timeoutMs: UInt64
        var outputLimitBytes: UInt64
    }

    var connectedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    var clockSyncs: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return syncs
    }

    var execs: [Exec] {
        lock.lock()
        defer { lock.unlock() }
        return recordedExecs
    }

    func connect(socketPath: String) throws -> any AgentControlClient {
        lock.lock()
        paths.append(socketPath)
        lock.unlock()
        return RecordingMachineAgentClient(recorder: self, telemetry: telemetry)
    }

    func recordClockSync(_ hostEpochNs: Int64) {
        lock.lock()
        syncs.append(hostEpochNs)
        lock.unlock()
    }

    func recordExec(_ exec: Exec) {
        lock.lock()
        recordedExecs.append(exec)
        lock.unlock()
    }
}

private final class RecordingMachineAgentClient: AgentControlClient, @unchecked Sendable {
    private let recorder: RecordingMachineAgentConnector
    private let telemetryValue: DoryTelemetry

    init(recorder: RecordingMachineAgentConnector, telemetry: DoryTelemetry) {
        self.recorder = recorder
        self.telemetryValue = telemetry
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(protocolVersion: 1, kernel: "Linux test", agentBuild: "dory-agent/test", uptimeSeconds: 1)
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        recorder.recordClockSync(hostEpochNs)
        return true
    }

    func portsWatch() throws -> DoryPortsSnapshot {
        DoryPortsSnapshot(ports: [], added: [], removed: [])
    }

    func telemetry() throws -> DoryTelemetry {
        telemetryValue
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        recorder.recordExec(RecordingMachineAgentConnector.Exec(
            argv: argv,
            cwd: cwd,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        ))
        return DoryExecResult(
            exitCode: 0,
            stdout: Data("machine-exec-ok\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func close() {}
}

private final class RecordingMachineBalloonController: MachineBalloonControlling, @unchecked Sendable {
    struct Apply: Equatable {
        var socketPath: String
        var targetMB: UInt64
    }

    private let lock = NSLock()
    private var applies: [Apply] = []

    var applied: [Apply] {
        lock.lock()
        defer { lock.unlock() }
        return applies
    }

    func setBalloonTarget(socketPath: String, targetMB: UInt64) throws {
        lock.lock()
        applies.append(Apply(socketPath: socketPath, targetMB: targetMB))
        lock.unlock()
    }
}

private func writeMachineBundle(
    toPath path: String,
    snapshot: DoryMachineSnapshot,
    rootfs: Data
) throws {
    let magic = Data("DORYMACHINE1\n".utf8)
    let metadata = try JSONEncoder().encode(snapshot)
    var length = Data()
    let count = UInt64(metadata.count)
    for shift in stride(from: 56, through: 0, by: -8) {
        length.append(UInt8((count >> UInt64(shift)) & 0xff))
    }
    var bundle = Data()
    bundle.append(magic)
    bundle.append(length)
    bundle.append(metadata)
    bundle.append(rootfs)
    try bundle.write(to: URL(fileURLWithPath: path))
}

private func waitForMachineState(
    _ manager: MachineManager,
    id: String,
    state: DoryMachineState,
    timeout: TimeInterval = 2
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id), status.state == state {
            return status
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try XCTUnwrap(manager.status(id: id))
}

private func waitForFileContent(_ path: String, timeout: TimeInterval = 2) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let content = try? String(contentsOfFile: path), !content.isEmpty {
            return content
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try String(contentsOfFile: path)
}
