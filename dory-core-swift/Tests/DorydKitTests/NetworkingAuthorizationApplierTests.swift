@testable import DorydKit
import XCTest

final class NetworkingAuthorizationApplierTests: XCTestCase {
    func testWritesResolverAndPfAnchorAndRunsWhitelistedCommands() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CommandRecorder()
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 18080,
            httpsProxyPort: 18443,
            privilegedTCPForwards: [
                PrivilegedTCPForward(listenPort: 25, targetPort: 1025),
            ],
            localCACertificatePath: nil
        ))

        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: recorder.run
        )
        let results = try applier.apply(plan)
        _ = try applier.apply(plan)

        let resolver = root + "/etc/resolver/dory.local"
        let anchor = root + "/etc/pf.anchors/dev.dory"
        XCTAssertEqual(try String(contentsOfFile: resolver), """
        # Managed by Dory. Do not edit.
        nameserver 127.0.0.1
        port 15353

        """)
        let anchorContents = try String(contentsOfFile: anchor)
        XCTAssertTrue(anchorContents.contains("port 25 -> 127.0.0.1 port 1025"))
        XCTAssertTrue(anchorContents.contains("port 80 -> 127.0.0.1 port 18080"))
        XCTAssertEqual(try permissions(atPath: resolver), 0o644)
        XCTAssertEqual(try permissions(atPath: anchor), 0o644)
        XCTAssertEqual(recorder.commands, [
            ["/sbin/pfctl", "-a", "com.apple/dev.dory", "-f", "/etc/pf.anchors/dev.dory"],
            ["/sbin/pfctl", "-E"],
            ["/sbin/pfctl", "-a", "com.apple/dev.dory", "-f", "/etc/pf.anchors/dev.dory"],
        ])
        XCTAssertEqual(results.map(\.kind), [.resolverFile, .pfAnchor, .pfEnable])
        XCTAssertEqual(
            try String(contentsOfFile: root + "/var/run/dev.dory/system-pf-enable-token"),
            "424242\n"
        )

        let removed = try applier.remove(plan)
        XCTAssertEqual(removed.map(\.action), [
            "release-pf-reference", "remove-file", "remove-file",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver))
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchor))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root + "/var/run/dev.dory/system-pf-enable-token"
        ))
        XCTAssertEqual(recorder.commands.suffix(2), [
            ["/sbin/pfctl", "-a", "com.apple/dev.dory", "-F", "all"],
            ["/sbin/pfctl", "-X", "424242"],
        ])
    }

    func testDryRunDoesNotWriteOrRunCommands() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CommandRecorder()
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))

        let results = try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            dryRun: true,
            runCommand: recorder.run
        ).apply(plan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/resolver/dory.local"))
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(results.allSatisfy(\.dryRun))

        let stateDirectory = root + "/private/var/db/dev.dory"
        let statePath = stateDirectory + "/network-authorization.json"
        try FileManager.default.createDirectory(
            atPath: stateDirectory,
            withIntermediateDirectories: true
        )
        try Data("root-only-state".utf8).write(to: URL(fileURLWithPath: statePath))
        XCTAssertEqual(chmod(statePath, 0o000), 0)

        let removalResults = try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            dryRun: true,
            runCommand: recorder.run
        ).remove(plan)

        XCTAssertTrue(removalResults.allSatisfy(\.dryRun))
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testMissingLocalCADoesNotPartiallyApplyPlan() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CommandRecorder()
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: "/Users/test/.dory/ca/ca.crt"
        ))

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: recorder.run
        ).apply(plan)) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationApplyError, .missingPayload("trust.local-ca"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/resolver/dory.local"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/pf.anchors/dev.dory"))
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testRejectsTamperedCommand() throws {
        var plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        let index = try XCTUnwrap(plan.requests.firstIndex { $0.kind == .pfEnable })
        plan.requests[index].command = ["/bin/sh", "-c", "echo unsafe"]

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(dryRun: true).apply(plan)) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationApplyError, .unsafeRequest("pf.dev.dory.enable"))
        }
    }

    func testRejectsReorderedRequests() throws {
        var plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        plan.requests.swapAt(0, 2)

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(dryRun: true).apply(plan)) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationApplyError, .unsafeRequest("pf.dev.dory.enable"))
        }
    }

    func testRejectsMissingExpectedRequest() throws {
        var plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        plan.requests.removeAll { $0.kind == .pfAnchor }

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(dryRun: true).apply(plan)) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationApplyError, .unsafeRequest("request-set"))
        }
    }

    func testRejectsForeignManagedPathWithoutChangingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = root + "/etc/resolver/dory.local"
        try FileManager.default.createDirectory(
            atPath: (resolver as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("owned by another tool\n".utf8).write(to: URL(fileURLWithPath: resolver))
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: CommandRecorder().run
        ).apply(plan)) { error in
            XCTAssertEqual(
                error as? NetworkingAuthorizationApplyError,
                .unsafeRequest("/etc/resolver/dory.local")
            )
        }
        XCTAssertEqual(try String(contentsOfFile: resolver), "owned by another tool\n")
    }

    func testRestoreReloadsOwnedAnchorAndReacquiresOnlyAMissingToken() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CommandRecorder()
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: recorder.run
        )
        _ = try applier.apply(plan)
        try FileManager.default.removeItem(
            atPath: root + "/var/run/dev.dory/system-pf-enable-token"
        )

        try applier.restorePFIfAuthorized()

        XCTAssertEqual(
            recorder.commands.filter { $0 == ["/sbin/pfctl", "-E"] }.count,
            2
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root + "/var/run/dev.dory/system-pf-enable-token"
        ))
    }

    func testPersistedOwnershipMigratesSuffixAndRemovesInstalledPlanFromAStaleRequest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CommandRecorder()
        let first = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "dory.local",
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        let second = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "dev.dory.local",
            dnsPort: 15354,
            httpProxyPort: 18081,
            localCACertificatePath: nil
        ))
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: 501,
            runCommand: recorder.run
        )

        _ = try applier.apply(first)
        _ = try applier.apply(second)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/resolver/dory.local"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/etc/resolver/dev.dory.local"))
        XCTAssertEqual(
            try permissions(atPath: root + "/private/var/db/dev.dory/network-authorization.json"),
            0o600
        )
        XCTAssertEqual(recorder.commands.filter { $0 == ["/sbin/pfctl", "-E"] }.count, 1)

        _ = try applier.remove(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/resolver/dev.dory.local"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root + "/private/var/db/dev.dory/network-authorization.json"
        ))
    }

    func testPersistedAuthorizationRejectsAnotherUser() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        _ = try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: 501,
            runCommand: CommandRecorder().run
        ).apply(plan)

        XCTAssertThrowsError(try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: 502,
            runCommand: CommandRecorder().run
        ).apply(plan)) { error in
            XCTAssertEqual(
                error as? NetworkingAuthorizationApplyError,
                .ownerMismatch(expected: 501, actual: 502)
            )
        }
    }

    func testUninstallRemovalUsesPersistedPlanAndCannotCrossUsers() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "owned.dory.local",
            dnsPort: 15354,
            localCACertificatePath: nil
        ))
        let recorder = CommandRecorder()
        _ = try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: 501,
            runCommand: recorder.run
        ).apply(plan)
        let maintenance = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: recorder.run
        )

        XCTAssertThrowsError(try maintenance.removeAuthorizedNetworking(clientUID: 502)) { error in
            XCTAssertEqual(
                error as? NetworkingAuthorizationApplyError,
                .ownerMismatch(expected: 501, actual: 502)
            )
        }
        XCTAssertTrue(try maintenance.removeAuthorizedNetworking(clientUID: 501))
        XCTAssertFalse(try maintenance.removeAuthorizedNetworking(clientUID: 501))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root + "/etc/resolver/owned.dory.local"
        ))
    }

    func testPersistsExactCAForReconciliationAfterUserCopyDisappears() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let caPath = root + "/Users/test/.dory/ca/ca.crt"
        try FileManager.default.createDirectory(
            atPath: (caPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("fixture-ca".utf8).write(to: URL(fileURLWithPath: caPath))
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: "/Users/test/.dory/ca/ca.crt"
        ))
        let recorder = CommandRecorder()
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: getuid(),
            runCommand: recorder.run
        )

        _ = try applier.apply(plan)

        let snapshot = root + "/private/var/db/dev.dory/local-ca.crt"
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snapshot)), Data("fixture-ca".utf8))
        XCTAssertEqual(try permissions(atPath: snapshot), 0o600)
        XCTAssertFalse(recorder.commands.contains { $0.first == "/usr/bin/security" })
        try FileManager.default.removeItem(atPath: caPath)

        _ = try applier.remove(plan)

        XCTAssertFalse(recorder.commands.contains { $0.first == "/usr/bin/security" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot))
    }

    func testSignedReconcileCannotCreateAuthorizationAndTracksLiveLowPortsForOwner() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let initial = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        let updated = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            privilegedTCPForwards: [
                PrivilegedTCPForward(listenPort: 25, targetPort: 60_025),
            ],
            localCACertificatePath: nil
        ))
        let recorder = CommandRecorder()
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            runCommand: recorder.run
        )

        XCTAssertFalse(try applier.reconcileIfAuthorized(updated, clientUID: 501))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/etc/resolver/dory.local"))
        _ = try NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: 501,
            runCommand: recorder.run
        ).apply(initial)
        XCTAssertTrue(try applier.reconcileIfAuthorized(updated, clientUID: 501))
        XCTAssertTrue(try String(
            contentsOfFile: root + "/etc/pf.anchors/dev.dory"
        ).contains("port 25 -> 127.0.0.1 port 60025"))

        XCTAssertThrowsError(try applier.reconcileIfAuthorized(updated, clientUID: 502)) { error in
            XCTAssertEqual(
                error as? NetworkingAuthorizationApplyError,
                .ownerMismatch(expected: 501, actual: 502)
            )
        }
    }

    func testSignedReconcileRejectsChangedCAUntilUserReauthorizes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let caPath = root + "/Users/test/.dory/ca/ca.crt"
        try FileManager.default.createDirectory(
            atPath: (caPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("old-ca".utf8).write(to: URL(fileURLWithPath: caPath))
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: "/Users/test/.dory/ca/ca.crt"
        ))
        let recorder = CommandRecorder()
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: getuid(),
            runCommand: recorder.run
        )
        _ = try applier.apply(plan)
        try Data("new-ca".utf8).write(to: URL(fileURLWithPath: caPath))

        let snapshot = root + "/private/var/db/dev.dory/local-ca.crt"
        XCTAssertThrowsError(try applier.reconcileIfAuthorized(plan, clientUID: getuid())) { error in
            XCTAssertEqual(
                error as? NetworkingAuthorizationApplyError,
                .certificateTrustRequiresInteraction
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: snapshot)),
            Data("old-ca".utf8)
        )

        _ = try applier.apply(plan)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: snapshot)),
            Data("new-ca".utf8)
        )
    }

    func testRemovalFailureRestoresSnapshotAndLeavesOwnedFilesRetryable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let caPath = root + "/Users/test/.dory/ca/ca.crt"
        try FileManager.default.createDirectory(
            atPath: (caPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("fixture-ca".utf8).write(to: URL(fileURLWithPath: caPath))
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: "/Users/test/.dory/ca/ca.crt"
        ))
        let recorder = CommandRecorder()
        let applier = NetworkingAuthorizationApplier(
            fileSystemRoot: root,
            ownerUID: getuid(),
            runCommand: recorder.run
        )
        _ = try applier.apply(plan)
        recorder.failNext([
            "/sbin/pfctl", "-a", "com.apple/dev.dory", "-F", "all",
        ])

        XCTAssertThrowsError(try applier.remove(plan))

        let snapshot = root + "/private/var/db/dev.dory/local-ca.crt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/etc/resolver/dory.local"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/etc/pf.anchors/dev.dory"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root + "/private/var/db/dev.dory/network-authorization.json"
        ))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: snapshot)),
            Data("fixture-ca".utf8)
        )
        XCTAssertFalse(recorder.commands.contains { $0.first == "/usr/bin/security" })
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    private var failingCommand: [String]?

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func failNext(_ command: [String]) {
        lock.lock()
        failingCommand = command
        lock.unlock()
    }

    func run(_ command: [String]) throws -> String {
        lock.lock()
        storage.append(command)
        let shouldFail = failingCommand == command
        if shouldFail { failingCommand = nil }
        lock.unlock()
        if shouldFail { throw CommandRecorderError.injectedFailure }
        if command == ["/sbin/pfctl", "-E"] {
            return "pf enabled\nToken : 424242\n"
        }
        return ""
    }
}

private enum CommandRecorderError: Error {
    case injectedFailure
}

private func temporaryRoot() -> String {
    let root = NSTemporaryDirectory() + "doryd-network-helper-\(getpid())-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func permissions(atPath path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
}
