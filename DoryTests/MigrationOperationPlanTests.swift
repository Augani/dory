import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationOperationPlanTests {
    @Test func planContainsExactContainerDependencyClosureAndFinalStates() throws {
        let prepared = try build(makeScenario())
        let objects = Dictionary(uniqueKeysWithValues: prepared.completenessPlan.objects.map {
            ($0.source, $0)
        })
        let image = DoryOperationObjectKey(kind: .image, sourceID: "image-id")
        let volume = DoryOperationObjectKey(kind: .volume, sourceID: "db-data")
        let network = DoryOperationObjectKey(kind: .network, sourceID: "backend")
        let layer = DoryOperationObjectKey(kind: .writableLayer, sourceID: "db-id")
        let database = DoryOperationObjectKey(kind: .container, sourceID: "db-id")
        let api = DoryOperationObjectKey(kind: .container, sourceID: "api-id")

        #expect(Set(objects.keys) == [image, volume, network, layer, database, api])
        #expect(objects[layer]?.dependencies == [image])
        #expect(Set(objects[database]?.dependencies ?? []) == [image, volume, network, layer])
        #expect(Set(objects[api]?.dependencies ?? []) == [image, database])
        #expect(objects[database]?.acceptedFinalState == .exited)
        #expect(objects[api]?.acceptedFinalState == .createdStoppedAwaitingPort)
        #expect(prepared.completenessPlan.userSelection == prepared.completenessPlan.userSelection.sorted())
        #expect(prepared.journalPlan.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(
            Set(prepared.specifications.map(\.digest))
                == Set(prepared.completenessPlan.objects.map(\.specificationDigest))
        )
        let apiSpecificationDigest = try #require(objects[api]?.specificationDigest)
        let apiSpecification = try #require(
            prepared.specifications.first { $0.digest == apiSpecificationDigest }
        )
        let apiTarget = try JSONDecoder().decode(ContainerSpec.self, from: apiSpecification.data)
        #expect(apiTarget.name == "api")
        #expect(apiTarget.labels["dev.dory.operation.id"] == "11111111-1111-1111-1111-111111111111")
        #expect(apiTarget.labels["dev.dory.object.kind"] == "container")
        #expect(apiTarget.labels["dev.dory.original.identity"] == "api-id")
        #expect(apiTarget.labels["dev.dory.target.identity"] == "api")
        #expect(apiTarget.labels["dev.dory.operation.state"] == "published")
    }

    @Test func planIsDeterministicAcrossInventoryOrdering() throws {
        let firstScenario = try makeScenario()
        var reversedScenario = firstScenario
        reversedScenario.source.images.reverse()
        reversedScenario.source.volumes.reverse()
        reversedScenario.source.networks.reverse()
        reversedScenario.source.containers.reverse()

        let first = try build(firstScenario)
        let second = try build(reversedScenario)

        #expect(first.completenessPlan == second.completenessPlan)
        #expect(first.journalPlan == second.journalPlan)
    }

    @Test func missingContainerModeDependencyFailsBeforeJournalOrDockerWrites() throws {
        var scenario = try makeScenario()
        scenario.containerSpecifications["api-id"]?.networkMode = "container:missing-db"

        #expect(throws: MigrationOperationPlanError.self) {
            try build(scenario)
        }
    }

    @Test func endpointOnlyNetworkAndLegacyLinkDependenciesJoinTheClosure() throws {
        var scenario = try makeScenario()
        scenario.containerSpecifications["db-id"]?.networks = []
        scenario.containerSpecifications["db-id"]?.networkEndpointSettings = [
            "backend": DockerEndpointSettings()
        ]
        scenario.containerSpecifications["api-id"]?.networkMode = nil
        scenario.containerSpecifications["api-id"]?.networkEndpointSettings = [
            "backend": DockerEndpointSettings(Links: ["/db:/api/db"])
        ]

        let prepared = try build(scenario)
        let objects = Dictionary(uniqueKeysWithValues: prepared.completenessPlan.objects.map {
            ($0.source, $0)
        })
        let network = DoryOperationObjectKey(kind: .network, sourceID: "backend")
        let database = DoryOperationObjectKey(kind: .container, sourceID: "db-id")
        let api = DoryOperationObjectKey(kind: .container, sourceID: "api-id")
        let databaseDependencies = Set(objects[database]?.dependencies ?? [])
        let apiDependencies = Set(objects[api]?.dependencies ?? [])

        #expect(databaseDependencies.contains(network))
        #expect(apiDependencies.isSuperset(of: [network, database]))
    }

    @Test func incompleteStrictInventoriesFailBeforeAPlanIsPublished() throws {
        var missingContainer = try makeScenario()
        missingContainer.containerSpecifications.removeValue(forKey: "api-id")
        var missingNetwork = try makeScenario()
        missingNetwork.sourceNetworkInspections = [:]

        #expect(throws: MigrationOperationPlanError.self) {
            try build(missingContainer)
        }
        #expect(throws: MigrationOperationPlanError.self) {
            try build(missingNetwork)
        }
    }

    @Test func fullNetworkContractChangesImmutablePlan() throws {
        let first = try build(makeScenario())
        var changedScenario = try makeScenario()
        changedScenario.sourceNetworkInspections["backend"] = try networkInspection(
            name: "backend",
            options: ["com.docker.network.bridge.enable_icc": "false"]
        )
        let changed = try build(changedScenario)

        #expect(first.completenessPlan != changed.completenessPlan)
        #expect(first.journalPlan != changed.journalPlan)
    }

    @Test func unrelatedTargetContainerConfigurationIsBoundExactly() throws {
        let existing = container(id: "existing-id", name: "existing", status: .stopped)
        var firstScenario = try makeScenario()
        firstScenario.target = RuntimeSnapshot(containers: [existing], engineVersion: "27.5.1")
        var firstSpec = ContainerSpec(name: "existing", image: "ghcr.io/example/app:v1")
        firstSpec.environment = ["MODE": "first"]
        firstScenario.targetContainerSpecifications = ["existing-id": firstSpec]
        var changedScenario = firstScenario
        var changedSpec = firstSpec
        changedSpec.environment = ["MODE": "changed"]
        changedScenario.targetContainerSpecifications = ["existing-id": changedSpec]

        let first = try build(firstScenario)
        let changed = try build(changedScenario)

        #expect(
            first.completenessPlan.context.targetInventoryDigest
                != changed.completenessPlan.context.targetInventoryDigest
        )
    }

    @Test func unrelatedTargetNameCollisionFailsBeforePlanning() throws {
        var scenario = try makeScenario()
        scenario.target = RuntimeSnapshot(volumes: [
            Volume(name: "db-data", size: "0 B", driver: "local", usedBy: "—", created: "now")
        ])

        #expect(throws: MigrationOperationPlanError.targetCollision(kind: .volume, name: "db-data")) {
            try build(scenario)
        }
    }

    @Test func namedVolumesRequireTheSignedTransferHelperContract() throws {
        var scenario = try makeScenario()
        scenario.capabilities = MigrationOperationCapabilityContract(
            sourceSupportsArchiveTransfer: true,
            targetSupportsArchiveTransfer: true,
            targetSupportsImageLoadReceipt: true,
            sourceSupportsRawAPI: true,
            targetSupportsRawAPI: true,
            transferHelper: nil
        )

        #expect(throws: MigrationOperationPlanError.unsupportedCapability(
            "named volumes require the signed arm64 transfer helper"
        )) {
            try build(scenario)
        }
    }

    @Test func missingRawAPIOrArchiveTransferBlocksPlanning() throws {
        var scenario = try makeScenario()
        scenario.capabilities = MigrationOperationCapabilityContract(
            sourceSupportsArchiveTransfer: false,
            targetSupportsArchiveTransfer: true,
            targetSupportsImageLoadReceipt: true,
            sourceSupportsRawAPI: true,
            targetSupportsRawAPI: true,
            transferHelper: .appleSiliconV1
        )

        #expect(throws: MigrationOperationPlanError.unsupportedCapability(
            "both engines must support streaming image archives"
        )) {
            try build(scenario)
        }
    }

    @Test func missingImmutableImageLoadReceiptBlocksPlanning() throws {
        var scenario = try makeScenario()
        scenario.capabilities = MigrationOperationCapabilityContract(
            sourceSupportsArchiveTransfer: true,
            targetSupportsArchiveTransfer: true,
            targetSupportsImageLoadReceipt: false,
            sourceSupportsRawAPI: true,
            targetSupportsRawAPI: true,
            transferHelper: .appleSiliconV1
        )

        #expect(throws: MigrationOperationPlanError.unsupportedCapability(
            "the target engine must return an immutable image-load receipt"
        )) {
            try build(scenario)
        }
    }
}

