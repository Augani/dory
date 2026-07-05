import Foundation
import Testing
@testable import DoryHV

struct HostFSEventRelayTests {
    @Test func mapsHostPathsIntoGuestSharePaths() async throws {
        let batcher = FSEventBatcher(
            shares: [
                HostFSEventShare(hostRoot: "/Users/me/Project", guestRoot: "/mnt/dory/src"),
                HostFSEventShare(hostRoot: "/Users/me/Cache", guestRoot: "/mnt/dory/cache"),
            ],
            send: { _ in }
        )

        #expect(batcher.mapHostPathToGuest("/Users/me/Project") == "/mnt/dory/src")
        #expect(batcher.mapHostPathToGuest("/Users/me/Project/Sources/App.swift") == "/mnt/dory/src/Sources/App.swift")
        #expect(batcher.mapHostPathToGuest("/Users/me/Cache/pkg") == "/mnt/dory/cache/pkg")
        #expect(batcher.mapHostPathToGuest("/Users/me/Other/file") == nil)
    }

    @Test func coalescesAndSortsDuplicatePathsPerFlush() async throws {
        let sink = BatchSink()
        let batcher = FSEventBatcher(
            shares: [HostFSEventShare(hostRoot: "/host", guestRoot: "/guest")],
            send: { paths in await sink.append(paths) }
        )

        batcher.enqueue(hostPaths: ["/host/b.txt", "/host/a.txt", "/host/b.txt", "/outside/nope"])
        await batcher.flushNow()
        await batcher.flushNow()

        #expect(await sink.batches == [["/guest/a.txt", "/guest/b.txt"]])
    }

    @Test func agentChannelSendsFSEventBatchMethod() async throws {
        let transport = StubAgentTransport(responsePayload: #"{"id":1,"result":{"touched":2}}"#)
        let channel = AgentChannel(transport: transport)

        let result = try await channel.sendFSEventBatch(paths: ["/mnt/dory/src/a", "/mnt/dory/src/b"])
        let request = try transport.decodedRequest()

        #expect(result.touched == 2)
        #expect(request.method == "fsevents.batch")
        #expect(request.params.paths == ["/mnt/dory/src/a", "/mnt/dory/src/b"])
    }
}

private actor BatchSink {
    private(set) var batches: [[String]] = []

    func append(_ paths: [String]) {
        batches.append(paths)
    }
}

private struct CapturedFSEventRequest: Decodable {
    var id: Int
    var method: String
    var params: FSEventBatchParams
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

    func decodedRequest() throws -> CapturedFSEventRequest {
        let length = try AgentFrameCodec.decodeLength(Array(written.prefix(4)))
        let payload = Data(written.dropFirst(4).prefix(length))
        return try JSONDecoder().decode(CapturedFSEventRequest.self, from: payload)
    }
}
