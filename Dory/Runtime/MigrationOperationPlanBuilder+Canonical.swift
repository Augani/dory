import CryptoKit
import DoryOperations
import Foundation

extension MigrationOperationPlanBuilder {
    static func imageDependency(
        container: Container,
        specification: ContainerSpec,
        index: MigrationImageIndex
    ) throws -> DoryOperationObjectKey {
        if let sourceImageID = container.sourceImageID,
           let key = index.byID[normalizedImageID(sourceImageID)] {
            return key
        }
        for reference in [specification.image, container.image] {
            if let key = index.byReference[canonicalImageReference(reference)] { return key }
            if let key = index.byID[normalizedImageID(reference)] { return key }
        }
        throw MigrationOperationPlanError.missingImage(
            container: container.name,
            image: container.sourceImageID ?? specification.image
        )
    }

    static func containerObjectDependencies(
        container: Container,
        specification: ContainerSpec,
        imageKey: DoryOperationObjectKey,
        context: MigrationContainerDependencyContext
    ) throws -> [DoryOperationObjectKey] {
        var dependencies = [imageKey]
        for mount in specification.mounts where mount.type.lowercased() == "volume" {
            guard let name = mount.source?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  context.volumeNames.contains(name) else {
                throw MigrationOperationPlanError.missingVolume(
                    container: container.name,
                    volume: mount.source ?? "<anonymous>"
                )
            }
            dependencies.append(DoryOperationObjectKey(kind: .volume, sourceID: name))
        }
        let attachedNetworks = Set(
            specification.networks
                + Array(specification.networkAliases.keys)
                + Array(specification.networkEndpointSettings.keys)
        )
        for network in attachedNetworks.sorted() where !defaultNetworks.contains(network) {
            guard context.networkNames.contains(network) else {
                throw MigrationOperationPlanError.missingNetwork(
                    container: container.name,
                    network: network
                )
            }
            dependencies.append(DoryOperationObjectKey(kind: .network, sourceID: network))
        }
        for rawDependency in containerDependencies(specification) {
            guard let dependency = context.containerIdentityIndex[normalizedContainerReference(rawDependency)] else {
                throw MigrationOperationPlanError.missingContainerDependency(
                    container: container.name,
                    dependency: rawDependency
                )
            }
            dependencies.append(DoryOperationObjectKey(kind: .container, sourceID: dependency.id))
        }
        return dependencies
    }

    static func containerIdentityIndex(_ containers: [Container]) -> [String: Container] {
        var result: [String: Container] = [:]
        for container in containers {
            result[normalizedContainerReference(container.id)] = container
            result[normalizedContainerReference(container.name)] = container
            result[normalizedContainerReference("/" + container.name)] = container
            if container.id.count >= 12 {
                result[normalizedContainerReference(String(container.id.prefix(12)))] = container
            }
        }
        return result
    }

    static func containerDependencies(_ specification: ContainerSpec) -> [String] {
        var result: [String] = []
        for mode in [specification.networkMode, specification.ipcMode, specification.pidMode] {
            if let mode, mode.hasPrefix("container:") {
                result.append(String(mode.dropFirst("container:".count)))
            }
        }
        result.append(contentsOf: specification.volumesFrom.compactMap {
            $0.split(separator: ":", maxSplits: 1).first.map(String.init)
        })
        result.append(contentsOf: specification.links.compactMap {
            $0.split(separator: ":", maxSplits: 1).first.map(String.init)
        })
        result.append(contentsOf: specification.networkEndpointSettings.values.flatMap {
            ($0.Links ?? []).compactMap { link in
                link.split(separator: ":", maxSplits: 1).first.map(String.init)
            }
        })
        var normalized = Set<String>()
        for value in result {
            normalized.insert(normalizedContainerReference(value))
        }
        return normalized.filter { !$0.isEmpty }.sorted()
    }

    static func acceptedFinalState(
        container: Container,
        specification: ContainerSpec
    ) -> DoryOperationAcceptedFinalState {
        if container.status == .running || container.status == .paused,
           specification.ports.contains(where: {
               DockerCreateBody.parsePort($0).hostPort?.isEmpty == false
           }) {
            return .createdStoppedAwaitingPort
        }
        switch container.status {
        case .running: return .running
        case .paused: return .paused
        case .stopped: return .exited
        }
    }

    static func imageCollisionDecision(
        _ image: DockerImage,
        references: [String],
        targetIDs: Set<String>,
        targetByReference: [String: DockerImage]
    ) throws -> DoryOperationTargetCollisionDecision {
        var decision: DoryOperationTargetCollisionDecision = targetIDs.contains(
            normalizedImageID(image.imageID)
        ) ? .reuseVerified : .create
        for reference in references {
            guard let existing = targetByReference[canonicalImageReference(reference)] else { continue }
            guard normalizedImageID(existing.imageID) == normalizedImageID(image.imageID) else {
                throw MigrationOperationPlanError.targetCollision(kind: .image, name: reference)
            }
            decision = .reuseVerified
        }
        return decision
    }

    static func stableImageSourceID(_ image: DockerImage) -> String {
        let normalized = normalizedImageID(image.imageID)
        return normalized.isEmpty ? (imageReferences(image).first ?? image.id) : normalized
    }

    static func normalizedImageID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
    }

    static func normalizedContainerReference(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func canonicalImageReference(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains("@"), !trimmed.hasPrefix("sha256:") else {
            return trimmed
        }
        let lastSlash = trimmed.lastIndex(of: "/")
        let lastColon = trimmed.lastIndex(of: ":")
        if let lastColon {
            if let lastSlash {
                if lastColon > lastSlash { return trimmed }
            } else {
                return trimmed
            }
        }
        return trimmed + ":latest"
    }

    static func imageReferences(_ image: DockerImage) -> [String] {
        var values = image.additionalReferences
        if image.repository != "<none>", !image.repository.isEmpty {
            values.append(
                image.tag == "<none>" || image.tag.isEmpty
                    ? image.repository
                    : "\(image.repository):\(image.tag)"
            )
        }
        var references = Set<String>()
        for value in values {
            let reference = canonicalImageReference(value)
            if !reference.isEmpty { references.insert(reference) }
        }
        return references.sorted()
    }

    static func makeSpecification<T: Encodable>(
        _ value: T
    ) throws -> DoryOperationSpecification {
        do {
            return try DoryOperationSpecification(canonical: value)
        } catch {
            throw MigrationOperationPlanError.encoding(String(describing: error))
        }
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw MigrationOperationPlanError.encoding(String(describing: error))
        }
    }
}
