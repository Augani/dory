import Testing
import Foundation
@testable import Dory

struct StreamingAndEncodingTests {
    private func frame(_ payload: String, stream: UInt8 = 1) -> Data {
        let bytes = Array(payload.utf8)
        let size = UInt32(bytes.count)
        var data = Data([stream, 0, 0, 0])
        data.append(contentsOf: [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
        data.append(contentsOf: bytes)
        return data
    }

    @Test func logStreamDecoderParsesCompleteFrames() {
        let decoder = LogStreamDecoder()
        let lines = decoder.feed(frame("2026-06-18T12:00:00.123456789Z hello world\n"))
        #expect(lines.count == 1)
        #expect(lines.first?.message == "hello world")
        #expect(lines.first?.timestamp == "12:00:00.123")
    }

    @Test func logStreamDecoderHandlesSplitChunks() {
        let decoder = LogStreamDecoder()
        let full = frame("line one\n")
        let firstHalf = full.prefix(5)
        let secondHalf = full.suffix(from: full.index(full.startIndex, offsetBy: 5))
        #expect(decoder.feed(Data(firstHalf)).isEmpty) // incomplete frame -> no lines yet
        let lines = decoder.feed(Data(secondHalf))
        #expect(lines.first?.message == "line one")
    }

    @Test func logStreamDecoderDetectsLevels() {
        let decoder = LogStreamDecoder()
        let lines = decoder.feed(frame("ERROR something failed\n") + frame("WARN watch out\n"))
        #expect(lines.count == 2)
        #expect(lines[0].level == .error)
        #expect(lines[1].level == .warn)
    }

    @Test func createBodyEncodesPortsAndEnv() throws {
        let spec = ContainerSpec(name: "web", image: "nginx:alpine", environment: ["A": "b"], ports: ["8080:80"], labels: ["x": "y"])
        let data = try JSONEncoder().encode(DockerCreateBody(spec: spec))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["Image"] as? String == "nginx:alpine")
        let env = json["Env"] as? [String]
        #expect(env == ["A=b"])
        let exposed = json["ExposedPorts"] as? [String: Any]
        #expect(exposed?["80/tcp"] != nil)
        let hostConfig = json["HostConfig"] as? [String: Any]
        let bindings = hostConfig?["PortBindings"] as? [String: Any]
        let portMaps = bindings?["80/tcp"] as? [[String: Any]]
        #expect(portMaps?.first?["HostPort"] as? String == "8080")
    }

    @Test func serializeResponseRoundTrips() throws {
        let response = HTTPCodec.serializeResponse(status: 200, headers: [(name: "Content-Type", value: "application/json")], body: Data("{}".utf8))
        let text = String(data: response, encoding: .utf8)!
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }

    @Test func parsesRequestWithQueryAndBody() throws {
        let raw = "POST /v1.47/containers/create?name=web HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/v1.47/containers/create")
        #expect(request.query["name"] == "web")
        #expect(String(data: request.body, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func chunkedStreamDecoderStripsFraming() {
        let decoder = ChunkedStreamDecoder()
        #expect(String(data: decoder.feed(Data("5\r\nhello\r\n".utf8)), encoding: .utf8) == "hello")
        #expect(String(data: decoder.feed(Data("6\r\n world\r\n0\r\n\r\n".utf8)), encoding: .utf8) == " world")
    }

    @Test func chunkedStreamDecoderWaitsForFullChunk() {
        let decoder = ChunkedStreamDecoder()
        #expect(decoder.feed(Data("5\r\nhel".utf8)).isEmpty) // partial chunk -> nothing yet
        #expect(String(data: decoder.feed(Data("lo\r\n".utf8)), encoding: .utf8) == "hello")
    }

    @Test func parsesChunkedRequestBody() throws {
        let raw = "PUT /containers/x/archive?path=/tmp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntar1\r\n4\r\ntar2\r\n0\r\n\r\n"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.method == "PUT")
        #expect(String(data: request.body, encoding: .utf8) == "tar1tar2")
    }

    @Test func chunkedStreamDecoderRejectsOversizedChunkSize() {
        // A near-Int.max chunk size used to trap on `dataStart + size + 2`; it must now be rejected
        // cleanly without crashing or allocating.
        let decoder = ChunkedStreamDecoder()
        #expect(decoder.feed(Data("7ffffffffffffffe\r\nx".utf8)).isEmpty)
        let huge = String(format: "%x", HTTPCodec.maxChunkBytes + 1)
        #expect(ChunkedStreamDecoder().feed(Data("\(huge)\r\nx".utf8)).isEmpty)
    }

    @Test func decodeChunkedRejectsOversizedChunkSize() {
        // The buffering decoder must surface a malformed-chunk error rather than trap on overflow.
        #expect(throws: HTTPError.malformedChunk) {
            _ = try HTTPCodec.decodeChunked(Data("7ffffffffffffffe\r\nx".utf8))
        }
    }

    @Test func parseResponseRejectsNegativeContentLength() throws {
        // A negative Content-Length used to trap on an index offset; it must fall through to
        // connection-close delimiting instead.
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nbody"
        let response = try #require(try HTTPCodec.parseResponse(Data(raw.utf8), connectionClosed: true))
        #expect(response.statusCode == 200)
        #expect(String(data: response.body, encoding: .utf8) == "body")
    }

    @Test func durationParsingEdgeCases() {
        #expect(ComposeParser.duration(nil) == nil)
        #expect(ComposeParser.duration("0s") == 0)
        #expect(ComposeParser.duration("1h30m") == 5400)
    }

    @Test func interpolatesNestedYAMLValues() {
        let value = YAMLValue.mapping([
            "url": .string("http://${HOST}:${PORT}"),
            "list": .sequence([.string("$ENV-a"), .string("plain")]),
        ])
        let out = ComposeInterpolation.interpolate(value, variables: ["HOST": "db", "PORT": "5432", "ENV": "prod"])
        #expect(out["url"]?.stringValue == "http://db:5432")
        #expect(out["list"]?.sequenceValue?.first?.stringValue == "prod-a")
    }

    @MainActor
    @Test func eventBusBroadcastsToConsumers() async {
        let bus = EventBus()
        let stream = bus.stream()
        bus.publish([DoryEvent(containerID: "a", name: "a", image: "img", action: .start)])
        var received: DoryEvent?
        for await event in stream { received = event; break }
        #expect(received?.action == .start)
        #expect(received?.containerID == "a")
    }
}
