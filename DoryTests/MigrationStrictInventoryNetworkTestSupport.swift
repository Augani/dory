import Foundation
@testable import Dory

@MainActor
extension StrictMigrationRuntime {
    func removeNetwork(name: String) async throws {
        removedNetworks.append(name)
        if failNetworkRemoval { throw TestMutationFailure.injected }
        snapshotValue.networks.removeAll { $0.name == name }
        networkInspections[name] = nil
    }

    func proxyRequest(
        method: String,
        path: String,
        headers: [(name: String, value: String)],
        body: Data
    ) async -> HTTPResponse? {
        if method == "POST", path == "/networks/create" {
            return createNetworkResponse(body)
        }
        guard method == "GET" else { return nil }
        if path == "/version" { return response(version) }
        if path == "/info" { return response(info) }
        if path.hasPrefix("/system/df") { return response(systemDiskUsage) }
        if path.hasPrefix("/containers/"), path.hasSuffix("/json") {
            let id = String(path.dropFirst("/containers/".count).dropLast("/json".count))
            return response(containerInspections[id])
        }
        if path.hasPrefix("/networks/") {
            let name = String(path.dropFirst("/networks/".count))
            return response(networkInspections[name])
        }
        return nil
    }

    private func createNetworkResponse(_ body: Data) -> HTTPResponse? {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = object["Name"] as? String,
              let driver = object["Driver"] as? String,
              let labels = object["Labels"] as? [String: String] else { return nil }
        createdNetworkRequests.append(body)
        object["Scope"] = "local"
        if mutateCreatedNetworkContract {
            object["Options"] = ["com.docker.network.bridge.enable_icc": "false"]
        }
        networkInspections[name] = object
        snapshotValue.networks.append(DoryNetwork(
            name: name,
            driver: driver,
            scope: "local",
            subnet: "172.30.0.0/24",
            containerCount: 0,
            labels: labels
        ))
        let responseBody = try? JSONSerialization.data(withJSONObject: ["Id": "network-id"])
        return HTTPResponse(
            statusCode: 201,
            reason: "Created",
            headers: [:],
            body: responseBody ?? Data()
        )
    }

    private func response(_ object: [String: Any]?) -> HTTPResponse? {
        guard let object,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data)
    }
}
