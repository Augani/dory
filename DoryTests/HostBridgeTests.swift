import Testing
import Foundation
@testable import Dory

struct HostBridgeTests {
    @Test func decodesOpenRequest() {
        let json = #"{"url":"https://example.com/cb?code=1","cwd":"/home/me","ts":1719800000}"#
        let req = HostBridge.decodeOpen(Data(json.utf8))
        #expect(req?.url == "https://example.com/cb?code=1")
        #expect(req?.cwd == "/home/me")
        #expect(req?.ts == 1719800000)
    }

    @Test func decodesForwardRequest() {
        let json = #"{"port":53219,"ts":1719800000,"ttlSec":300}"#
        let req = HostBridge.decodeForward(Data(json.utf8))
        #expect(req?.port == 53219)
        #expect(req?.ts == 1719800000)
        #expect(req?.ttlSec == 300)
    }

    @Test func decodesForwardRequestWithoutTTL() {
        let json = #"{"port":53219,"ts":1719800000}"#
        let req = HostBridge.decodeForward(Data(json.utf8))
        #expect(req?.port == 53219)
        #expect(req?.ts == 1719800000)
        #expect(req?.ttlSec == nil)
    }

    @Test func decodesOpenRequestWithoutCwd() {
        let json = #"{"url":"https://example.com/cb","ts":1719800000}"#
        let req = HostBridge.decodeOpen(Data(json.utf8))
        #expect(req?.url == "https://example.com/cb")
        #expect(req?.cwd == nil)
        #expect(req?.ts == 1719800000)
    }

    @Test func rejectsMalformedJSON() {
        #expect(HostBridge.decodeOpen(Data("not json".utf8)) == nil)
        #expect(HostBridge.decodeForward(Data(#"{"port":"x"}"#.utf8)) == nil)
    }

    @Test func allowsHTTPAndHTTPSOnly() {
        #expect(HostBridge.allowedURL("https://example.com/cb?code=1") != nil)
        #expect(HostBridge.allowedURL("http://127.0.0.1:53219/cb") != nil)
        #expect(HostBridge.allowedURL("file:///etc/passwd") == nil)
        #expect(HostBridge.allowedURL("vscode://x") == nil)
        #expect(HostBridge.allowedURL("") == nil)
        #expect(HostBridge.allowedURL("javascript:alert(1)") == nil)
        #expect(HostBridge.allowedURL("HTTPS://EXAMPLE.com") != nil)
    }

    @Test func rejectsOversizedOpenPayload() {
        let padding = String(repeating: "a", count: HostBridge.maxRequestBytes)
        let json = #"{"url":"https://example.com/cb","cwd":"\#(padding)","ts":1719800000}"#
        let data = Data(json.utf8)
        #expect(data.count > HostBridge.maxRequestBytes)
        #expect(HostBridge.decodeOpen(data) == nil)
    }
}
