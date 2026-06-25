import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Dory

@Suite(.serialized)
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

    @Test func kubeServiceProxyBuildsStableServiceRoutes() {
        #expect(KubeServiceProxy.serviceHost(name: "Web", namespace: "Default", suffix: "dory.local") == "web.default.k8s.dory.local")
        #expect(KubeServiceProxy.serviceProxyPath(name: "web", namespace: "default", port: 8080) == "/api/v1/namespaces/default/services/web:8080/proxy")
        #expect(KubeServiceProxy.firstPort(from: "8080/TCP, 8443/TCP") == 8080)
    }

    @Test func kubeServiceBrowserURLFallsBackToKubectlProxy() throws {
        let domainURL = try #require(KubeServiceProxy.browserURL(
            name: "web",
            namespace: "default",
            ports: "80/TCP",
            suffix: "dory.local",
            domainAvailable: true
        ))
        #expect(domainURL.absoluteString == "http://web.default.k8s.dory.local")

        let proxyURL = try #require(KubeServiceProxy.browserURL(
            name: "web",
            namespace: "default",
            ports: "80/TCP",
            suffix: "dory.local",
            domainAvailable: false
        ))
        #expect(proxyURL.absoluteString == "http://127.0.0.1:18001/api/v1/namespaces/default/services/web:80/proxy/")
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

    @Test func unixSocketHTTPHonorsIOTimeoutWhenPeerHangs() async throws {
        let path = Self.shortSocketPath("dory-hung")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 0.05)

        do {
            _ = try await client.send(HTTPRequest(method: "GET", path: "/version"))
            Issue.record("expected hung socket to time out")
        } catch let error as HTTPError {
            guard case .socket(let message) = error else {
                Issue.record("expected socket error, got \(error)")
                return
            }
            #expect(message.contains("read"))
        } catch {
            Issue.record("expected HTTPError, got \(error)")
        }
    }

    private static func shortSocketPath(_ prefix: String) -> String {
        let path = "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: path)
        return path
    }
}

private final class HangingUnixSocket {
    private let path: String
    private let fd: Int32
    private let accepted = DispatchSemaphore(value: 0)
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
        Thread.detachNewThread { [fd, accepted, weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.lock.lock()
            self?.clientFD = client
            self?.lock.unlock()
            accepted.signal()
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
