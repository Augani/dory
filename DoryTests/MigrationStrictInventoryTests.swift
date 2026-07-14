import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationStrictInventoryTests: StrictInventoryTestCase {
    @Test func cleanAppleSiliconInventoryProducesAnExactOwnedPlan() async throws {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)

        #expect(prepared.sourceAuthority.product == "OrbStack")
        #expect(prepared.targetAuthority.product == "Dory")
        #expect(prepared.source.snapshot.containers.map(\.id) == ["container-id"])
        #expect(prepared.target.snapshot.containers.isEmpty)
        #expect(prepared.sourceVolumeBytes == ["db-data": 4_096])
        #expect(prepared.source.writableLayerSizes == ["container-id": 1_024])
        #expect(Set(prepared.source.networkInspections.keys) == ["backend"])
        #expect(prepared.capacity.requiredHostBytes == 4_012_010_240)
        #expect(prepared.capacity.requiredEngineBytes == 4_012_010_240)
        #expect(prepared.operation.completenessPlan.objects.count == 5)
        #expect(prepared.ownership.operationID == fixture.identity.id.uuidString.lowercased())

        let volume = try specification(
            kind: .volume,
            in: prepared,
            as: MigrationVolumeContract.self
        )
        let network = try specification(
            kind: .network,
            in: prepared,
            as: MigrationNetworkContract.self
        )
        let container = try specification(
            kind: .container,
            in: prepared,
            as: ContainerSpec.self
        )
        for labels in [volume.labels, network.labels, container.labels] {
            #expect(labels["dev.dory.operation.id"] == fixture.identity.id.uuidString.lowercased())
            #expect(labels["dev.dory.source.authority"] == prepared.ownership.sourceAuthorityHash)
        }
        #expect(volume.labels["dev.dory.operation.state"] == "published")
        #expect(network.labels["dev.dory.operation.state"] == "published")
        #expect(container.labels["dev.dory.operation.state"] == "published")
        #expect(container.mounts.first?.source == "db-data")
        #expect(container.networkEndpointSettings["backend"]?.EndpointID == nil)
        #expect(container.networkEndpointSettings["backend"]?.IPAddress == nil)
        #expect(
            container.networkEndpointSettings["backend"]?.IPAMConfig?.IPv4Address
                == "172.30.0.5"
        )
    }

    @Test func sameDaemonThroughDifferentSocketsIsRejected() async {
        let fixture = makeFixture()
        fixture.target.info["ID"] = fixture.source.info["ID"]
        fixture.target.info["DockerRootDir"] = fixture.source.info["DockerRootDir"]

        await #expect(throws: MigrationStrictInventoryError.unsafe(
            "source and target resolve to the same Docker daemon"
        )) {
            _ = try await collect(fixture)
        }
    }

    @Test func incompleteContainerNetworkAndStorageReadsFailBeforePlanning() async {
        do {
            let fixture = makeFixture()
            fixture.source.containerInspections = [:]
            await #expect(throws: MigrationContainerInspectionError.unavailable("app")) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.networkInspections = [:]
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "network backend could not be inspected exactly"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.systemDiskUsage = dockerUsage(volumes: ["other": 4_096])
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "Docker did not report every named-volume size"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.target.systemDiskUsage = nil
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "target Docker storage usage is unavailable"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    @Test func volumeUsageMustExactlyMatchTheSnapshot() async {
        let fixture = makeFixture()
        fixture.source.systemDiskUsage = dockerUsage(volumes: [
            "db-data": 4_096,
            "unreported": 1
        ])

        await #expect(throws: MigrationStrictInventoryError.incomplete(
            "Docker did not report every named-volume size"
        )) {
            _ = try await collect(fixture)
        }
    }

    @Test func runningVolumeAndWritableLayerSourcesMustBeQuiescent() async {
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.containers[0].status = .running
            await #expect(throws: MigrationStrictInventoryError.unsafe(
                "running containers are writing named volumes: app"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.containers[0].status = .running
            fixture.source.containerInspections["container-id"] = containerInspection(mount: nil)
            await #expect(throws: MigrationStrictInventoryError.unsafe(
                "running containers have writable-layer changes: app"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    @Test func legacyNamedVolumeBindsBecomePortableTypedMounts() async throws {
        let fixture = makeFixture()
        fixture.source.containerInspections["container-id"] = legacyNamedVolumeInspection()

        let prepared = try await collect(fixture)
        let container = try specification(
            kind: .container,
            in: prepared,
            as: ContainerSpec.self
        )
        let mount = try #require(container.mounts.first)
        #expect(container.volumes.isEmpty)
        #expect(mount.type == "volume")
        #expect(mount.source == "db-data")
        #expect(mount.target == "/var/lib/app")
        #expect(mount.readOnly)
        #expect(mount.volumeOptions?.NoCopy == true)
    }
}
