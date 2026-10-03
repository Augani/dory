import Foundation
import XCTest
@testable import DoryVZMacCore

/// Exercises lease/manifest admission without creating a VZ VM, disks, or networking.
/// Only Apple artifact decoding is replaced; reload uses real durable metadata I/O.
final class DoryVZMacRuntimeAdmissionTests: XCTestCase {
    func testReloadOwnsAndRetainsLeaseBeforeAnyRuntimeAllocation() throws {
        try withFixture { fixture in
            var reloads = 0
            var admission: DoryVZMacRuntimeAdmission? = try DoryVZMacRuntimeAdmission.acquire(for: fixture.requested) { root in
                reloads += 1
                XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: root)) { error in
                    XCTAssertEqual(error as? DoryVZMacMachineLeaseError, .alreadyInUse(root.path))
                }
                return try fixture.load(root)
            }
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(admission?.bundle.manifest, fixture.requested.manifest)
            XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: fixture.root))
            try fixture.assertArtifactsUnchanged()
            admission = nil
            XCTAssertNoThrow(try DoryVZMacMachineLease(rootURL: fixture.root))
            _ = admission
        }
    }

    func testStaleStoppedSnapshotCannotColdBootAfterPriorOwnerChangesState() throws {
        let successors: [DoryVZMacMachineInstallationState] = [
            .suspending, .suspended, .restoring, .installing, .installFailed,
        ]
        for state in successors {
            try withFixture { fixture in
                var priorOwner: DoryVZMacMachineLease? = try DoryVZMacMachineLease(rootURL: fixture.root)
                let successor = fixture.requested.manifest.replacingInstallationState(state)
                try fixture.write(successor)
                priorOwner = nil
                _ = priorOwner

                XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                    for: fixture.requested, loadBundle: fixture.load
                ), "state \(state.rawValue)") { error in
                    XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
                }
                XCTAssertEqual(try fixture.load(fixture.root).manifest, successor)
                try fixture.assertArtifactsUnchanged()
                // Rejected admission releases only its own lease; retry must reopen current state.
                XCTAssertNoThrow(try DoryVZMacMachineLease(rootURL: fixture.root))
            }
        }
    }

    func testSameStateResourceAndIdentityChangesAreNotSilentlyAdopted() throws {
        for field in ["cpuCount", "memoryBytes", "displays", "machineIdentifierSHA256", "hardwareModelSHA256", "macAddress"] {
            try withFixture { fixture in
                var object = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(fixture.requested.manifest)
                ) as? [String: Any])
                var resources = try XCTUnwrap(object["resources"] as? [String: Any])
                switch field {
                case "cpuCount": resources[field] = 6
                case "memoryBytes": resources[field] = 12 * DoryVZMacResourcePlan.gibibyte
                case "displays":
                    resources[field] = [["widthInPixels": 2560, "heightInPixels": 1600, "pixelsPerInch": 220]]
                case "macAddress": object[field] = "02:66:77:88:99:aa"
                default: object[field] = String(repeating: "f", count: 64)
                }
                object["resources"] = resources
                let successor = try JSONDecoder().decode(
                    DoryVZMacMachineManifest.self, from: JSONSerialization.data(withJSONObject: object)
                )
                try successor.validate()
                try fixture.write(successor)
                XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                    for: fixture.requested, loadBundle: fixture.load
                ), "changed \(field)") { error in
                    XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
                }
                XCTAssertEqual(try fixture.load(fixture.root).manifest, successor)
                try fixture.assertArtifactsUnchanged()
            }
        }
    }

    func testExistingLeaseIsReusedButForeignRootAndConcurrentOwnerRejectBeforeReload() throws {
        try withFixture { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
            defer { withExtendedLifetime(lease) {} }
            var reloads = 0
            XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(for: fixture.requested) { root in
                reloads += 1
                return try fixture.load(root)
            })
            XCTAssertEqual(reloads, 0)
            let admission = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            XCTAssertTrue(admission.lease === lease)
            XCTAssertEqual(admission.bundle.manifest, fixture.requested.manifest)

            try withFixture { other in
                XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                    for: other.requested, holding: lease,
                    loadBundle: { root in reloads += 1; return try other.load(root) }
                )) { error in
                    XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
                }
                XCTAssertEqual(reloads, 0)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: other.root.appendingPathComponent(DoryVZMacMachineLease.lockName).path
                ))
                try other.assertArtifactsUnchanged()
            }
            try fixture.assertArtifactsUnchanged()
        }
    }

    func testReloadFailureAndReturnedForeignRootNeverPublishRuntimeAdmission() throws {
        enum Failure: Error { case unreadable }
        try withFixture { fixture in
            XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, loadBundle: { root in
                    XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: root))
                    throw Failure.unreadable
                }
            )) { error in XCTAssertTrue(error is Failure) }
            XCTAssertNoThrow(try DoryVZMacMachineLease(rootURL: fixture.root))
            try withFixture { other in
                XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                    for: fixture.requested,
                    loadBundle: { _ in DoryVZMacMachineBundle(rootURL: other.root, manifest: fixture.requested.manifest) }
                )) { error in
                    XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
                }
            }
            try fixture.assertArtifactsUnchanged()
        }
    }

    func testReplacedLockCannotReuseAnOldLeaseBeforeOrDuringReload() throws {
        for replaceDuringReload in [false, true] {
            try withFixture { fixture in
                let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
                defer { withExtendedLifetime(lease) {} }
                let lockURL = fixture.root.appendingPathComponent(DoryVZMacMachineLease.lockName)
                let retainedLock = fixture.root.appendingPathComponent("retained-old-lock")
                func replaceLock() throws {
                    try FileManager.default.moveItem(at: lockURL, to: retainedLock)
                    try DoryVZMacMetadataFile.write(Data("replacement lock".utf8), to: lockURL)
                }
                if !replaceDuringReload { try replaceLock() }
                var reloads = 0
                XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                    for: fixture.requested, holding: lease, loadBundle: { root in
                        reloads += 1
                        if replaceDuringReload { try replaceLock() }
                        return try fixture.load(root)
                    }
                )) { error in
                    XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
                }
                XCTAssertEqual(reloads, replaceDuringReload ? 1 : 0)
                XCTAssertFalse(lease.ownsRoot(fixture.root))
                try fixture.assertArtifactsUnchanged()
            }
        }
    }

    func testReplacedRootCannotReuseAnOldLeaseEvenWithTheSameManifest() throws {
        try withFixture { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
            defer { withExtendedLifetime(lease) {} }
            let oldRoot = fixture.root.appendingPathExtension("retained-original")
            try FileManager.default.moveItem(at: fixture.root, to: oldRoot)
            defer { try? FileManager.default.removeItem(at: oldRoot) }
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
            try fixture.write(fixture.requested.manifest)
            // Even moving the actual locked inode into the successor root cannot transfer
            // directory ownership. The previous descriptor remains owned until lease deinit.
            try FileManager.default.moveItem(
                at: oldRoot.appendingPathComponent(DoryVZMacMachineLease.lockName),
                to: fixture.root.appendingPathComponent(DoryVZMacMachineLease.lockName)
            )
            var reloads = 0
            XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease,
                loadBundle: { root in reloads += 1; return try fixture.load(root) }
            )) { error in
                XCTAssertEqual(error as? DoryVZMacConfigurationError, .machineBundleChangedBeforeRuntimeAdmission)
            }
            XCTAssertEqual(reloads, 0)
            XCTAssertFalse(lease.ownsRoot(fixture.root))
            for (url, bytes) in fixture.artifacts {
                let original = oldRoot.appendingPathComponent(
                    String(url.path.dropFirst(fixture.root.path.count + 1))
                )
                XCTAssertEqual(try Data(contentsOf: original), bytes)
            }
        }
    }

    func testSharedLeaseCannotAdmitSecondRuntimeOrInvokeItsReload() throws {
        try withFixture { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
            var first: DoryVZMacRuntimeAdmission? = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: { root in
                    // Even re-entry during the first reload cannot acquire another claim.
                    XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                        for: fixture.requested, holding: lease,
                        loadBundle: { _ in XCTFail("second reload must not run"); return fixture.requested }
                    )) { error in
                        XCTAssertEqual(error as? DoryVZMacMachineLeaseError, .alreadyInUse(root.path))
                    }
                    return try fixture.load(root)
                }
            )
            XCTAssertNotNil(first)
            XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease,
                loadBundle: { _ in XCTFail("second reload must not run"); return fixture.requested }
            )) { error in
                XCTAssertEqual(error as? DoryVZMacMachineLeaseError, .alreadyInUse(fixture.root.path))
            }
            first = nil
            let successor = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            XCTAssertTrue(successor.lease === lease)
            withExtendedLifetime(successor) {}
            try fixture.assertArtifactsUnchanged()
            _ = first
        }
    }

    func testReloadFailureReleasesOnlyItsOwnRuntimeClaim() throws {
        enum Failure: Error { case unreadable }
        try withFixture { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
            XCTAssertThrowsError(try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: { root in
                    XCTAssertThrowsError(try lease.claimRuntime())
                    throw Failure.unreadable
                }
            )) { error in XCTAssertTrue(error is Failure) }
            let successor = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            XCTAssertThrowsError(try lease.claimRuntime())
            withExtendedLifetime(successor) {}
            try fixture.assertArtifactsUnchanged()
        }
    }

    func testOldRuntimeClaimCloseAndDeinitCannotRevokeSuccessor() throws {
        try withFixture { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.root)
            var old: DoryVZMacRuntimeAdmission? = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            // Simulates initializer failure/retirement while an old cleanup reference survives.
            old?.claim.close()
            let successor = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            old?.claim.close()
            old = nil
            XCTAssertThrowsError(try lease.claimRuntime()) { error in
                XCTAssertEqual(error as? DoryVZMacMachineLeaseError, .alreadyInUse(fixture.root.path))
            }
            successor.claim.close()
            let replacement = try DoryVZMacRuntimeAdmission.acquire(
                for: fixture.requested, holding: lease, loadBundle: fixture.load
            )
            successor.claim.close()
            XCTAssertThrowsError(try lease.claimRuntime())
            withExtendedLifetime(replacement) {}
            try fixture.assertArtifactsUnchanged()
            _ = old
        }
    }

    private struct Fixture {
        let root: URL
        let requested: DoryVZMacMachineBundle
        let artifacts: [URL: Data]

        func write(_ manifest: DoryVZMacMachineManifest) throws {
            try DoryVZMacMetadataFile.write(JSONEncoder().encode(manifest), to: requested.manifestURL)
        }

        func load(_ root: URL) throws -> DoryVZMacMachineBundle {
            let manifest = try JSONDecoder().decode(DoryVZMacMachineManifest.self,
                from: DoryVZMacMetadataFile.read(from: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName)))
            try manifest.validate()
            return DoryVZMacMachineBundle(rootURL: root, manifest: manifest)
        }

        func assertArtifactsUnchanged() throws {
            for (url, bytes) in artifacts { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-runtime-admission-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try DoryVZMacResourcePlan(
            requestedCPUCount: 4, requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte, requestedDisplays: nil,
            minimumCPUCount: 2, minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8, maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
        )
        let manifest = DoryVZMacMachineManifest(
            createdAt: "2026-10-02T00:00:00Z", installationState: .stopped, origin: .created,
            parentMachineIdentifierSHA256: nil, restoreImageBuild: "27A266a", restoreImageVersion: "27.0",
            restoreImageSourceURL: "https://updates.cdn-apple.com/restore.ipsw", restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64), hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64), macAddress: "02:11:22:33:44:55", resources: resources
        )
        let requested = DoryVZMacMachineBundle(rootURL: root, manifest: manifest)
        let ram = requested.suspendedStateURL.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName)
        try FileManager.default.createDirectory(at: requested.suspendedStateURL, withIntermediateDirectories: false)
        let artifacts = Dictionary(uniqueKeysWithValues:
            [requested.diskURL, requested.auxiliaryStorageURL, requested.hardwareModelURL, requested.machineIdentifierURL, ram].map {
                ($0, Data("preserved-\($0.lastPathComponent)".utf8))
            })
        for (url, bytes) in artifacts { try DoryVZMacMetadataFile.write(bytes, to: url) }
        let fixture = Fixture(root: root, requested: requested, artifacts: artifacts)
        try fixture.write(manifest)
        try body(fixture)
    }
}
