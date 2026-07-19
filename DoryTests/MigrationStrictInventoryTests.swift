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
        #expect(prepared.capacity.engineLogicalBytes == 128 * 1024 * 1024 * 1024)
        #expect(prepared.capacity.engineUsableBytes == 120 * 1024 * 1024 * 1024)
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

    @Test func imageOnlySelectionExcludesUnrelatedLiveStorageFromAdmission() async throws {
        let fixture = makeFixture()
        fixture.source.snapshotValue.containers[0].status = .running
        let imageID = MigrationOperationPlanBuilder.stableImageSourceID(
            fixture.source.snapshotValue.images[0]
        )

        let prepared = try await collect(
            fixture,
            transferHelper: nil,
            userSelection: [DoryOperationObjectKey(kind: .image, sourceID: imageID)]
        )

        #expect(prepared.operation.completenessPlan.objects.map(\.source.kind) == [.image])
        #expect(prepared.sourceVolumeBytes.isEmpty)
        #expect(prepared.capacity.sourceVolumeBytes.isEmpty)
        #expect(prepared.capacity.sourceWritableLayerBytes.isEmpty)
    }

    @Test func imageOnlySelectionIsNotBlockedByOmittedHostBoundObjects() async throws {
        let fixture = makeFixture()
        fixture.source.containerInspections["container-id"] = containerInspection(mount: [
            "Type": "bind",
            "Source": "/Users/test/private-source",
            "Target": "/workspace/private-source",
            "ReadOnly": true,
        ])
        fixture.source.networkInspections["backend"] = networkInspection(driver: "overlay")
        let imageID = MigrationOperationPlanBuilder.stableImageSourceID(
            fixture.source.snapshotValue.images[0]
        )

        let prepared = try await collect(
            fixture,
            transferHelper: nil,
            userSelection: [DoryOperationObjectKey(kind: .image, sourceID: imageID)]
        )

        #expect(prepared.operation.completenessPlan.objects.map(\.source.kind) == [.image])
        let omitted = try JSONDecoder().decode(
            [DoryOperationInventoryObject].self,
            from: prepared.operation.baselineManifests.unselectedSourceInventory
        )
        #expect(Set(omitted.map(\.key.kind)) == [
            .container, .network, .volume, .writableLayer,
        ])
    }

    @Test func selectedHostBoundContainerStillFailsPortabilityAdmission() async {
        let fixture = makeFixture()
        fixture.source.containerInspections["container-id"] = containerInspection(mount: [
            "Type": "bind",
            "Source": "/Users/test/private-source",
            "Target": "/workspace/private-source",
            "ReadOnly": true,
        ])

        await #expect(throws: Error.self) {
            _ = try await collect(fixture)
        }
    }

    @Test func grownGuestFilesystemAdmitsAnImportAboveTheOriginal120GiBFloor() async throws {
        let fixture = makeFixture()
        let incomingBytes: Int64 = 110 * 1024 * 1024 * 1024
        fixture.source.snapshotValue.images[0].sizeBytes = incomingBytes
        fixture.source.systemDiskUsage = dockerUsage(
            images: incomingBytes,
            volumes: ["db-data": 4_096],
            containers: 1_024
        )

        let prepared = try await collect(
            fixture,
            availableHostBytes: 500 * 1024 * 1024 * 1024,
            transferHelper: .appleSiliconV1,
            engineCapacity: MigrationEngineCapacity(
                logicalBytes: 256 * 1024 * 1024 * 1024,
                usableBytes: 240 * 1024 * 1024 * 1024
            )
        )

        #expect(prepared.capacity.requiredEngineBytes > 120 * 1024 * 1024 * 1024)
        #expect(prepared.capacity.requiredEngineBytes < prepared.capacity.engineUsableBytes)
        #expect(prepared.capacity.engineLogicalBytes == 256 * 1024 * 1024 * 1024)
        #expect(prepared.capacity.engineUsableBytes == 240 * 1024 * 1024 * 1024)
    }

    @Test func legacyCapacityJournalDecodesWithTheQualifiedDefaultFloor() throws {
        let legacy = Data(#"""
        {
          "sourceVolumeBytes":{},
          "sourceWritableLayerBytes":{},
          "targetDockerBytes":0,
          "availableHostBytes":10000000000,
          "requiredHostBytes":4000000000,
          "requiredEngineBytes":4000000000
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(MigrationCapacityContract.self, from: legacy)

        #expect(decoded.engineLogicalBytes == 128 * 1024 * 1024 * 1024)
        #expect(decoded.engineUsableBytes == 120 * 1024 * 1024 * 1024)
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

    @Test func dockerDefaultOOMKillSettingIsCanonicalButExplicitDisableIsPreserved() async throws {
        do {
            let fixture = makeFixture()
            var inspection = containerInspection(mount: volumeMount)
            var hostConfig = try #require(inspection["HostConfig"] as? [String: Any])
            hostConfig["OomKillDisable"] = false
            inspection["HostConfig"] = hostConfig
            fixture.source.containerInspections["container-id"] = inspection

            let prepared = try await collect(fixture)
            let container = try specification(
                kind: .container,
                in: prepared,
                as: ContainerSpec.self
            )
            #expect(container.resources.oomKillDisable == nil)
        }
        do {
            let fixture = makeFixture()
            var inspection = containerInspection(mount: volumeMount)
            var hostConfig = try #require(inspection["HostConfig"] as? [String: Any])
            hostConfig["OomKillDisable"] = true
            inspection["HostConfig"] = hostConfig
            fixture.source.containerInspections["container-id"] = inspection

            let prepared = try await collect(fixture)
            let container = try specification(
                kind: .container,
                in: prepared,
                as: ContainerSpec.self
            )
            #expect(container.resources.oomKillDisable == true)
        }
    }

    @Test func doryInternalLoopbackIntentRestoresThePortableCreateContract() async throws {
        let fixture = makeFixture()
        var inspection = containerInspection(mount: volumeMount)
        var config = try #require(inspection["Config"] as? [String: Any])
        config["ExposedPorts"] = ["5432/tcp": [:]]
        config["Labels"] = [
            "com.example.role": "app",
            MigrationContainerInspector.internalLoopbackPortIntentLabel:
                #"{"5432/tcp":{"15432":"ipv4"}}"#,
        ]
        inspection["Config"] = config
        var hostConfig = try #require(inspection["HostConfig"] as? [String: Any])
        hostConfig["PortBindings"] = [
            "5432/tcp": [["HostIp": "", "HostPort": "15432"]],
        ]
        hostConfig["ExtraHosts"] = [
            "host.docker.internal:host-gateway",
            "host.dory.internal:host-gateway",
            "database.internal:192.0.2.10",
        ]
        inspection["HostConfig"] = hostConfig
        fixture.source.containerInspections["container-id"] = inspection

        let container = try #require(fixture.source.snapshotValue.containers.first)
        let specification = try await MigrationContainerInspector.inspect(
            container,
            on: fixture.source,
            sharedHome: "/Users/test"
        )

        #expect(specification.labels == ["com.example.role": "app"])
        #expect(specification.ports == ["127.0.0.1:15432:5432"])
        #expect(specification.extraHosts == ["database.internal:192.0.2.10"])
    }
}