@MainActor
private extension MigrationOperationPlanTests {
    @MainActor
    struct Scenario {
        var source: RuntimeSnapshot
        var containerSpecifications: [String: ContainerSpec]
        var sourceNetworkInspections: [String: Data]
        var target = RuntimeSnapshot()
        var targetContainerSpecifications: [String: ContainerSpec] = [:]
        var targetNetworkInspections: [String: Data] = [:]
        var capabilities = MigrationOperationCapabilityContract(
            sourceSupportsArchiveTransfer: true,
            targetSupportsArchiveTransfer: true,
            targetSupportsImageLoadReceipt: true,
            sourceSupportsRawAPI: true,
            targetSupportsRawAPI: true,
            transferHelper: .appleSiliconV1
        )
    }

    func build(_ scenario: Scenario) throws -> PreparedMigrationOperation {
        let operationID = try #require(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        return try MigrationOperationPlanBuilder.build(MigrationOperationPlanningInput(
            source: MigrationOperationSource(
                snapshot: scenario.source,
                authorityID: "docker:source",
                containerSpecifications: scenario.containerSpecifications,
                networkInspections: scenario.sourceNetworkInspections,
                writableLayerSizes: ["db-id": 4096, "api-id": 0]
            ),
            target: MigrationOperationTarget(
                snapshot: scenario.target,
                authorityID: "docker:dory",
                containerSpecifications: scenario.targetContainerSpecifications,
                networkInspections: scenario.targetNetworkInspections
            ),
            capabilities: scenario.capabilities,
            capacity: capacity,
            identity: MigrationOperationIdentity(
                id: operationID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ))
    }

    func makeScenario() throws -> Scenario {
        let image = DockerImage(
            repository: "ghcr.io/example/app",
            tag: "v1",
            imageID: "sha256:image-id",
            size: "12 MB",
            created: "now",
            usedByCount: 2,
            sizeBytes: 12_000_000
        )
        let volume = Volume(
            name: "db-data",
            size: "4 KB",
            driver: "local",
            usedBy: "db",
            created: "now"
        )
        let network = DoryNetwork(
            name: "backend",
            driver: "bridge",
            scope: "local",
            subnet: "172.30.0.0/24",
            containerCount: 1
        )
        let database = container(id: "db-id", name: "db", status: .stopped)
        let api = container(id: "api-id", name: "api", status: .running)
        var databaseSpec = ContainerSpec(name: "db", image: "ghcr.io/example/app:v1")
        databaseSpec.mounts = [
            ContainerMount(type: "volume", source: "db-data", target: "/var/lib/db")
        ]
        databaseSpec.networks = ["backend"]
        var apiSpec = ContainerSpec(name: "api", image: "ghcr.io/example/app:v1")
        apiSpec.networkMode = "container:db-id"
        apiSpec.ports = ["127.0.0.1:8080:80/tcp"]
        return Scenario(
            source: RuntimeSnapshot(
                containers: [api, database],
                images: [image],
                volumes: [volume],
                networks: [network],
                engineVersion: "27.5.1"
            ),
            containerSpecifications: ["db-id": databaseSpec, "api-id": apiSpec],
            sourceNetworkInspections: ["backend": try networkInspection(name: "backend")]
        )
    }

    func networkInspection(
        name: String,
        options: [String: String] = ["com.docker.network.bridge.enable_icc": "true"]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "Name": name,
            "Driver": "bridge",
            "Internal": false,
            "Attachable": true,
            "EnableIPv6": false,
            "IPAM": [
                "Driver": "default",
                "Config": [[
                    "Subnet": "172.30.0.0/24",
                    "Gateway": "172.30.0.1"
                ]]
            ],
            "Options": options
        ], options: [.sortedKeys])
    }

    func container(id: String, name: String, status: RunState) -> Container {
        Container(
            id: id,
            name: name,
            image: "ghcr.io/example/app:v1",
            status: status,
            cpuPercent: 0,
            memoryDisplay: "0 B",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "",
            restartPolicy: "no",
            sourceImageID: "sha256:image-id"
        )
    }

    var capacity: MigrationCapacityContract {
        MigrationCapacityContract(
            sourceVolumeBytes: ["db-data": 4096],
            sourceWritableLayerBytes: ["db-id": 4096, "api-id": 0],
            targetDockerBytes: 0,
            availableHostBytes: 100_000_000_000,
            requiredHostBytes: 4_000_020_000,
            requiredEngineBytes: 4_000_020_000
        )
    }
}
