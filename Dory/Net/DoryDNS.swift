import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A minimal UDP DNS resolver that answers `*.<suffix>` (default `*.dory.local`) with the loopback
/// address, so container domains resolve to the host where Dory's reverse proxy is listening. Exact
/// host overrides let machine names resolve to their guest IPs while other names keep using loopback.
/// Non-matching queries are refused so the system resolver falls through to real DNS.
///
/// Binds an unprivileged port by default (validated end to end); production binds :53 and adds an
/// `/etc/resolver/<suffix>` entry, which is the consent-gated system change.
final class DoryDNS: @unchecked Sendable {
    let suffix: String
    let address: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var hostIPs: [String: String] = [:]

    init(suffix: String = "dory.local", address: String = "127.0.0.1") {
        self.suffix = suffix.lowercased()
        self.address = address
    }

    func start(port: UInt16) throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw DNSError.socket("socket") }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(socketFD); throw DNSError.socket("bind :\(port)") }
        lock.lock(); fd = socketFD; running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.serve(socketFD) }
    }

    func stop() {
        lock.lock(); running = false; let socketFD = fd; fd = -1; lock.unlock()
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    func replaceHostIPs(_ entries: [String: String]) {
        let normalized = entries.reduce(into: [String: String]()) { result, pair in
            let host = Self.normalizeHost(pair.key)
            guard !host.isEmpty, Self.ipv4Bytes(pair.value) != nil else { return }
            result[host] = pair.value
        }
        lock.lock(); hostIPs = normalized; lock.unlock()
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func serve(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512)
        while isRunning() {
            var client = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &client) { sptr in
                sptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { caddr in
                    recvfrom(socketFD, &buffer, buffer.count, 0, caddr, &clientLen)
                }
            }
            if n <= 0 { if isRunning() { continue } else { break } }
            let overrides = currentHostIPs()
            guard let response = Self.makeResponse(Array(buffer[0..<n]), suffix: suffix, ip: address, hostIPs: overrides) else { continue }
            _ = response.withUnsafeBytes { raw in
                withUnsafeMutablePointer(to: &client) { sptr in
                    sptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { caddr in
                        sendto(socketFD, raw.baseAddress, raw.count, 0, caddr, clientLen)
                    }
                }
            }
        }
    }

    /// Build a DNS answer for an A query whose name ends with the suffix; nil otherwise.
    nonisolated static func makeResponse(_ query: [UInt8], suffix: String, ip: String) -> [UInt8]? {
        makeResponse(query, suffix: suffix, ip: ip, hostIPs: [:])
    }

    /// Build a DNS answer for an A query whose name ends with the suffix; nil otherwise.
    /// `hostIPs` is an exact-name override table for guests that should resolve directly.
    nonisolated static func makeResponse(_ query: [UInt8], suffix: String, ip: String, hostIPs: [String: String]) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        let qdcount = (Int(query[4]) << 8) | Int(query[5])
        guard qdcount >= 1 else { return nil }

        var index = 12
        var labels: [String] = []
        while index < query.count {
            let length = Int(query[index]); index += 1
            if length == 0 { break }
            guard length <= 63, index + length <= query.count else { return nil }
            labels.append(String(bytes: query[index..<index + length], encoding: .utf8) ?? "")
            index += length
        }
        guard index + 4 <= query.count else { return nil }
        let qtype = (Int(query[index]) << 8) | Int(query[index + 1])
        let name = labels.joined(separator: ".").lowercased()
        // Only answer A/AAAA queries inside our suffix; refuse everything else so DNS falls through.
        guard name.hasSuffix(suffix), qtype == 1 || qtype == 28 else { return nil }
        let answerIP = hostIPs[normalizeHost(name)] ?? ip
        guard ipv4Bytes(answerIP) != nil else { return nil }
        let questionEnd = index + 4

        var response = [UInt8]()
        response.append(query[0]); response.append(query[1])     // ID
        response.append(0x81); response.append(0x80)             // flags: response, RD, RA
        response.append(0x00); response.append(0x01)             // QDCOUNT
        // AAAA gets 0 answers (we only serve IPv4 loopback), A gets 1.
        let answerCount: UInt8 = qtype == 1 ? 1 : 0
        response.append(0x00); response.append(answerCount)      // ANCOUNT
        response.append(0x00); response.append(0x00)             // NSCOUNT
        response.append(0x00); response.append(0x00)             // ARCOUNT
        response.append(contentsOf: query[12..<questionEnd])     // echo the question

        if qtype == 1 {
            response.append(0xC0); response.append(0x0C)         // NAME pointer → offset 12
            response.append(0x00); response.append(0x01)         // TYPE A
            response.append(0x00); response.append(0x01)         // CLASS IN
            response.append(contentsOf: [0x00, 0x00, 0x00, 0x1E]) // TTL 30s
            response.append(0x00); response.append(0x04)         // RDLENGTH 4
            response.append(contentsOf: ipv4Bytes(answerIP) ?? [0, 0, 0, 0])
        }
        return response
    }

    private func currentHostIPs() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return hostIPs
    }

    nonisolated static func normalizeHost(_ host: String) -> String {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
    }

    nonisolated static func ipv4Bytes(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    enum DNSError: Error, Sendable { case socket(String) }
}
