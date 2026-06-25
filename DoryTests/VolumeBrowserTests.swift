import Testing
import Foundation
@testable import Dory

struct VolumeBrowserTests {
    private func makeTar(name: String, content: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array(name.utf8).prefix(100).enumerated() { header[i] = b }
        let sizeOctal = Array(String(format: "%011o", content.count).utf8)
        for (i, b) in sizeOctal.enumerated() { header[124 + i] = b }
        header[156] = UInt8(ascii: "0")
        var tar = header + content
        let pad = (512 - content.count % 512) % 512
        tar += [UInt8](repeating: 0, count: pad)
        tar += [UInt8](repeating: 0, count: 1024)
        return Data(tar)
    }

    @Test func extractsRegularFileContent() {
        let content = Array("hi there".utf8)
        let tar = makeTar(name: "hello.txt", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func extractsEmptyFile() {
        let tar = makeTar(name: "empty", content: [])
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data())
    }

    @Test func extractsBinaryContentLosslessly() {
        let content: [UInt8] = [0x00, 0xFF, 0x10, 0x80, 0x00, 0x7F]
        let tar = makeTar(name: "bin.dat", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func returnsNilForShortData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data([1, 2, 3])) == nil)
    }

    @Test func returnsNilForAllZeroData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data(count: 1024)) == nil)
    }

    @Test func exportFileStrictlyEncodesArchiveQueryPath() async {
        let content = Array("hello".utf8)
        let capture = ProxyRequestCapture()
        let runtime = VolumeExportRuntime(capture: capture, archive: makeTar(name: "file.txt", content: content))

        let exported = await VolumeBrowser(runtime: runtime).exportFile(volume: "cache", path: "/a&b?c=d+e.txt")

        #expect(exported == Data(content))
        #expect(capture.archiveTargets == [
            "/containers/helper123/archive?path=%2Fdata%2Fa%26b%3Fc%3Dd%2Be.txt",
        ])
    }
}

private final class ProxyRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(method: String, path: String)] = []

    var archiveTargets: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
            .filter { $0.method == "GET" && $0.path.contains("/archive?") }
            .map(\.path)
    }

    func record(method: String, path: String) {
        lock.lock()
        requests.append((method, path))
        lock.unlock()
    }
}

private struct VolumeExportRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    let capture: ProxyRequestCapture
    let archive: Data

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { spec.name }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        capture.record(method: method, path: path)
        if method == "POST", path == "/containers/create" {
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"helper123"}"#.utf8))
        }
        if method == "GET", path.contains("/archive?") {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: archive)
        }
        return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
    }
}
