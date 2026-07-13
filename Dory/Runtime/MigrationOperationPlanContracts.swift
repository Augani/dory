import DoryOperations
import CryptoKit
import Foundation

struct MigrationOperationSource: Sendable {
    let snapshot: RuntimeSnapshot
    let authorityID: String
    let containerSpecifications: [String: ContainerSpec]
    let networkInspections: [String: Data]
    let writableLayerSizes: [String: Int64]
}

struct MigrationOperationTarget: Sendable {
    let snapshot: RuntimeSnapshot
    let authorityID: String
    let containerSpecifications: [String: ContainerSpec]
    let networkInspections: [String: Data]
}

struct MigrationOperationCapabilityContract: Codable, Sendable, Equatable {
    let sourceSupportsArchiveTransfer: Bool
    let targetSupportsArchiveTransfer: Bool
    let sourceSupportsRawAPI: Bool
    let targetSupportsRawAPI: Bool
    let transferHelper: MigrationTransferHelperContract?
}

struct MigrationOperationPlanningInput: Sendable {
    let source: MigrationOperationSource
    let target: MigrationOperationTarget
    let capabilities: MigrationOperationCapabilityContract
    let capacity: MigrationCapacityContract
    let identity: MigrationOperationIdentity

    var ownership: MigrationOperationOwnership {
        MigrationOperationOwnership(identity: identity, sourceAuthorityID: source.authorityID)
    }
}

struct MigrationOperationIdentity: Sendable {
    let id: UUID
    let createdAt: Date

    nonisolated static func fresh() -> MigrationOperationIdentity {
        MigrationOperationIdentity(id: UUID(), createdAt: Date())
    }
}

struct MigrationOperationOwnership: Sendable, Equatable {
    let operationID: String
    let sourceAuthorityHash: String

    init(identity: MigrationOperationIdentity, sourceAuthorityID: String) {
        self.init(operationID: identity.id, sourceAuthorityID: sourceAuthorityID)
    }

    init(operationID: UUID, sourceAuthorityID: String) {
        self.operationID = operationID.uuidString.lowercased()
        sourceAuthorityHash = SHA256.hash(data: Data(sourceAuthorityID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func labels(
        existing: [String: String],
        kind: DoryOperationObjectKind,
        sourceID: String,
        targetID: String
    ) -> [String: String] {
        var labels = existing
        labels["dev.dory.operation.id"] = operationID
        labels["dev.dory.source.authority"] = sourceAuthorityHash
        labels["dev.dory.object.kind"] = kind.rawValue
        labels["dev.dory.original.identity"] = sourceID
        labels["dev.dory.target.identity"] = targetID
        labels["dev.dory.operation.state"] = "published"
        return labels
    }
}

struct MigrationCapacityContract: Codable, Sendable, Equatable {
    let sourceVolumeBytes: [String: Int64]
    let sourceWritableLayerBytes: [String: Int64]
    let targetDockerBytes: Int64
    let availableHostBytes: Int64
    let requiredHostBytes: Int64
    let requiredEngineBytes: Int64
}

struct MigrationPlanAssembly {
    var inventory: [DoryOperationInventoryObject] = []
    var intents: [DoryOperationObjectIntent] = []
    var specifications: [String: DoryOperationSpecification] = [:]

    mutating func retain(_ specification: DoryOperationSpecification) {
        specifications[specification.digest] = specification
    }
}

struct MigrationImageIndex {
    let byID: [String: DoryOperationObjectKey]
    let byReference: [String: DoryOperationObjectKey]
}

struct MigrationContainerDependencyContext {
    let imageIndex: MigrationImageIndex
    let volumeNames: Set<String>
    let networkNames: Set<String>
    let containerIdentityIndex: [String: Container]
}

struct MigrationContainerPlanningContext {
    let targetNames: Set<String>
    let dependencies: MigrationContainerDependencyContext
    let ownership: MigrationOperationOwnership
}

struct MigrationImageIdentity: Codable { let id: String }
struct MigrationAuthorityContract: Codable {
    let id: String
    let engineVersion: String
    let inventoryDigest: String
}
struct MigrationWritableLayerContract: Codable {
    let containerID: String
    let logicalBytes: Int64
}
struct MigrationContainerSourceContract: Codable {
    let id: String
    let specification: ContainerSpec
}

struct MigrationImageContract: Codable {
    let id: String
    let references: [String]
    let sizeBytes: Int64
    let labels: [String: String]

    init(image: DockerImage) {
        id = image.imageID
        references = MigrationOperationPlanBuilder.imageReferences(image)
        sizeBytes = image.sizeBytes
        labels = image.labels
    }
}

struct MigrationVolumeContract: Codable {
    let name: String
    let driver: String
    let labels: [String: String]
    let options: [String: String]

    init(volume: Volume, labels: [String: String]? = nil) {
        name = volume.name
        driver = volume.driver
        self.labels = labels ?? volume.labels
        options = volume.options
    }
}

struct MigrationNetworkContract: Codable {
    let name: String
    let driver: String
    let labels: [String: String]
    let portableCreateContract: Data

    init(
        network: DoryNetwork,
        inspectedData: Data,
        labels: [String: String]? = nil
    ) throws {
        guard let root = try? JSONSerialization.jsonObject(with: inspectedData) as? [String: Any],
              root["Name"] as? String == network.name,
              let inspectedDriver = root["Driver"] as? String,
              !inspectedDriver.isEmpty,
              inspectedDriver == network.driver,
              root["IPAM"] is [String: Any] else {
            throw MigrationOperationPlanError.invalidNetworkSpecification(network.name)
        }
        let keys = [
            "Driver", "Internal", "Attachable", "Ingress", "IPAM", "EnableIPv4", "EnableIPv6",
            "Options", "ConfigOnly", "ConfigFrom"
        ]
        let portable = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Any)? in
            guard let value = root[key], !(value is NSNull) else { return nil }
            return (key, value)
        })
        guard JSONSerialization.isValidJSONObject(portable),
              let canonical = try? JSONSerialization.data(withJSONObject: portable, options: [.sortedKeys]) else {
            throw MigrationOperationPlanError.invalidNetworkSpecification(network.name)
        }
        name = network.name
        driver = network.driver
        self.labels = labels ?? network.labels
        portableCreateContract = canonical
    }
}

