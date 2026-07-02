import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import Dory

struct DockerEngineSocketDiscoveryTests {
    @Test func dockerHostUnixSocketHasHighestPriority() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.writeDockerContext(home: home, id: "a", name: "colima", host: "unix:///tmp/colima.sock")

        let candidates = DockerEngineSocketDiscovery.candidates(
            environment: ["DOCKER_HOST": "unix:///tmp/explicit.sock"],
            home: home.path
        )

        #expect(candidates.first == "/tmp/explicit.sock")
        #expect(candidates.contains("/tmp/colima.sock"))
    }

    @Test func dockerContextNamePrioritizesMatchingContext() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.writeDockerContext(home: home, id: "a", name: "colima", host: "unix:///tmp/colima.sock")
        try Self.writeDockerContext(home: home, id: "b", name: "podman", host: "unix:///tmp/podman.sock")

        let candidates = DockerEngineSocketDiscovery.candidates(
            environment: ["DOCKER_CONTEXT": "podman"],
            home: home.path
        )

        #expect(candidates.first == "/tmp/podman.sock")
        #expect(candidates.contains("/tmp/colima.sock"))
    }

    @Test func currentDockerContextFromConfigIsPreferred() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.writeDockerConfig(home: home, currentContext: "colima")
        try Self.writeDockerContext(home: home, id: "a", name: "colima", host: "unix:///tmp/colima.sock")
        try Self.writeDockerContext(home: home, id: "b", name: "rancher", host: "unix:///tmp/rancher.sock")

        let candidates = DockerEngineSocketDiscovery.candidates(environment: [:], home: home.path)

        #expect(candidates.first == "/tmp/colima.sock")
        #expect(candidates.contains("/tmp/rancher.sock"))
    }

    @Test func commonSocketsCoverDockerCompatibleMacEngines() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        let candidates = DockerEngineSocketDiscovery.candidates(environment: [:], home: home.path)

        #expect(candidates.contains("/var/run/docker.sock"))
        #expect(candidates.contains("\(home.path)/.orbstack/run/docker.sock"))
        #expect(candidates.contains("\(home.path)/.docker/run/docker.sock"))
        #expect(candidates.contains("\(home.path)/.colima/default/docker.sock"))
        #expect(candidates.contains("\(home.path)/.rd/docker.sock"))
        #expect(candidates.contains("\(home.path)/.local/share/containers/podman/machine/podman-machine-default/podman.sock"))
    }

    @Test func duplicateSocketsAreRemovedPreservingOrder() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.writeDockerContext(home: home, id: "a", name: "defaultish", host: "unix:///var/run/docker.sock")

        let candidates = DockerEngineSocketDiscovery.candidates(
            environment: ["DOCKER_HOST": "unix:///var/run/docker.sock"],
            home: home.path
        )

        #expect(candidates.filter { $0 == "/var/run/docker.sock" }.count == 1)
    }

    @Test func doryShimSocketIsExcludedFromDockerHostAndContexts() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        let dorySocket = "\(home.path)/.dory/dory.sock"
        try Self.writeDockerContext(home: home, id: "a", name: "dory", host: "unix://\(dorySocket)")

        let candidates = DockerEngineSocketDiscovery.candidates(
            environment: ["DOCKER_HOST": "unix://\(dorySocket)", "DOCKER_CONTEXT": "dory"],
            home: home.path
        )

        #expect(!candidates.contains(dorySocket))
    }

    @Test func activeDoryContextFallsThroughToRealHostEngineCandidates() throws {
        let home = try TempHome.make()
        defer { try? FileManager.default.removeItem(at: home) }

        let dorySocket = "\(home.path)/.dory/dory.sock"
        try Self.writeDockerConfig(home: home, currentContext: "dory")
        try Self.writeDockerContext(home: home, id: "a", name: "dory", host: "unix://\(dorySocket)")
        try Self.writeDockerContext(home: home, id: "b", name: "colima", host: "unix:///tmp/colima.sock")

        let candidates = DockerEngineSocketDiscovery.candidates(environment: [:], home: home.path)

        #expect(candidates.first == "/tmp/colima.sock")
        #expect(!candidates.contains(dorySocket))
    }

    @MainActor
    @Test func detectSkipsHungSocketAndFindsNextCandidate() async throws {
        let hungPath = Self.shortSocketPath("dory-detect-hung")
        let goodPath = Self.shortSocketPath("dory-detect-good")
        let hung = try HungUnixSocketCandidate(path: hungPath)
        defer { hung.stop() }
        let server = ShimHTTPServer(socketPath: goodPath) { _ in
            ShimResponse(
                status: 200,
                headers: [(name: "Content-Type", value: "application/json")],
                body: Data(#"{"Version":"29.5.3","ApiVersion":"1.47"}"#.utf8)
            )
        }
        try server.start()
        defer { server.stop() }

        let started = Date()
        let runtime = await DockerEngineRuntime.detect(candidates: [hungPath, goodPath], probeTimeout: 2.5)

        #expect(runtime?.socketPath == goodPath)
        #expect(Date().timeIntervalSince(started) < 6.0)
    }

    @MainActor
    @Test func detectProbesMultipleStaleSocketsConcurrently() async throws {
        let hungPaths = (0..<4).map { Self.shortSocketPath("dory-detect-stale-\($0)") }
        let goodPath = Self.shortSocketPath("dory-detect-concurrent-good")
        let hung = try hungPaths.map { try HungUnixSocketCandidate(path: $0) }
        defer { hung.forEach { $0.stop() } }
        let server = ShimHTTPServer(socketPath: goodPath) { _ in
            ShimResponse(
                status: 200,
                headers: [(name: "Content-Type", value: "application/json")],
                body: Data(#"{"Version":"29.5.3","ApiVersion":"1.47"}"#.utf8)
            )
        }
        try server.start()
        defer { server.stop() }

        let started = Date()
        let runtime = await DockerEngineRuntime.detect(candidates: hungPaths + [goodPath], probeTimeout: 2.5)

        #expect(runtime?.socketPath == goodPath)
        #expect(Date().timeIntervalSince(started) < 6.0)
    }

    private static func shortSocketPath(_ prefix: String) -> String {
        let path = "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: path)
        return path
    }

    private static func writeDockerConfig(home: URL, currentContext: String) throws {
        let url = home.appendingPathComponent(".docker/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"currentContext":"\#(currentContext)"}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeDockerContext(home: URL, id: String, name: String, host: String) throws {
        let url = home
            .appendingPathComponent(".docker/contexts/meta")
            .appendingPathComponent(id)
            .appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)"}}}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum TempHome {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class HungUnixSocketCandidate {
    private let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var clientFD: Int32 = -1

    init(path: String) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("socket")) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw HTTPError.socket("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = byte }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("bind")) }
        guard listen(fd, 1) == 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("listen")) }
        Thread.detachNewThread { [fd, weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.lock.lock()
            self?.clientFD = client
            self?.lock.unlock()
            Thread.sleep(forTimeInterval: 2)
            self?.lock.lock()
            if self?.clientFD == client {
                self?.clientFD = -1
                Darwin.close(client)
            }
            self?.lock.unlock()
        }
    }

    func stop() {
        Darwin.close(fd)
        lock.lock()
        let client = clientFD
        clientFD = -1
        lock.unlock()
        if client >= 0 { Darwin.close(client) }
        try? FileManager.default.removeItem(atPath: path)
    }
}
