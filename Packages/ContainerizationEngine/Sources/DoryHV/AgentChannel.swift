import Foundation

public protocol AgentByteTransport: AnyObject {
    func readExact(_ count: Int) async throws -> [UInt8]
    func writeAll(_ bytes: [UInt8]) async throws
}

public final class AgentVsockTransport: AgentByteTransport {
    private let connection: VsockConnection
    private let readTimeoutNanoseconds: UInt64

    public init(connection: VsockConnection, readTimeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.connection = connection
        self.readTimeoutNanoseconds = readTimeoutNanoseconds
    }

    private static let minPollIntervalNanoseconds: UInt64 = 1_000_000
    private static let maxPollIntervalNanoseconds: UInt64 = 16_000_000

    public func readExact(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        let deadline = DispatchTime.now().uptimeNanoseconds + readTimeoutNanoseconds
        var pollInterval = Self.minPollIntervalNanoseconds
        while result.count < count {
            let read = try buffer.withUnsafeMutableBytes {
                try connection.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<(count - result.count)]))
            }
            if read == 0 {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw AgentProtocolError.malformedFrame
                }
                try await Task.sleep(nanoseconds: pollInterval)
                pollInterval = min(pollInterval * 2, Self.maxPollIntervalNanoseconds)
                continue
            }
            result.append(contentsOf: buffer.prefix(read))
            pollInterval = Self.minPollIntervalNanoseconds
        }
        return result
    }

    public func writeAll(_ bytes: [UInt8]) async throws {
        try connection.write(bytes)
    }
}

public enum AgentProtocolError: Error, Equatable {
    case frameTooLarge(Int)
    case malformedFrame
    case remoteError(code: Int, message: String)
}

public struct AgentFrameCodec {
    public static let maximumFrameBytes = 16 * 1024 * 1024

    public static func encode(_ payload: [UInt8]) throws -> [UInt8] {
        do {
            return try LengthPrefixCodec.encode(payload, maximumFrameBytes: maximumFrameBytes)
        } catch {
            throw mapped(error)
        }
    }

    public static func decodeLength(_ prefix: [UInt8]) throws -> Int {
        do {
            return try LengthPrefixCodec.decodeLength(prefix, maximumFrameBytes: maximumFrameBytes)
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> AgentProtocolError {
        switch error {
        case LengthPrefixCodecError.frameTooLarge(let size):
            return .frameTooLarge(size)
        case LengthPrefixCodecError.malformedPrefix:
            return .malformedFrame
        default:
            return .malformedFrame
        }
    }
}

public final class AgentChannel {
    private let transport: AgentByteTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextID = 1

    public init(transport: AgentByteTransport) {
        self.transport = transport
    }

    public func syncClock(hostEpochNanoseconds: Int64) async throws -> ClockSyncResult {
        try await call("clock.sync", ClockSyncParams(hostEpochNanoseconds: hostEpochNanoseconds))
    }

    public func watchPorts() async throws -> AgentPortSnapshot {
        try await call("ports.watch", EmptyAgentParams())
    }

    public func call<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        let id = nextID
        nextID += 1
        let request = Request(id: id, method: method, params: AnyEncodable(params))
        let payload = Array(try encoder.encode(request))
        try await transport.writeAll(AgentFrameCodec.encode(payload))

        let prefix = try await transport.readExact(4)
        let length = try AgentFrameCodec.decodeLength(prefix)
        let responsePayload = try await transport.readExact(length)
        let response = try decoder.decode(Response<R>.self, from: Data(responsePayload))
        if let error = response.error {
            throw AgentProtocolError.remoteError(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw AgentProtocolError.malformedFrame
        }
        return result
    }

    private struct Request: Encodable {
        var id: Int
        var method: String
        var params: AnyEncodable
    }

    private struct Response<Result: Decodable>: Decodable {
        var id: Int
        var result: Result?
        var error: RemoteError?
    }

    private struct RemoteError: Decodable {
        var code: Int
        var message: String
    }
}

public struct ClockSyncParams: Encodable, Equatable, Sendable {
    public var hostEpochNanoseconds: Int64

    public init(hostEpochNanoseconds: Int64) {
        self.hostEpochNanoseconds = hostEpochNanoseconds
    }

    enum CodingKeys: String, CodingKey {
        case hostEpochNanoseconds = "hostEpochNS"
    }
}

public struct ClockSyncResult: Decodable, Equatable, Sendable {
    public var synced: Bool

    public init(synced: Bool) {
        self.synced = synced
    }
}

public struct AgentListenPort: Decodable, Equatable, Sendable {
    public var `protocol`: String
    public var port: UInt16

    public init(protocol: String, port: UInt16) {
        self.protocol = `protocol`
        self.port = port
    }
}

public struct AgentPortEvent: Decodable, Equatable, Sendable {
    public var action: String
    public var `protocol`: String
    public var port: UInt16

    public init(action: String, protocol: String, port: UInt16) {
        self.action = action
        self.protocol = `protocol`
        self.port = port
    }
}

public struct AgentPortSnapshot: Decodable, Equatable, Sendable {
    public var ports: [AgentListenPort]
    public var added: [AgentPortEvent]
    public var removed: [AgentPortEvent]

    public init(ports: [AgentListenPort], added: [AgentPortEvent], removed: [AgentPortEvent]) {
        self.ports = ports
        self.added = added
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey {
        case ports
        case added
        case removed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ports = try container.decodeIfPresent([AgentListenPort].self, forKey: .ports) ?? []
        added = try container.decodeIfPresent([AgentPortEvent].self, forKey: .added) ?? []
        removed = try container.decodeIfPresent([AgentPortEvent].self, forKey: .removed) ?? []
    }
}

private struct EmptyAgentParams: Encodable {}

private struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        self.encodeBody = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}
