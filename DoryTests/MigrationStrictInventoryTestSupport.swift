import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
protocol StrictInventoryTestCase {}

@MainActor
struct StrictInventoryFixture {
    let source: StrictMigrationRuntime
    let target: StrictMigrationRuntime
    let identity: MigrationOperationIdentity
}

@MainActor
extension StrictInventoryTestCase {
    var volumeMount: [String: Any] {
        [
            "Type": "volume",
            "Source": "db-data",
            "Target": "/var/lib/app",
            "ReadOnly": false,
            "VolumeOptions": ["NoCopy": true]
        ]
    }

    func makeFixture() -> StrictInventoryFixture {
        let source = StrictMigrationRuntime(
            identifier: "unix:///orbstack.sock",
            daemonID: "orbstack-daemon",
            product: "OrbStack"
        )
        let target = StrictMigrationRuntime(
            identifier: "unix:///dory.sock",
            daemonID: "dory-daemon",
            product: "Dory"
        )
        configureSource(source)
        target.snapshotValue = RuntimeSnapshot(engineVersion: "27.5.1")
        target.systemDiskUsage = dockerUsage()
        let operationID = UUID(uuid: (
            0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
            0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
        ))
        return StrictInventoryFixture(
            source: source,
            target: target,
            identity: MigrationOperationIdentity(
                id: operationID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    func collect(
        _ fixture: StrictInventoryFixture,
        availableHostBytes: Int64 = 100_000_000_000,
        hostArchitecture: String = "arm64"
    ) async throws -> PreparedMigrationExecution {
        try await collect(
            fixture,
            availableHostBytes: availableHostBytes,
            transferHelper: .appleSiliconV1,
            hostArchitecture: hostArchitecture
        )
    }

    func collect(
        _ fixture: StrictInventoryFixture,
        availableHostBytes: Int64 = 100_000_000_000,
        transferHelper: MigrationTransferHelperContract?,
        hostArchitecture: String = "arm64"
    ) async throws -> PreparedMigrationExecution {
        try await MigrationStrictInventoryCollector.collect(
            from: fixture.source,
            to: fixture.target,
            availableHostBytes: availableHostBytes,
            sharedHome: "/Users/test",
            transferHelper: transferHelper,
            identity: fixture.identity,
            hostArchitecture: hostArchitecture
        )
    }

    func specification<T: Decodable>(
        kind: DoryOperationObjectKind,
        in prepared: PreparedMigrationExecution,
        as type: T.Type
    ) throws -> T {
        let object = try #require(
            prepared.operation.completenessPlan.objects.first { $0.source.kind == kind }
        )
        let specification = try #require(
            prepared.operation.specifications.first { $0.digest == object.specificationDigest }
        )
        return try JSONDecoder().decode(type, from: specification.data)
    }

    func containerInspection(
        mount: [String: Any]?,
        devices: [[String: Any]]? = nil,
        runtime: String = "runc"
    ) -> [String: Any] {
        var hostConfig: [String: Any] = [
            "NetworkMode": "backend",
            "Runtime": runtime
        ]
        if let mount { hostConfig["Mounts"] = [mount] }
        if let devices { hostConfig["Devices"] = devices }
        var root: [String: Any] = [
            "Config": [
                "Image": "ghcr.io/example/app:v1",
                "Env": ["MODE=production"],
                "Labels": ["com.example.role": "app"]
            ],
            "HostConfig": hostConfig,
            "NetworkSettings": [
                "Networks": [
                    "backend": [
                        "IPAMConfig": ["IPv4Address": "172.30.0.5"],
                        "Aliases": ["app"],
                        "NetworkID": "daemon-local-network-id",
                        "EndpointID": "daemon-local-endpoint-id",
                        "IPAddress": "172.30.0.5"
                    ]
                ]
            ]
        ]
        if let mount { root["Mounts"] = [mount] }
        return root
    }

    func networkInspection(driver: String = "bridge") -> [String: Any] {
        [
            "Name": "backend",
            "Driver": driver,
            "Scope": "local",
            "Internal": false,
            "Attachable": true,
            "Ingress": false,
            "ConfigOnly": false,
            "ConfigFrom": [:],
            "EnableIPv6": false,
            "IPAM": [
                "Driver": "default",
                "Config": [[
                    "Subnet": "172.30.0.0/24",
                    "Gateway": "172.30.0.1"
                ]]
            ],
            "Options": ["com.docker.network.bridge.enable_icc": "true"]
        ]
    }

    func legacyNamedVolumeInspection(modes: String = "ro,nocopy") -> [String: Any] {
        let target = "/var/lib/app"
        var root = containerInspection(mount: nil)
        var hostConfig = root["HostConfig"] as? [String: Any] ?? [:]
        hostConfig["Binds"] = ["db-data:\(target):\(modes)"]
        root["HostConfig"] = hostConfig
        root["Mounts"] = [[
            "Type": "volume",
            "Name": "db-data",
            "Source": "/var/lib/docker/volumes/db-data/_data",
            "Destination": target,
            "Mode": modes,
            "RW": !modes.split(separator: ",").contains("ro")
        ]]
        return root
    }

    func dockerUsage(
        images: Int64 = 0,
        volumes: [String: Int64] = [:],
        containers: Int64 = 0,
        buildCache: Int64 = 0
    ) -> [String: Any] {
        let volumeItems = volumes.keys.sorted().map { name in
            ["Name": name, "UsageData": ["Size": volumes[name] ?? 0]] as [String: Any]
        }
        return [
            "ImageUsage": ["TotalSize": images],
            "VolumeUsage": [
                "TotalSize": volumes.values.reduce(Int64(0), +),
                "Items": volumeItems
            ],
            "ContainerUsage": ["TotalSize": containers],
            "BuildCacheUsage": ["TotalSize": buildCache]
        ]
    }

    private func configureSource(_ source: StrictMigrationRuntime) {
        source.snapshotValue = sourceSnapshot()
        source.writableSizes = ["container-id": 1_024]
        source.containerInspections = [
            "container-id": containerInspection(mount: volumeMount)
        ]
        source.networkInspections = ["backend": networkInspection()]
        source.systemDiskUsage = dockerUsage(
            images: 12_000_000,
            volumes: ["db-data": 4_096],
            containers: 1_024
        )
    }

    private func sourceSnapshot() -> RuntimeSnapshot {
        let imageID = "sha256:" + String(repeating: "a", count: 64)
        let image = DockerImage(
            repository: "ghcr.io/example/app",
            tag: "v1",
            imageID: imageID,
            size: "12 MB",
            created: "now",
            usedByCount: 1,
            sizeBytes: 12_000_000
        )
        let volume = Volume(
            name: "db-data",
            size: "4 KB",
            driver: "local",
            usedBy: "app",
            created: "now"
        )
        let network = DoryNetwork(
            name: "backend",
            driver: "bridge",
            scope: "local",
            subnet: "172.30.0.0/24",
            containerCount: 1
        )
        return RuntimeSnapshot(
            containers: [sourceContainer(imageID: imageID)],
            images: [image],
            volumes: [volume],
            networks: [network],
            engineVersion: "27.5.1"
        )
    }

    private func sourceContainer(imageID: String) -> Container {
        Container(
            id: "container-id",
            name: "app",
            image: "ghcr.io/example/app:v1",
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0 B",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "172.30.0.5",
            domain: "",
            command: "",
            restartPolicy: "no",
            sourceImageID: imageID
        )
    }
}

@MainActor
final class StrictMigrationRuntime: ContainerRuntime {
    nonisolated let kind: RuntimeKind
    nonisolated let migrationSourceIdentifier: String
    nonisolated let supportsImageArchiveTransfer = true
    nonisolated let supportsImageLoadReceipt = true
    nonisolated let supportsRawProxy = true

