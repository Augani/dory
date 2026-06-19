import Foundation

enum ComposeGraphError: Error, Sendable, Equatable {
    case cycle([String])
    case unknownDependency(service: String, dependency: String)
}

/// Builds a start-order from service dependencies using Kahn's algorithm, detecting cycles and
/// dangling dependencies. Dependencies are started before their dependents.
struct DependencyGraph: Sendable {
    let dependencies: [String: [String]]

    init(dependencies: [String: [String]]) { self.dependencies = dependencies }

    func topologicalOrder() throws -> [String] {
        let nodes = Set(dependencies.keys)
        for (service, deps) in dependencies {
            for dep in deps where !nodes.contains(dep) {
                throw ComposeGraphError.unknownDependency(service: service, dependency: dep)
            }
        }

        var indegree: [String: Int] = [:]
        for node in nodes { indegree[node] = 0 }
        for (_, deps) in dependencies {
            for dep in deps { indegree[dep, default: 0] += 0 }
        }
        // Edge dep -> service (dependency must come first); indegree counts incoming edges.
        var adjacency: [String: [String]] = [:]
        for (service, deps) in dependencies {
            for dep in deps {
                adjacency[dep, default: []].append(service)
                indegree[service, default: 0] += 1
            }
        }

        var queue = nodes.filter { indegree[$0] == 0 }.sorted()
        var order: [String] = []
        while !queue.isEmpty {
            let node = queue.removeFirst()
            order.append(node)
            for next in (adjacency[node] ?? []).sorted() {
                indegree[next]! -= 1
                if indegree[next] == 0 { queue.append(next); queue.sort() }
            }
        }

        if order.count != nodes.count {
            let remaining = nodes.subtracting(order).sorted()
            throw ComposeGraphError.cycle(remaining)
        }
        return order
    }
}
