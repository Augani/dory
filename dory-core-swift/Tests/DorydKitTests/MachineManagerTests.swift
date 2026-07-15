import CryptoKit
import DoryCore
@testable import DorydKit
import XCTest

final class MachineManagerTests: XCTestCase {
    func testShareArgumentsRoundTripDelimiterHeavyPathsAndJSON() throws {
        let shares = [
            DoryMachineShareConfiguration(
                tag: "source.one",
                hostPath: "/Volumes/Work: 2026/日本語/src",
                guestPath: "/workspace/client: app/日本語",
                readOnly: false
            ),
            DoryMachineShareConfiguration(
                tag: "cache",
                hostPath: "/tmp/cache:one",
                guestPath: "/var/cache/build:one",
                readOnly: true
            ),
        ]

        for share in shares {
            XCTAssertTrue(share.argumentValue.hasPrefix("dory-share-v1."))
            XCTAssertEqual(try DoryMachineShareConfiguration(argument: share.argumentValue), share)

            let json = try XCTUnwrap(String(
                data: JSONEncoder().encode(share),
                encoding: .utf8
            ))
            XCTAssertEqual(try DoryMachineShareConfiguration(argument: json), share)
        }

        XCTAssertEqual(
            try DoryMachineShareConfiguration(argument: "src=/tmp/src:/workspace/src:ro"),
            DoryMachineShareConfiguration(
                tag: "src",
                hostPath: "/tmp/src",
                guestPath: "/workspace/src",
                readOnly: true
            )
        )
        XCTAssertThrowsError(try DoryMachineShareConfiguration(argument: "dory-share-v1.invalid"))
        XCTAssertThrowsError(try DoryMachineShareConfiguration(argument: "{\"tag\":1}"))
    }

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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
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

