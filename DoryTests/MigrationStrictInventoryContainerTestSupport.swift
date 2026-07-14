import Foundation
@testable import Dory

struct StrictCreatedContainer {
    let id: String
    let specification: ContainerSpec
}

@MainActor
extension StrictMigrationRuntime {
    func create(_ spec: ContainerSpec) async throws -> String {
        let id = "strict-created-\(createdContainers.count + 1)"
        createdContainers.append(StrictCreatedContainer(id: id, specification: spec))
        containerInspections[id] = try containerInspection(spec)
        snapshotValue.containers.append(Container(
            id: id,
            name: spec.name,
            image: spec.image,
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0 B",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "",
            domain: spec.domainname ?? "",
            command: spec.command.joined(separator: " "),
            restartPolicy: spec.restart ?? "no",
            labels: spec.labels,
            networks: spec.networks,
            networkEndpointSettings: spec.networkEndpointSettings,
            sourceImageID: spec.image
        ))
        return id
    }

    func start(containerID: String) async throws {
        startedContainers.append(containerID)
        if failContainerStart { throw TestMutationFailure.injected }
        try updateContainerState(containerID, state: .running)
    }

    func pause(containerID: String) async throws {
        pausedContainers.append(containerID)
        if failContainerPause { throw TestMutationFailure.injected }
        try updateContainerState(containerID, state: .paused)
    }

    func remove(containerID: String) async throws {
        removedContainers.append(containerID)
        if failContainerRemoval { throw TestMutationFailure.injected }
        snapshotValue.containers.removeAll { $0.id == containerID }
        containerInspections[containerID] = nil
    }

    private func updateContainerState(_ id: String, state: RunState) throws {
        guard let index = snapshotValue.containers.firstIndex(where: { $0.id == id }) else {
            throw TestMutationFailure.injected
        }
        snapshotValue.containers[index].status = state
    }

    private func containerInspection(_ specification: ContainerSpec) throws -> [String: Any] {
        let data = try JSONEncoder().encode(DockerCreateBody(spec: specification))
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostConfig = config.removeValue(forKey: "HostConfig") as? [String: Any] else {
            throw TestMutationFailure.injected
        }
        let networking = config.removeValue(forKey: "NetworkingConfig") as? [String: Any]
        let endpoints = networking?["EndpointsConfig"] as? [String: Any] ?? [:]
        return [
            "Config": config,
            "HostConfig": hostConfig,
            "NetworkSettings": ["Networks": endpoints],
            "Mounts": hostConfig["Mounts"] as? [[String: Any]] ?? []
        ]
    }
}
