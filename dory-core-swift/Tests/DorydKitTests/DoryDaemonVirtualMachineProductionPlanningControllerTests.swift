import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Production VM planning controller")
struct DoryDaemonVirtualMachineProductionPlanningControllerTests {
    @Test("controller publishes every exact boot and storage authority before planning")
    func publishesClosedArtifactSet() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }

        do {
            _ = try fixture.controller.resolveReserveAndPublish(
                fixture.request,
                artifacts: fixture.publications
            )
            Issue.record("Expected the fixture transaction to stop after artifact publication")
        } catch let failure
            as DoryDaemonVirtualMachineProductionPlanningControllerFailure {
            #expect(failure.code == .transactionRejected)
        }
        #expect(fixture.coordinator.callCount == 1)
        #expect(try fixture.authority.resolve(
            reference: fixture.bootReference,
            kind: .installedLinuxBootBundle,
            source: .bundledByDory
        ).media.artifactSHA256 != nil)
        #expect(try fixture.authority.resolve(
            reference: fixture.diskReference,
            kind: .virtualDisk,
            source: .userProvided
        ).media.mutableProvenance != nil)
    }

    @Test("missing extra duplicate and mismatched artifact publications fail before planning")
    func rejectsNonExactPublicationSets() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        var cases: [[DoryDaemonVirtualMachinePlanningArtifactPublication]] = [
            [fixture.publications[0]],
            fixture.publications + [fixture.publications[0]],
        ]
        var wrongSource = fixture.publications
        wrongSource[1].source = .bundledByDory
        cases.append(wrongSource)
        var wrongMutability = fixture.publications
        wrongMutability[1].mutability = .immutable
        cases.append(wrongMutability)
        var swappedPaths = fixture.publications
        swappedPaths[0].path = fixture.diskPath
        swappedPaths[1].path = fixture.bootPath
        cases.append(swappedPaths)

        for publications in cases {
            do {
                _ = try fixture.controller.resolveReserveAndPublish(
                    fixture.request,
                    artifacts: publications
                )
                Issue.record("Expected non-exact publication rejection")
            } catch let failure
                as DoryDaemonVirtualMachineProductionPlanningControllerFailure {
                #expect(failure.code == .invalidRequest)
            }
        }
        #expect(fixture.coordinator.callCount == 0)
    }

    @Test("changed immutable boot bytes cannot reuse a published authority")
    func changedPublishedArtifactFailsClosed() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        _ = try? fixture.controller.resolveReserveAndPublish(
            fixture.request,
            artifacts: fixture.publications
        )
        try Data("changed-boot".utf8).write(
            to: URL(fileURLWithPath: fixture.bootPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fixture.bootPath
        )

        do {
            _ = try fixture.controller.resolveReserveAndPublish(
                fixture.request,
                artifacts: fixture.publications
            )
            Issue.record("Expected changed immutable authority rejection")
        } catch let failure
            as DoryDaemonVirtualMachineProductionPlanningControllerFailure {
            #expect(failure.code == .mediaAuthorityConflict)
        }
        #expect(fixture.coordinator.callCount == 1)
    }
}

private final class ControllerFixture: @unchecked Sendable {
    let root: String
    let authority: DoryVirtualMachineArtifactAuthority
    let coordinator = RejectingPlanningCoordinator()
    let controller: DoryDaemonVirtualMachineProductionPlanningController
    let request: DoryDaemonVirtualMachinePlanningTransactionRequest
    let bootReference = DoryVMResolverReference(
        namespace: "artifact", identifier: "controller-boot"
    )
    let diskReference = DoryVMResolverReference(
        namespace: "artifact", identifier: "controller-disk"
    )
    let bootPath: String
    let diskPath: String
    let publications: [DoryDaemonVirtualMachinePlanningArtifactPublication]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-production-planning-controller-\(UUID().uuidString)"
        ).standardizedFileURL.path
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        bootPath = root + "/boot.bundle"
        diskPath = root + "/system.raw"
        try Data("boot-bundle".utf8).write(to: URL(fileURLWithPath: bootPath))
        try Data(repeating: 0x31, count: 4_096).write(to: URL(fileURLWithPath: diskPath))
        for path in [bootPath, diskPath] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path
            )
        }
        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 2 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(
                id: "controller-vm", name: "Controller VM"
            ),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system",
                    role: .system,
                    kind: .installedLinuxBootBundle,
                    source: .bundledByDory,
                    artifact: bootReference,
                    removable: false
                )],
                order: ["system"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .required, backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.none]),
            resources: resources,
            storage: [DoryVMStorageAttachment(
                id: "system-disk",
                role: .system,
                artifact: diskReference,
                source: .userProvided,
                capacityBytes: resources.diskBytes
            )],
            audio: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            input: DoryVMInputConfiguration(keyboardEnabled: false, pointerEnabled: false),
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_700_000_000_000,
                updatedAtUnixMilliseconds: 1_700_000_000_000
            )
        )
        let machine = DoryMachineConfiguration(
            id: definition.identity.id,
            kernelPath: bootPath,
            rootfsPath: diskPath,
            bootMode: .linuxKernel,
            displayMode: .desktop
        )
        request = DoryDaemonVirtualMachinePlanningTransactionRequest(
            planning: DoryDaemonVirtualMachinePlanningRequest(
                definition: definition,
                canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(definition),
                machine: machine,
                publication: .create
            ),
            workspacePublication: .create
        )
        authority = DoryVirtualMachineArtifactAuthority(root: root + "/authority")
        controller = DoryDaemonVirtualMachineProductionPlanningController(
            artifactAuthority: authority,
            coordinator: coordinator,
            workspaces: DoryWorkspaceRepository(root: root),
            plans: DoryResolvedMachinePlanRepository(root: root)
        )
        publications = [
            DoryDaemonVirtualMachinePlanningArtifactPublication(
                reference: bootReference,
                path: bootPath,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory,
                mutability: .immutable
            ),
            DoryDaemonVirtualMachinePlanningArtifactPublication(
                reference: diskReference,
                path: diskPath,
                kind: .virtualDisk,
                source: .userProvided,
                mutability: .mutable
            ),
        ]
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private final class RejectingPlanningCoordinator:
    DoryDaemonVirtualMachinePlanningTransactionCoordinating, @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func resolveReserveAndPublish(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        _ = request
        lock.withLock { calls += 1 }
        throw ControllerFixtureError.expectedRejection
    }
}

private enum ControllerFixtureError: Error { case expectedRejection }
