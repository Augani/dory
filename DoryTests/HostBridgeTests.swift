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

    @Test func trimsWhitespaceBeforeParsing() {
        #expect(HostBridge.allowedURL("  https://x.com  ") != nil)
    }

    @Test func rejectsHostlessURL() {
        #expect(HostBridge.allowedURL("http://") == nil)
        #expect(HostBridge.allowedURL("http://user@/path") == nil)
    }

    @Test func forwardPortRange() {
        #expect(HostBridge.allowedForwardPort(1024))
        #expect(HostBridge.allowedForwardPort(53219))
        #expect(HostBridge.allowedForwardPort(65535))
        #expect(!HostBridge.allowedForwardPort(1023))
        #expect(!HostBridge.allowedForwardPort(80))
        #expect(!HostBridge.allowedForwardPort(0))
        #expect(!HostBridge.allowedForwardPort(65536))
        #expect(!HostBridge.allowedForwardPort(-5))
    }

    @Test func ttlDefaultsAndClamps() {
        #expect(HostBridge.resolvedTTL(nil) == 300)
        #expect(HostBridge.resolvedTTL(120) == 120)
        #expect(HostBridge.resolvedTTL(0) == 300)
        #expect(HostBridge.resolvedTTL(-10) == 300)
        #expect(HostBridge.resolvedTTL(99999) == 3600)
    }

    @Test func consumeReadsThenDeletes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("req.json")
        try Data("payload".utf8).write(to: file)
        let data = HostBridge.consume(at: file)
        #expect(data == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func consumeSkipsTmpFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("req.json.tmp")
        try Data("partial".utf8).write(to: file)
        #expect(HostBridge.consume(at: file) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func rejectsOversizedOpenPayload() {
        let padding = String(repeating: "a", count: HostBridge.maxRequestBytes)
        let json = #"{"url":"https://example.com/cb","cwd":"\#(padding)","ts":1719800000}"#
        let data = Data(json.utf8)
        #expect(data.count > HostBridge.maxRequestBytes)
        #expect(HostBridge.decodeOpen(data) == nil)
    }

    @Test func watcherOpensValidURLAndDeletesRequest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = OpenRecorder()
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { url in recorded.append(url) }
        watcher.startWatching(machine: "dev")
        defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
        let openDir = root.appendingPathComponent("dev/open")
        let file = openDir.appendingPathComponent("\(UUID().uuidString).json")
        try Data(#"{"url":"https://example.com/cb?code=1","cwd":null,"ts":1}"#.utf8).write(to: file)
        watcher.scanOnce(machine: "dev")
        #expect(recorded.urls.map(\.absoluteString) == ["https://example.com/cb?code=1"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func watcherRejectsFileSchemeButStillDeletes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = OpenRecorder()
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { url in recorded.append(url) }
        watcher.startWatching(machine: "dev")
        defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
        let file = root.appendingPathComponent("dev/open/\(UUID().uuidString).json")
        try Data(#"{"url":"file:///etc/passwd","cwd":null,"ts":1}"#.utf8).write(to: file)
        watcher.scanOnce(machine: "dev")
        #expect(recorded.urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func watcherWiresForwardForValidPort() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { _ in }
        watcher.startWatching(machine: "dev")
        defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
        let file = root.appendingPathComponent("dev/forward/54020.json")
        try Data(#"{"port":54020,"ts":1,"ttlSec":300}"#.utf8).write(to: file)
        watcher.scanOnce(machine: "dev")
        #expect(fwd.activeLoopbackKeys() == ["dev:54020"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func startAndStopTracksWatchedMachines() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { _ in }
        watcher.startWatching(machine: "dev")
        #expect(watcher.watchedMachines() == ["dev"])
        watcher.stopWatching(machine: "dev")
        #expect(watcher.watchedMachines().isEmpty)
        fwd.stopAll()
    }

    final class OpenRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    }
}
