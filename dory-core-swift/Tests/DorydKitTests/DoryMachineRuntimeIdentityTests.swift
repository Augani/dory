import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Machine runtime identity", .serialized)
struct DoryMachineRuntimeIdentityTests {
    @Test("legacy and replanning identities round trip with an explicit hardware ABI")
    func compatibilityIdentityRoundTrip() throws {
        let identities: [DoryMachineRuntimeIdentity] = [
            .legacyCompatibility(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
            ),
            .requiresReplanning(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                reason: .definitionChanged
            ),
        ]
        for identity in identities {
            #expect(identity.validate().isEmpty)
            let data = try JSONEncoder().encode(identity)
            #expect(try JSONDecoder().decode(DoryMachineRuntimeIdentity.self, from: data) == identity)
            #expect(identity.virtualHardwareABIVersion == 1)
        }
    }

    @Test("old snapshot metadata decodes as explicit legacy compatibility")
    func oldestSnapshotGoldenDecodes() throws {
        let data = Data(#"""
        {
          "id":"s1","machineID":"dev","note":"","createdISO":"2026-01-01T00:00:00Z",
          "rootfsPath":"/state/dev/snapshots/s1.ext4","sizeBytes":4,
          "kernelPath":"/state/dev/snapshots/s1.kernel","architecture":"arm64",
          "memoryMB":2048,"cpuCount":2,"displayMode":"headless","shares":[],
          "environment":{},"bootMode":"linux-kernel"
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(DoryMachineSnapshot.self, from: data)
        #expect(snapshot.runtimeIdentity.mode == .legacyCompatibility)
        #expect(
            snapshot.runtimeIdentity.virtualHardwareABIVersion
                == DoryMachineRuntimeIdentity.oldestLegacyVirtualHardwareABIVersion
        )
        #expect(
            snapshot.runtimeIdentity.virtualHardwareABIVersion
                != DoryMachineRuntimeIdentity.oldestLegacyVirtualHardwareABIVersion + 1
        )
        #expect(snapshot.artifactEvidence == nil)
    }

    @Test("new snapshots bind mutable artifacts and reject later disk tampering")
    func snapshotArtifactTamperingIsRejected() throws {
        let root = "/tmp/dory-runtime-identity-\(UUID().uuidString.lowercased())"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: root,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        let snapshot = try manager.snapshot(id: "dev", snapshotID: "s1")
        let evidence = try #require(snapshot.artifactEvidence)
        #expect(evidence.isValid)
        #expect(evidence.rootfs.sha256.count == 64)
        #expect(snapshot.runtimeIdentity.mode == .legacyCompatibility)
        #expect(snapshot.runtimeIdentity.virtualHardwareABIVersion == 1)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: snapshot.rootfsPath))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()
        #expect(throws: MachineManagerError.self) {
            _ = try manager.restoreSnapshot(machineID: "dev", snapshotID: "s1")
        }
    }

    @Test("resolved-plan policy never labels an unplanned machine as legacy")
    func requiredPolicyStartsAsRequiresReplanning() throws {
        let root = "/tmp/dory-runtime-identity-required-\(UUID().uuidString.lowercased())"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: root,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            launchPolicy: .requireResolvedPlan
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
        #expect(created.runtimeIdentity.mode == .requiresReplanning)
        #expect(created.runtimeIdentity.invalidationReason == .planNotInstalled)
        #expect(created.runtimeIdentity.virtualHardwareABIVersion == 1)
    }
}
