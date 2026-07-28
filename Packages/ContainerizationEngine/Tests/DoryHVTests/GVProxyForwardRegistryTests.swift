import Foundation
import Testing
@testable import DoryHV
@testable import dory_hv

@Suite(.serialized) struct GVProxyForwardRegistryTests {
    @Test func decodesOnlyContainerPublishedForwardsFromBundledGVProxyRegistry() throws {
        let data = Data(#"""
        [
          {"local":"127.0.0.1:2222","remote":"192.168.127.2:22","protocol":"tcp"},
          {"local":"127.0.0.1:55120","remote":"192.168.127.2:55120","protocol":"tcp"},
          {"local":"[::1]:5353","remote":"192.168.127.2:5353","protocol":"udp"},
          {"local":"/tmp/dory.sock","remote":"tcp://192.168.127.2:2377","protocol":"unix"}
        ]
        """#.utf8)

        #expect(GVProxyForwardRegistry.publishedForwards(
            from: data,
            guestIP: "192.168.127.2"
        ) == [
            forward(.tcp, host: "127.0.0.1", port: 55_120),
            forward(.udp, host: "[::1]", port: 5_353),
        ])
    }

    @Test func sigusr2RepairsMissingAndOrphanedForwardsUsingActualGVProxyState() {
        let previousSIGUSR2Handler = signal(SIGUSR2, SIG_IGN)
        _ = signal(SIGUSR2, previousSIGUSR2Handler)
        let missing = forward(.tcp, host: "127.0.0.1", port: 55_999)
        let orphan = forward(.tcp, host: "127.0.0.1", port: 55_120)
        let calls = ForwardCallRecorder()
        let registry = ForwardRegistryStub([missing])
        let forwarder = PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            publishedPortsProvider: {
                [PublishedPortBinding(
                    protocol: .tcp,
                    port: missing.publishedPort,
                    hostIP: "127.0.0.1"
                )]
            },
            registeredForwardsProvider: { registry.current },
            exposeProvider: { calls.recordExpose($0); return true },
            unexposeProvider: { calls.recordUnexpose($0); return true }
        )
        defer {
            _ = signal(SIGUSR2, previousSIGUSR2Handler)
            forwarder.stop()
        }

        // Seed the forwarder's in-memory cache while Docker and gvproxy agree. Then mutate only
        // gvproxy to reproduce issue #45: the desired forward disappears behind the stale cache,
        // while an unrelated orphan appears without ever entering that cache.
        forwarder.reconcileNow()
        #expect(calls.exposed.isEmpty)
        #expect(calls.unexposed.isEmpty)

        registry.current = [orphan]
        let signalRegistration = EngineMode.installPortReconcileSignal(portForwarder: forwarder)
        #expect(kill(getpid(), SIGUSR2) == 0)
        #expect(calls.waitForOperations(count: 2))
        signalRegistration.waitUntilIdle()

        #expect(calls.exposed == [missing])
        #expect(calls.unexposed == [orphan])

        signalRegistration.cancel()
        #expect(kill(getpid(), SIGUSR2) == 0)
    }

    @Test func machineForwardOwnershipIsSerializedAndProtectedFromDockerCleanup() async {
        let machine = forward(.tcp, host: "127.0.0.1", port: 57_000)
        let calls = ForwardCallRecorder()
        let forwarder = PortForwarder(
            engineSocket: "/unused/engine.sock",
            apiSocket: "/unused/gvproxy.sock",
            guestIP: "192.168.127.2",
            log: { _ in },
            publishedPortsProvider: { [] },
            registeredForwardsProvider: { [machine] },
            exposeProvider: { calls.recordExpose($0); return true },
            unexposeProvider: { calls.recordUnexpose($0); return true }
        )

        forwarder.start()
        #expect(await forwarder.exposeMachinePort(57_000))
        forwarder.reconcileNow()

        #expect(calls.exposed == [machine])
        #expect(calls.unexposed.isEmpty)
    }

    @Test func malformedRegistryFailsClosed() {
        #expect(GVProxyForwardRegistry.publishedForwards(
            from: Data("not-json".utf8),
            guestIP: "192.168.127.2"
        ) == nil)
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

    init(_ forwards: Set<PublishedPortForward>) {
        stored = forwards
    }

    var current: Set<PublishedPortForward> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ForwardCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let operationCompleted = DispatchSemaphore(value: 0)
    private var storedExposed = Set<PublishedPortForward>()
    private var storedUnexposed = Set<PublishedPortForward>()

    var exposed: Set<PublishedPortForward> {
        lock.withLock { storedExposed }
    }

    var unexposed: Set<PublishedPortForward> {
        lock.withLock { storedUnexposed }
    }

    func recordExpose(_ forward: PublishedPortForward) {
        _ = lock.withLock { storedExposed.insert(forward) }
        operationCompleted.signal()
    }

    func recordUnexpose(_ forward: PublishedPortForward) {
        _ = lock.withLock { storedUnexposed.insert(forward) }
        operationCompleted.signal()
    }

    func waitForOperations(count: Int) -> Bool {
        for _ in 0..<count {
            guard operationCompleted.wait(timeout: .now() + 2) == .success else {
                return false
            }
        }
        return true
    }
}
