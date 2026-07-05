import Foundation
import Testing
@testable import DoryHV

@Suite struct AgentProtocolTests {
    @Test func frameCodecUsesBigEndianLengthPrefix() throws {
        let frame = try AgentFrameCodec.encode([1, 2, 3])
        #expect(frame.prefix(4) == [0, 0, 0, 3])
        #expect(try AgentFrameCodec.decodeLength(Array(frame.prefix(4))) == 3)
        #expect(Array(frame.dropFirst(4)) == [1, 2, 3])
    }

    @Test func frameCodecRejectsOversizedFrames() throws {
        #expect(throws: AgentProtocolError.self) {
            _ = try AgentFrameCodec.decodeLength([1, 0, 0, 1])
        }
    }

    @Test func callReturnsDecodedResult() async throws {
        let transport = StubAgentTransport(responsePayload: #"{"id":1,"result":{"ok":true,"kernel":"6.12.30-dory"}}"#)
        let channel = AgentChannel(transport: transport)
        let result: PingResult = try await channel.call("ping", EmptyParams())

        #expect(result.ok)
        #expect(result.kernel == "6.12.30-dory")
        let request = try transport.decodedRequest()
        #expect(request.method == "ping")
        #expect(request.id == 1)
    }

    @Test func callThrowsRemoteErrors() async throws {
        let transport = StubAgentTransport(responsePayload: #"{"id":1,"error":{"code":-32601,"message":"unknown method"}}"#)
        let channel = AgentChannel(transport: transport)

        await #expect(throws: AgentProtocolError.remoteError(code: -32601, message: "unknown method")) {
            let _: PingResult = try await channel.call("missing", EmptyParams())
        }
    }

    @Test func clockSyncUsesAgentTimestampKey() async throws {
        let transport = StubAgentTransport(responsePayload: #"{"id":1,"result":{"synced":true}}"#)
        let channel = AgentChannel(transport: transport)

        let result = try await channel.syncClock(hostEpochNanoseconds: 1_725_000_000_123_456_789)
        let request = try transport.decodedRequest()
        let params: ClockParams = try transport.decodedParams()

        #expect(result.synced)
        #expect(request.method == "clock.sync")
        #expect(params.hostEpochNS == 1_725_000_000_123_456_789)
    }

    @Test func vsockTransportReadsExactBytesAcrossFragments() async throws {
        let connection = StubVsockConnection(chunks: [[1, 2], [3], [4, 5]])
        let transport = AgentVsockTransport(connection: connection)

        #expect(try await transport.readExact(5) == [1, 2, 3, 4, 5])
        try await transport.writeAll([9, 8, 7])
        #expect(connection.written == [9, 8, 7])
    }

    private struct EmptyParams: Encodable {}

    private struct PingResult: Decodable {
        var ok: Bool
        var kernel: String
    }

    private struct CapturedRequest: Decodable {
        var id: Int
        var method: String
    }

    private struct Envelope<Params: Decodable>: Decodable {
        var params: Params
    }

    private struct ClockParams: Decodable {
        var hostEpochNS: Int64
    }

    private final class StubAgentTransport: AgentByteTransport {
        private var response: [UInt8]
        private(set) var written = [UInt8]()

        init(responsePayload: String) {
            self.response = (try? AgentFrameCodec.encode(Array(responsePayload.utf8))) ?? []
        }

        func readExact(_ count: Int) async throws -> [UInt8] {
            let bytes = Array(response.prefix(count))
            response.removeFirst(min(count, response.count))
            return bytes
        }

        func writeAll(_ bytes: [UInt8]) async throws {
            written.append(contentsOf: bytes)
        }

        func decodedRequest() throws -> CapturedRequest {
            let length = try AgentFrameCodec.decodeLength(Array(written.prefix(4)))
            let payload = Data(written.dropFirst(4).prefix(length))
            return try JSONDecoder().decode(CapturedRequest.self, from: payload)
        }

        func decodedParams<Params: Decodable>() throws -> Params {
            let length = try AgentFrameCodec.decodeLength(Array(written.prefix(4)))
            let payload = Data(written.dropFirst(4).prefix(length))
            return try JSONDecoder().decode(Envelope<Params>.self, from: payload).params
        }
    }

    private final class StubVsockConnection: VsockConnection {
        private var chunks: [[UInt8]]
        private(set) var written = [UInt8]()

        init(chunks: [[UInt8]]) {
            self.chunks = chunks
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            guard !chunks.isEmpty else { return 0 }
            let chunk = chunks.removeFirst()
            let count = min(buffer.count, chunk.count)
            chunk.prefix(count).withUnsafeBytes { source in
                buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
            }
            if count < chunk.count {
                chunks.insert(Array(chunk.dropFirst(count)), at: 0)
            }
            return count
        }

        func write(_ bytes: [UInt8]) throws {
            written.append(contentsOf: bytes)
        }

        func close() { closed = true }

        private(set) var closed = false
        var isPeerClosed: Bool { closed }
    }
}
