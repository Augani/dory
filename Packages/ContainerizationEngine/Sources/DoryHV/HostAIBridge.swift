import Darwin
import Foundation

/// Lets Linux containers reach Metal-backed AI services running on macOS loopback.
///
/// The guest agent listens on the Docker host gateway for selected TCP ports and dials the same
/// vsock port back to the host. This host-side bridge accepts that vsock stream and connects it to
/// `127.0.0.1:<port>`, where tools such as Ollama and LM Studio normally bind.
public final class HostAIBridge: @unchecked Sendable {
    /// Single source of truth for the AI-bridge port list. EngineMode serializes this into
    /// DORY_HOST_AI_BRIDGE_PORTS for the Rust guest agent, which mirrors it only as a fallback.
    /// User-facing copy in
    /// SettingsView, DockerShim, and the READMEs also references these numbers; change them in
    /// lockstep if this set ever changes.
    public static let defaultPorts: [UInt16] = [11_434, 1_234, 18_190]

    private let ports: [UInt16]
    private let host: String
    private let log: @Sendable (String) -> Void
    private let lifecycle: BoundedGuestVsockServiceLifecycle

    public init(
        ports: [UInt16] = HostAIBridge.defaultPorts,
        host: String = "127.0.0.1",
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.ports = Array(Set(ports)).sorted()
        self.host = host
        self.log = log
        self.lifecycle = BoundedGuestVsockServiceLifecycle(
            endpointLabel: "host AI bridge",
            log: log
        )
    }

    public func attach(to vsock: VirtioVsock) throws {
        try lifecycle.beginAttachment(to: vsock)
        var unregister = [@Sendable () -> Void]()
        do {
            let host = self.host
            let log = self.log
            for port in ports {
                let registration = try vsock.registerServiceListener(
                    port: UInt32(port),
                    service: .hostAI
                ) { [weak lifecycle] connection in
                    guard let lifecycle else {
                        connection.close()
                        return
                    }
                    lifecycle.admit(connection) { connection, completion in
                        GuestVsockHostSocketRelaySession(
                            connection: connection,
                            connector: { session in
                                let descriptor = Self.connectTCP(
                                    host: host,
                                    port: port,
                                    context: session
                                )
                                if descriptor == nil {
                                    log("host AI bridge could not connect to \(host):\(port)")
                                }
                                return descriptor
                            },
                            completion: completion
                        )
                    }
                }
                unregister.append { registration.close() }
            }
            guard lifecycle.commitAttachment(unregister: unregister) else {
                throw VMError.invalidConfiguration(
                    "host AI bridge stopped while attaching"
                )
            }
        } catch {
            lifecycle.cancelAttachment(unregister: unregister)
            throw error
        }
        if !ports.isEmpty {
            log("host AI bridge ready on ports \(ports.map(String.init).joined(separator: ","))")
        }
    }

    public func stop(timeout: TimeInterval = 1) {
        lifecycle.stop(timeout: timeout)
    }

    public var activeSessionCount: Int {
        lifecycle.activeSessionCount
    }

    public var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot? {
        lifecycle.serviceAdmissionSnapshot
    }

    deinit {
        lifecycle.stop()
    }

    static func connectTCP(
        host: String,
        port: UInt16,
        timeoutMilliseconds: Int32 = 2_000
    ) -> Int32? {
        connectTCP(
            host: host,
            port: port,
            timeoutMilliseconds: timeoutMilliseconds,
            context: UncancelledHostSocketConnectContext()
        )
    }

    private static func connectTCP(
        host: String,
        port: UInt16,
        timeoutMilliseconds: Int32 = 2_000,
        context: any BoundedHostSocketConnectContext
    ) -> Int32? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return BoundedHostSocketConnector.connect(
            domain: AF_INET,
            timeout: TimeInterval(max(0, timeoutMilliseconds)) / 1_000,
            context: context,
            initiate: { descriptor in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            },
            verify: { descriptor in
                var peer = sockaddr_in()
                var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let result = withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getpeername(descriptor, $0, &peerLength)
                    }
                }
                return result == 0
                    && peer.sin_family == sa_family_t(AF_INET)
                    && peer.sin_port == address.sin_port
                    && peer.sin_addr.s_addr == address.sin_addr.s_addr
            }
        )
    }
}