    var snapshotValue = RuntimeSnapshot(engineVersion: "27.5.1")
    var writableSizes: [String: Int64] = [:]
    var version: [String: Any]
    var info: [String: Any]
    var systemDiskUsage: [String: Any]?
    var containerInspections: [String: [String: Any]] = [:]
    var networkInspections: [String: [String: Any]] = [:]
    var createdVolumes: [MigrationVolumeContract] = []
    var createdNetworkRequests: [Data] = []
    var commitRequests: [StrictCommitRequest] = []
    var createdContainers: [StrictCreatedContainer] = []
    var startedContainers: [String] = []
    var pausedContainers: [String] = []
    var removedContainers: [String] = []
    var failContainerStart = false
    var failContainerPause = false
    var failContainerRemoval = false
    var removedVolumes: [String] = []
    var removedNetworks: [String] = []
    var removedImages: [String] = []
    var transferHelperMetadata: MigrationTransferHelperMetadata?
    var loadedTransferHelperArchives: [Data] = []
    var failVolumeRemoval = false
    var failNetworkRemoval = false
    var failImageRemoval = false
    var mutateCreatedNetworkContract = false

    init(
        identifier: String,
        daemonID: String,
        product: String,
        kind: RuntimeKind = .docker
    ) {
        self.kind = kind
        migrationSourceIdentifier = identifier
        version = [
            "ApiVersion": "1.52",
            "Arch": "arm64",
            "Os": "linux",
            "Version": "27.5.1",
            "Platform": ["Name": product]
        ]
        info = [
            "Architecture": "arm64",
            "OSType": "linux",
            "ID": daemonID,
            "DockerRootDir": "/var/lib/docker",
            "OperatingSystem": "\(product) Linux",
            "Name": product,
            "Driver": "overlayfs"
        ]
    }

