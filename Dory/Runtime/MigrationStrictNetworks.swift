import Foundation

extension MigrationStrictInventoryCollector {
    static func networkInspections(
        _ networks: [DoryNetwork],
        runtime: any ContainerRuntime,
        requirePortable: Bool
    ) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        for network in networks.sorted(by: { $0.name < $1.name }) {
            guard let response = await runtime.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(network.name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            ), response.isSuccess,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  JSONSerialization.isValidJSONObject(object),
                  let canonical = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.sortedKeys]
                  ) else {
                throw MigrationStrictInventoryError.incomplete(
                    "network \(network.name) could not be inspected exactly"
                )
            }
            if requirePortable { try validateNetwork(object, network: network) }
            result[network.name] = canonical
        }
        return result
    }
}

private extension MigrationStrictInventoryCollector {
    static func validateNetwork(
        _ object: [String: Any],
        network: DoryNetwork
    ) throws {
        let driver = (object["Driver"] as? String)?.lowercased() ?? ""
        let scope = (object["Scope"] as? String)?.lowercased() ?? network.scope.lowercased()
        let ingress = object["Ingress"] as? Bool ?? false
        let configOnly = object["ConfigOnly"] as? Bool ?? false
        let configFrom = object["ConfigFrom"] as? [String: Any] ?? [:]
        guard driver == "bridge",
              scope == "local",
              !ingress,
              !configOnly,
              configFrom.isEmpty else {
            throw MigrationStrictInventoryError.unsupported(
                "network \(network.name) depends on non-local bridge or swarm state"
            )
        }
    }
}
