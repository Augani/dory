import Foundation

/// Per-engine paths for gvproxy and its private control sockets. Keeping these sockets in a
/// process-scoped directory prevents a rapid restart from reconnecting to endpoints that Darwin is
/// still releasing from the previous gvproxy instance.
public struct GVProxyRuntimePaths: Equatable, Sendable {
    public let directory: String
    public let datapathSocket: String
    public let lanDatapathSocket: String
    public let apiSocket: String
    public let shutdownSocket: String
    public let healthSocket: String
    public let vmSocket: String
    public let reclaimSocket: String

    public init(stateDirectory: String, processIdentifier: Int32) throws {
        guard processIdentifier > 0 else {
            throw VMError.invalidConfiguration("gvproxy runtime process identifier must be positive")
        }
        let directory = stateDirectory + "/n\(processIdentifier)"
        self.directory = directory
        self.datapathSocket = directory + "/d.sock"
        self.lanDatapathSocket = directory + "/l.sock"
        self.apiSocket = directory + "/a.sock"
        self.shutdownSocket = directory + "/s.sock"
        self.healthSocket = directory + "/h.sock"
        self.vmSocket = directory + "/v.sock"
        self.reclaimSocket = directory + "/r.sock"

        for path in socketPaths {
            try DockerSocketBridge.validateSocketPath(path)
        }
    }

    public var socketPaths: [String] {
        [
            datapathSocket,
            lanDatapathSocket,
            apiSocket,
            shutdownSocket,
            healthSocket,
            vmSocket,
            reclaimSocket,
        ]
    }
}
