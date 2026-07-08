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

    public init(
        ports: [UInt16] = HostAIBridge.defaultPorts,
        host: String = "127.0.0.1",
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.ports = Array(Set(ports)).sorted()
        self.host = host
        self.log = log
    }

    public func attach(to vsock: VirtioVsock) {
        for port in ports {
            vsock.listen(port: UInt32(port)) { [self] connection in
                let box = ConnectionBox(connection)
                Thread.detachNewThread {
                    self.serve(connection: box.connection, port: port)
                }
            }
        }
        if !ports.isEmpty {
            log("host AI bridge ready on ports \(ports.map(String.init).joined(separator: ","))")
        }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection

        init(_ connection: VsockConnection) {
            self.connection = connection
        }
    }

    private func serve(connection: VsockConnection, port: UInt16) {
        guard let upstream = Self.connectTCP(host: host, port: port) else {
            log("host AI bridge could not connect to \(host):\(port)")
            connection.close()
            return
        }
        defer {
            connection.close()
            shutdown(upstream, SHUT_RDWR)
            close(upstream)
        }

        let group = DispatchGroup()
        group.enter()
        let box = ConnectionBox(connection)
        Thread.detachNewThread {
            Self.pumpTCPToVsock(from: upstream, to: box.connection)
            group.leave()
        }
        Self.pumpVsockToTCP(from: connection, to: upstream)
        // The guest has stopped sending the request: half-close only the write side to the upstream
        // so it sees request-EOF while the reply keeps streaming back on the other pump. The defer
        // does the full teardown once pumpTCPToVsock has drained the response.
        shutdown(upstream, SHUT_WR)
        group.wait()
    }

    private static func pumpTCPToVsock(from fd: Int32, to connection: VsockConnection) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
            if count <= 0 { break }
            do {
                try connection.write(Array(buffer.prefix(count)))
            } catch {
                break
            }
        }
    }

    private static func pumpVsockToTCP(from connection: VsockConnection, to fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var pollInterval: useconds_t = 1_000
        let maxPollInterval: useconds_t = 16_000
        while true {
            let capacity = buffer.count
            let count = (try? buffer.withUnsafeMutableBytes {
                try connection.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<capacity]))
            }) ?? 0
            if count == 0 {
                if connection.isPeerClosed { break }
                usleep(pollInterval)
                pollInterval = min(pollInterval * 2, maxPollInterval)
                continue
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(fd, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written <= 0 { return }
                offset += written
            }
            pollInterval = 1_000
        }
    }

    private static func connectTCP(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