    func testCreateRejectsInvalidKernelAndRootfsWithoutPublishingState() throws {
        let base = "/tmp/dory-machine-artifact-validation-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let sources = "\(base)/sources"
        try FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let emptyRootfs = "\(sources)/empty.ext4"
        let directoryRootfs = "\(sources)/directory.ext4"
        let symlinkRootfs = "\(sources)/symlink.ext4"
        let emptyKernel = "\(sources)/empty-kernel"
        let directoryKernel = "\(sources)/directory-kernel"
        let symlinkKernel = "\(sources)/symlink-kernel"
        try Data().write(to: URL(fileURLWithPath: emptyRootfs))
        try Data().write(to: URL(fileURLWithPath: emptyKernel))
        try FileManager.default.createDirectory(atPath: directoryRootfs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: directoryKernel, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(doryTestRootfsPath, symlinkRootfs), 0)
        XCTAssertEqual(symlink(doryTestKernelPath, symlinkKernel), 0)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        let invalidArtifacts = [
            ("missing-kernel", "\(sources)/missing-kernel", doryTestRootfsPath),
            ("empty-kernel", emptyKernel, doryTestRootfsPath),
            ("directory-kernel", directoryKernel, doryTestRootfsPath),
            ("symlink-kernel", symlinkKernel, doryTestRootfsPath),
            ("missing-rootfs", doryTestKernelPath, "\(sources)/missing.ext4"),
            ("empty-rootfs", doryTestKernelPath, emptyRootfs),
            ("directory-rootfs", doryTestKernelPath, directoryRootfs),
            ("symlink-rootfs", doryTestKernelPath, symlinkRootfs),
        ]

        for (id, kernel, rootfs) in invalidArtifacts {
            XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
                id: id,
                kernelPath: kernel,
                rootfsPath: rootfs
            )), id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/\(id)"), id)
        }
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testCreatePublishesOnlyPrivateManagedArtifacts() throws {
        let base = "/tmp/dory-machine-managed-rootfs-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let sourceRootfs = "\(base)/source.ext4"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data("source-disk".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        let managedRootfs = "\(base)/machines/dev/rootfs.ext4"
        let managedKernel = "\(base)/machines/dev/kernel"
        let definition = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: "\(base)/machines/dev/machine.json"))
        )
        XCTAssertEqual(definition.rootfsPath, managedRootfs)
        XCTAssertEqual(definition.kernelPath, managedKernel)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: managedRootfs)), Data("source-disk".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: managedKernel)), try Data(contentsOf: URL(fileURLWithPath: doryTestKernelPath)))
        for path in [managedRootfs, managedKernel] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
        }
    }

    func testLiveRootfsSubstitutionCannotReachStartOrSnapshot() throws {
        let base = "/tmp/dory-machine-live-rootfs-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sentinel = "\(base)/sentinel"
        try Data("host-private-data".utf8).write(to: URL(fileURLWithPath: sentinel))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let managedRootfs = "\(base)/machines/dev/rootfs.ext4"

        try FileManager.default.removeItem(atPath: managedRootfs)
        XCTAssertEqual(symlink(sentinel, managedRootfs), 0)
        XCTAssertThrowsError(try manager.start(id: "dev"))
        XCTAssertThrowsError(try manager.snapshot(id: "dev", snapshotID: "symlink"))

        try FileManager.default.removeItem(atPath: managedRootfs)
        XCTAssertEqual(link(sentinel, managedRootfs), 0)
        XCTAssertThrowsError(try manager.start(id: "dev"))
        XCTAssertThrowsError(try manager.snapshot(id: "dev", snapshotID: "hardlink"))
        XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "host-private-data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/symlink.ext4"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/hardlink.ext4"))
    }

    func testLiveKernelSubstitutionCannotReachStartOrSnapshot() throws {
        let base = "/tmp/dory-machine-live-kernel-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sentinel = "\(base)/sentinel"
        try Data("host-private-kernel".utf8).write(to: URL(fileURLWithPath: sentinel))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let managedKernel = "\(base)/machines/dev/kernel"

        try FileManager.default.removeItem(atPath: managedKernel)
        XCTAssertEqual(symlink(sentinel, managedKernel), 0)
        XCTAssertThrowsError(try manager.start(id: "dev"))
        XCTAssertThrowsError(try manager.snapshot(id: "dev", snapshotID: "symlink"))

        try FileManager.default.removeItem(atPath: managedKernel)
        XCTAssertEqual(link(sentinel, managedKernel), 0)
        XCTAssertThrowsError(try manager.start(id: "dev"))
        XCTAssertThrowsError(try manager.snapshot(id: "dev", snapshotID: "hardlink"))
        XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "host-private-kernel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/symlink.kernel"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/hardlink.kernel"))
    }

    func testSnapshotDirectorySubstitutionCannotRedirectWrites() throws {
        let base = "/tmp/dory-machine-snapshot-directory-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let redirected = "\(base)/redirected"
        try FileManager.default.createDirectory(atPath: redirected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let snapshotsPath = "\(base)/machines/dev/snapshots"
        XCTAssertEqual(symlink(redirected, snapshotsPath), 0)

        XCTAssertThrowsError(try manager.snapshot(id: "dev", snapshotID: "redirected"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirected).isEmpty)
        XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty)
    }

    func testPersistedRootfsRedirectIsNotLoaded() throws {
        let base = "/tmp/dory-machine-persisted-rootfs-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sentinel = "\(base)/sentinel"
        try Data("host-private-data".utf8).write(to: URL(fileURLWithPath: sentinel))
        let configuration = MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        )
        let manager = MachineManager(configuration: configuration)
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let definitionPath = "\(base)/machines/dev/machine.json"
        var definition = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: definitionPath))
        )
        definition.rootfsPath = sentinel
        try JSONEncoder().encode(definition).write(to: URL(fileURLWithPath: definitionPath), options: .atomic)

        let reloaded = MachineManager(configuration: configuration)
        XCTAssertTrue(reloaded.list().isEmpty)
        XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "host-private-data")
    }

    func testPersistedMachineDirectorySymlinkIsNotLoaded() throws {
        let base = "/tmp/dory-machine-directory-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let external = "\(base)/external-dev"
        let machines = "\(base)/machines"
        try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: external)
        try FileManager.default.createDirectory(atPath: machines, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let visibleRootfs = "\(machines)/dev/rootfs.ext4"
        let externalRootfs = "\(external)/rootfs.ext4"
        try Data("redirected-rootfs".utf8).write(to: URL(fileURLWithPath: externalRootfs))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalRootfs)
        let definition = DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: visibleRootfs
        )
        try JSONEncoder().encode(definition).write(
            to: URL(fileURLWithPath: "\(external)/machine.json")
        )
        XCTAssertEqual(symlink(external, "\(machines)/dev"), 0)

        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: machines,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        XCTAssertTrue(manager.list().isEmpty)
        XCTAssertEqual(try String(contentsOfFile: externalRootfs, encoding: .utf8), "redirected-rootfs")
    }

    func testPersistedMachineMetadataRejectsSymlinksHardLinksAndPublicFiles() throws {
        let base = "/tmp/dory-machine-metadata-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let machines = "\(base)/machines"
        let definitionPath = "\(machines)/dev/machine.json"
        let externalPath = "\(base)/external-machine.json"
        let configuration = MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: machines,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        let manager = MachineManager(configuration: configuration)
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let validDefinition = try Data(contentsOf: URL(fileURLWithPath: definitionPath))

        for variant in ["symlink", "hardlink", "public", "empty", "oversized"] {
            try? FileManager.default.removeItem(atPath: definitionPath)
            try? FileManager.default.removeItem(atPath: externalPath)
            try validDefinition.write(to: URL(fileURLWithPath: externalPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalPath)

            switch variant {
            case "symlink":
                XCTAssertEqual(symlink(externalPath, definitionPath), 0)
            case "hardlink":
                XCTAssertEqual(link(externalPath, definitionPath), 0)
            case "public":
                try validDefinition.write(to: URL(fileURLWithPath: definitionPath))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: definitionPath)
            case "empty":
                try Data().write(to: URL(fileURLWithPath: definitionPath))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definitionPath)
            default:
                try Data(repeating: 0, count: 16 * 1024 * 1024 + 1)
                    .write(to: URL(fileURLWithPath: definitionPath))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definitionPath)
            }

            let reloaded = MachineManager(configuration: configuration)
            XCTAssertTrue(reloaded.list().isEmpty, variant)
        }
    }

    func testDeleteFailurePreservesPersistedStoppedMachine() throws {
        let base = "/tmp/dory-machine-delete-failure-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let configuration = MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        )
        let manager = MachineManager(configuration: configuration)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base)
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base)

        XCTAssertThrowsError(try manager.delete(id: "dev")) { error in
            guard case let MachineManagerError.persistence(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("could not delete dev"))
        }
        XCTAssertEqual(manager.status(id: "dev")?.state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/dev/machine.json"))

        let reloaded = MachineManager(configuration: configuration)
        XCTAssertEqual(reloaded.list().map(\.id), ["dev"])
    }

    func testManagerRemovesInterruptedDeletionQuarantinesOnStartup() throws {
        let base = "/tmp/dory-machine-delete-quarantine-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let quarantine = "\(base)/.dory-machine-delete-dev-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: quarantine, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: "\(quarantine)/rootfs.ext4"))
        defer { try? FileManager.default.removeItem(atPath: base) }

        _ = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine))
    }

    func testManagerRemovesInterruptedMachineMetadataOnStartup() throws {
        let base = "/tmp/dory-machine-metadata-cleanup-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let temporaryMetadata = "\(base)/dev/.dory-machine-metadata-fixture"
        let temporaryRootfs = "\(base)/dev/.rootfs.ext4.tmp-fixture"
        let temporaryKernel = "\(base)/dev/.kernel.tmp-fixture"
        let restoreRootfs = "\(base)/dev/.restore-rootfs-fixture"
        let restoreKernel = "\(base)/dev/.restore-kernel-fixture"
        let temporaryRestore = "\(base)/dev/..restore-rootfs-fixture.tmp-fixture"
        try FileManager.default.createDirectory(atPath: "\(base)/dev", withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: temporaryMetadata))
        try Data("partial-disk".utf8).write(to: URL(fileURLWithPath: temporaryRootfs))
        try Data("partial-kernel".utf8).write(to: URL(fileURLWithPath: temporaryKernel))
        try Data("restore-disk".utf8).write(to: URL(fileURLWithPath: restoreRootfs))
        try Data("restore-kernel".utf8).write(to: URL(fileURLWithPath: restoreKernel))
        try Data("partial-restore".utf8).write(to: URL(fileURLWithPath: temporaryRestore))
        defer { try? FileManager.default.removeItem(atPath: base) }

        _ = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryMetadata))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRootfs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryKernel))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreRootfs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreKernel))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRestore))
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidID("bad/id"))
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .duplicateMachine("dev"))
        }
    }

    func testCreateNeverOverwritesAnAbandonedMachineStateDirectory() throws {
        let base = "/tmp/dory-machine-abandoned-create-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let abandoned = "\(base)/dev"
        try FileManager.default.createDirectory(atPath: abandoned, withIntermediateDirectories: true)
        let sentinel = "\(abandoned)/keep"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .duplicateMachine("dev"))
        }
        XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "keep")
        XCTAssertTrue(manager.list().isEmpty)
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
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath
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
            kernelPath: doryTestKernelPath,
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

    func testImportSnapshotRejectsInvalidResourcesBeforeExtractingRootfs() throws {
        let base = "/tmp/dory-machine-import-resources-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        let bundlePath = "\(base)/invalid-resources.dorymachine"
        try writeMachineBundle(
            toPath: bundlePath,
            snapshot: DoryMachineSnapshot(
                id: "s1",
                machineID: "dev",
                note: "",
                createdISO: "2026-07-07T00:00:00Z",
                rootfsPath: "/ignored",
                sizeBytes: 0,
            kernelPath: doryTestKernelPath,
                memoryMB: 2048,
                cpuCount: 0
            ),
            rootfs: Data("invalid".utf8)
        )

        XCTAssertThrowsError(try manager.importSnapshot(fromPath: bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/s1.ext4"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev/snapshots/s1.json"))
    }

    func testImportSnapshotRejectsCorruptTruncatedTrailingAndLegacyBundles() throws {
        let base = "/tmp/dory-machine-import-integrity-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        let validPath = "\(base)/valid.dorymachine"
        try writeMachineBundle(
            toPath: validPath,
            snapshot: DoryMachineSnapshot(
                id: "s1",
                machineID: "dev",
                note: "integrity",
                createdISO: "2026-07-07T00:00:00Z",
                rootfsPath: "/ignored",
                sizeBytes: 0,
            kernelPath: doryTestKernelPath,
                memoryMB: 2048,
                cpuCount: 2
            ),
            rootfs: Data("machine-rootfs-payload".utf8)
        )
        let valid = try Data(contentsOf: URL(fileURLWithPath: validPath))
        let payloadOffset = try machineBundlePayloadOffset(valid)

        var corruptMetadata = valid
        corruptMetadata[payloadOffset - 1] ^= 0xff
        var corruptPayload = valid
        corruptPayload[payloadOffset] ^= 0xff
        var corruptKernel = valid
        corruptKernel[corruptKernel.count - 1] ^= 0xff
        var trailing = valid
        trailing.append(0xff)
        var legacy = valid
        legacy[Data("DORYMACHINE".utf8).count] = Character("2").asciiValue!
        let variants = [
            ("corrupt-metadata", corruptMetadata),
            ("corrupt-payload", corruptPayload),
            ("corrupt-kernel", corruptKernel),
            ("truncated", valid.dropLast()),
            ("trailing", trailing),
            ("legacy", legacy),
        ]

        for (name, bytes) in variants {
            let path = "\(base)/\(name).dorymachine"
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try manager.importSnapshot(fromPath: path), name)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: "\(base)/machines/dev/snapshots/s1.ext4"
            ), name)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: "\(base)/machines/dev/snapshots/s1.json"
            ), name)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: "\(base)/machines/dev/snapshots/s1.kernel"
            ), name)
            let artifacts = (try? FileManager.default.contentsOfDirectory(
                atPath: "\(base)/machines/dev/snapshots"
            )) ?? []
            XCTAssertTrue(artifacts.isEmpty, "\(name) left import artifacts: \(artifacts)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: "\(base)/machines/dev"),
                "\(name) left an orphaned machine namespace"
            )
        }

        let symlinkPath = "\(base)/symlink.dorymachine"
        XCTAssertEqual(symlink(validPath, symlinkPath), 0)
        XCTAssertThrowsError(try manager.importSnapshot(fromPath: symlinkPath))
        let fifoPath = "\(base)/fifo.dorymachine"
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0)
        XCTAssertThrowsError(try manager.importSnapshot(fromPath: fifoPath))
    }

    func testDeletingLastImportedSnapshotRemovesOrphanedNamespace() throws {
        let base = "/tmp/dory-machine-import-cleanup-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let bundlePath = "\(base)/archive.dorymachine"
        try writeMachineBundle(
            toPath: bundlePath,
            snapshot: DoryMachineSnapshot(
                id: "backup",
                machineID: "archive",
                note: "portable backup",
                createdISO: "2026-07-07T00:00:00Z",
                rootfsPath: "/ignored",
                sizeBytes: 0,
                kernelPath: doryTestKernelPath,
                memoryMB: 2048,
                cpuCount: 2
            ),
            rootfs: Data("portable-rootfs".utf8)
        )
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        let imported = try manager.importSnapshot(fromPath: bundlePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/machines/archive"))
        try manager.deleteSnapshot(machineID: imported.machineID, snapshotID: imported.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/archive"))
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

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
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

    func testRestoreRollsBackRootfsWhenKernelCopyFails() throws {
        let base = "/tmp/dory-machine-restore-kernel-failure-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let rootfs = "\(base)/source-rootfs.ext4"
        let kernel = "\(base)/source-kernel"
        try Data("snapshot-rootfs".utf8).write(to: URL(fileURLWithPath: rootfs))
        try Data("snapshot-kernel".utf8).write(to: URL(fileURLWithPath: kernel))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: kernel,
            rootfsPath: rootfs
        ))
        let snapshot = try manager.snapshot(id: "dev", snapshotID: "s1")
        let liveRootfs = "\(base)/machines/dev/rootfs.ext4"
        let liveKernel = "\(base)/machines/dev/kernel"
        try Data("live-rootfs".utf8).write(to: URL(fileURLWithPath: liveRootfs))
        try Data("live-kernel".utf8).write(to: URL(fileURLWithPath: liveKernel))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: snapshot.kernelPath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.kernelPath)
        }

        XCTAssertThrowsError(try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1"))
        XCTAssertEqual(try String(contentsOfFile: liveRootfs, encoding: .utf8), "live-rootfs")
        XCTAssertEqual(try String(contentsOfFile: liveKernel, encoding: .utf8), "live-kernel")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: "\(base)/machines/dev")
            .filter { $0.hasPrefix(".restore-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSnapshotMetadataCannotRedirectOperationsOutsideManagedStorage() throws {
        let base = "/tmp/dory-machine-snapshot-redirect-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        let sentinel = "\(base)/sentinel"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        try Data("private-host-data".utf8).write(to: URL(fileURLWithPath: sentinel))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        var snapshot = try manager.snapshot(id: "dev", snapshotID: "s1")
        snapshot.rootfsPath = sentinel
        let metadataPath = "\(base)/machines/dev/snapshots/s1.json"
        try JSONEncoder().encode(snapshot).write(to: URL(fileURLWithPath: metadataPath), options: .atomic)

        XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty)
        XCTAssertThrowsError(try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1")) { error in
            XCTAssertEqual(error as? MachineManagerError, .unknownSnapshot("s1"))
        }
        XCTAssertThrowsError(try manager.exportSnapshot(
            machineID: "dev",
            snapshotID: "s1",
            toPath: "\(base)/redirected.dorymachine"
        )) { error in
            XCTAssertEqual(error as? MachineManagerError, .unknownSnapshot("s1"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/redirected.dorymachine"))
    }

    func testSnapshotMetadataRejectsSymlinksHardLinksAndPublicFiles() throws {
        let base = "/tmp/dory-machine-snapshot-metadata-tamper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let metadataPath = "\(base)/machines/dev/snapshots/s1.json"
        let externalPath = "\(base)/external-snapshot.json"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        _ = try manager.snapshot(id: "dev", snapshotID: "s1")
        let validMetadata = try Data(contentsOf: URL(fileURLWithPath: metadataPath))

        for variant in ["symlink", "hardlink", "public"] {
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: externalPath)
            try validMetadata.write(to: URL(fileURLWithPath: externalPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalPath)

            switch variant {
            case "symlink":
                XCTAssertEqual(symlink(externalPath, metadataPath), 0)
            case "hardlink":
                XCTAssertEqual(link(externalPath, metadataPath), 0)
            default:
                try validMetadata.write(to: URL(fileURLWithPath: metadataPath))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadataPath)
            }

            XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty, variant)
            XCTAssertThrowsError(try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1"), variant) { error in
                XCTAssertEqual(error as? MachineManagerError, .unknownSnapshot("s1"))
            }
        }
    }

    func testSnapshotOperationsRejectSymlinkAndHardLinkRootfsSubstitution() throws {
        let base = "/tmp/dory-machine-snapshot-links-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        let sentinel = "\(base)/sentinel"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        try Data("private-host-data".utf8).write(to: URL(fileURLWithPath: sentinel))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        let snapshot = try manager.snapshot(id: "dev", snapshotID: "s1")
        try FileManager.default.removeItem(atPath: snapshot.rootfsPath)
        XCTAssertEqual(symlink(sentinel, snapshot.rootfsPath), 0)
        XCTAssertThrowsError(try manager.exportSnapshot(
            machineID: "dev",
            snapshotID: "s1",
            toPath: "\(base)/symlink.dorymachine"
        )) { error in
            XCTAssertEqual(error as? MachineManagerError, .unknownSnapshot("s1"))
        }

        try FileManager.default.removeItem(atPath: snapshot.rootfsPath)
        XCTAssertEqual(link(sentinel, snapshot.rootfsPath), 0)
        XCTAssertThrowsError(try manager.exportSnapshot(
            machineID: "dev",
            snapshotID: "s1",
            toPath: "\(base)/hardlink.dorymachine"
        )) { error in
            XCTAssertEqual(error as? MachineManagerError, .unknownSnapshot("s1"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/symlink.dorymachine"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/hardlink.dorymachine"))
    }

    func testSnapshotDeleteFailurePreservesVisibleSnapshot() throws {
        let base = "/tmp/dory-machine-snapshot-delete-failure-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
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

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        let snapshot = try manager.snapshot(id: "dev", snapshotID: "s1")
        let snapshotDirectory = "\(base)/machines/dev/snapshots"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: snapshotDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory)
        }

        XCTAssertThrowsError(try manager.deleteSnapshot(machineID: "dev", snapshotID: "s1"))
        XCTAssertEqual(try manager.listSnapshots(machineID: "dev").map(\.id), ["s1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.rootfsPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(snapshotDirectory)/s1.json"))
    }

    func testManagerRemovesInterruptedSnapshotArtifactsOnStartup() throws {
        let base = "/tmp/dory-machine-snapshot-cleanup-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let directory = "\(base)/dev/snapshots"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let quarantinedRootfs = "\(directory)/.dory-snapshot-delete-s1-fixture.ext4"
        let quarantinedKernel = "\(directory)/.dory-snapshot-delete-s1-fixture.kernel"
        let quarantinedMetadata = "\(directory)/.dory-snapshot-delete-s1-fixture.json"
        let temporaryMetadata = "\(directory)/.dory-snapshot-metadata-s1-fixture"
        let temporaryRootfs = "\(directory)/.s1.ext4.tmp-fixture"
        let temporaryKernel = "\(directory)/.s1.kernel.tmp-fixture"
        for path in [
            quarantinedRootfs,
            quarantinedKernel,
            quarantinedMetadata,
            temporaryMetadata,
            temporaryRootfs,
            temporaryKernel,
        ] {
            try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        }
        defer { try? FileManager.default.removeItem(atPath: base) }

        _ = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedRootfs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedKernel))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedMetadata))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryMetadata))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRootfs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryKernel))
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
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
        let sharePath = "\(base)/share: build 日本語"
        try FileManager.default.createDirectory(atPath: sharePath, withIntermediateDirectories: true)
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [
                DoryMachineShareConfiguration(
                    tag: "src",
                    hostPath: sharePath,
                    guestPath: "/workspace/client: app 日本語"
                ),
            ],
            environment: ["APP_ENV": "dev"]
        ))
        _ = try manager.start(id: "dev")

        let args = try waitForFileContent(argsPath)
        XCTAssertTrue(args.contains("--env\nAPP_ENV=dev"))
        let rows = args.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shareFlagIndex = try XCTUnwrap(rows.firstIndex(of: "--share"))
        let wireShare = rows[shareFlagIndex + 1]
        XCTAssertEqual(
            try DoryMachineShareConfiguration(argument: wireShare),
            DoryMachineShareConfiguration(
                tag: "src",
                hostPath: sharePath,
                guestPath: "/workspace/client: app 日本語"
            )
        )
    }

    func testMachineDefinitionsLoadWithoutOptionalShareField() throws {
        let base = "/tmp/dory-machine-optional-fields-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/dev", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: "\(base)/dev")
        let rootfsPath = "\(base)/dev/rootfs.ext4"
        let kernelPath = "\(base)/dev/kernel"
        try Data("managed-rootfs".utf8).write(to: URL(fileURLWithPath: rootfsPath))
        try Data("managed-kernel".utf8).write(to: URL(fileURLWithPath: kernelPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootfsPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kernelPath)
        let definition = Data("""
        {
          "id": "dev",
          "kernelPath": "\(kernelPath)",
          "rootfsPath": "\(rootfsPath)",
          "memoryMB": 2048,
          "cpuCount": 2
        }
        """.utf8)
        let definitionPath = "\(base)/dev/machine.json"
        try definition.write(to: URL(fileURLWithPath: definitionPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definitionPath)

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

    func testPersistedInvalidResourcesCannotReachTheVMM() throws {
        let base = "/tmp/dory-machine-invalid-persisted-resources-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: "\(base)/dev", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: "\(base)/dev")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let rootfsPath = "\(base)/dev/rootfs.ext4"
        let kernelPath = "\(base)/dev/kernel"
        try Data("managed-rootfs".utf8).write(to: URL(fileURLWithPath: rootfsPath))
        try Data("managed-kernel".utf8).write(to: URL(fileURLWithPath: kernelPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootfsPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kernelPath)
        let definitionPath = "\(base)/dev/machine.json"
        try Data("""
        {
          "id": "dev",
          "kernelPath": "\(kernelPath)",
          "rootfsPath": "\(rootfsPath)",
          "memoryMB": 2048,
          "cpuCount": 0
        }
        """.utf8).write(to: URL(fileURLWithPath: definitionPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definitionPath)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertEqual(manager.status(id: "dev")?.cpuCount, 0)
        XCTAssertThrowsError(try manager.start(id: "dev"))
        XCTAssertEqual(manager.status(id: "dev")?.state, .stopped)
        XCTAssertNil(manager.status(id: "dev")?.pid)
    }

    func testPersistedInvalidAddressShareAndEnvironmentCannotReachTheVMM() throws {
        let base = "/tmp/dory-machine-invalid-persisted-host-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let invalidConfigurations: [(DoryMachineConfiguration, MachineManagerError)] = [
            (
                DoryMachineConfiguration(
                    id: "bad-address",
                    kernelPath: "\(base)/bad-address/kernel",
                    rootfsPath: "\(base)/bad-address/rootfs.ext4",
                    address: "machine.dory.local"
                ),
                .invalidAddress("machine.dory.local")
            ),
            (
                DoryMachineConfiguration(
                    id: "bad-share",
                    kernelPath: "\(base)/bad-share/kernel",
                    rootfsPath: "\(base)/bad-share/rootfs.ext4",
                    shares: [DoryMachineShareConfiguration(
                        tag: "src",
                        hostPath: "\(base)/missing-share",
                        guestPath: "/workspace/src"
                    )]
                ),
                .invalidShare("\(base)/missing-share")
            ),
            (
                DoryMachineConfiguration(
                    id: "bad-environment",
                    kernelPath: "\(base)/bad-environment/kernel",
                    rootfsPath: "\(base)/bad-environment/rootfs.ext4",
                    environment: ["1INVALID": "value"]
                ),
                .invalidEnvironment("1INVALID")
            ),
        ]
        for (machine, _) in invalidConfigurations {
            let directory = "\(base)/\(machine.id)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            try Data("managed-rootfs".utf8).write(to: URL(fileURLWithPath: machine.rootfsPath))
            try Data("managed-kernel".utf8).write(to: URL(fileURLWithPath: machine.kernelPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: machine.rootfsPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: machine.kernelPath)
            let definitionPath = "\(directory)/machine.json"
            try JSONEncoder().encode(machine).write(to: URL(fileURLWithPath: definitionPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definitionPath)
        }

        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        XCTAssertEqual(Set(manager.list().map(\.id)), Set(invalidConfigurations.map { $0.0.id }))
        for (machine, expectedError) in invalidConfigurations {
            XCTAssertThrowsError(try manager.start(id: machine.id)) { error in
                XCTAssertEqual(error as? MachineManagerError, expectedError)
            }
            XCTAssertEqual(manager.status(id: machine.id)?.state, .stopped)
            XCTAssertNil(manager.status(id: machine.id)?.pid)
        }
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
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

    func testAddressOnlyUpdateChangesDNSOverrideWithoutRestartAndNoOpDoesNot() throws {
        let base = "/tmp/dory-machine-address-restart-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let starter = RecordingProcessStarter()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            processStarter: { process in try starter.start(process) }
        )
        defer { try? manager.delete(id: "dev") }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            address: "192.168.215.40"
        ))
        _ = try manager.start(id: "dev")
        XCTAssertEqual(starter.attemptCount, 1)

        let changed = try manager.update(
            id: "dev",
            address: "192.168.215.41",
            updatesAddress: true
        )
        XCTAssertEqual(changed.state, .running)
        XCTAssertEqual(changed.address, "192.168.215.41")
        XCTAssertEqual(changed.configuredAddress, "192.168.215.41")
        XCTAssertEqual(starter.attemptCount, 1)

        let unchanged = try manager.update(
            id: "dev",
            address: "192.168.215.41",
            updatesAddress: true
        )
        XCTAssertEqual(unchanged.state, .running)
        XCTAssertEqual(starter.attemptCount, 1)
    }

    func testFailedUpdatedLaunchRestoresDefinitionAndRunningMachine() throws {
        let base = "/tmp/dory-machine-update-rollback-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let starter = RecordingProcessStarter(failingAttempts: [2])
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            processStarter: { process in try starter.start(process) }
        )
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2048,
            cpuCount: 2,
            address: "192.168.215.40"
        ))
        _ = try manager.start(id: "dev")

        XCTAssertThrowsError(try manager.update(id: "dev", memoryMB: 4096)) { error in
            guard case let MachineManagerError.persistence(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("original configuration was restored"))
        }

        XCTAssertEqual(starter.attemptCount, 3)
        let restored = try XCTUnwrap(manager.status(id: "dev"))
        XCTAssertEqual(restored.state, .running)
        XCTAssertEqual(restored.memoryMB, 2048)
        XCTAssertEqual(restored.cpuCount, 2)
        XCTAssertEqual(restored.address, "192.168.215.40")
        XCTAssertNotNil(restored.pid)
        let stored = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: "\(base)/dev/machine.json"))
        )
        XCTAssertEqual(stored.memoryMB, 2048)
        XCTAssertEqual(stored.cpuCount, 2)
        XCTAssertEqual(stored.address, "192.168.215.40")
    }

    func testUpdatePersistenceFailurePreservesThePublishedDefinition() throws {
        let base = "/tmp/dory-machine-update-persistence-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2048,
            cpuCount: 2
        ))
        _ = try manager.start(id: "dev")
        let definitionPath = "\(base)/dev/machine.json"
        let before = try Data(contentsOf: URL(fileURLWithPath: definitionPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: "\(base)/dev")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: "\(base)/dev")
        }

        XCTAssertThrowsError(try manager.update(id: "dev", memoryMB: 4096))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: definitionPath)), before)
        XCTAssertEqual(manager.status(id: "dev")?.memoryMB, 2048)
        XCTAssertEqual(manager.status(id: "dev")?.cpuCount, 2)
        XCTAssertEqual(manager.status(id: "dev")?.state, .running)
        XCTAssertNotNil(manager.status(id: "dev")?.pid)
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            address: "dev.dory.local"
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidAddress("dev.dory.local"))
        }
    }

    func testMachineResourcesStayWithinAdvertisedContractWithoutMutation() throws {
        let base = "/tmp/dory-machine-resources-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))

        for (memory, cpus) in [
            (UInt64(1023), 2),
            (UInt64(16 * 1024 + 1), 2),
            (UInt64(2048), 0),
            (UInt64(2048), 9),
        ] {
            let configuration = DoryMachineConfiguration(
                id: "invalid-\(memory)-\(cpus)",
            kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: memory,
                cpuCount: cpus
            )
            XCTAssertEqual(configuration.cpuCount, cpus)
            XCTAssertThrowsError(try manager.create(configuration))
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2048,
            cpuCount: 2
        ))
        let before = try Data(contentsOf: URL(fileURLWithPath: "\(base)/dev/machine.json"))

        XCTAssertThrowsError(try manager.update(id: "dev", memoryMB: 512))
        XCTAssertThrowsError(try manager.update(id: "dev", cpuCount: 9))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(base)/dev/machine.json")), before)

        let maximum = try manager.update(id: "dev", memoryMB: 16 * 1024, cpuCount: 8)
        XCTAssertEqual(maximum.memoryMB, 16 * 1024)
        XCTAssertEqual(maximum.cpuCount, 8)
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
            kernelPath: doryTestKernelPath,
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

    func testSnapshotsCopyRestoreCloneExportImportAndDeleteArtifacts() throws {
        let base = "/tmp/dory-machine-snapshots-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        let sourceKernel = "\(base)/base-kernel"
        let sharePath = "\(base)/shared-source"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        try Data("kernel-v1".utf8).write(to: URL(fileURLWithPath: sourceKernel))
        try FileManager.default.createDirectory(atPath: sharePath, withIntermediateDirectories: true)
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
            try? manager.delete(id: "dev-portable")
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: sourceKernel,
            rootfsPath: sourceRootfs,
            memoryMB: 4096,
            cpuCount: 4,
            address: "192.168.215.55",
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: sharePath,
                guestPath: "/workspace/src"
            )],
            environment: ["DORY_TEST_TOKEN": "snapshot-secret"]
        ))
        _ = try manager.start(id: "dev")
        let devRootfs = "\(base)/machines/dev/rootfs.ext4"
        let devKernel = "\(base)/machines/dev/kernel"
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
        XCTAssertEqual(snapshot.address, "192.168.215.55")
        XCTAssertEqual(snapshot.shares.map(\.hostPath), [sharePath])
        XCTAssertEqual(snapshot.environment, ["DORY_TEST_TOKEN": "snapshot-secret"])
        XCTAssertEqual(manager.status(id: "dev")?.state, .running)
        XCTAssertEqual(try manager.listSnapshots(machineID: "dev").map(\.id), ["s1"])
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: snapshot.rootfsPath)), encoding: .utf8), "snapshot-v1")
        XCTAssertEqual(snapshot.kernelPath, "\(base)/machines/dev/snapshots/s1.kernel")
        XCTAssertEqual(try String(contentsOfFile: snapshot.kernelPath, encoding: .utf8), "kernel-v1")

        _ = try manager.update(
            id: "dev",
            memoryMB: 2048,
            cpuCount: 2,
            address: "192.168.215.56",
            updatesAddress: true,
            shares: [],
            updatesShares: true,
            environment: ["DORY_TEST_TOKEN": "changed-secret"],
            updatesEnvironment: true
        )
        try Data("snapshot-v2".utf8).write(to: URL(fileURLWithPath: devRootfs))
        try Data("kernel-v2".utf8).write(to: URL(fileURLWithPath: devKernel))
        let clone = try manager.cloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-copy")
        XCTAssertEqual(clone.state, .running)
        XCTAssertEqual(clone.memoryMB, 4096)
        XCTAssertEqual(clone.cpuCount, 4)
        XCTAssertNil(clone.address)
        XCTAssertEqual(clone.shares.map(\.hostPath), [sharePath])
        XCTAssertEqual(clone.environment, ["DORY_TEST_TOKEN": "snapshot-secret"])
        XCTAssertEqual(
            String(data: try Data(contentsOf: URL(fileURLWithPath: "\(base)/machines/dev-copy/rootfs.ext4")), encoding: .utf8),
            "snapshot-v1"
        )
        XCTAssertEqual(try String(contentsOfFile: "\(base)/machines/dev-copy/kernel", encoding: .utf8), "kernel-v1")

        let restored = try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1")
        XCTAssertEqual(restored.state, .running)
        XCTAssertEqual(restored.memoryMB, 4096)
        XCTAssertEqual(restored.cpuCount, 4)
        XCTAssertEqual(restored.address, "192.168.215.55")
        XCTAssertEqual(restored.shares.map(\.hostPath), [sharePath])
        XCTAssertEqual(restored.environment, ["DORY_TEST_TOKEN": "snapshot-secret"])
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: devRootfs)), encoding: .utf8), "snapshot-v1")
        XCTAssertEqual(try String(contentsOfFile: devKernel, encoding: .utf8), "kernel-v1")
        let restoredDefinition = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: "\(base)/machines/dev/machine.json"))
        )
        XCTAssertEqual(restoredDefinition.memoryMB, 4096)
        XCTAssertEqual(restoredDefinition.cpuCount, 4)
        XCTAssertEqual(restoredDefinition.address, "192.168.215.55")
        XCTAssertEqual(restoredDefinition.shares.map(\.hostPath), [sharePath])
        XCTAssertEqual(restoredDefinition.environment, ["DORY_TEST_TOKEN": "snapshot-secret"])

        let bundle = "\(base)/dev.dorymachine"
        try manager.exportSnapshot(machineID: "dev", snapshotID: "s1", toPath: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle))
        let bundleData = try Data(contentsOf: URL(fileURLWithPath: bundle))
        XCTAssertNil(bundleData.range(of: Data(base.utf8)))
        XCTAssertNil(bundleData.range(of: Data("snapshot-secret".utf8)))
        XCTAssertNil(bundleData.range(of: Data("192.168.215.55".utf8)))

        try manager.deleteSnapshot(machineID: "dev", snapshotID: "s1")
        XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty)

        let imported = try manager.importSnapshot(fromPath: bundle)
        XCTAssertEqual(imported.id, "s1")
        XCTAssertEqual(imported.machineID, "dev")
        XCTAssertEqual(try manager.listSnapshots(machineID: "dev").map(\.id), ["s1"])
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: imported.rootfsPath)), encoding: .utf8), "snapshot-v1")
        XCTAssertEqual(try String(contentsOfFile: imported.kernelPath, encoding: .utf8), "kernel-v1")
        XCTAssertNil(imported.address)
        XCTAssertTrue(imported.shares.isEmpty)
        XCTAssertTrue(imported.environment.isEmpty)

        let portable = try manager.cloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-portable")
        XCTAssertEqual(portable.state, .running)
        XCTAssertNil(portable.address)
        XCTAssertTrue(portable.shares.isEmpty)
        XCTAssertTrue(portable.environment.isEmpty)
        try manager.deleteSnapshot(machineID: "dev", snapshotID: "s1")
        _ = try manager.stop(id: "dev-portable")
        XCTAssertEqual(try manager.start(id: "dev-portable").state, .running)
        XCTAssertEqual(try String(contentsOfFile: "\(base)/machines/dev-portable/kernel", encoding: .utf8), "kernel-v1")
    }

    func testSnapshotExportFailurePreservesExistingBundle() throws {
        let base = "/tmp/dory-machine-export-atomic-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
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
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        _ = try manager.snapshot(id: "dev", snapshotID: "s1")

        let exportDirectory = "\(base)/exports"
        let bundlePath = "\(exportDirectory)/dev.dorymachine"
        try FileManager.default.createDirectory(atPath: exportDirectory, withIntermediateDirectories: true)
        let existing = Data("existing-export-must-survive".utf8)
        try existing.write(to: URL(fileURLWithPath: bundlePath))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: exportDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exportDirectory)
        }

        XCTAssertThrowsError(try manager.exportSnapshot(
            machineID: "dev",
            snapshotID: "s1",
            toPath: bundlePath
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bundlePath)), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDirectory), ["dev.dorymachine"])
    }

    func testCloneStartFailureDeletesTheNewMachineDefinition() throws {
        let base = "/tmp/dory-machine-clone-rollback-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sourceRootfs = "\(base)/base-rootfs.ext4"
        try Data("base-rootfs".utf8).write(to: URL(fileURLWithPath: sourceRootfs))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "\(base)/missing-dory-vmm",
            stateDirectory: "\(base)/machines",
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: sourceRootfs
        ))
        _ = try manager.snapshot(id: "dev", snapshotID: "s1")

        XCTAssertThrowsError(try manager.cloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-copy"))
        XCTAssertEqual(manager.list().map(\.id), ["dev"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/machines/dev-copy"))

        let reloaded = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "\(base)/missing-dory-vmm",
            stateDirectory: "\(base)/machines",
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        XCTAssertEqual(reloaded.list().map(\.id), ["dev"])
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
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

    func testRequiredHandoffPublishesGuestReportedRuntimeAddress() throws {
        let base = "/tmp/dory-machine-runtime-address-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector(execResult: DoryExecResult(
            exitCode: 0,
            stdout: Data("2: eth0: <UP> mtu 1500\n    inet 192.168.64.19/24 brd 192.168.64.255 scope global eth0\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(machineID: "dev", agentSocketPath: "/run/agent.sock"),
            fileDescriptors: []
        )

        let running = try waitForMachineAddress(manager, id: "dev", address: "192.168.64.19")
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.runtimeAddress, "192.168.64.19")
        XCTAssertNil(running.configuredAddress)
        XCTAssertEqual(connector.execs.first?.argv, ["/sbin/ip", "-4", "addr", "show", "dev", "eth0"])
    }

    func testConfiguredDNSOverrideWinsWithoutHidingRuntimeAddress() throws {
        let base = "/tmp/dory-machine-address-override-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector(execResult: DoryExecResult(
            exitCode: 0,
            stdout: Data("inet 192.168.64.20/24 scope global eth0\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            address: "10.0.0.50"
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(machineID: "dev", agentSocketPath: "/run/agent.sock"),
            fileDescriptors: []
        )

        let running = try waitForMachineRuntimeAddress(manager, id: "dev", address: "192.168.64.20")
        XCTAssertEqual(running.address, "10.0.0.50")
        XCTAssertEqual(running.configuredAddress, "10.0.0.50")
        XCTAssertEqual(running.runtimeAddress, "192.168.64.20")
    }

    func testLateAddressProbeCannotPublishAfterMachineStops() throws {
        let base = "/tmp/dory-machine-stale-address-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let connector = RecordingMachineAgentConnector(
            execResult: DoryExecResult(
                exitCode: 0,
                stdout: Data("inet 192.168.64.21/24 scope global eth0\n".utf8),
                stderr: Data(),
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            ),
            execDelay: 0.2
        )
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(machineID: "dev", agentSocketPath: "/run/agent.sock"),
            fileDescriptors: []
        )
        _ = try waitForRecordedExecs(connector, count: 1)
        _ = try manager.stop(id: "dev")
        Thread.sleep(forTimeInterval: 0.3)

        let stopped = try XCTUnwrap(manager.status(id: "dev"))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.address)
        XCTAssertNil(stopped.runtimeAddress)
    }

    func testRuntimeAddressParserRejectsUnusableAndIncompleteResults() {
        func result(_ stdout: String, exitCode: Int32 = 0, timedOut: Bool = false) -> DoryExecResult {
            DoryExecResult(
                exitCode: exitCode,
                stdout: Data(stdout.utf8),
                stderr: Data(),
                timedOut: timedOut,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        }

        XCTAssertEqual(
            MachineManager.runtimeIPv4Address(from: result(
                "inet 127.0.0.1/8 scope host lo\ninet 192.168.64.22/24 scope global eth0\n"
            )),
            "192.168.64.22"
        )
        XCTAssertNil(MachineManager.runtimeIPv4Address(from: result("inet 169.254.1.2/16 scope link eth0\n")))
        XCTAssertNil(MachineManager.runtimeIPv4Address(from: result("inet not-an-address/24\n")))
        XCTAssertNil(MachineManager.runtimeIPv4Address(from: result("inet 192.168.64.22/24\n", exitCode: 1)))
        XCTAssertNil(MachineManager.runtimeIPv4Address(from: result("inet 192.168.64.22/24\n", timedOut: true)))
    }

    func testMaximumLengthMachineIDUsesBoundedTransientSocketPath() throws {
        let durable = "/tmp/dory-machine-durable-\(getpid())-\(String(repeating: "x", count: 70))"
        let runtime = "/tmp/dory-machine-runtime-\(getpid())"
        let id = String(repeating: "m", count: 63)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: durable,
            runtimeDirectory: runtime,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: true
        ))
        defer {
            try? manager.delete(id: id)
            try? FileManager.default.removeItem(atPath: durable)
            try? FileManager.default.removeItem(atPath: runtime)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: id,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let starting = try manager.start(id: id)
        let handoffPath = try XCTUnwrap(starting.handoffSocketPath)
        XCTAssertTrue(handoffPath.hasPrefix(runtime + "/"))
        XCTAssertLessThan(handoffPath.utf8.count, 104)
        XCTAssertFalse(handoffPath.contains(id))

        try sendVmmHandoff(
            path: handoffPath,
            ready: VmmReadyMessage(machineID: id),
            fileDescriptors: []
        )
        _ = try waitForMachineState(manager, id: id, state: .running)
        _ = try manager.stop(id: id)
    }

    func testMachineIDRejectsMoreThanSixtyThreeBytes() throws {
        let base = "/tmp/dory-machine-id-limit-\(getpid())"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/usr/bin/true",
            stateDirectory: base
        ))
        defer { try? FileManager.default.removeItem(atPath: base) }
        let id = String(repeating: "m", count: 64)

        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
            id: id,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidID(id))
        }
    }

    func testProcessArgumentsSeparateDurableStateFromTransientSockets() throws {
        let base = "/tmp/dory-machine-socket-args-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let durable = base + "/durable"
        let runtime = base + "/runtime"
        let capture = base + "/arguments.txt"
        let helper = base + "/helper.sh"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(capture)'\nsleep 30\n".write(
            toFile: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: helper,
            stateDirectory: durable,
            runtimeDirectory: runtime,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        _ = try manager.start(id: "dev")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: capture) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let arguments = try String(contentsOfFile: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        func value(after flag: String) throws -> String {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag))
            return arguments[index + 1]
        }

        XCTAssertEqual(try value(after: "--state-dir"), durable + "/dev")
        for flag in ["--dockerd-sock", "--agent-sock", "--shell-sock", "--control-sock"] {
            let path = try value(after: flag)
            XCTAssertTrue(path.hasPrefix(runtime + "/"), "\(flag) should use transient runtime storage")
            XCTAssertLessThan(path.utf8.count, 104)
        }
        _ = try manager.stop(id: "dev")
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
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
        _ = try waitForRecordedExecs(connector, count: 1)

        let result = manager.syncAgentClock(now: Date(timeIntervalSince1970: 1_234.5))

        XCTAssertEqual(result, AgentClockSyncResult(name: "machines", attempted: true, synced: true))
        XCTAssertEqual(connector.connectedPaths, ["/run/agent.sock", "/run/agent.sock"])
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

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
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
        _ = try waitForRecordedExecs(connector, count: 1)

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
                argv: ["/sbin/ip", "-4", "addr", "show", "dev", "eth0"],
                cwd: "",
                env: [],
                timeoutMs: 5_000,
                outputLimitBytes: 16 * 1024
            ),
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
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
        _ = try waitForRecordedExecs(connector, count: 1)

        let snapshots = manager.memorySnapshots()

        XCTAssertEqual(snapshots.map(\.id), ["machine.dev"])
        XCTAssertEqual(snapshots.first?.kind, .virtualMachine)
        XCTAssertEqual(snapshots.first?.currentTargetMB, 3072)
        XCTAssertEqual(snapshots.first?.maximumTargetMB, 3072)
        XCTAssertEqual(snapshots.first?.telemetry.memTotalKB, 3072 * 1024)
        XCTAssertEqual(snapshots.first?.canBalloon, true)
        XCTAssertEqual(connector.connectedPaths, ["/run/agent.sock", "/run/agent.sock"])
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

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
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
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
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
    private let execResult: DoryExecResult
    private let execDelay: TimeInterval

    init(
        telemetry: DoryTelemetry = DoryTelemetry(memTotalKB: 1, memAvailableKB: 1, psiSomeAvg10: 0, psiFullAvg10: 0),
        execResult: DoryExecResult = DoryExecResult(
            exitCode: 0,
            stdout: Data("machine-exec-ok\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        ),
        execDelay: TimeInterval = 0
    ) {
        self.telemetry = telemetry
        self.execResult = execResult
        self.execDelay = execDelay
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
        return RecordingMachineAgentClient(
            recorder: self,
            telemetry: telemetry,
            execResult: execResult,
            execDelay: execDelay
        )
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
    private let execResult: DoryExecResult
    private let execDelay: TimeInterval

    init(
        recorder: RecordingMachineAgentConnector,
        telemetry: DoryTelemetry,
        execResult: DoryExecResult = DoryExecResult(
            exitCode: 0,
            stdout: Data("machine-exec-ok\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        ),
        execDelay: TimeInterval = 0
    ) {
        self.recorder = recorder
        self.telemetryValue = telemetry
        self.execResult = execResult
        self.execDelay = execDelay
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
        if execDelay > 0 {
            Thread.sleep(forTimeInterval: execDelay)
        }
        return execResult
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

private final class RecordingProcessStarter: @unchecked Sendable {
    private let lock = NSLock()
    private let failingAttempts: Set<Int>
    private var attempts = 0

    init(failingAttempts: Set<Int> = []) {
        self.failingAttempts = failingAttempts
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func start(_ process: HvProcess) throws {
        lock.lock()
        attempts += 1
        let attempt = attempts
        let shouldFail = failingAttempts.contains(attempt)
        lock.unlock()
        if shouldFail {
            throw RecordingProcessStarterError.rejected(attempt)
        }
        try process.start()
    }
}

private enum RecordingProcessStarterError: Error {
    case rejected(Int)
}

private func writeMachineBundle(
    toPath path: String,
    snapshot: DoryMachineSnapshot,
    rootfs: Data,
    kernel: Data = Data("portable-test-kernel".utf8)
) throws {
    let magic = Data("DORYMACHINE3\n".utf8)
    var snapshot = snapshot
    snapshot.rootfsPath = ""
    snapshot.kernelPath = ""
    snapshot.sizeBytes = Int64(rootfs.count)
    let metadata = try JSONEncoder().encode(snapshot)
    var bundle = Data()
    bundle.append(magic)
    bundle.append(machineBundleUInt64(UInt64(metadata.count)))
    bundle.append(machineBundleUInt64(UInt64(rootfs.count)))
    bundle.append(machineBundleUInt64(UInt64(kernel.count)))
    bundle.append(contentsOf: SHA256.hash(data: metadata))
    bundle.append(contentsOf: SHA256.hash(data: rootfs))
    bundle.append(contentsOf: SHA256.hash(data: kernel))
    bundle.append(metadata)
    bundle.append(rootfs)
    bundle.append(kernel)
    try bundle.write(to: URL(fileURLWithPath: path))
}

private func machineBundlePayloadOffset(_ bundle: Data) throws -> Int {
    let magic = Data("DORYMACHINE3\n".utf8)
    let fixedHeaderLength = magic.count + (8 * 3) + (32 * 3)
    guard bundle.count >= fixedHeaderLength,
          bundle.prefix(magic.count) == magic else {
        throw MachineManagerError.persistence("invalid test machine bundle")
    }
    let lengthStart = magic.count
    let metadataLength = bundle[lengthStart..<(lengthStart + 8)].reduce(UInt64(0)) { partial, byte in
        (partial << 8) | UInt64(byte)
    }
    guard metadataLength <= UInt64(Int.max - fixedHeaderLength) else {
        throw MachineManagerError.persistence("invalid test machine bundle length")
    }
    return fixedHeaderLength + Int(metadataLength)
}

private func machineBundleUInt64(_ value: UInt64) -> Data {
    var bytes = Data()
    for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
    return bytes
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

private func waitForMachineAddress(
    _ manager: MachineManager,
    id: String,
    address: String,
    timeout: TimeInterval = 2
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id), status.address == address {
            return status
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try XCTUnwrap(manager.status(id: id))
}

private func waitForMachineRuntimeAddress(
    _ manager: MachineManager,
    id: String,
    address: String,
    timeout: TimeInterval = 2
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id), status.runtimeAddress == address {
            return status
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try XCTUnwrap(manager.status(id: id))
}

@discardableResult
private func waitForRecordedExecs(
    _ connector: RecordingMachineAgentConnector,
    count: Int,
    timeout: TimeInterval = 2
) throws -> [RecordingMachineAgentConnector.Exec] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let execs = connector.execs
        if execs.count >= count {
            return execs
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let execs = connector.execs
    XCTAssertGreaterThanOrEqual(execs.count, count)
    return execs
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
