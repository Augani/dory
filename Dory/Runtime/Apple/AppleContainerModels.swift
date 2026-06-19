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
