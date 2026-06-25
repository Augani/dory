import Foundation

struct ACImageRef: Decodable, Sendable {
    var reference: String?
}

struct ACInitProcess: Decodable, Sendable {
    var executable: String?
    var arguments: [String]?
    var environment: [String]?
    var workingDirectory: String?
}

struct ACResources: Decodable, Sendable {
    var cpus: Int?
    var memoryInBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case cpus, memoryInBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decodeFlexibleIntIfPresent(forKey: .cpus)
        memoryInBytes = try container.decodeFlexibleInt64IfPresent(forKey: .memoryInBytes)
    }
}

struct ACPublishedPort: Decodable, Sendable {
    var hostPort: Int?
    var containerPort: Int?
    var proto: String?
    enum CodingKeys: String, CodingKey { case hostPort, containerPort, proto = "protocol" }
}

struct ACConfiguration: Decodable, Sendable {
    var id: String?
    var image: ACImageRef?
    var initProcess: ACInitProcess?
    var labels: [String: String]?
    var resources: ACResources?
    var creationDate: String?
    var publishedPorts: [ACPublishedPort]?
    var rosetta: Bool?
}

struct ACStatusNetwork: Decodable, Sendable {
    var hostname: String?
    var ipv4Address: String?
    var ipv4Gateway: String?
    var network: String?
}

struct ACStatus: Decodable, Sendable {
    var state: String?
    var startedDate: String?
    var networks: [ACStatusNetwork]?
    var exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case state, startedDate, networks, exitCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        startedDate = try container.decodeIfPresent(String.self, forKey: .startedDate)
        networks = try container.decodeIfPresent([ACStatusNetwork].self, forKey: .networks)
        if let code = try? container.decodeIfPresent(Int.self, forKey: .exitCode) {
            exitCode = code
        } else if let raw = try? container.decodeIfPresent(String.self, forKey: .exitCode) {
            exitCode = Int(raw)
        } else {
            exitCode = nil
        }
    }
}

struct ACContainer: Decodable, Sendable {
    var id: String
    var configuration: ACConfiguration?
    var status: ACStatus?
}

struct ACImageDescriptor: Decodable, Sendable {
    var digest: String?
    var size: Int64?
}

struct ACImageConfiguration: Decodable, Sendable {
    var name: String?
    var descriptor: ACImageDescriptor?
    var creationDate: String?
    var labels: [String: String]?
}

struct ACImage: Decodable, Sendable {
    var id: String
    var configuration: ACImageConfiguration?
}

struct ACVolumeConfiguration: Decodable, Sendable {
    var name: String?
    var driver: String?
    var sizeInBytes: Int64?
    var creationDate: String?
    var source: String?
}

struct ACVolume: Decodable, Sendable {
    var id: String
    var configuration: ACVolumeConfiguration?
}

struct ACStats: Decodable, Sendable {
    var id: String
    var cpuUsageUsec: Int64?
    var memoryUsageBytes: Int64?
    var memoryLimitBytes: Int64?
    var cpus: Int?

    enum CodingKeys: String, CodingKey {
        case id, cpuUsageUsec, memoryUsageBytes, memoryLimitBytes, cpus, onlineCPUs
        case onlineCPUsSnake = "online_cpus"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cpuUsageUsec = try container.decodeFlexibleInt64IfPresent(forKey: .cpuUsageUsec)
        memoryUsageBytes = try container.decodeFlexibleInt64IfPresent(forKey: .memoryUsageBytes)
        memoryLimitBytes = try container.decodeFlexibleInt64IfPresent(forKey: .memoryLimitBytes)
        cpus = try container.decodeFlexibleIntIfPresent(forKey: .cpus)
            ?? container.decodeFlexibleIntIfPresent(forKey: .onlineCPUs)
            ?? container.decodeFlexibleIntIfPresent(forKey: .onlineCPUsSnake)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Int(value) }
        if let raw = try? decodeIfPresent(String.self, forKey: key) { return Int(raw) }
        return nil
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
        if let raw = try? decodeIfPresent(String.self, forKey: key) { return Int64(raw) }
        return nil
    }
}

struct ACMachine: Decodable, Sendable {
    var id: String
    var status: String?
    var cpus: Int?
    var memory: Int64?
    var ipAddress: String?
    var diskSize: Int64?
    var createdDate: String?
    var `default`: Bool?
}
