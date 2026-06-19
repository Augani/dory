import Foundation

enum DependencyCondition: String, Sendable, Equatable {
    case started = "service_started"
    case healthy = "service_healthy"
    case completedSuccessfully = "service_completed_successfully"
}

struct ComposeDependency: Sendable, Equatable {
    var service: String
    var condition: DependencyCondition
}

struct ComposeHealthcheck: Sendable, Equatable {
    var test: [String]
    var interval: TimeInterval
    var timeout: TimeInterval
    var retries: Int
    var startPeriod: TimeInterval

    var config: HealthcheckConfig {
        HealthcheckConfig(interval: interval, timeout: timeout, retries: retries, startPeriod: startPeriod)
    }
}

struct ComposeService: Sendable, Equatable {
    var name: String
    var image: String?
    var build: String?
    var command: [String]
    var environment: [String: String]
    var ports: [String]
    var volumes: [String]
    var networks: [String]
    var dependsOn: [ComposeDependency]
    var restart: String?
    var healthcheck: ComposeHealthcheck?
    var profiles: [String]
}

struct ComposeProject: Sendable, Equatable {
    var name: String
    var services: [ComposeService]
    var networks: [String]
    var volumes: [String]

    func service(named name: String) -> ComposeService? { services.first { $0.name == name } }

    /// Start order honoring depends_on (dependencies first).
    func startOrder() throws -> [String] {
        var deps: [String: [String]] = [:]
        for service in services { deps[service.name] = service.dependsOn.map(\.service) }
        return try DependencyGraph(dependencies: deps).topologicalOrder()
    }
}

enum ComposeParser {
    static func parse(_ text: String, projectName: String, variables: [String: String] = [:]) throws -> ComposeProject {
        let parsed = try YAMLParser.parse(text)
        let interpolated = ComposeInterpolation.interpolate(parsed, variables: variables)
        guard let root = interpolated.mappingValue else {
            throw YAMLError.malformed("compose root is not a mapping")
        }

        let servicesMap = root["services"]?.mappingValue ?? [:]
        let services = servicesMap.keys.sorted().compactMap { name -> ComposeService? in
            guard let value = servicesMap[name]?.mappingValue else { return nil }
            return parseService(name: name, value: value)
        }

        let networks = Array((root["networks"]?.mappingValue ?? [:]).keys).sorted()
        let volumes = Array((root["volumes"]?.mappingValue ?? [:]).keys).sorted()
        return ComposeProject(name: projectName, services: services, networks: networks, volumes: volumes)
    }

    private static func parseService(name: String, value: [String: YAMLValue]) -> ComposeService {
        let command: [String]
        switch value["command"] {
        case let .string(string): command = [string]
        case let .sequence(items): command = items.compactMap(\.stringValue)
        default: command = []
        }

        var environment: [String: String] = [:]
        switch value["environment"] {
        case let .mapping(map): for (key, val) in map { environment[key] = val.stringValue ?? "" }
        case let .sequence(items):
            for item in items {
                guard let entry = item.stringValue else { continue }
                if let eq = entry.firstIndex(of: "=") {
                    environment[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
                } else {
                    environment[entry] = ""
                }
            }
        default: break
        }

        return ComposeService(
            name: name,
            image: value["image"]?.stringValue,
            build: value["build"]?.stringValue ?? value["build"]?["context"]?.stringValue,
            command: command,
            environment: environment,
            ports: value["ports"]?.stringList ?? [],
            volumes: value["volumes"]?.stringList ?? [],
            networks: value["networks"]?.stringList ?? [],
            dependsOn: parseDependsOn(value["depends_on"]),
            restart: value["restart"]?.stringValue,
            healthcheck: parseHealthcheck(value["healthcheck"]),
            profiles: value["profiles"]?.stringList ?? []
        )
    }

    private static func parseDependsOn(_ value: YAMLValue?) -> [ComposeDependency] {
        switch value {
        case let .sequence(items):
            return items.compactMap { $0.stringValue.map { ComposeDependency(service: $0, condition: .started) } }
        case let .mapping(map):
            return map.keys.sorted().map { service in
                let condition = map[service]?["condition"]?.stringValue
                return ComposeDependency(service: service, condition: DependencyCondition(rawValue: condition ?? "") ?? .started)
            }
        default:
            return []
        }
    }

    private static func parseHealthcheck(_ value: YAMLValue?) -> ComposeHealthcheck? {
        guard let map = value?.mappingValue else { return nil }
        let test: [String]
        switch map["test"] {
        case let .string(string): test = ["CMD-SHELL", string]
        case let .sequence(items): test = items.compactMap(\.stringValue)
        default: test = []
        }
        return ComposeHealthcheck(
            test: test,
            interval: duration(map["interval"]?.stringValue) ?? 30,
            timeout: duration(map["timeout"]?.stringValue) ?? 30,
            retries: Int(map["retries"]?.stringValue ?? "") ?? 3,
            startPeriod: duration(map["start_period"]?.stringValue) ?? 0
        )
    }

    /// Parse Compose durations like "1m30s", "10s", "500ms".
    static func duration(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        if let plain = TimeInterval(text) { return plain }
        var total: TimeInterval = 0
        var number = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isNumber || c == "." { number.append(c) }
            else {
                var unit = String(c)
                let next = text.index(after: i)
                if c == "m", next < text.endIndex, text[next] == "s" { unit = "ms"; i = next }
                let value = TimeInterval(number) ?? 0
                switch unit {
                case "ms": total += value / 1000
                case "s": total += value
                case "m": total += value * 60
                case "h": total += value * 3600
                default: break
                }
                number = ""
            }
            i = text.index(after: i)
        }
        return total
    }
}
