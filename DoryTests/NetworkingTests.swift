import Testing
import Foundation
@testable import Dory

struct NetworkingTests {
    private func dnsQuery(name: String, qtype: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)
        packet.append(contentsOf: [0x00, qtype, 0x00, 0x01])
        return packet
    }

    @Test func dnsAnswersDomainSuffixWithLoopback() throws {
        let query = dnsQuery(name: "myapp.dory.local", qtype: 1)
        let response = try #require(DoryDNS.makeResponse(query, suffix: "dory.local", ip: "127.0.0.1"))
        #expect(response[0] == 0x12 && response[1] == 0x34)          // echoed ID
        #expect(response[2] & 0x80 != 0)                              // QR = response
        #expect(response[7] == 0x01)                                  // ANCOUNT = 1
        #expect(Array(response.suffix(4)) == [127, 0, 0, 1])          // A record RDATA
    }

    @Test func dnsRefusesForeignDomains() {
        #expect(DoryDNS.makeResponse(dnsQuery(name: "google.com", qtype: 1), suffix: "dory.local", ip: "127.0.0.1") == nil)
    }

    @Test func dnsReturnsNoAnswerForAAAA() throws {
        let response = try #require(DoryDNS.makeResponse(dnsQuery(name: "myapp.dory.local", qtype: 28), suffix: "dory.local", ip: "127.0.0.1"))
        #expect(response[7] == 0x00)                                  // ANCOUNT = 0 (we only serve A)
    }

    @Test func reverseProxyExtractsHost() {
        let request = Data("GET /path HTTP/1.1\r\nHost: MyApp.dory.local:8080\r\nAccept: */*\r\n\r\n".utf8)
        #expect(DoryReverseProxy.hostHeader(request) == "myapp.dory.local")
    }

    @Test func reverseProxyMissingHostIsNil() {
        let request = Data("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n".utf8)
        #expect(DoryReverseProxy.hostHeader(request) == nil)
    }

    @Test func domainTableRoutesToLoopbackPort() {
        let table = DomainTable()
        table.replaceContainers(["myapp.dory.local": 8091])
        let backend = table.backend(for: "MyApp.dory.local")
        #expect(backend?.host == "127.0.0.1")
        #expect(backend?.port == 8091)
        #expect(backend?.pathPrefix == "")
        #expect(table.backend(for: "other.dory.local") == nil)
    }

    @Test func domainTableRoutesKubeServices() {
        let table = DomainTable()
        table.replaceKube(["web.default.k8s.dory.local": ProxyBackend(host: "127.0.0.1", port: 18001, pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy")])
        let backend = table.backend(for: "web.default.k8s.dory.local")
        #expect(backend?.port == 18001)
        #expect(backend?.pathPrefix.contains("services/web:80/proxy") == true)
    }

    @Test func rewriteRequestPrependsPathPrefix() {
        let request = Data("GET /healthz HTTP/1.1\r\nHost: web.default.k8s.dory.local\r\n\r\n".utf8)
        let rewritten = DoryReverseProxy.rewriteRequest(request, pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy")
        let text = String(data: rewritten, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("GET /api/v1/namespaces/default/services/web:80/proxy/healthz HTTP/1.1\r\n"))
        #expect(text.contains("Host: web.default.k8s.dory.local"))
    }

    @Test func volumeBrowserParsesListing() {
        let output = """
        total 8
        drwxr-xr-x    2 root     root          4096 2026-06-18 11:31:05 +0000 logs
        -rw-r--r--    1 root     root            23 2026-06-18 11:31:05 +0000 readme.txt
        """
        let entries = VolumeBrowser.parseListing(output)
        #expect(entries.count == 2)
        #expect(entries.first?.name == "logs")          // directories sort first
        #expect(entries.first?.isDirectory == true)
        #expect(entries.last?.name == "readme.txt")
        #expect(entries.last?.isDirectory == false)
    }

    @Test func volumeBrowserPathIsSandboxed() {
        #expect(VolumeBrowser.safePath("../../etc/passwd") == "/data/etc/passwd")
        #expect(VolumeBrowser.safePath("/logs/app.log") == "/data/logs/app.log")
        #expect(VolumeBrowser.safePath("") == "/data/")
    }
}