    func snapshot() async throws -> RuntimeSnapshot { snapshotValue }
    func migrationSnapshot() async throws -> RuntimeSnapshot { snapshotValue }
    func migrationContainerWritableSizes() async throws -> [String: Int64] { writableSizes }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }

    func createVolume(
        name: String,
        driver: String?,
        labels: [String: String],
        driverOptions: [String: String]
    ) async throws {
        let contract = MigrationVolumeContract(
            volume: Volume(
                name: name,
                size: "0 B",
                driver: driver ?? "local",
                usedBy: "",
                created: "now",
                labels: labels,
                options: driverOptions
            )
        )
        createdVolumes.append(contract)
        if !snapshotValue.volumes.contains(where: { $0.name == name }) {
            snapshotValue.volumes.append(Volume(
                name: name,
                size: "0 B",
                driver: driver ?? "local",
                usedBy: "",
                created: "now",
                labels: labels,
                options: driverOptions
            ))
        }
    }

    func removeVolume(name: String) async throws {
        removedVolumes.append(name)
        if failVolumeRemoval { throw TestMutationFailure.injected }
        snapshotValue.volumes.removeAll { $0.name == name }
    }

    func removeImage(id: String) async throws {
        removedImages.append(id)
        if failImageRemoval { throw TestMutationFailure.injected }
        let normalized = MigrationOperationPlanBuilder.normalizedImageID(id)
        snapshotValue.images.removeAll {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == normalized
                || MigrationOperationPlanBuilder.imageReferences($0).contains(
                    MigrationOperationPlanBuilder.canonicalImageReference(id)
                )
        }
    }

    func removeImageForRollback(id: String) async throws {
        removedImages.append(id)
        if failImageRemoval { throw TestMutationFailure.injected }
        let normalizedID = MigrationOperationPlanBuilder.normalizedImageID(id)
        if let index = snapshotValue.images.firstIndex(where: {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == normalizedID
        }) {
            guard MigrationOperationPlanBuilder.imageReferences(snapshotValue.images[index]).isEmpty else {
                throw TestMutationFailure.imageReferenced
            }
            snapshotValue.images.remove(at: index)
            return
        }
        let reference = MigrationOperationPlanBuilder.canonicalImageReference(id)
        guard let index = snapshotValue.images.firstIndex(where: {
            MigrationOperationPlanBuilder.imageReferences($0).contains(reference)
        }) else { return }
        var references = MigrationOperationPlanBuilder.imageReferences(snapshotValue.images[index])
        references.removeAll { $0 == reference }
        guard let primary = references.first else {
            snapshotValue.images.remove(at: index)
            return
        }
        let split = DockerRegistry.splitImageRef(primary)
        snapshotValue.images[index].repository = split.repo
        snapshotValue.images[index].tag = split.tag
        snapshotValue.images[index].additionalReferences = Array(references.dropFirst())
    }

    enum TestMutationFailure: Error { case injected, imageReferenced }
}
