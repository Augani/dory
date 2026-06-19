import Testing
import Foundation
@testable import Dory

struct HTTPCodecTests {
    @Test func serializesRequestWithHeaders() throws {
        let request = HTTPRequest(method: "GET", path: "/v1.47/containers/json", headers: [(name: "Accept", value: "application/json")])
        let text = String(data: HTTPCodec.serialize(request), encoding: .utf8)!
        #expect(text.hasPrefix("GET /v1.47/containers/json HTTP/1.1\r\n"))
        #expect(text.contains("Host: dory\r\n"))
        #expect(text.contains("Accept: application/json\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func serializesBodyWithContentLength() throws {
        let body = Data(#"{"Image":"redis"}"#.utf8)
        let request = HTTPRequest(method: "POST", path: "/containers/create", headers: [(name: "Content-Type", value: "application/json")], body: body)
        let data = HTTPCodec.serialize(request)
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.hasSuffix(#"{"Image":"redis"}"#))
    }

    @Test func parsesContentLengthResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"hello\":\"x\"}"
        let response = try #require(try HTTPCodec.parseResponse(Data(raw.utf8)))
        #expect(response.statusCode == 200)
        #expect(response.reason == "OK")
        #expect(response.header("content-type") == "application/json")
        #expect(String(data: response.body, encoding: .utf8) == "{\"hello\":\"x\"}")
        #expect(response.isSuccess)
    }

    @Test func returnsNilWhenBodyIncomplete() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nonly-partial"
        let result = try HTTPCodec.parseResponse(Data(raw.utf8))
        #expect(result == nil)
    }

    @Test func returnsNilWhenHeadersIncomplete() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n"
        let result = try HTTPCodec.parseResponse(Data(raw.utf8))
        #expect(result == nil)
    }

    @Test func decodesChunkedResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let response = try #require(try HTTPCodec.parseResponse(Data(raw.utf8)))
        #expect(String(data: response.body, encoding: .utf8) == "hello world")
    }

    @Test func chunkedReturnsNilUntilTerminator() throws {
        let body = Data("5\r\nhello\r\n".utf8)
        let result = try HTTPCodec.decodeChunked(body)
        #expect(result == nil)
    }

    @Test func parsesErrorStatus() throws {
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        let response = try #require(try HTTPCodec.parseResponse(Data(raw.utf8)))
        #expect(response.statusCode == 404)
        #expect(!response.isSuccess)
    }
}
