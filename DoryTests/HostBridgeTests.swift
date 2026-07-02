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
        #expect(req?.ttlSec == 300)
    }

    @Test func rejectsMalformedJSON() {
        #expect(HostBridge.decodeOpen(Data("not json".utf8)) == nil)
        #expect(HostBridge.decodeForward(Data(#"{"port":"x"}"#.utf8)) == nil)
    }
}
