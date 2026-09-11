import Darwin
import DoryCore
import Foundation
import Testing
@testable import DoryHV
@testable import dory_hv

@Suite(.serialized) struct GVProxyForwardRegistryTests {
    @Test func decodesOnlyDoryContainerForwardShape() throws {
        let data = Data(#"""
        [
          {"local":"127.0.0.1:2222","remote":"192.168.127.2:22","protocol":"tcp"},
          {"local":":6443","remote":"192.168.127.2:6443","protocol":"tcp"},
          {"local":"127.0.0.1:55120","remote":"192.168.127.2:55120","protocol":"tcp"},
          {"local":"[::1]:5353","remote":"udp://192.168.127.2:5353","protocol":"udp"},
          {"local":"/tmp/shutdown.sock","remote":"tcp://192.168.127.2:2377","protocol":"unix"},
          {"local":"127.0.0.1:55999","remote":"192.168.127.3:55999","protocol":"tcp"}
        ]
        """#.utf8)

        let registry = try #require(GVProxyForwardRegistry.decode(data))
        #expect(registry.publishedForwards(guestIP: "192.168.127.2") == [
            forward(.tcp, host: "127.0.0.1", port: 55_120),
            forward(.udp, host: "[::1]", port: 5_353),
        ])
    }

    @Test func sigusr2RepairsLiveDriftAndPublishesValidatedReceipt() throws {
        let previousSIGUSR2Handler = signal(SIGUSR2, SIG_IGN)
        _ = signal(SIGUSR2, previousSIGUSR2Handler)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-port-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = forward(.tcp, host: "127.0.0.1", port: 55_999)
        let orphan = forward(.tcp, host: "127.0.0.1", port: 55_120)
        let registry = ForwardRegistryStub([missing])
        let calls = ForwardCallRecorder()
        let forwarder = makeForwarder(wanted: missing, registry: registry, calls: calls)
        defer {
            forwarder.stop()
            _ = signal(SIGUSR2, previousSIGUSR2Handler)
        }

        #expect(forwarder.reconcileNow().succeeded)
        #expect(calls.operations.isEmpty)
        registry.replace(with: [orphan])

        let request = PublishedPortReconcileRequest(enginePID: getpid())
        let requestURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.requestFilename)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let registration = EngineMode.installPortReconcileSignal(
            portForwarder: forwarder,
            stateDirectory: directory.path
        )
        defer { registration.cancel() }

        #expect(kill(getpid(), SIGUSR2) == 0)
        #expect(calls.waitForOperations(count: 2))
        registration.waitUntilIdle()

        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        let receipt = try JSONDecoder().decode(
            PublishedPortReconcileReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        #expect(receipt.requestID == request.requestID)
        #expect(receipt.enginePID == getpid())
        #expect(receipt.succeeded)
        #expect(receipt.addedForwardCount == 1)
        #expect(receipt.removedForwardCount == 1)
        #expect(registry.forwards == [missing])
        #expect(calls.operations == [.unexpose(orphan), .expose(missing)])
        let permissions = try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        registration.cancel()
        #expect(kill(getpid(), SIGUSR2) == 0)
    }

    @Test func conflictingKeyIsUnexposedBeforeWantedForward() {
        let wanted = forward(.tcp, host: "127.0.0.1", port: 55_999)
        let conflicting = PublishedPortForward(
            protocol: .tcp,
            publishedPort: 55_998,
            localHost: "127.0.0.1",
            localPort: 55_999,
            guestHost: "192.168.127.2",
            guestPort: 55_998
        )
        let registry = ForwardRegistryStub([conflicting])
        let calls = ForwardCallRecorder()
        let forwarder = makeForwarder(wanted: wanted, registry: registry, calls: calls)
        defer { forwarder.stop() }

        let result = forwarder.reconcileNow()

        #expect(result.succeeded)
        #expect(registry.forwards == [wanted])
        #expect(calls.operations == [.unexpose(wanted), .expose(wanted)])
    }

    @Test func machineForwardIsProtectedFromDockerOrphanCleanup() async {
        let machine = forward(.tcp, host: "127.0.0.1", port: 57_000)
        let registry = ForwardRegistryStub()
        let calls = ForwardCallRecorder()
        let forwarder = PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            publishedPortsProvider: { [] },
            registeredForwardsProvider: { registry.snapshot },
            exposeProvider: { forward in
                calls.record(.expose(forward))
                registry.expose(forward)
                return true
            },
            unexposeProvider: { forward in
                calls.record(.unexpose(forward))
                registry.unexpose(forward)
                return true
            }
        )
        defer { forwarder.stop() }

        #expect(await forwarder.exposeMachinePort(57_000))
        #expect(forwarder.reconcileNow().succeeded)
        #expect(registry.forwards == [machine])
        #expect(calls.operations == [.expose(machine)])
    }

    @Test func manualRepairFailsWhenPostMutationRegistryCannotBeRead() {
        let wanted = forward(.tcp, host: "127.0.0.1", port: 55_999)
        let registry = ForwardRegistryStub()
        let calls = ForwardCallRecorder()
        let reads = LockedInt()
        let forwarder = PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            publishedPortsProvider: {
                [PublishedPortBinding(protocol: .tcp, port: wanted.publishedPort, hostIP: "127.0.0.1")]
            },
            registeredForwardsProvider: {
                reads.increment() == 1 ? registry.snapshot : nil
            },
            exposeProvider: { forward in
                calls.record(.expose(forward))
                registry.expose(forward)
                return true
            },
            unexposeProvider: { _ in true }
        )
        defer { forwarder.stop() }

        let result = forwarder.reconcileNow()

        #expect(!result.succeeded)
        #expect(result.error?.contains("could not be read after") == true)
    }

    @Test func nilDockerInventoryFailsClosedWithoutMutatingGvproxy() {
        let registry = ForwardRegistryStub()
        let calls = ForwardCallRecorder()
        let logs = LockedStringList()
        let forwarder = PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { logs.append($0) },
            publishedPortsProvider: { nil },
            registeredForwardsProvider: { registry.snapshot },
            exposeProvider: { forward in
                calls.record(.expose(forward))
                registry.expose(forward)
                return true
            },
            unexposeProvider: { forward in
                calls.record(.unexpose(forward))
                registry.unexpose(forward)
                return true
            }
        )
        defer { forwarder.stop() }

        let result = forwarder.reconcileNow()

        #expect(!result.succeeded)
        #expect(result.error == "Docker published-port inventory is unavailable")
        #expect(result.publishedPortCount == 0)
        #expect(result.desired.isEmpty)
        #expect(result.missing.isEmpty)
        #expect(result.unexpected.isEmpty)
        #expect(calls.operations.isEmpty)
        #expect(registry.forwards.isEmpty)
        #expect(logs.strings.contains("Docker published-port inventory is unavailable"))
    }

    @Test func inProcessContainerListCreatesWantedGvproxyForward() throws {
        let body = #"[{"Id":"abc","Names":["/web"],"State":"running","Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":38099,"Type":"tcp"}]}]"#
        let server = try RepeatingUnixHTTPServer.containersJSON(body)
        defer { server.stop() }
        let wanted = forward(.tcp, host: "127.0.0.1", port: 38_099)
        let registry = ForwardRegistryStub()
        let calls = ForwardCallRecorder()
        let forwarder = PortForwarder(
            engineSocket: server.path,
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            registeredForwardsProvider: { registry.snapshot },
            exposeProvider: { forward in
                calls.record(.expose(forward))
                registry.expose(forward)
                return true
            },
            unexposeProvider: { forward in
                calls.record(.unexpose(forward))
                registry.unexpose(forward)
                return true
            }
        )
        defer { forwarder.stop() }

        let result = forwarder.reconcileNow()

        #expect(result.succeeded)
        #expect(result.publishedPortCount == 1)
        #expect(registry.forwards.contains(wanted))
        #expect(calls.operations == [.expose(wanted)])
        #expect(server.paths.contains(PublishedPortForwardPlan.dockerContainerListPath))
    }

    @Test func malformedRegistryFailsClosed() {
        #expect(GVProxyForwardRegistry.decode(Data("not-json".utf8)) == nil)
        #expect(GVProxyForwardRegistry.decode(Data(#"""
        [{"local":"not-an-endpoint","remote":"192.168.127.2:55999","protocol":"tcp"}]
        """#.utf8)) == nil)
    }

    @Test func scopedIPv6LocalAddressPreservesRegistryIdentity() throws {
        let registry = try #require(GVProxyForwardRegistry.decode(Data(#"""
        [{"local":"[FE80::1%EN0]:55121","remote":"192.168.127.2:55121","protocol":"tcp"}]
        """#.utf8)))

        #expect(registry.publishedForwards(guestIP: "192.168.127.2") == [
            forward(.tcp, host: "[FE80::1%EN0]", port: 55_121),
        ])
    }

    private func makeForwarder(
        wanted: PublishedPortForward,
        registry: ForwardRegistryStub,
        calls: ForwardCallRecorder
    ) -> PortForwarder {
        PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            publishedPortsProvider: {
                [PublishedPortBinding(
                    protocol: wanted.protocol,
                    port: wanted.publishedPort,
                    hostIP: wanted.localHost
                )]
            },
            registeredForwardsProvider: { registry.snapshot },
            exposeProvider: { forward in
                calls.record(.expose(forward))
                registry.expose(forward)
                return true
            },
            unexposeProvider: { forward in
                calls.record(.unexpose(forward))
                registry.unexpose(forward)
                return true
            }
        )
    }

    private func forward(
        _ protocolValue: PublishedPortForwardProtocol,
        host: String,
        port: Int
    ) -> PublishedPortForward {
        PublishedPortForward(
            protocol: protocolValue,
            publishedPort: port,
            localHost: host,
            localPort: port,
            guestHost: "192.168.127.2",
            guestPort: port
        )
    }
}

private final class ForwardRegistryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<PublishedPortForward>

    init(_ forwards: Set<PublishedPortForward> = []) {
        stored = forwards
    }

    var forwards: Set<PublishedPortForward> {
        lock.withLock { stored }
    }

    var snapshot: GVProxyForwardRegistry {
        let rows = lock.withLock {
            stored.map { forward in
                [
                    "local": forward.localEndpoint,
                    "remote": forward.remoteEndpoint,
                    "protocol": forward.protocol.rawValue,
                ]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return GVProxyForwardRegistry.decode(data)!
    }

    func replace(with forwards: Set<PublishedPortForward>) {
        lock.withLock { stored = forwards }
    }

    func expose(_ forward: PublishedPortForward) {
        lock.withLock { _ = stored.insert(forward) }
    }

    func unexpose(_ forward: PublishedPortForward) {
        lock.withLock {
            stored = stored.filter {
                $0.protocol != forward.protocol || $0.localEndpoint != forward.localEndpoint
            }
        }
    }
}

private enum ForwardOperation: Sendable, Equatable {
    case expose(PublishedPortForward)
    case unexpose(PublishedPortForward)
}

private final class ForwardCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var stored: [ForwardOperation] = []

    var operations: [ForwardOperation] {
        lock.withLock { stored }
    }

    func record(_ operation: ForwardOperation) {
        lock.withLock { stored.append(operation) }
        completed.signal()
    }

    func waitForOperations(count: Int) -> Bool {
        for _ in 0..<count {
            guard completed.wait(timeout: .now() + 2) == .success else { return false }
        }
        return true
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() -> Int {
        lock.withLock {
            stored += 1
            return stored
        }
    }
}

private final class LockedStringList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var strings: [String] { lock.withLock { stored } }

    func append(_ value: String) {
        lock.withLock { stored.append(value) }
    }
}

private final class RepeatingUnixHTTPServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let response: Data
    private let queue = DispatchQueue(label: "dev.dory.test.repeating-unix-http")
    private let lock = NSLock()
    private var storedPaths: [String] = []
    private var stopped = false

    var paths: [String] { lock.withLock { storedPaths } }

    static func containersJSON(_ body: String) throws -> RepeatingUnixHTTPServer {
        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return try RepeatingUnixHTTPServer(response: header + body)
    }

    init(response: String) throws {
        let base = "/tmp/dory-port-forward-http-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        path = base + "/server.sock"
        fd = try repeatingUnixBindListener(path: path)
        self.response = Data(response.utf8)
        acceptLoop()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        close(fd)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func acceptLoop() {
        queue.async { [self] in
            while true {
                if lock.withLock({ stopped }) { return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var requestBytes = Data()
        var byte: UInt8 = 0
        while requestBytes.count < 8_192, Darwin.read(client, &byte, 1) == 1 {
            requestBytes.append(byte)
            if requestBytes.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        let request = String(decoding: requestBytes, as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.lock()
        storedPaths.append(path)
        lock.unlock()
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(client, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else { break }
                offset += count
            }
        }
        shutdown(client, SHUT_WR)
    }
}

private enum RepeatingUnixHTTPServerError: Error {
    case syscall(String, Int32)
    case pathTooLong
}

private func repeatingUnixBindListener(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RepeatingUnixHTTPServerError.syscall("socket", errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw RepeatingUnixHTTPServerError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
        let code = errno
        close(fd)
        throw RepeatingUnixHTTPServerError.syscall("bind/listen", code)
    }
    return fd
}