struct MigrationCapabilitySnapshot: Codable {
    let sourceEngineVersion: String
    let targetEngineVersion: String
    let sourceSupportsArchiveTransfer: Bool
    let targetSupportsArchiveTransfer: Bool
    let sourceSupportsRawAPI: Bool
    let targetSupportsRawAPI: Bool
    let transferHelper: MigrationTransferHelperContract?

    init(
        sourceEngineVersion: String,
        targetEngineVersion: String,
        contract: MigrationOperationCapabilityContract
    ) {
        self.sourceEngineVersion = sourceEngineVersion
        self.targetEngineVersion = targetEngineVersion
        sourceSupportsArchiveTransfer = contract.sourceSupportsArchiveTransfer
        targetSupportsArchiveTransfer = contract.targetSupportsArchiveTransfer
        sourceSupportsRawAPI = contract.sourceSupportsRawAPI
        targetSupportsRawAPI = contract.targetSupportsRawAPI
        transferHelper = contract.transferHelper
    }
}

struct MigrationQuiescenceContract: Codable {
    struct ContainerState: Codable {
        let id: String
        let state: String
        let writableVolumes: [String]
    }

    let containers: [ContainerState]

    init(containers: [Container]) {
        self.containers = containers.map {
            ContainerState(
                id: $0.id,
                state: $0.status.rawValue,
                writableVolumes: $0.mounts.compactMap { mount in
                    guard mount.type == "volume", !mount.readOnly else { return nil }
                    return mount.source
                }.sorted()
            )
        }.sorted { $0.id < $1.id }
    }
}

struct MigrationTargetInventory: Codable {
    struct ContainerContract: Codable {
        let id: String
        let name: String
        let state: String
        let specification: ContainerSpec
    }

    let images: [MigrationImageContract]
    let volumes: [MigrationVolumeContract]
    let networks: [MigrationNetworkContract]
    let containers: [ContainerContract]

    init(
        snapshot: RuntimeSnapshot,
        containerSpecifications: [String: ContainerSpec],
        networkInspections: [String: Data]
    ) throws {
        var imageRows: [(sortKey: String, contract: MigrationImageContract)] = []
        for image in snapshot.images {
            let contract = MigrationImageContract(image: image)
            imageRows.append((contract.id, contract))
        }
        images = imageRows.sorted { $0.sortKey < $1.sortKey }.map(\.contract)
        var volumeRows: [(sortKey: String, contract: MigrationVolumeContract)] = []
        for volume in snapshot.volumes {
            let contract = MigrationVolumeContract(volume: volume)
            volumeRows.append((contract.name, contract))
        }
        volumes = volumeRows.sorted { $0.sortKey < $1.sortKey }.map(\.contract)
        networks = try snapshot.networks.map { network in
            guard let inspection = networkInspections[network.name] else {
                throw MigrationOperationPlanError.missingNetworkSpecification(network.name)
            }
            return try MigrationNetworkContract(network: network, inspectedData: inspection)
        }.sorted { $0.name < $1.name }
        containers = try snapshot.containers.map { container in
            guard let specification = containerSpecifications[container.id] else {
                throw MigrationOperationPlanError.missingContainerSpecification(container.name)
            }
            return ContainerContract(
                id: container.id,
                name: container.name,
                state: container.status.rawValue,
                specification: specification
            )
        }.sorted { $0.id < $1.id }
    }
}
