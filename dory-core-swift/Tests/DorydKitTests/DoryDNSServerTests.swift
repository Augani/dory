import Darwin
@testable import DorydKit
import XCTest

final class DoryDNSServerTests: XCTestCase {
    func testHighPortDNSServerResolvesARecord() throws {
        let server = DoryDNSServer(port: 0, routes: [
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.42"),
        ])
        try server.start()
        defer { server.stop() }

        let response = try queryDNS(hostname: "web.dory.local", port: server.port)

        XCTAssertEqual(response.id, 0x1234)
        XCTAssertEqual(response.rcode, 0)
        XCTAssertEqual(response.answers, ["127.0.0.42"])
    }

    func testHighPortDNSServerReturnsNXDomainForUnknownHost() throws {
        let server = DoryDNSServer(port: 0, routes: [
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.42"),
        ])
        try server.start()
        defer { server.stop() }

        let response = try queryDNS(hostname: "missing.dory.local", port: server.port)

        XCTAssertEqual(response.rcode, 3)
        XCTAssertTrue(response.answers.isEmpty)
    }

    func testKnownHostAAAAIsNoErrorWithoutAnIPv4ShapedAnswer() throws {
        let server = DoryDNSServer(port: 0, routes: [
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.42"),
        ])
        try server.start()
        defer { server.stop() }

        let response = try queryDNS(hostname: "web.dory.local", qtype: 28, port: server.port)

        XCTAssertEqual(response.rcode, 0)
        XCTAssertTrue(response.answers.isEmpty)
    }

    func testRoutesCanBeReplacedWhileRunning() throws {
        let server = DoryDNSServer(port: 0)
        try server.start()
        defer { server.stop() }

        server.updateRoutes([DomainRoute(hostname: "api.dory.local", address: "127.0.0.7")])
        let response = try queryDNS(hostname: "api.dory.local", port: server.port)

        XCTAssertEqual(response.answers, ["127.0.0.7"])
    }
}

private struct DNSParsedResponse {
    var id: UInt16
    var rcode: UInt8
    var answers: [String]
}

private enum DNSTestError: Error {
    case syscall(String, Int32)
    case shortResponse
    case malformedResponse
}

private func queryDNS(hostname: String, qtype: UInt16 = 1, port: UInt16) throws -> DNSParsedResponse {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw DNSTestError.syscall("socket", errno) }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let packet = dnsQuery(hostname: hostname, qtype: qtype)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

    let sent = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            packet.withUnsafeBytes { bytes in
                sendto(fd, bytes.baseAddress!, packet.count, 0, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent == packet.count else { throw DNSTestError.syscall("sendto", errno) }

    var buffer = [UInt8](repeating: 0, count: 512)
    let capacity = buffer.count
    let got = buffer.withUnsafeMutableBytes { raw in
        recv(fd, raw.baseAddress!, capacity, 0)
    }
    guard got >= 12 else {
        throw got < 0 ? DNSTestError.syscall("recv", errno) : DNSTestError.shortResponse
    }
    return try parseDNSResponse(Array(buffer.prefix(got)))
}

private func dnsQuery(hostname: String, qtype: UInt16) -> [UInt8] {
    var out: [UInt8] = []
    appendUInt16(0x1234, to: &out)
    appendUInt16(0x0100, to: &out)
    appendUInt16(1, to: &out)
    appendUInt16(0, to: &out)
    appendUInt16(0, to: &out)
    appendUInt16(0, to: &out)
    for label in hostname.split(separator: ".") {
        out.append(UInt8(label.utf8.count))
        out.append(contentsOf: label.utf8)
    }
    out.append(0)
    appendUInt16(qtype, to: &out)
    appendUInt16(1, to: &out)
    return out
}

private func parseDNSResponse(_ bytes: [UInt8]) throws -> DNSParsedResponse {
    guard bytes.count >= 12 else { throw DNSTestError.shortResponse }
    let id = readUInt16(bytes, 0)
    let flags = readUInt16(bytes, 2)
    let qdcount = readUInt16(bytes, 4)
    let ancount = readUInt16(bytes, 6)
    var offset = 12
    for _ in 0..<qdcount {
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 { break }
            offset += length
        }
        offset += 4
    }
    var answers: [String] = []
    for _ in 0..<ancount {
        guard offset + 16 <= bytes.count else { throw DNSTestError.malformedResponse }
        offset += 2
        let type = readUInt16(bytes, offset)
        offset += 2
        offset += 2
        offset += 4
        let rdlength = Int(readUInt16(bytes, offset))
        offset += 2
        guard offset + rdlength <= bytes.count else { throw DNSTestError.malformedResponse }
        if type == 1, rdlength == 4 {
            answers.append(bytes[offset..<offset + 4].map(String.init).joined(separator: "."))
        }
        offset += rdlength
    }
    return DNSParsedResponse(id: id, rcode: UInt8(flags & 0x000f), answers: answers)
}

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8(value & 0xff))
}
